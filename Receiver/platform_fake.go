//go:build !windows

package main

import (
	"log"
	"math"
	"os"
	"sync"
	"time"
)

// fakePlatform stands in for Windows when testing on a Mac: a two-monitor desktop with a
// moving square, and input that is only logged.
type fakePlatform struct {
	mu    sync.Mutex
	img   []byte
	t0    time.Time
	clip  string
	seq   uint32
	logIn bool

	// SLR_SCROLL: the first monitor shows a text page that the mouse wheel scrolls, for
	// testing scroll performance. SLR_LASTFRAME=path saves each new frame there.
	scroll    bool
	scrollY   int
	lastFrame string
	drawnY    int
	notches   int
	photos    bool
}

const fakeW, fakeH = 2080, 720

func newPlatform() Platform {
	return &fakePlatform{img: make([]byte, fakeW*fakeH*4), t0: time.Now(), logIn: os.Getenv("SLR_LOG_INPUT") != "",
		scroll: os.Getenv("SLR_SCROLL") != "", photos: os.Getenv("SLR_SCROLL") == "photos", lastFrame: os.Getenv("SLR_LASTFRAME"), drawnY: -1}
}

func (f *fakePlatform) Capture() ([]byte, int, int, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.scroll {
		f.drawScrollPage()
		return f.img, fakeW, fakeH, nil
	}
	t := time.Since(f.t0).Seconds()
	if os.Getenv("SLR_STATIC") != "" {
		t = 0
	}
	sx := int(200 + 150*math.Sin(t))
	for y := 0; y < fakeH; y++ {
		for x := 0; x < fakeW; x++ {
			o := (y*fakeW + x) * 4
			var b, g, r byte
			switch {
			case x >= 1280 && (y < 60 || y >= 660): // gap outside the second monitor
			case x >= sx && x < sx+80 && y >= 300 && y < 380:
				b, g, r = 0, 120, 255
			case x < 1280 && y < 40: // title bar with "text"
				b, g, r = 235, 235, 235
				if y > 12 && y < 28 && (x/3)%5 < 2 && x%97 < 60 {
					b, g, r = 20, 20, 20
				}
			case x >= 1280:
				b, g, r = byte(x), byte(y), 90
			default:
				b, g, r = byte(x*255/1280), byte(y*255/720), byte((x^y)&0x3f)
			}
			f.img[o], f.img[o+1], f.img[o+2], f.img[o+3] = b, g, r, 255
		}
	}
	return f.img, fakeW, fakeH, nil
}

func (f *fakePlatform) Monitors() []Rect {
	return []Rect{{0, 0, 1280, 720}, {1280, 60, 800, 600}}
}

var fakeCursor = func() *Cursor {
	c := &Cursor{W: 9, H: 18, HotX: 4, HotY: 9, BGRA: make([]byte, 9*18*4)}
	for y := 0; y < 18; y++ {
		for x := 0; x < 9; x++ {
			if y == 0 || y == 17 || x == 4 {
				c.BGRA[(y*9+x)*4+3] = 255
			}
		}
	}
	return c
}()

func (f *fakePlatform) Cursor() (*Cursor, uint64) { return fakeCursor, 1 }
func (f *fakePlatform) MovePointer(x, y int) {
	if f.logIn {
		log.Printf("input: move %d,%d", x, y)
	}
}
func (f *fakePlatform) Button(b int, down bool) { log.Printf("input: button %d down=%v", b, down) }
func (f *fakePlatform) Wheel(dx, dy int) {
	if f.scroll {
		f.mu.Lock()
		f.scrollY = max(0, f.scrollY-dy*20) // one notch = 20 px, like a line of text
		f.notches++
		f.mu.Unlock()
		return
	}
	log.Printf("input: wheel %d,%d", dx, dy)
}

