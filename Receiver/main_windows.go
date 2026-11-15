package main

import (
	"bufio"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

const taskName = "ScreenLink Receiver"

func main() {
	// Physical pixels on every monitor, whatever the Windows scaling setting.
	dpiOK := false
	if pSetProcessDpiAwarenessContext.Find() == nil {
		r, _, _ := pSetProcessDpiAwarenessContext.Call(^uintptr(3)) // PER_MONITOR_AWARE_V2 (-4)
		dpiOK = r != 0
	}
	if !dpiOK && pSetProcessDPIAware.Find() == nil {
		pSetProcessDPIAware.Call()
	}
	args := strings.Join(os.Args[1:], " ")
	switch {
	case strings.Contains(args, "--install"):
		os.Exit(installElevated())
	case strings.Contains(args, "--firewall"):
		os.Exit(firewallElevated())
	case strings.Contains(args, "--setup"):
		runSetup(true)
		return
	}
	cfg := loadConfig()
	if !cfg.configured() {
		runSetup(false)
		return
	}
	background := strings.Contains(args, "--background")
	exe, _ := os.Executable()
	if !background && !strings.EqualFold(filepath.Clean(exe), filepath.Clean(installedExe())) {
		upgrade(exe)
		return
	}
	runReceiver(cfg, background)
}

// upgrade: a newly downloaded copy was opened on a PC that's already set up. Replace the
// installed copy with it and restart.
func upgrade(exe string) {
	if err := copyFile(exe, installedExe()); err != nil {
		messageBox("Couldn't update ScreenLink Receiver:\n\n"+err.Error(), appName, 0x10)
		return
	}
	if exec.Command("schtasks", "/Run", "/TN", taskName).Run() != nil {
		exec.Command(installedExe(), "--background").Start()
	}
	messageBox("ScreenLink Receiver is updated and running.\n\n"+addressHelp(), appName, 0x40)
}

// ---------------------------------------------------------------------------------------
// Running

func setupLog() {
	os.MkdirAll(configDir(), 0o700)
	path := filepath.Join(configDir(), "receiver.log")
	if st, err := os.Stat(path); err == nil && st.Size() > 1<<20 {
		os.Rename(path, path+".old")
	}
	if f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600); err == nil {
		log.SetOutput(f)
	}
}

func runReceiver(cfg *Config, background bool) {
	setupLog()
	mutex, _, err := pCreateMutexW.Call(0, 0, uintptr(unsafe.Pointer(u16("Local\\ScreenLinkReceiver"))))
	if mutex == 0 || err == syscall.Errno(183) { // ERROR_ALREADY_EXISTS
		if !background {
			messageBox("ScreenLink Receiver is already running (look for its icon by the clock).\n\n"+addressHelp(), appName, 0x40)
		}
		return
	}
	appCfg = cfg
	l, err := listen(cfg)
	if err != nil {
		log.Print(err)
		messageBox("ScreenLink Receiver couldn't start:\n\n"+err.Error(), appName, 0x10)
		return
	}
	log.Printf("%s started, listening on port %d (Tailscale IP %q)", appName, cfg.Port, tailscaleIP())
	plat := newWinPlatform(cfg)
	srv := NewServer(cfg, plat)
	awake := make(chan bool, 4)
	go keepAwake(awake)
	srv.OnViewers = func(n int) {
		awake <- n > 0
		setTrayTip(n)
	}
	go func() {
		err := srv.Serve(l)
		log.Printf("server stopped: %v", err)
		os.Exit(1)
	}()
	runTray(!background)
}

// keepAwake stops the PC from sleeping while someone is connected.
func keepAwake(on <-chan bool) {
	runtime.LockOSThread()
	const esContinuous, esSystem, esDisplay = 0x80000000, 0x1, 0x2
	for v := range on {
		if v {
			pSetThreadExecutionState.Call(esContinuous | esSystem | esDisplay)
		} else {
			pSetThreadExecutionState.Call(esContinuous)
		}
	}
}

func addressHelp() string {
	cfg := loadConfig()
	ts, lan := tailscaleIP(), lanIP()
	host, _ := os.Hostname()
	var addr string
	switch {
	case ts != "" && cfg.AllowLAN && lan != "":
		addr = fmt.Sprintf("  Address: %s  (anywhere, with Tailscale)\n       or: %s  (on this Wi-Fi, no Tailscale needed)", ts, lan)
	case ts != "":
		addr = fmt.Sprintf("  Address: %s  (or %s)", ts, strings.ToLower(host))
	case cfg.AllowLAN && lan != "":
		addr = fmt.Sprintf("  Address: %s  (your iPhone must be on the same Wi-Fi)", lan)
	default:
		return "Tailscale isn't running on this PC. Either install it from tailscale.com/download/windows and sign in with the same account as your iPhone, or turn on \"Allow devices on this Wi-Fi\" in the ScreenLink tray menu (by the clock)."
	}
	return fmt.Sprintf("In ScreenLink on your iPhone, add this PC:\n%s\n  Username: %s\n  Password: the one you chose during setup", addr, windowsUser())
}

