package main

import (
	"bytes"
	"compress/zlib"
	"encoding/binary"
	"log"
	"time"
)

const tile = 64

// updateLoop answers the viewer's update requests: it polls the screen, finds the 64×64
// tiles that changed since the viewer's copy, and sends them ZRLE-compressed. Like macOS
// Screen Sharing it only sends after being asked, so a slow phone is never flooded.
func (ss *session) updateLoop(done <-chan struct{}) {
	interval := 40 * time.Millisecond
	t := time.NewTimer(0)
	defer t.Stop()
	for {
		select {
		case <-done:
			return
		case <-ss.wake:
		case <-t.C:
		}
		sent, err := ss.tryUpdate()
		if err != nil {
			select {
			case <-done: // viewer already gone
			default:
				log.Printf("update failed: %v", err)
			}
			ss.conn.Close()
			return
		}
		// Poll faster while things are moving, slower when the screen is still.
		if sent {
			interval = 25 * time.Millisecond
		} else if interval < 80*time.Millisecond {
			interval += 5 * time.Millisecond
		}
		t.Reset(interval)
	}
}

// tryUpdate sends one FramebufferUpdate if there is a request and something to send.
func (ss *session) tryUpdate() (bool, error) {
	ss.mu.Lock()
	if !ss.pending {
		ss.mu.Unlock()
		return false, nil
	}
	full := ss.full
	ss.pending, ss.full = false, nil
	pf, zrle, cursorEnc, ext, dsize := ss.pf, ss.zrle, ss.cursorEnc, ss.extDesktop, ss.desktopSize
	curSer := ss.cursorSer
	ss.mu.Unlock()

	s := ss.srv
	s.capMu.Lock()
	defer s.capMu.Unlock()

	img, w, h, err := s.plat.Capture()
	if err != nil {
		// Usually the secure desktop (UAC prompt, lock screen): keep the last picture.
		ss.repend(full)
		return false, nil
	}

	var body bytes.Buffer
	count := 0

	resized := w != ss.fbW || h != ss.fbH
	if resized {
		if !ext && !dsize {
			// Viewer can't resize; keep its size and send what fits.
			w, h = min(w, ss.fbW), min(h, ss.fbH)
		} else {
			ss.fbW, ss.fbH = w, h
			ss.sent = nil
			if !ext {
				writeRectHeader(&body, 0, 0, w, h, encDesktopSize)
				count++
			}
		}
	}
	if ext {
		mons := s.plat.Monitors()
		if resized || !sameRects(mons, ss.sentMonitor) {
			writeRectHeader(&body, 0, 0, ss.fbW, ss.fbH, encExtDesktop)
			body.WriteByte(byte(len(mons)))
			body.Write([]byte{0, 0, 0})
			for i, m := range mons {
				binary.Write(&body, binary.BigEndian, uint32(i+1))
				for _, v := range []int{m.X, m.Y, m.W, m.H} {
					binary.Write(&body, binary.BigEndian, uint16(v))
				}
				binary.Write(&body, binary.BigEndian, uint32(0))
			}
			ss.sentMonitor = mons
			count++
		}
	}
	if cursorEnc {
		cur, ser := s.plat.Cursor()
		if ser != curSer {
			writeCursor(&body, cur, pf)
			ss.mu.Lock()
			ss.cursorSer = ser
			ss.mu.Unlock()
			count++
		}
	}

	stride := w * 4
	fbStride := ss.fbW * 4
	if len(ss.sent) != ss.fbW*ss.fbH*4 {
		ss.sent = make([]byte, ss.fbW*ss.fbH*4)
		full = &Rect{0, 0, ss.fbW, ss.fbH}
	}
	tw, th := (w+tile-1)/tile, (h+tile-1)/tile
	for ty := 0; ty < th; ty++ {
		y0 := ty * tile
		rh := min(tile, h-y0)
		runStart := -1
		flush := func(end int) {
			if runStart < 0 {
				return
			}
			x0 := runStart * tile
			rw := min(end*tile, w) - x0
			if zrle {
				ss.writeZRLE(&body, img, stride, x0, y0, rw, rh, pf)
			} else {
				writeRaw(&body, img, stride, x0, y0, rw, rh, pf)
			}
			for row := y0; row < y0+rh; row++ {
				copy(ss.sent[row*fbStride+x0*4:row*fbStride+(x0+rw)*4], img[row*stride+x0*4:row*stride+(x0+rw)*4])
			}
			count++
			runStart = -1
		}
		for tx := 0; tx < tw; tx++ {
			x0 := tx * tile
			rw := min(tile, w-x0)
			dirty := full != nil && overlaps(*full, Rect{x0, y0, rw, rh})
			if !dirty {
				for row := y0; row < y0+rh; row++ {
					a := img[row*stride+x0*4 : row*stride+(x0+rw)*4]
					b := ss.sent[row*fbStride+x0*4 : row*fbStride+(x0+rw)*4]
					if !bytes.Equal(a, b) {
						dirty = true
						break
					}
				}
			}
			if dirty {
				if runStart < 0 {
					runStart = tx
				}
			} else {
				flush(tx)
			}
		}
		flush(tw)
	}

	if count == 0 && full == nil {
		ss.repend(nil) // nothing changed yet; keep the request open
		return false, nil
	}
	msg := make([]byte, 4, 4+body.Len())
	msg[0] = 0
	binary.BigEndian.PutUint16(msg[2:], uint16(count))
	msg = append(msg, body.Bytes()...)
	ss.wmu.Lock()
	ss.conn.SetWriteDeadline(time.Now().Add(60 * time.Second))
	_, err = ss.conn.Write(msg)
	ss.wmu.Unlock()
	return true, err
}

