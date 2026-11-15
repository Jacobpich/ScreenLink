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
}

const fakeW, fakeH = 2080, 720

func newPlatform() Platform {
	return &fakePlatform{img: make([]byte, fakeW*fakeH*4), t0: time.Now(), logIn: os.Getenv("SLR_LOG_INPUT") != ""}
}

func (f *fakePlatform) Capture() ([]byte, int, int, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
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
func (f *fakePlatform) Wheel(dx, dy int)        { log.Printf("input: wheel %d,%d", dx, dy) }
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