func windowsUser() string {
	if u, err := user.Current(); err == nil {
		name := u.Username
		if i := strings.LastIndex(name, "\\"); i >= 0 {
			name = name[i+1:]
		}
		return name
	}
	return os.Getenv("USERNAME")
}

// ---------------------------------------------------------------------------------------
// First-run setup (in a console window)

func openConsole() (in *bufio.Reader, out io.Writer, inFile *os.File) {
	pAllocConsole.Call()
	pSetConsoleTitleW.Call(uintptr(unsafe.Pointer(u16("ScreenLink Receiver Setup"))))
	o, _ := os.OpenFile("CONOUT$", os.O_RDWR, 0)
	i, _ := os.OpenFile("CONIN$", os.O_RDWR, 0)
	os.Stdout, os.Stderr = o, o
	return bufio.NewReader(i), o, i
}

func readHidden(in *bufio.Reader, f *os.File) string {
	var mode uint32
	h := f.Fd()
	pGetConsoleMode.Call(h, uintptr(unsafe.Pointer(&mode)))
	pSetConsoleMode.Call(h, uintptr(mode&^0x0004)) // no echo
	line, _ := in.ReadString('\n')
	pSetConsoleMode.Call(h, uintptr(mode))
	fmt.Println()
	return strings.TrimRight(line, "\r\n")
}

func installedExe() string {
	base := os.Getenv("LOCALAPPDATA")
	if base == "" {
		base = configDir()
	}
	return filepath.Join(base, "Programs", "ScreenLink Receiver", "ScreenLinkReceiver.exe")
}

func runSetup(changeOnly bool) {
	in, out, inFile := openConsole()
	p := func(format string, a ...any) { fmt.Fprintf(out, format, a...) }
	wait := func() {
		p("\nPress Enter to close this window.")
		in.ReadString('\n')
		pFreeConsole.Call()
	}
	cfg := loadConfig()
	p("ScreenLink Receiver\n===================\n\n")
	p("This lets ScreenLink on your iPhone see and control this PC.\n\n")

	for {
		p("Choose a password for ScreenLink to use (at least 8 characters): ")
		a := readHidden(in, inFile)
		if len(a) < 8 {
			p("That's too short. Try again.\n\n")
			continue
		}
		p("Type it again: ")
		if b := readHidden(in, inFile); a != b {
			p("Those didn't match. Try again.\n\n")
			continue
		}
		cfg.setPassword(a)
		break
	}
	if !changeOnly {
		p("\nAllow iPhones on this Wi-Fi to connect without Tailscale? (Tailscale also encrypts the\n")
		p("picture, so only say yes for your home network.) Type y or n, then Enter: ")
		ans, _ := in.ReadString('\n')
		cfg.AllowLAN = strings.HasPrefix(strings.ToLower(strings.TrimSpace(ans)), "y")
	}
	if err := cfg.save(); err != nil {
		p("\nCouldn't save settings: %v\n", err)
		wait()
		return
	}
	p("Password saved.\n")
	if changeOnly && running() {
		p("\nScreenLink Receiver is running and will use the new password from now on.\n")
		wait()
		return
	}

	// Copy to a permanent place so it still works if the download is deleted.
	exe, _ := os.Executable()
	target := installedExe()
	if !strings.EqualFold(filepath.Clean(exe), filepath.Clean(target)) {
		os.MkdirAll(filepath.Dir(target), 0o755)
		if err := copyFile(exe, target); err != nil {
			p("\nCouldn't install to %s: %v\nRunning from the current location instead.\n", target, err)
			target = exe
		}
	}

	p("\nNext, Windows will ask for permission. Click Yes so ScreenLink can:\n")
	p("  - start automatically when you sign in\n")
	p("  - control apps that run as administrator\n")
	if cfg.AllowLAN {
		p("  - accept connections through the firewall (Tailscale and this network only)\n\n")
	} else {
		p("  - accept connections through the firewall (Tailscale devices only)\n\n")
	}
	code, err := runElevated(target, "--install")
	switch {
	case err == nil && code == 0:
		exec.Command("schtasks", "/Run", "/TN", taskName).Run()
		p("Done. ScreenLink Receiver is running (icon by the clock) and will start when you sign in.\n")
	default:
		if err != nil {
			p("Permission wasn't given (%v), so using a simpler setup.\n", err)
		} else {
			p("Admin setup failed (code %d), so using a simpler setup.\n", code)
		}
		setRunKey(target)
		exec.Command(target, "--background").Start()
		p("ScreenLink Receiver is running and will start when you sign in.\n")
		p("If Windows asks whether to allow it through the firewall, click Allow.\n")
	}
	p("\n%s\n", addressHelp())
	wait()
}