func (ss *session) repend(full *Rect) {
	ss.mu.Lock()
	ss.pending = true
	if full != nil {
		if ss.full == nil {
			ss.full = full
		} else {
			u := union(*ss.full, *full)
			ss.full = &u
		}
	}
	ss.mu.Unlock()
}

func overlaps(a, b Rect) bool {
	return a.X < b.X+b.W && b.X < a.X+a.W && a.Y < b.Y+b.H && b.Y < a.Y+a.H
}

func sameRects(a, b []Rect) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func writeRectHeader(b *bytes.Buffer, x, y, w, h int, enc int32) {
	var hdr [12]byte
	binary.BigEndian.PutUint16(hdr[0:], uint16(x))
	binary.BigEndian.PutUint16(hdr[2:], uint16(y))
	binary.BigEndian.PutUint16(hdr[4:], uint16(w))
	binary.BigEndian.PutUint16(hdr[6:], uint16(h))
	binary.BigEndian.PutUint32(hdr[8:], uint32(enc))
	b.Write(hdr[:])
}

func putPixel(b *bytes.Buffer, pf pixelFormat, p uint32) {
	if pf.bigEndian {
		b.Write([]byte{byte(p >> 24), byte(p >> 16), byte(p >> 8), byte(p)})
	} else {
		b.Write([]byte{byte(p), byte(p >> 8), byte(p >> 16), byte(p >> 24)})
	}
}

func writeRaw(b *bytes.Buffer, img []byte, stride, x, y, w, h int, pf pixelFormat) {
	writeRectHeader(b, x, y, w, h, encRaw)
	for row := y; row < y+h; row++ {
		o := row*stride + x*4
		for i := 0; i < w; i++ {
			p := img[o+i*4:]
			putPixel(b, pf, pf.pixel(p[0], p[1], p[2]))
		}
	}
}

func writeCursor(b *bytes.Buffer, c *Cursor, pf pixelFormat) {
	if c == nil || c.W == 0 || c.H == 0 {
		writeRectHeader(b, 0, 0, 0, 0, encCursor) // hidden pointer
		return
	}
	writeRectHeader(b, c.HotX, c.HotY, c.W, c.H, encCursor)
	for i := 0; i < c.W*c.H; i++ {
		p := c.BGRA[i*4:]
		putPixel(b, pf, pf.pixel(p[0], p[1], p[2]))
	}
	rowBytes := (c.W + 7) / 8
	for y := 0; y < c.H; y++ {
		row := make([]byte, rowBytes)
		for x := 0; x < c.W; x++ {
			if c.BGRA[(y*c.W+x)*4+3] >= 128 {
				row[x/8] |= 0x80 >> (x % 8)
			}
		}
		b.Write(row)
	}
}

// ---------------------------------------------------------------------------------------
// ZRLE (RFC 6143 §7.7.6): 64×64 tiles, each solid, palette-packed, RLE, or raw, all through
// one zlib stream that lasts the whole connection.

func (ss *session) writeZRLE(b *bytes.Buffer, img []byte, stride, x, y, w, h int, pf pixelFormat) {
	if ss.zw == nil {
		ss.zw, _ = zlib.NewWriterLevel(&ss.zbuf, zlib.BestSpeed)
	}
	var e zrleEnc
	e.pf = pf
	e.cpx = 3
	e.native = pf.native()
	if !e.native {
		fitsLow := uint32(pf.rMax)<<pf.rShift|uint32(pf.gMax)<<pf.gShift|uint32(pf.bMax)<<pf.bShift < 1<<24
		if !fitsLow || pf.depth > 24 {
			e.cpx = 4
		}
	}
	for ty := y; ty < y+h; ty += tile {
		th := min(tile, y+h-ty)
		for tx := x; tx < x+w; tx += tile {
			e.tile(img, stride, tx, ty, min(tile, x+w-tx), th)
		}
	}
	ss.zbuf.Reset()
	ss.zw.Write(e.out)
	ss.zw.Flush()
	writeRectHeader(b, x, y, w, h, encZRLE)
	binary.Write(b, binary.BigEndian, uint32(ss.zbuf.Len()))
	b.Write(ss.zbuf.Bytes())
}

