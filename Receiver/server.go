package main

import (
	"bufio"
	"bytes"
	"compress/zlib"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"sync"
	"sync/atomic"
	"time"
	"unicode/utf8"
)

// Rect is a rectangle in desktop pixels (origin = top-left of the whole desktop).
type Rect struct{ X, Y, W, H int }

// Cursor is the current mouse pointer shape, BGRA with straight alpha.
type Cursor struct {
	W, H, HotX, HotY int
	BGRA             []byte
}

// Platform is everything OS-specific: screen capture, input and the clipboard.
type Platform interface {
	Injector
	// Capture returns the whole desktop as BGRA, top-down, stride w*4. The buffer may be
	// reused by the next call.
	Capture() (img []byte, w, h int, err error)
	Monitors() []Rect
	// Cursor returns the pointer shape and a serial that changes when the shape does.
	Cursor() (*Cursor, uint64)
	MovePointer(x, y int)
	Button(b int, down bool) // 0 left, 1 middle, 2 right
	Wheel(dx, dy int)        // notches; dy > 0 = scroll up (content moves down), dx > 0 = right
	Clipboard() (text string, seq uint32)
	SetClipboard(text string)
	DesktopName() string
}

const (
	encRaw         = 0
	encCopyRect    = 1
	encZRLE        = 16
	encCursor      = -239
	encDesktopSize = -223
	encExtDesktop  = -308
)

type pixelFormat struct {
	bpp, depth             uint8
	bigEndian, trueColor   bool
	rMax, gMax, bMax       uint16
	rShift, gShift, bShift uint8
}

var defaultPF = pixelFormat{bpp: 32, depth: 24, trueColor: true, rMax: 255, gMax: 255, bMax: 255, rShift: 16, gShift: 8, bShift: 0}

func (pf pixelFormat) native() bool {
	return pf == defaultPF || (pf.bpp == 32 && !pf.bigEndian && pf.trueColor && pf.rMax == 255 && pf.gMax == 255 &&
		pf.bMax == 255 && pf.rShift == 16 && pf.gShift == 8 && pf.bShift == 0)
}

func (pf pixelFormat) pixel(b, g, r byte) uint32 {
	return uint32(r)*uint32(pf.rMax)/255<<pf.rShift | uint32(g)*uint32(pf.gMax)/255<<pf.gShift | uint32(b)*uint32(pf.bMax)/255<<pf.bShift
}

// Server shares one desktop with any number of ScreenLink viewers.
type Server struct {
	cfg   *Config
	plat  Platform
	kb    *Keyboard
	inMu  sync.Mutex // input goes to Windows one event at a time
	capMu sync.Mutex // one screen capture at a time (the capture buffer is shared)

	mu       sync.Mutex
	sessions map[*session]bool
	failures map[string][]time.Time

	clipSeq   uint32
	clipEcho  string
	OnViewers func(n int)
}

func NewServer(cfg *Config, plat Platform) *Server {
	return &Server{cfg: cfg, plat: plat, kb: NewKeyboard(plat), sessions: map[*session]bool{}, failures: map[string][]time.Time{}}
}

func (s *Server) Serve(l net.Listener) error {
	go s.watchClipboard()
	for {
		c, err := l.Accept()
		if err != nil {
			return err
		}
		go s.handle(c)
	}
}

func (s *Server) viewerCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.sessions)
}

