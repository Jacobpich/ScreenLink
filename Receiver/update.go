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
		ss.drainWake()
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
		// Poll faster while things are moving, slower when the screen is still, and fastest
		// right after the viewer clicks, types or scrolls, so the result shows up at once.
		if sent {
			interval = 20 * time.Millisecond
		} else if interval < 80*time.Millisecond {
			interval += 5 * time.Millisecond
		}
		next := interval
		if time.Since(time.Unix(0, ss.lastInput.Load())) < 600*time.Millisecond {
			next = min(next, 10*time.Millisecond)
		}
		t.Reset(next)
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
	pf, zrle, copyRect, cursorEnc, ext, dsize := ss.pf, ss.zrle, ss.copyRect, ss.cursorEnc, ss.extDesktop, ss.desktopSize
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

	// Which 64×64 tiles differ from the viewer's copy.
	dirtyTile := make([]bool, tw*th)
	tileDirty := func(tx, ty int) bool {
		x0, y0 := tx*tile, ty*tile
		rw, rh := min(tile, w-x0), min(tile, h-y0)
		if full != nil && overlaps(*full, Rect{x0, y0, rw, rh}) {
			return true
		}
		for row := y0; row < y0+rh; row++ {
			if !bytes.Equal(img[row*stride+x0*4:row*stride+(x0+rw)*4], ss.sent[row*fbStride+x0*4:row*fbStride+(x0+rw)*4]) {
				return true
			}
		}
		return false
	}
	nDirty := 0
	for i := range dirtyTile {
		dirtyTile[i] = tileDirty(i%tw, i/tw)
		if dirtyTile[i] {
			nDirty++
		}
	}

	// Scrolling: if most of a big changed area is the old picture moved up or down, tell the
	// viewer to move the pixels it already has (CopyRect) and send only what's new. A scroll
	// then costs a strip of new content instead of the whole window.
	if copyRect && (full == nil || full.W*full.H < w*h/4) && w == ss.fbW && h == ss.fbH && nDirty*tile*tile >= 120_000 {
		bx0, by0, bx1, by1 := tw, th, -1, -1
		for i, d := range dirtyTile {
			if d {
				tx, ty := i%tw, i/tw
				bx0, by0, bx1, by1 = min(bx0, tx), min(by0, ty), max(bx1, tx), max(by1, ty)
			}
		}
		area := Rect{bx0 * tile, by0 * tile, min((bx1+1)*tile, w) - bx0*tile, min((by1+1)*tile, h) - by0*tile}
		if dst, srcY, ok := detectScroll(img, ss.sent, stride, area); ok {
			writeRectHeader(&body, dst.X, dst.Y, dst.W, dst.H, encCopyRect)
			binary.Write(&body, binary.BigEndian, uint16(dst.X))
			binary.Write(&body, binary.BigEndian, uint16(srcY))
			count++
			copyRows(ss.sent, fbStride, dst, srcY)
			for ty := dst.Y / tile; ty <= (dst.Y+dst.H-1)/tile; ty++ {
				for tx := dst.X / tile; tx <= (dst.X+dst.W-1)/tile; tx++ {
					dirtyTile[ty*tw+tx] = tileDirty(tx, ty)
				}
			}
		}
	}

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
			if dirtyTile[ty*tw+tx] {
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

// inputArrived notes viewer input so the update loop checks the screen again right away.
func (ss *session) inputArrived() {
	ss.lastInput.Store(time.Now().UnixNano())
	go func() {
		time.Sleep(8 * time.Millisecond) // give the app a moment to redraw
		select {
		case ss.wake <- struct{}{}:
		default:
		}
	}()
}

func (ss *session) drainWake() {
	select {
	case <-ss.wake:
	default:
	}
}

// copyRows applies a vertical CopyRect to an image: rows of dst come from srcY onwards.
func copyRows(img []byte, stride int, dst Rect, srcY int) {
	x0, n := dst.X*4, dst.W*4
	if srcY > dst.Y {
		for i := 0; i < dst.H; i++ {
			copy(img[(dst.Y+i)*stride+x0:(dst.Y+i)*stride+x0+n], img[(srcY+i)*stride+x0:(srcY+i)*stride+x0+n])
		}
	} else {
		for i := dst.H - 1; i >= 0; i-- {
			copy(img[(dst.Y+i)*stride+x0:(dst.Y+i)*stride+x0+n], img[(srcY+i)*stride+x0:(srcY+i)*stride+x0+n])
		}
	}
}

// rowHash hashes one row segment of a BGRA image (alpha ignored). uniform reports whether
// every pixel in it is the same color (such rows match anything and can't vote).
func rowHash(img []byte, off, n int) (h uint64, uniform bool) {
	h = 1469598103934665603
	first := binary.LittleEndian.Uint32(img[off:]) & 0xFFFFFF
	uniform = true
	for i := 0; i < n; i++ {
		p := binary.LittleEndian.Uint32(img[off+i*4:]) & 0xFFFFFF
		if p != first {
			uniform = false
		}
		h = (h ^ uint64(p)) * 1099511628211
	}
	return h, uniform
}

// detectScroll looks inside area for content that moved straight up or down since the
// viewer's copy (sent). It returns the destination rectangle and source row for a CopyRect.
func detectScroll(img, sent []byte, stride int, area Rect) (dst Rect, srcY int, ok bool) {
	if area.W < 256 || area.H < 160 {
		return
	}
	// Columns of up to 64 px; each row of each column is hashed in both images.
	type col struct {
		x, w       int
		cur, old   []uint64
		curU, oldU []bool
	}
	var cols []col
	for x := area.X; x < area.X+area.W; x += tile {
		c := col{x: x, w: min(tile, area.X+area.W-x)}
		c.cur, c.old = make([]uint64, area.H), make([]uint64, area.H)
		c.curU, c.oldU = make([]bool, area.H), make([]bool, area.H)
		for i := 0; i < area.H; i++ {
			off := (area.Y+i)*stride + x*4
			c.cur[i], c.curU[i] = rowHash(img, off, c.w)
			c.old[i], c.oldU[i] = rowHash(sent, off, c.w)
		}
		cols = append(cols, c)
	}

	// Each distinctive row votes for the shifts that would explain it.
	votes := map[int]int{}
	for _, c := range cols {
		where := make(map[uint64][]int, area.H)
		for j, hh := range c.old {
			if !c.oldU[j] && len(where[hh]) < 4 {
				where[hh] = append(where[hh], j)
			}
		}
		for i, hh := range c.cur {
			if c.curU[i] || c.cur[i] == c.old[i] {
				continue
			}
			for _, j := range where[hh] {
				if j != i {
					votes[j-i]++
				}
			}
		}
	}
	best, bestVotes := 0, 0
	for d, v := range votes {
		if v > bestVotes || (v == bestVotes && abs(d) < abs(best)) {
			best, bestVotes = d, v
		}
	}
	if bestVotes < 24 {
		return
	}
	dy := best // row i now shows what row i+dy showed before

	// Columns where (nearly) every row is explained by that shift.
	lo, hi := max(0, -dy), min(area.H, area.H-dy) // rows i with i+dy inside the area
	if hi-lo < 64 {
		return
	}
	agree := make([]bool, len(cols))
	for k, c := range cols {
		match := 0
		for i := lo; i < hi; i++ {
			if c.cur[i] == c.old[i+dy] {
				match++
			}
		}
		agree[k] = match*10 >= (hi-lo)*9
	}
	// The widest run of agreeing columns.
	bk0, bk1 := -1, -1
	for k := 0; k < len(cols); {
		if !agree[k] {
			k++
			continue
		}
		e := k
		for e < len(cols) && agree[e] {
			e++
		}
		if bk0 < 0 || e-k > bk1-bk0 {
			bk0, bk1 = k, e
		}
		k = e
	}
	if bk0 < 0 || bk1-bk0 < 3 {
		return
	}
	// The longest run of rows where every column in that run matches exactly.
	bi0, bi1 := -1, -1
	for i := lo; i < hi; {
		rowOK := func(i int) bool {
			for k := bk0; k < bk1; k++ {
				if cols[k].cur[i] != cols[k].old[i+dy] {
					return false
				}
			}
			return true
		}
		if !rowOK(i) {
			i++
			continue
		}
		e := i
		for e < hi && rowOK(e) {
			e++
		}
		if bi0 < 0 || e-i > bi1-bi0 {
			bi0, bi1 = i, e
		}
		i = e
	}
	if bi0 < 0 || bi1-bi0 < 48 {
		return
	}
	x0 := cols[bk0].x
	x1 := cols[bk1-1].x + cols[bk1-1].w
	dst = Rect{x0, area.Y + bi0, x1 - x0, bi1 - bi0}
	return dst, dst.Y + dy, true
}

func abs(v int) int {
	if v < 0 {
		return -v
	}
	return v
}
