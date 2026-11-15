package main

import (
	"log"
	"runtime"
	"time"
	"unicode/utf16"
	"unsafe"
)

// Windows shows UAC prompts, the lock screen and the sign-in screen on a separate "secure
// desktop" (Winlogon). A thread can only capture and inject input on the desktop it is attached
// to, so all screen and input work runs on one dedicated thread that follows whichever desktop
// currently has the input. Switching to Winlogon only works for SYSTEM, which is why the
// receiver runs as a service (see service_windows.go); as a normal app it stays on Default.

const (
	genericAll = 0x10000000
	uoiName    = 2
)

type deskThread struct {
	work     chan func()
	cur      uintptr
	curName  string
	lastSync time.Time
}

var desk = newDeskThread()

func newDeskThread() *deskThread {
	d := &deskThread{work: make(chan func(), 1)}
	go func() {
		runtime.LockOSThread() // never unlocked: this OS thread is attached to the input desktop
		for f := range d.work {
			d.sync()
			f()
		}
	}()
	return d
}

// do runs f on the desktop thread and waits for it.
func (d *deskThread) do(f func()) {
	done := make(chan struct{})
	d.work <- func() {
		defer close(done)
		f()
	}
	<-done
}

// sync attaches the thread to the input desktop if it changed (at most every 20 ms).
func (d *deskThread) sync() {
	if time.Since(d.lastSync) < 20*time.Millisecond {
		return
	}
	d.lastSync = time.Now()
	h, _, _ := pOpenInputDesktop.Call(0, 0, genericAll)
	if h == 0 {
		return // not allowed (normal app while the secure desktop is up), or no desktop
	}
	name := desktopName(h)
	if name == d.curName && d.cur != 0 {
		pCloseDesktop.Call(h)
		return
	}
	if r, _, err := pSetThreadDesktop.Call(h); r == 0 {
		pCloseDesktop.Call(h)
		if d.curName != "!"+name {
			log.Printf("couldn't switch to desktop %q: %v", name, err)
			d.curName = "!" + name
		}
		return
	}
	if d.cur != 0 {
		pCloseDesktop.Call(d.cur)
	}
	log.Printf("following input desktop %q", name)
	d.cur, d.curName = h, name
}

func desktopName(h uintptr) string {
	var buf [64]uint16
	var need uint32
	pGetUserObjectInformationW.Call(h, uoiName, uintptr(unsafe.Pointer(&buf[0])), unsafe.Sizeof(buf), uintptr(unsafe.Pointer(&need)))
	n := 0
	for n < len(buf) && buf[n] != 0 {
		n++
	}
	return string(utf16.Decode(buf[:n]))
}

// clipHwnd owns the clipboard when there's no tray window (the service's agent).
var clipHwnd uintptr

// startClipboardWindow makes a hidden message-only window on its own thread (the desktop thread
// must have no windows, or it couldn't switch desktops).
func startClipboardWindow() {
	ready := make(chan struct{})
	go func() {
		runtime.LockOSThread()
		cls := u16("ScreenLinkClipboard")
		wc := wndClassEx{WndProc: pDefWindowProcW.Addr(), ClassName: cls}
		wc.Size = uint32(unsafe.Sizeof(wc))
		pRegisterClassExW.Call(uintptr(unsafe.Pointer(&wc)))
		const hwndMessage = ^uintptr(2) // (HWND)-3
		clipHwnd, _, _ = pCreateWindowExW.Call(0, uintptr(unsafe.Pointer(cls)), 0, 0, 0, 0, 0, 0, hwndMessage, 0, 0, 0)
		close(ready)
		var m msg
		for {
			if r, _, _ := pGetMessageW.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0); int32(r) <= 0 {
				return
			}
			pDispatchMessageW.Call(uintptr(unsafe.Pointer(&m)))
		}
	}()
	<-ready
}

func clipOwner() uintptr {
	if clipHwnd != 0 {
		return clipHwnd
	}
	return trayHwnd
}

// foregroundLayout is the keyboard layout of the app the user is typing into, so shortcuts
// (Ctrl+C…) hit the right keys even from the service, whose own layout may differ.
func foregroundLayout() uintptr {
	fg, _, _ := pGetForegroundWindow.Call()
	tid, _, _ := pGetWindowThreadProcessId.Call(fg, 0)
	hkl, _, _ := pGetKeyboardLayout.Call(tid)
	return hkl
}
