package main

import (
	"errors"
	"os"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf16"
	"unsafe"
)

const (
	smXVirtualScreen  = 76
	smYVirtualScreen  = 77
	smCXVirtualScreen = 78
	smCYVirtualScreen = 79
	srcCopy           = 0x00CC0020
	cursorShowing     = 1
	diNormal          = 3

	inputMouse    = 0
	inputKeyboard = 1

	mouseLeftDown   = 0x0002
	mouseLeftUp     = 0x0004
	mouseRightDown  = 0x0008
	mouseRightUp    = 0x0010
	mouseMiddleDown = 0x0020
	mouseMiddleUp   = 0x0040
	mouseWheel      = 0x0800
	mouseHWheel     = 0x1000

	keyExtended = 0x0001
	keyUp       = 0x0002
	keyUnicode  = 0x0004

	cfUnicodeText = 13
	gmemMoveable  = 0x0002
)

// winPlatform captures the screen with GDI and injects input with SendInput.
type winPlatform struct {
	cfg *Config

	capMu      sync.Mutex
	memDC      uintptr
	bmp        uintptr
	bits       unsafe.Pointer
	w, h       int
	vx, vy     int
	monCache   []Rect
	monChecked time.Time

	curMu     sync.Mutex
	curHandle uintptr
	curShown  bool
	cur       *Cursor
	curSerial uint64

	clipMu   sync.Mutex
	clipSeq  uint32
	clipText string
}

func newWinPlatform(cfg *Config) *winPlatform {
	dc, _, _ := pCreateCompatibleDC.Call(0)
	return &winPlatform{cfg: cfg, memDC: dc}
}

func metric(i int) int {
	r, _, _ := pGetSystemMetrics.Call(uintptr(i))
	return int(int32(r))
}

func (p *winPlatform) Capture() ([]byte, int, int, error) {
	p.capMu.Lock()
	defer p.capMu.Unlock()
	vx, vy := metric(smXVirtualScreen), metric(smYVirtualScreen)
	w, h := metric(smCXVirtualScreen), metric(smCYVirtualScreen)
	if w <= 0 || h <= 0 {
		return nil, 0, 0, errors.New("no display")
	}
	if w != p.w || h != p.h || p.bmp == 0 {
		if p.bmp != 0 {
			pDeleteObject.Call(p.bmp)
		}
		p.bmp, p.bits = newDIB(w, h)
		if p.bmp == 0 {
			return nil, 0, 0, errors.New("could not allocate the capture bitmap")
		}
		pSelectObject.Call(p.memDC, p.bmp)
		p.w, p.h = w, h
	}
	p.vx, p.vy = vx, vy
	screen, _, _ := pGetDC.Call(0)
	if screen == 0 {
		return nil, 0, 0, errors.New("screen not available")
	}
	ok, _, _ := pBitBlt.Call(p.memDC, 0, 0, uintptr(w), uintptr(h), screen, uintptr(vx), uintptr(vy), srcCopy)
	pReleaseDC.Call(0, screen)
	pGdiFlush.Call()
	if ok == 0 {
		// Happens while the secure desktop (UAC prompt or lock screen) is up.
		return nil, 0, 0, errors.New("screen capture blocked")
	}
	return unsafe.Slice((*byte)(p.bits), w*h*4), w, h, nil
}

var (
	monMu     sync.Mutex
	monList   []rect32
	monEnumCB = syscall.NewCallback(func(hmon, hdc uintptr, r *rect32, data uintptr) uintptr {
		monList = append(monList, *r)
		return 1
	})
)

func (p *winPlatform) Monitors() []Rect {
	monMu.Lock()
	defer monMu.Unlock()
	if p.monCache != nil && time.Since(p.monChecked) < time.Second {
		return p.monCache
	}
	monList = nil
	pEnumDisplayMonitors.Call(0, 0, monEnumCB, 0)
	vx, vy := metric(smXVirtualScreen), metric(smYVirtualScreen)
	var out []Rect
	for _, r := range monList {
		out = append(out, Rect{int(r.Left) - vx, int(r.Top) - vy, int(r.Right - r.Left), int(r.Bottom - r.Top)})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].X != out[j].X {
			return out[i].X < out[j].X
		}
		return out[i].Y < out[j].Y
	})
	p.monCache, p.monChecked = out, time.Now()
	return out
}

