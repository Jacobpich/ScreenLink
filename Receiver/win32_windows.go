package main

import (
	"syscall"
	"unsafe"
)

var (
	user32   = syscall.NewLazyDLL("user32.dll")
	gdi32    = syscall.NewLazyDLL("gdi32.dll")
	kernel32 = syscall.NewLazyDLL("kernel32.dll")
	shell32  = syscall.NewLazyDLL("shell32.dll")

	pGetDC                         = user32.NewProc("GetDC")
	pReleaseDC                     = user32.NewProc("ReleaseDC")
	pGetSystemMetrics              = user32.NewProc("GetSystemMetrics")
	pSetProcessDpiAwarenessContext = user32.NewProc("SetProcessDpiAwarenessContext")
	pSetProcessDPIAware            = user32.NewProc("SetProcessDPIAware")
	pEnumDisplayMonitors           = user32.NewProc("EnumDisplayMonitors")
	pGetCursorInfo                 = user32.NewProc("GetCursorInfo")
	pGetIconInfo                   = user32.NewProc("GetIconInfo")
	pDrawIconEx                    = user32.NewProc("DrawIconEx")
	pSetCursorPos                  = user32.NewProc("SetCursorPos")
	pGetCursorPos                  = user32.NewProc("GetCursorPos")
	pSendInput                     = user32.NewProc("SendInput")
	pVkKeyScanW                    = user32.NewProc("VkKeyScanW")
	pMapVirtualKeyW                = user32.NewProc("MapVirtualKeyW")
	pOpenClipboard                 = user32.NewProc("OpenClipboard")
	pCloseClipboard                = user32.NewProc("CloseClipboard")
	pEmptyClipboard                = user32.NewProc("EmptyClipboard")
	pGetClipboardData              = user32.NewProc("GetClipboardData")
	pSetClipboardData              = user32.NewProc("SetClipboardData")
	pGetClipboardSequenceNumber    = user32.NewProc("GetClipboardSequenceNumber")
	pRegisterClassExW              = user32.NewProc("RegisterClassExW")
	pCreateWindowExW               = user32.NewProc("CreateWindowExW")
	pDefWindowProcW                = user32.NewProc("DefWindowProcW")
	pGetMessageW                   = user32.NewProc("GetMessageW")
	pTranslateMessage              = user32.NewProc("TranslateMessage")
	pDispatchMessageW              = user32.NewProc("DispatchMessageW")
	pPostQuitMessage               = user32.NewProc("PostQuitMessage")
	pPostMessageW                  = user32.NewProc("PostMessageW")
	pCreatePopupMenu               = user32.NewProc("CreatePopupMenu")
	pAppendMenuW                   = user32.NewProc("AppendMenuW")
	pTrackPopupMenu                = user32.NewProc("TrackPopupMenu")
	pDestroyMenu                   = user32.NewProc("DestroyMenu")
	pSetForegroundWindow           = user32.NewProc("SetForegroundWindow")
	pMessageBoxW                   = user32.NewProc("MessageBoxW")
	pRegisterWindowMessageW        = user32.NewProc("RegisterWindowMessageW")
	pCreateIconIndirect            = user32.NewProc("CreateIconIndirect")
	pLoadIconW                     = user32.NewProc("LoadIconW")
	pCreateCompatibleDC            = gdi32.NewProc("CreateCompatibleDC")
	pCreateDIBSection              = gdi32.NewProc("CreateDIBSection")
	pCreateBitmap                  = gdi32.NewProc("CreateBitmap")
	pSelectObject                  = gdi32.NewProc("SelectObject")
	pBitBlt                        = gdi32.NewProc("BitBlt")
	pDeleteObject                  = gdi32.NewProc("DeleteObject")
	pDeleteDC                      = gdi32.NewProc("DeleteDC")
	pGetObjectW                    = gdi32.NewProc("GetObjectW")
	pGdiFlush                      = gdi32.NewProc("GdiFlush")
	pGlobalAlloc                   = kernel32.NewProc("GlobalAlloc")
	pGlobalFree                    = kernel32.NewProc("GlobalFree")
	pGlobalLock                    = kernel32.NewProc("GlobalLock")
	pGlobalUnlock                  = kernel32.NewProc("GlobalUnlock")
	pGlobalSize                    = kernel32.NewProc("GlobalSize")
	pAllocConsole                  = kernel32.NewProc("AllocConsole")
	pFreeConsole                   = kernel32.NewProc("FreeConsole")
	pGetConsoleMode                = kernel32.NewProc("GetConsoleMode")
	pSetConsoleMode                = kernel32.NewProc("SetConsoleMode")
	pSetConsoleTitleW              = kernel32.NewProc("SetConsoleTitleW")
	pCreateMutexW                  = kernel32.NewProc("CreateMutexW")
	pSetThreadExecutionState       = kernel32.NewProc("SetThreadExecutionState")
	pWaitForSingleObject           = kernel32.NewProc("WaitForSingleObject")
	pGetExitCodeProcess            = kernel32.NewProc("GetExitCodeProcess")
	pShellNotifyIconW              = shell32.NewProc("Shell_NotifyIconW")
	pShellExecuteExW               = shell32.NewProc("ShellExecuteExW")
	pIsUserAnAdmin                 = shell32.NewProc("IsUserAnAdmin")
)