func running() bool {
	h, _, err := pCreateMutexW.Call(0, 0, uintptr(unsafe.Pointer(u16("Local\\ScreenLinkReceiver"))))
	if h != 0 {
		defer syscall.CloseHandle(syscall.Handle(h))
	}
	return err == syscall.Errno(183)
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	tmp := dst + ".new"
	out, err := os.Create(tmp)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	out.Close()
	// If an older copy is running, stop it so it can be replaced.
	exec.Command("taskkill", "/F", "/IM", "ScreenLinkReceiver.exe", "/FI", fmt.Sprintf("PID ne %d", os.Getpid())).Run()
	time.Sleep(300 * time.Millisecond)
	return os.Rename(tmp, dst)
}

// runElevated starts exe with a UAC prompt and waits for it.
func runElevated(exe, args string) (int, error) {
	const seeMaskNoCloseProcess = 0x40
	info := shellExecuteInfo{FMask: seeMaskNoCloseProcess, LpVerb: u16("runas"), LpFile: u16(exe), LpParameters: u16(args), NShow: 0}
	info.CbSize = uint32(unsafe.Sizeof(info))
	if r, _, err := pShellExecuteExW.Call(uintptr(unsafe.Pointer(&info))); r == 0 {
		return -1, err
	}
	pWaitForSingleObject.Call(info.HProcess, 0xFFFFFFFF)
	var code uint32
	pGetExitCodeProcess.Call(info.HProcess, uintptr(unsafe.Pointer(&code)))
	syscall.CloseHandle(syscall.Handle(info.HProcess))
	return int(code), nil
}

// installElevated runs as administrator: logon task with highest privileges + firewall rule.
func installElevated() int {
	setupLog()
	exe, _ := os.Executable()
	cfg := loadConfig()
	tr := fmt.Sprintf(`"%s" --background`, exe)
	// Created by the signed-in user (elevated), so it runs as them, only while they're signed in.
	out, err := exec.Command("schtasks", "/Create", "/F", "/TN", taskName, "/SC", "ONLOGON", "/RL", "HIGHEST", "/TR", tr).CombinedOutput()
	if err != nil {
		log.Printf("schtasks failed: %v %s", err, out)
		return 2
	}
	// The task's default 3-day time limit would stop the receiver; remove it.
	exec.Command("powershell", "-NoProfile", "-Command",
		fmt.Sprintf(`$s = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries; Set-ScheduledTask -TaskName '%s' -Settings $s`, taskName)).Run()
	addFirewallRule(exe, cfg)
	removeRunKey()
	return 0
}

// firewallElevated runs as administrator after the tray's Wi-Fi switch changes the setting.
func firewallElevated() int {
	setupLog()
	exe, _ := os.Executable()
	if addFirewallRule(exe, loadConfig()) != nil {
		return 2
	}
	return 0
}

func addFirewallRule(exe string, cfg *Config) error {
	exec.Command("netsh", "advfirewall", "firewall", "delete", "rule", "name="+taskName).Run()
	out, err := exec.Command("netsh", "advfirewall", "firewall", "add", "rule", "name="+taskName, "dir=in", "action=allow",
		"program="+exe, "enable=yes", "profile=any", "protocol=TCP", fmt.Sprintf("localport=%d", cfg.Port),
		"remoteip="+cfg.firewallRemote()).CombinedOutput()
	if err != nil {
		log.Printf("firewall rule failed: %v %s", err, out)
	} else {
		log.Printf("firewall rule set: remoteip=%s", cfg.firewallRemote())
	}
	return err
}