func (s *Server) handle(c net.Conn) {
	defer c.Close()
	ip := remoteIP(c)
	if !s.cfg.allowed(ip) {
		log.Printf("refused %s (only Tailscale devices may connect)", ip)
		return
	}
	if t, ok := c.(*net.TCPConn); ok {
		t.SetNoDelay(true)
	}
	if s.lockedOut(ip.String()) {
		log.Printf("refused %s: too many wrong passwords, try again later", ip)
		return
	}
	c.SetDeadline(time.Now().Add(30 * time.Second))
	br := bufio.NewReaderSize(c, 64*1024)
	ss := &session{srv: s, conn: c, r: br, pf: defaultPF, wake: make(chan struct{}, 1)}
	if err := ss.handshake(ip.String()); err != nil {
		log.Printf("%s: %v", ip, err)
		return
	}
	c.SetDeadline(time.Time{})
	s.mu.Lock()
	s.sessions[ss] = true
	n := len(s.sessions)
	s.mu.Unlock()
	log.Printf("viewer connected: %s (%d watching)", ip, n)
	if s.OnViewers != nil {
		s.OnViewers(n)
	}

	done := make(chan struct{})
	go func() { ss.updateLoop(done) }()
	err := ss.readLoop()
	close(done)
	c.Close()

	s.mu.Lock()
	delete(s.sessions, ss)
	n = len(s.sessions)
	s.mu.Unlock()
	if n == 0 {
		s.inMu.Lock()
		s.kb.ReleaseAll()
		for b := 0; b < 3; b++ {
			if ss.buttons&(1<<b) != 0 {
				s.plat.Button(b, false)
			}
		}
		s.inMu.Unlock()
	}
	if err != nil && !errors.Is(err, io.EOF) && !errors.Is(err, net.ErrClosed) {
		log.Printf("viewer %s left: %v", ip, err)
	} else {
		log.Printf("viewer %s left", ip)
	}
	if s.OnViewers != nil {
		s.OnViewers(n)
	}
}

func (s *Server) lockedOut(ip string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	var recent []time.Time
	for _, t := range s.failures[ip] {
		if time.Since(t) < 10*time.Minute {
			recent = append(recent, t)
		}
	}
	s.failures[ip] = recent
	return len(recent) >= 10
}

func (s *Server) authFailed(ip string) {
	s.mu.Lock()
	s.failures[ip] = append(s.failures[ip], time.Now())
	n := len(s.failures[ip])
	s.mu.Unlock()
	if n >= 3 {
		time.Sleep(2 * time.Second)
	}
}

// watchClipboard sends the PC's clipboard to viewers whenever it changes.
func (s *Server) watchClipboard() {
	_, s.clipSeq = s.plat.Clipboard()
	for range time.Tick(400 * time.Millisecond) {
		if s.viewerCount() == 0 {
			_, s.clipSeq = s.plat.Clipboard()
			continue
		}
		text, seq := s.plat.Clipboard()
		if seq == s.clipSeq {
			continue
		}
		s.clipSeq = seq
		s.mu.Lock()
		echo := s.clipEcho
		s.mu.Unlock()
		if text == "" || text == echo {
			continue
		}
		s.mu.Lock()
		for ss := range s.sessions {
			ss.sendClipboard(text)
		}
		s.mu.Unlock()
	}
}

// ---------------------------------------------------------------------------------------

type session struct {
	srv  *Server
	conn net.Conn
	r    *bufio.Reader
	wmu  sync.Mutex // one writer at a time (updates and clipboard)

	mu          sync.Mutex
	pf          pixelFormat
	zrle        bool
	copyRect    bool
	cursorEnc   bool
	extDesktop  bool
	desktopSize bool
	pending     bool  // an update request is outstanding
	full        *Rect // area requested non-incrementally (union)
	wake        chan struct{}

	buttons   uint8
	lastX     int
	lastY     int
	lastInput atomic.Int64 // UnixNano of the viewer's last key/pointer event

	// Encoder state (update goroutine only)
	fbW, fbH    int
	sent        []byte // what the viewer has, BGRA
	cursorSer   uint64
	sentMonitor []Rect
	zbuf        bytes.Buffer
	zw          *zlib.Writer
}