type rect32 struct{ Left, Top, Right, Bottom int32 }
type point32 struct{ X, Y int32 }

type bitmapInfoHeader struct {
	Size          uint32
	Width         int32
	Height        int32
	Planes        uint16
	BitCount      uint16
	Compression   uint32
	SizeImage     uint32
	XPelsPerMeter int32
	YPelsPerMeter int32
	ClrUsed       uint32
	ClrImportant  uint32
}

type bitmap struct {
	Type       int32
	Width      int32
	Height     int32
	WidthBytes int32
	Planes     uint16
	BitsPixel  uint16
	Bits       uintptr
}

type cursorInfo struct {
	Size    uint32
	Flags   uint32
	Cursor  uintptr
	ScreenX int32
	ScreenY int32
}

type iconInfo struct {
	Icon     int32
	XHotspot uint32
	YHotspot uint32
	Mask     uintptr
	Color    uintptr
}

// INPUT with the mouse or keyboard union member (40 bytes on 64-bit Windows).
type mouseInput struct {
	Type      uint32
	_         uint32
	Dx, Dy    int32
	MouseData uint32
	Flags     uint32
	Time      uint32
	_         uint32
	Extra     uintptr
}

type keybdInput struct {
	Type  uint32
	_     uint32
	Vk    uint16
	Scan  uint16
	Flags uint32
	Time  uint32
	_     uint32
	Extra uintptr
	_     [8]byte
}

type wndClassEx struct {
	Size       uint32
	Style      uint32
	WndProc    uintptr
	ClsExtra   int32
	WndExtra   int32
	Instance   uintptr
	Icon       uintptr
	Cursor     uintptr
	Background uintptr
	MenuName   *uint16
	ClassName  *uint16
	IconSm     uintptr
}

type msg struct {
	Hwnd    uintptr
	Message uint32
	WParam  uintptr
	LParam  uintptr
	Time    uint32
	Pt      point32
	Private uint32
}

type notifyIconData struct {
	CbSize           uint32
	HWnd             uintptr
	UID              uint32
	UFlags           uint32
	UCallbackMessage uint32
	HIcon            uintptr
	SzTip            [128]uint16
	DwState          uint32
	DwStateMask      uint32
	SzInfo           [256]uint16
	UVersion         uint32
	SzInfoTitle      [64]uint16
	DwInfoFlags      uint32
	GuidItem         [16]byte
	HBalloonIcon     uintptr
}

type shellExecuteInfo struct {
	CbSize       uint32
	FMask        uint32
	Hwnd         uintptr
	LpVerb       *uint16
	LpFile       *uint16
	LpParameters *uint16
	LpDirectory  *uint16
	NShow        int32
	HInstApp     uintptr
	LpIDList     uintptr
	LpClass      *uint16
	HkeyClass    uintptr
	DwHotKey     uint32
	HIcon        uintptr
	HProcess     uintptr
}

func u16(s string) *uint16 {
	p, _ := syscall.UTF16PtrFromString(s)
	return p
}

func copyU16(dst []uint16, s string) {
	w, _ := syscall.UTF16FromString(s)
	if len(w) > len(dst) {
		w = w[:len(dst)]
		w[len(w)-1] = 0
	}
	copy(dst, w)
}

func messageBox(text, title string, flags uintptr) int {
	r, _, _ := pMessageBoxW.Call(0, uintptr(unsafe.Pointer(u16(text))), uintptr(unsafe.Pointer(u16(title))), flags)
	return int(r)
}

func newDIB(w, h int) (bmp uintptr, bits unsafe.Pointer) {
	bi := bitmapInfoHeader{Size: uint32(unsafe.Sizeof(bitmapInfoHeader{})), Width: int32(w), Height: -int32(h), Planes: 1, BitCount: 32}
	var p unsafe.Pointer
	bmp, _, _ = pCreateDIBSection.Call(0, uintptr(unsafe.Pointer(&bi)), 0, uintptr(unsafe.Pointer(&p)), 0, 0)
	return bmp, p
}