// drawScrollPage draws a browser-like window on the first monitor whose page is scrolled by
// scrollY, with a scrollbar thumb that moves. Caller holds f.mu.
func (f *fakePlatform) drawScrollPage() {
	if f.drawnY == f.scrollY {
		return
	}
	f.drawnY = f.scrollY
	log.Printf("page scrolled to %d (%d notches)", f.scrollY, f.notches)
	const pageX0, pageX1, top = 180, 1240, 70
	for y := 0; y < fakeH; y++ {
		for x := 0; x < fakeW; x++ {
			o := (y*fakeW + x) * 4
			var b, g, r byte = 60, 50, 40 // desktop
			switch {
			case x >= 1280:
				if y >= 60 && y < 660 {
					b, g, r = byte(x), byte(y), 90
				} else {
					b, g, r = 0, 0, 0
				}
			case y < top: // toolbar
				b, g, r = 236, 236, 236
				if y > 25 && y < 45 && x > 300 && x < 1000 {
					b, g, r = 255, 255, 255
				}
			case x < pageX0: // sidebar (doesn't scroll)
				b, g, r = 245, 240, 238
				if (y/24)%2 == 0 && x > 20 && x < 140 && y%24 > 8 && y%24 < 16 {
					b, g, r = 90, 90, 90
				}
			case x >= pageX1: // scrollbar
				b, g, r = 230, 230, 230
				thumb := top + (f.scrollY/4)%(fakeH-top-80)
				if y >= thumb && y < thumb+80 && x > pageX1+8 && x < pageX1+30 {
					b, g, r = 140, 140, 140
				}
			default: // page content
				py := y - top + f.scrollY
				b, g, r = 255, 255, 255
				line, in := py/22, py%22
				if in >= 5 && in < 17 {
					// "Words": runs of dark pixels whose pattern depends on the line number.
					cx := x - pageX0 - 40
					word := (cx / 70)
					if cx >= 0 && cx < 900 && (cx%70) < 40+((line*7+word*13)%28) && ((cx/3+line+in)%4 != 0) {
						// anti-aliased-looking text: many grey levels
						v := byte(30 + (cx*37+py*11+line*5)%120)
						b, g, r = v, v-10, v-20
					}
				}
				if f.photos && line%9 >= 6 && x > 700 { // photos down the right side
					n := uint32(x*2654435761) ^ uint32(py*40503)
					b, g, r = byte(n>>3), byte(n>>11)|byte(py), byte(n>>19)^byte(x)
				}
				if line%37 == 5 && in < 22 { // an image every so often
					b, g, r = byte(x*3+py), byte(py*2), byte(200-x/8)
				}
			}
			f.img[o], f.img[o+1], f.img[o+2], f.img[o+3] = b, g, r, 255
		}
	}
	if f.lastFrame != "" {
		os.WriteFile(f.lastFrame, f.img, 0o644)
	}
}
func (f *fakePlatform) Key(vk uint16, down bool) {
	log.Printf("input: key vk %02X down=%v", vk, down)
}
func (f *fakePlatform) Unicode(r rune, down bool) { log.Printf("input: char %q down=%v", r, down) }
func (f *fakePlatform) CharKey(r rune) (uint16, bool, bool) {
	if r >= 'a' && r <= 'z' {
		return uint16(r - 32), false, true
	}
	if r >= '0' && r <= '9' {
		return uint16(r), false, true
	}
	return 0, false, false
}
func (f *fakePlatform) Clipboard() (string, uint32) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.clip, f.seq
}
func (f *fakePlatform) SetClipboard(s string) {
	f.mu.Lock()
	f.clip = s
	f.seq++
	f.mu.Unlock()
	log.Printf("input: clipboard %q", s)
}
func (f *fakePlatform) DesktopName() string { return "Test PC" }

// ScrollNotches is how many wheel notches the scrolling test page has received.
func (f *fakePlatform) ScrollNotches() int { f.mu.Lock(); defer f.mu.Unlock(); return f.notches }