// toggleLAN flips "Allow devices on this Wi-Fi" and updates the firewall rule (with a UAC prompt).
func toggleLAN() {
	cfg := appCfg
	cfg.mu.Lock()
	cfg.AllowLAN = !cfg.AllowLAN
	on := cfg.AllowLAN
	cfg.mu.Unlock()
	if err := cfg.save(); err != nil {
		messageBox("Couldn't save the setting:\n\n"+err.Error(), appName, 0x10)
		return
	}
	exe, _ := os.Executable()
	if code, err := runElevated(exe, "--firewall"); err != nil || code != 0 {
		cfg.mu.Lock()
		cfg.AllowLAN = !on
		cfg.mu.Unlock()
		cfg.save()
		messageBox("Windows didn't give permission to change the firewall, so nothing changed.", appName, 0x30)
		return
	}
	setTrayTip(trayViewers)
	if on {
		messageBox("iPhones on this Wi-Fi can now connect without Tailscale.\n\n"+addressHelp(), appName, 0x40)
	} else {
		messageBox("Only Tailscale devices can connect now.", appName, 0x40)
	}
}

func setRunKey(exe string) {
	exec.Command("reg", "add", `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, "/v", taskName, "/t", "REG_SZ",
		"/d", fmt.Sprintf(`"%s" --background`, exe), "/f").Run()
}

func removeRunKey() {
	exec.Command("reg", "delete", `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, "/v", taskName, "/f").Run()
}

// ---------------------------------------------------------------------------------------
// Tray icon

var (
	appCfg      *Config
	trayHwnd    uintptr
	trayData    notifyIconData
	taskbarMsg  uintptr
	trayViewers int
)

const (
	wmApp       = 0x8000
	trayMsg     = wmApp + 1
	wmDestroy   = 0x0002
	wmCommand   = 0x0111
	wmLButtonUp = 0x0202
	wmRButtonUp = 0x0205
	nimAdd      = 0
	nimModify   = 1
	nimDelete   = 2
	nifMessage  = 1
	nifIcon     = 2
	nifTip      = 4
	nifInfo     = 0x10

	menuPassword = 10
	menuLog      = 11
	menuQuit     = 12
	menuLAN      = 13
)

// connectAddress is the address to show in the tray: Tailscale first, else this network's.
func connectAddress() string {
	if ip := tailscaleIP(); ip != "" {
		return ip
	}
	if appCfg != nil && appCfg.AllowLAN {
		return lanIP()
	}
	return ""
}

func trayTip() string {
	ip := connectAddress()
	if ip == "" {
		ip = "Tailscale not running"
	}
	if trayViewers > 0 {
		return fmt.Sprintf("ScreenLink Receiver – %d connected (%s)", trayViewers, ip)
	}
	return fmt.Sprintf("ScreenLink Receiver – waiting (%s)", ip)
}

func setTrayTip(n int) {
	trayViewers = n
	if trayHwnd == 0 {
		return
	}
	d := trayData
	d.UFlags = nifTip
	copyU16(d.SzTip[:], trayTip())
	pShellNotifyIconW.Call(nimModify, uintptr(unsafe.Pointer(&d)))
}

func addTrayIcon(balloon bool) {
	trayData = notifyIconData{HWnd: trayHwnd, UID: 1, UFlags: nifMessage | nifIcon | nifTip, UCallbackMessage: trayMsg, HIcon: makeIcon()}
	trayData.CbSize = uint32(unsafe.Sizeof(trayData))
	copyU16(trayData.SzTip[:], trayTip())
	d := trayData
	if balloon {
		d.UFlags |= nifInfo
		copyU16(d.SzInfoTitle[:], "ScreenLink Receiver is on")
		copyU16(d.SzInfo[:], "Your iPhone can now connect to this PC.")
	}
	pShellNotifyIconW.Call(nimAdd, uintptr(unsafe.Pointer(&d)))
}

func runTray(balloon bool) {
	runtime.LockOSThread()
	cls := u16("ScreenLinkReceiverTray")
	wc := wndClassEx{WndProc: syscall.NewCallback(trayProc), ClassName: cls}
	wc.Size = uint32(unsafe.Sizeof(wc))
	pRegisterClassExW.Call(uintptr(unsafe.Pointer(&wc)))
	trayHwnd, _, _ = pCreateWindowExW.Call(0, uintptr(unsafe.Pointer(cls)), uintptr(unsafe.Pointer(u16(appName))), 0, 0, 0, 0, 0, 0, 0, 0, 0)
	taskbarMsg, _, _ = pRegisterWindowMessageW.Call(uintptr(unsafe.Pointer(u16("TaskbarCreated"))))
	addTrayIcon(balloon)
	var m msg
	for {
		r, _, _ := pGetMessageW.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
		if int32(r) <= 0 {
			break
		}
		pTranslateMessage.Call(uintptr(unsafe.Pointer(&m)))
		pDispatchMessageW.Call(uintptr(unsafe.Pointer(&m)))
	}
	pShellNotifyIconW.Call(nimDelete, uintptr(unsafe.Pointer(&trayData)))
	os.Exit(0)
}