// Cursor reads the pointer shape. Drawing it once on black and once on white recovers its
// alpha, and also catches classic "inverting" cursors such as the text I-beam.
func (p *winPlatform) Cursor() (*Cursor, uint64) {
	p.curMu.Lock()
	defer p.curMu.Unlock()
	ci := cursorInfo{Size: uint32(unsafe.Sizeof(cursorInfo{}))}
	if r, _, _ := pGetCursorInfo.Call(uintptr(unsafe.Pointer(&ci))); r == 0 {
		return p.cur, p.curSerial
	}
	shown := ci.Flags&cursorShowing != 0 && ci.Cursor != 0
	if shown == p.curShown && ci.Cursor == p.curHandle && p.curSerial != 0 {
		return p.cur, p.curSerial
	}
	p.curShown, p.curHandle = shown, ci.Cursor
	p.curSerial++
	if !shown {
		p.cur = nil
		return nil, p.curSerial
	}
	p.cur = renderCursor(ci.Cursor)
	return p.cur, p.curSerial
}

func renderCursor(hc uintptr) *Cursor {
	var ii iconInfo
	if r, _, _ := pGetIconInfo.Call(hc, uintptr(unsafe.Pointer(&ii))); r == 0 {
		return nil
	}
	defer func() {
		if ii.Mask != 0 {
			pDeleteObject.Call(ii.Mask)
		}
		if ii.Color != 0 {
			pDeleteObject.Call(ii.Color)
		}
	}()
	var bm bitmap
	src := ii.Color
	if src == 0 {
		src = ii.Mask
	}
	pGetObjectW.Call(src, unsafe.Sizeof(bm), uintptr(unsafe.Pointer(&bm)))
	w, h := int(bm.Width), int(bm.Height)
	if ii.Color == 0 {
		h /= 2 // monochrome: AND mask on top of XOR mask
	}
	if w <= 0 || h <= 0 || w > 256 || h > 256 {
		return nil
	}
	draw := func(fill byte) []byte {
		dc, _, _ := pCreateCompatibleDC.Call(0)
		defer pDeleteDC.Call(dc)
		bmp, bits := newDIB(w, h)
		if bmp == 0 {
			return nil
		}
		defer pDeleteObject.Call(bmp)
		old, _, _ := pSelectObject.Call(dc, bmp)
		px := unsafe.Slice((*byte)(bits), w*h*4)
		for i := range px {
			px[i] = fill
		}
		pDrawIconEx.Call(dc, 0, 0, hc, uintptr(w), uintptr(h), 0, 0, diNormal)
		pGdiFlush.Call()
		out := append([]byte(nil), px...)
		pSelectObject.Call(dc, old)
		return out
	}
	onBlack, onWhite := draw(0), draw(255)
	if onBlack == nil || onWhite == nil {
		return nil
	}
	c := &Cursor{W: w, H: h, HotX: int(ii.XHotspot), HotY: int(ii.YHotspot), BGRA: make([]byte, w*h*4)}
	inverted := false
	for i := 0; i < w*h; i++ {
		b, wt := onBlack[i*4:i*4+3], onWhite[i*4:i*4+3]
		if int(wt[1]) < int(b[1])-64 { // black→white and white→black: an inverting pixel
			inverted = true
			c.BGRA[i*4+3] = 255 // drawn black, outlined below
			continue
		}
		a := 255 - (int(wt[1]) - int(b[1]))
		if a <= 0 {
			continue
		}
		for ch := 0; ch < 3; ch++ {
			c.BGRA[i*4+ch] = byte(min(255, int(b[ch])*255/a))
		}
		c.BGRA[i*4+3] = byte(a)
	}
	if inverted { // give black inverting pixels a white outline so they show on dark screens
		opaque := func(x, y int) bool {
			return x >= 0 && y >= 0 && x < w && y < h && c.BGRA[(y*w+x)*4+3] >= 128 && c.BGRA[(y*w+x)*4] == 0
		}
		out := append([]byte(nil), c.BGRA...)
		for y := 0; y < h; y++ {
			for x := 0; x < w; x++ {
				if c.BGRA[(y*w+x)*4+3] >= 128 {
					continue
				}
				if opaque(x-1, y) || opaque(x+1, y) || opaque(x, y-1) || opaque(x, y+1) {
					copy(out[(y*w+x)*4:], []byte{255, 255, 255, 255})
				}
			}
		}
		c.BGRA = out
	}
	return c
}

func (p *winPlatform) MovePointer(x, y int) {
	p.capMu.Lock()
	vx, vy := p.vx, p.vy
	p.capMu.Unlock()
	pSetCursorPos.Call(uintptr(int32(x+vx)), uintptr(int32(y+vy)))
}

func sendMouse(flags uint32, data int32) {
	in := mouseInput{Type: inputMouse, MouseData: uint32(data), Flags: flags}
	pSendInput.Call(1, uintptr(unsafe.Pointer(&in)), unsafe.Sizeof(in))
}