func (ss *session) handshake(ip string) error {
	c := ss.conn
	if _, err := c.Write([]byte("RFB 003.008\n")); err != nil {
		return err
	}
	ver := make([]byte, 12)
	if _, err := io.ReadFull(ss.r, ver); err != nil {
		return err
	}
	if !bytes.HasPrefix(ver, []byte("RFB 003.")) || string(ver[8:11]) < "007" {
		return fmt.Errorf("unsupported viewer version %q", ver)
	}
	// Security type 30: Diffie-Hellman + AES, carries a username and a full-length password.
	if _, err := c.Write([]byte{1, 30}); err != nil {
		return err
	}
	choice, err := ss.r.ReadByte()
	if err != nil {
		return err
	}
	if choice != 30 {
		return fmt.Errorf("viewer chose unsupported security type %d", choice)
	}
	user, pass, err := serverAppleAuth(c, ss.r)
	if err != nil {
		return err
	}
	ss.srv.cfg.reload()
	if !ss.srv.cfg.checkPassword(pass) {
		ss.srv.authFailed(ip)
		msg := "Wrong password for this PC."
		out := binary.BigEndian.AppendUint32(nil, 1)
		out = binary.BigEndian.AppendUint32(out, uint32(len(msg)))
		c.Write(append(out, msg...))
		return fmt.Errorf("wrong password (user %q)", user)
	}
	if _, err := c.Write([]byte{0, 0, 0, 0}); err != nil {
		return err
	}
	if _, err := ss.r.ReadByte(); err != nil { // ClientInit (shared flag; we always share)
		return err
	}
	_, w, h, err := ss.srv.plat.Capture()
	if err != nil {
		return fmt.Errorf("screen capture failed: %w", err)
	}
	ss.fbW, ss.fbH = w, h
	name := ss.srv.plat.DesktopName()
	init := binary.BigEndian.AppendUint16(nil, uint16(w))
	init = binary.BigEndian.AppendUint16(init, uint16(h))
	init = append(init, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0)
	init = binary.BigEndian.AppendUint32(init, uint32(len(name)))
	init = append(init, name...)
	_, err = c.Write(init)
	log.Printf("%s signed in as %q, desktop %dx%d", ip, user, w, h)
	return err
}

func (ss *session) readLoop() error {
	r := ss.r
	buf := make([]byte, 64)
	for {
		t, err := r.ReadByte()
		if err != nil {
			return err
		}
		switch t {
		case 0: // SetPixelFormat
			if _, err := io.ReadFull(r, buf[:19]); err != nil {
				return err
			}
			p := buf[3:19]
			pf := pixelFormat{bpp: p[0], depth: p[1], bigEndian: p[2] != 0, trueColor: p[3] != 0,
				rMax: binary.BigEndian.Uint16(p[4:]), gMax: binary.BigEndian.Uint16(p[6:]), bMax: binary.BigEndian.Uint16(p[8:]),
				rShift: p[10], gShift: p[11], bShift: p[12]}
			if pf.bpp != 32 || !pf.trueColor {
				return fmt.Errorf("viewer wants %d-bit colour; only 32-bit is supported", pf.bpp)
			}
			ss.mu.Lock()
			ss.pf = pf
			ss.mu.Unlock()
		case 2: // SetEncodings
			if _, err := io.ReadFull(r, buf[:3]); err != nil {
				return err
			}
			n := int(binary.BigEndian.Uint16(buf[1:3]))
			encs := make([]byte, 4*n)
			if _, err := io.ReadFull(r, encs); err != nil {
				return err
			}
			ss.mu.Lock()
			ss.zrle, ss.copyRect, ss.cursorEnc, ss.extDesktop, ss.desktopSize = false, false, false, false, false
			for i := 0; i < n; i++ {
				switch int32(binary.BigEndian.Uint32(encs[4*i:])) {
				case encZRLE:
					ss.zrle = true
				case encCopyRect:
					ss.copyRect = true
				case encCursor:
					ss.cursorEnc = true
				case encExtDesktop:
					ss.extDesktop = true
				case encDesktopSize:
					ss.desktopSize = true
				}
			}
			ss.cursorSer = 0 // resend the cursor in the newly agreed form
			ss.mu.Unlock()
		case 3: // FramebufferUpdateRequest
			if _, err := io.ReadFull(r, buf[:9]); err != nil {
				return err
			}
			inc := buf[0] != 0
			rc := Rect{int(binary.BigEndian.Uint16(buf[1:])), int(binary.BigEndian.Uint16(buf[3:])),
				int(binary.BigEndian.Uint16(buf[5:])), int(binary.BigEndian.Uint16(buf[7:]))}
			ss.mu.Lock()
			ss.pending = true
			if !inc {
				if ss.full == nil {
					ss.full = &rc
				} else {
					u := union(*ss.full, rc)
					ss.full = &u
				}
			}
			ss.mu.Unlock()
			select {
			case ss.wake <- struct{}{}:
			default:
			}
		case 4: // KeyEvent
			if _, err := io.ReadFull(r, buf[:7]); err != nil {
				return err
			}
			down := buf[0] != 0
			sym := binary.BigEndian.Uint32(buf[3:7])
			ss.inputArrived()
			ss.srv.inMu.Lock()
			ss.srv.kb.Event(sym, down)
			ss.srv.inMu.Unlock()
		case 5: // PointerEvent
			if _, err := io.ReadFull(r, buf[:5]); err != nil {
				return err
			}
			ss.pointer(buf[0], int(binary.BigEndian.Uint16(buf[1:])), int(binary.BigEndian.Uint16(buf[3:])))
			ss.inputArrived()
		case 6: // ClientCutText
			if _, err := io.ReadFull(r, buf[:7]); err != nil {
				return err
			}
			n := int(binary.BigEndian.Uint32(buf[3:7]))
			if n > 16<<20 {
				return errors.New("clipboard text too large")
			}
			data := make([]byte, n)
			if _, err := io.ReadFull(r, data); err != nil {
				return err
			}
			text := string(data)
			if !utf8.Valid(data) { // Latin-1 per the RFB spec
				rs := make([]rune, n)
				for i, b := range data {
					rs[i] = rune(b)
				}
				text = string(rs)
			}
			ss.srv.mu.Lock()
			ss.srv.clipEcho = text
			ss.srv.mu.Unlock()
			ss.srv.plat.SetClipboard(text)
		default:
			return fmt.Errorf("unknown message type %d from viewer", t)
		}
	}
}