func trayProc(hwnd, message, wParam, lParam uintptr) uintptr {
	switch {
	case message == trayMsg && (lParam&0xFFFF == wmRButtonUp || lParam&0xFFFF == wmLButtonUp):
		showMenu()
		return 0
	case message == taskbarMsg && taskbarMsg != 0: // Explorer restarted
		addTrayIcon(false)
		return 0
	case message == wmDestroy:
		pPostQuitMessage.Call(0)
		return 0
	}
	r, _, _ := pDefWindowProcW.Call(hwnd, message, wParam, lParam)
	return r
}

func showMenu() {
	menu, _, _ := pCreatePopupMenu.Call()
	defer pDestroyMenu.Call(menu)
	add := func(flags, id uintptr, text string) {
		pAppendMenuW.Call(menu, flags, id, uintptr(unsafe.Pointer(u16(text))))
	}
	const mfGrayed, mfChecked, mfSeparator = 0x1, 0x8, 0x800
	ip := connectAddress()
	if ip == "" {
		add(mfGrayed, 0, "Tailscale isn't running on this PC")
	} else {
		add(mfGrayed, 0, fmt.Sprintf("Connect ScreenLink to %s", ip))
	}
	if trayViewers > 0 {
		add(mfGrayed, 0, fmt.Sprintf("%d iPhone connected", trayViewers))
	}
	add(mfSeparator, 0, "")
	lanFlag := uintptr(0)
	if appCfg != nil && appCfg.AllowLAN {
		lanFlag = mfChecked
	}
	add(lanFlag, menuLAN, "Allow Devices on This Wi-Fi (No Tailscale)")
	add(0, menuPassword, "Change Password…")
	add(0, menuLog, "Open Log")
	add(0, menuQuit, "Quit ScreenLink Receiver")
	var pt point32
	pGetCursorPos.Call(uintptr(unsafe.Pointer(&pt)))
	pSetForegroundWindow.Call(trayHwnd)
	cmd, _, _ := pTrackPopupMenu.Call(menu, 0x0100|0x0002, uintptr(pt.X), uintptr(pt.Y), 0, trayHwnd, 0) // RETURNCMD|RIGHTBUTTON
	pPostMessageW.Call(trayHwnd, 0, 0, 0)
	exe, _ := os.Executable()
	switch cmd {
	case menuPassword:
		exec.Command(exe, "--setup").Start()
	case menuLAN:
		go toggleLAN()
	case menuLog:
		exec.Command("notepad", filepath.Join(configDir(), "receiver.log")).Start()
	case menuQuit:
		pShellNotifyIconW.Call(nimDelete, uintptr(unsafe.Pointer(&trayData)))
		os.Exit(0)
	}
}

// makeIcon draws a small monitor glyph for the tray (32×32, white on blue).
func makeIcon() uintptr {
	const n = 32
	color, bits := newDIB(n, n)
	if color == 0 {
		r, _, _ := pLoadIconW.Call(0, 32512)
		return r
	}
	px := unsafe.Slice((*byte)(bits), n*n*4)
	set := func(x, y int, b, g, r, a byte) {
		o := (y*n + x) * 4
		px[o], px[o+1], px[o+2], px[o+3] = b, g, r, a
	}
	for y := 0; y < n; y++ {
		for x := 0; x < n; x++ {
			dx, dy := float64(x)-15.5, float64(y)-15.5
			if dx*dx+dy*dy <= 15.5*15.5 {
				set(x, y, 0xF0, 0x84, 0x0A, 255) // blue disc
			}
		}
	}
	for y := 8; y <= 20; y++ { // screen outline
		for x := 7; x <= 24; x++ {
			if y == 8 || y == 20 || x == 7 || x == 24 || y == 9 || x == 8 || x == 23 || y == 19 {
				set(x, y, 255, 255, 255, 255)
			}
		}
	}
	for y := 21; y <= 23; y++ { // stand
		for x := 14; x <= 17; x++ {
			set(x, y, 255, 255, 255, 255)
		}
	}
	for x := 11; x <= 20; x++ {
		set(x, 24, 255, 255, 255, 255)
	}
	mask, _, _ := pCreateBitmap.Call(n, n, 1, 1, uintptr(unsafe.Pointer(&make([]byte, n*n/8)[0])))
	ii := iconInfo{Icon: 1, Mask: mask, Color: color}
	icon, _, _ := pCreateIconIndirect.Call(uintptr(unsafe.Pointer(&ii)))
	pDeleteObject.Call(mask)
	pDeleteObject.Call(color)
	if icon == 0 {
		icon, _, _ = pLoadIconW.Call(0, 32512)
	}
	return icon
}