func (p *winPlatform) Button(b int, down bool) {
	flags := [3][2]uint32{{mouseLeftUp, mouseLeftDown}, {mouseMiddleUp, mouseMiddleDown}, {mouseRightUp, mouseRightDown}}
	d := 0
	if down {
		d = 1
	}
	sendMouse(flags[b][d], 0)
}

func (p *winPlatform) Wheel(dx, dy int) {
	step := p.cfg.ScrollStep
	if dy != 0 {
		sendMouse(mouseWheel, int32(dy*step))
	}
	if dx != 0 {
		sendMouse(mouseHWheel, int32(dx*step))
	}
}

func sendKey(vk, scan uint16, flags uint32) {
	in := keybdInput{Type: inputKeyboard, Vk: vk, Scan: scan, Flags: flags}
	pSendInput.Call(1, uintptr(unsafe.Pointer(&in)), unsafe.Sizeof(in))
}

func (p *winPlatform) Key(vk uint16, down bool) {
	scan, _, _ := pMapVirtualKeyW.Call(uintptr(vk), 0)
	var flags uint32
	if isExtendedVK(vk) {
		flags |= keyExtended
	}
	if !down {
		flags |= keyUp
	}
	sendKey(vk, uint16(scan), flags)
}

func (p *winPlatform) Unicode(r rune, down bool) {
	var flags uint32 = keyUnicode
	if !down {
		flags |= keyUp
	}
	if r > 0xFFFF {
		a, b := utf16.EncodeRune(r)
		sendKey(0, uint16(a), flags)
		sendKey(0, uint16(b), flags)
		return
	}
	sendKey(0, uint16(r), flags)
}

func (p *winPlatform) CharKey(r rune) (uint16, bool, bool) {
	if r > 0xFFFF {
		return 0, false, false
	}
	v, _, _ := pVkKeyScanW.Call(uintptr(r))
	s := int16(v)
	if s == -1 {
		return 0, false, false
	}
	return uint16(s & 0xff), s&0x100 != 0, true
}

func openClipboard() bool {
	for i := 0; i < 10; i++ {
		if r, _, _ := pOpenClipboard.Call(trayHwnd); r != 0 {
			return true
		}
		time.Sleep(20 * time.Millisecond)
	}
	return false
}

func (p *winPlatform) Clipboard() (string, uint32) {
	seq, _, _ := pGetClipboardSequenceNumber.Call()
	p.clipMu.Lock()
	defer p.clipMu.Unlock()
	if uint32(seq) == p.clipSeq {
		return p.clipText, p.clipSeq
	}
	if !openClipboard() {
		return p.clipText, p.clipSeq
	}
	defer pCloseClipboard.Call()
	p.clipSeq = uint32(seq)
	p.clipText = ""
	h, _, _ := pGetClipboardData.Call(cfUnicodeText)
	if h == 0 {
		return "", p.clipSeq
	}
	ptr, _, _ := pGlobalLock.Call(h)
	if ptr == 0 {
		return "", p.clipSeq
	}
	size, _, _ := pGlobalSize.Call(h)
	n := int(size / 2)
	if n > 8<<20 {
		n = 8 << 20
	}
	words := unsafe.Slice((*uint16)(ptrOf(ptr)), n)
	end := 0
	for end < n && words[end] != 0 {
		end++
	}
	p.clipText = strings.ReplaceAll(string(utf16.Decode(words[:end])), "\r\n", "\n")
	pGlobalUnlock.Call(h)
	return p.clipText, p.clipSeq
}

func (p *winPlatform) SetClipboard(text string) {
	words := utf16.Encode([]rune(strings.ReplaceAll(strings.ReplaceAll(text, "\r\n", "\n"), "\n", "\r\n")))
	words = append(words, 0)
	h, _, _ := pGlobalAlloc.Call(gmemMoveable, uintptr(len(words)*2))
	if h == 0 {
		return
	}
	ptr, _, _ := pGlobalLock.Call(h)
	copy(unsafe.Slice((*uint16)(ptrOf(ptr)), len(words)), words)
	pGlobalUnlock.Call(h)
	if !openClipboard() {
		pGlobalFree.Call(h)
		return
	}
	pEmptyClipboard.Call()
	if r, _, _ := pSetClipboardData.Call(cfUnicodeText, h); r == 0 {
		pGlobalFree.Call(h)
	}
	pCloseClipboard.Call()
}

func (p *winPlatform) DesktopName() string {
	n, err := os.Hostname()
	if err != nil || n == "" {
		return "Windows PC"
	}
	return n
}

// ptrOf turns a pointer Windows returned as an integer (GlobalLock) into an unsafe.Pointer.
func ptrOf(p uintptr) unsafe.Pointer { return *(*unsafe.Pointer)(unsafe.Pointer(&p)) }