type zrleEnc struct {
	pf     pixelFormat
	native bool
	cpx    int
	out    []byte
	px     [tile * tile]uint32
	pal    [127]uint32
	keys   [256]uint32
	idx    [256]int8
}

func (e *zrleEnc) cpixel(p uint32) {
	switch {
	case e.cpx == 4 && e.pf.bigEndian:
		e.out = append(e.out, byte(p>>24), byte(p>>16), byte(p>>8), byte(p))
	case e.cpx == 4:
		e.out = append(e.out, byte(p), byte(p>>8), byte(p>>16), byte(p>>24))
	case e.pf.bigEndian:
		e.out = append(e.out, byte(p>>16), byte(p>>8), byte(p))
	default:
		e.out = append(e.out, byte(p), byte(p>>8), byte(p>>16))
	}
}

func (e *zrleEnc) runLen(n int) {
	n--
	for n >= 255 {
		e.out = append(e.out, 255)
		n -= 255
	}
	e.out = append(e.out, byte(n))
}

func (e *zrleEnc) tile(img []byte, stride, x, y, w, h int) {
	n := w * h
	px := e.px[:n]
	i := 0
	for row := y; row < y+h; row++ {
		o := row*stride + x*4
		for col := 0; col < w; col++ {
			p := img[o : o+4]
			if e.native {
				px[i] = uint32(p[0]) | uint32(p[1])<<8 | uint32(p[2])<<16
			} else {
				px[i] = e.pf.pixel(p[0], p[1], p[2])
			}
			o += 4
			i++
		}
	}

	// Palette (up to 127 colours) via a small open-addressing table.
	for k := range e.idx {
		e.idx[k] = -1
	}
	ncol := 0
	runs := 0
	rleBytes := 0 // plain RLE payload size
	for j := 0; j < n; {
		c := px[j]
		r := 1
		for j+r < n && px[j+r] == c {
			r++
		}
		runs++
		rleBytes += e.cpx + (r-1)/255 + 1
		if ncol <= 127 {
			h := (c * 2654435761) >> 24
			for {
				if e.idx[h] < 0 {
					if ncol < 127 {
						e.idx[h] = int8(ncol)
						e.keys[h] = c
						e.pal[ncol] = c
					}
					ncol++
					break
				}
				if e.keys[h] == c {
					break
				}
				h = (h + 1) & 255
			}
		}
		j += r
	}

	if ncol == 1 {
		e.out = append(e.out, 1)
		e.cpixel(px[0])
		return
	}
	best, mode := n*e.cpx, 0 // raw
	if rleBytes < best {
		best, mode = rleBytes, 128
	}
	if ncol <= 127 {
		palRLE := ncol*e.cpx + runs // each run: index byte (+ length when > 1)
		for j := 0; j < n; {
			r := 1
			for j+r < n && px[j+r] == px[j] {
				r++
			}
			if r > 1 {
				palRLE += (r-1)/255 + 1
			}
			j += r
		}
		if palRLE < best {
			best, mode = palRLE, 130
		}
	}
	if ncol <= 16 {
		bits := 4
		if ncol == 2 {
			bits = 1
		} else if ncol <= 4 {
			bits = 2
		}
		packed := ncol*e.cpx + h*((w*bits+7)/8)
		if packed <= best {
			best, mode = packed, 2
		}
	}
	look := func(c uint32) int {
		h := (c * 2654435761) >> 24
		for e.keys[h] != c || e.idx[h] < 0 {
			h = (h + 1) & 255
		}
		return int(e.idx[h])
	}

	switch mode {
	case 0:
		e.out = append(e.out, 0)
		for _, c := range px {
			e.cpixel(c)
		}
	case 128:
		e.out = append(e.out, 128)
		for j := 0; j < n; {
			r := 1
			for j+r < n && px[j+r] == px[j] {
				r++
			}
			e.cpixel(px[j])
			e.runLen(r)
			j += r
		}
	case 130:
		e.out = append(e.out, byte(128+ncol))
		for k := 0; k < ncol; k++ {
			e.cpixel(e.pal[k])
		}
		for j := 0; j < n; {
			r := 1
			for j+r < n && px[j+r] == px[j] {
				r++
			}
			ix := byte(look(px[j]))
			if r == 1 {
				e.out = append(e.out, ix)
			} else {
				e.out = append(e.out, ix|128)
				e.runLen(r)
			}
			j += r
		}
	case 2:
		e.out = append(e.out, byte(ncol))
		for k := 0; k < ncol; k++ {
			e.cpixel(e.pal[k])
		}
		bits := 4
		if ncol == 2 {
			bits = 1
		} else if ncol <= 4 {
			bits = 2
		}
		for row := 0; row < h; row++ {
			var cur byte
			nb := 0
			for col := 0; col < w; col++ {
				cur = cur<<bits | byte(look(px[row*w+col]))
				nb += bits
				if nb == 8 {
					e.out = append(e.out, cur)
					cur, nb = 0, 0
				}
			}
			if nb > 0 {
				e.out = append(e.out, cur<<(8-nb))
			}
		}
	}
}
