//go:build !windows

package main

import "testing"

// The fake page scrolled by 60 px: detectScroll must find the page area moved by 60 rows.
func TestDetectScroll(t *testing.T) {
	f := newPlatform().(*fakePlatform)
	f.scroll = true
	a, w, h, _ := f.Capture()
	old := append([]byte(nil), a...)
	f.scrollY = 60
	b, _, _, _ := f.Capture()
	dst, srcY, ok := detectScroll(b, old, w*4, Rect{0, 0, 1280, h})
	if !ok || srcY-dst.Y != 60 || dst.W < 900 || dst.H < 500 {
		t.Fatalf("got ok=%v dst=%+v srcY=%d", ok, dst, srcY)
	}
	// Applying the copy to the old picture must reproduce the new one inside dst.
	copyRows(old, w*4, dst, srcY)
	for y := dst.Y; y < dst.Y+dst.H; y++ {
		for x := dst.X; x < dst.X+dst.W; x++ {
			o := (y*w + x) * 4
			if old[o] != b[o] || old[o+1] != b[o+1] || old[o+2] != b[o+2] {
				t.Fatalf("pixel %d,%d differs after copy", x, y)
			}
		}
	}
	// Nothing moved: no copy.
	if _, _, ok := detectScroll(b, b, w*4, Rect{0, 0, 1280, h}); ok {
		t.Fatal("found a scroll in an unchanged picture")
	}
}