func (ss *session) pointer(mask uint8, x, y int) {
	s := ss.srv
	s.inMu.Lock()
	defer s.inMu.Unlock()
	if x != ss.lastX || y != ss.lastY {
		s.plat.MovePointer(x, y)
		ss.lastX, ss.lastY = x, y
	}
	changed := mask ^ ss.buttons
	if changed != 0 {
		s.kb.SyncForPointer()
	}
	for b := 0; b < 3; b++ { // VNC: bit 0 left, 1 middle, 2 right
		if changed&(1<<b) != 0 {
			s.plat.Button(b, mask&(1<<b) != 0)
		}
	}
	// Wheel: buttons 4/5 = up/down, 6/7 = left/right, sent as press+release per notch.
	if press := changed & mask; press&0x78 != 0 {
		dx, dy := 0, 0
		if press&0x08 != 0 {
			dy++
		}
		if press&0x10 != 0 {
			dy--
		}
		if press&0x20 != 0 {
			dx--
		}
		if press&0x40 != 0 {
			dx++
		}
		s.plat.Wheel(dx, dy)
	}
	ss.buttons = mask & 0x07
	ss.buttons |= mask & 0x78 // remember wheel bits so the release isn't a second notch
}

func (ss *session) sendClipboard(text string) {
	msg := []byte{3, 0, 0, 0}
	msg = binary.BigEndian.AppendUint32(msg, uint32(len(text)))
	msg = append(msg, text...)
	ss.wmu.Lock()
	ss.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
	ss.conn.Write(msg)
	ss.wmu.Unlock()
}

func union(a, b Rect) Rect {
	x0, y0 := min(a.X, b.X), min(a.Y, b.Y)
	x1, y1 := max(a.X+a.W, b.X+b.W), max(a.Y+a.H, b.Y+b.H)
	return Rect{x0, y0, x1 - x0, y1 - y0}
}

func remoteIP(c net.Conn) net.IP {
	if a, ok := c.RemoteAddr().(*net.TCPAddr); ok {
		return a.IP
	}
	return nil
}
