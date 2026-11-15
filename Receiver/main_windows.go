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

	"golang.org/x/sys/windows/svc/mgr"
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
	case strings.Contains(args, "--service"):
		runService()
		return
	case strings.Contains(args, "--agent"):
		runAgent()
		return
	case strings.Contains(args, "--install"):
		os.Exit(installElevated())
	case strings.Contains(args, "--firewall"):
		os.Exit(firewallElevated())
	case strings.Contains(args, "--migrate-config"):
		setupLogAt(userConfigDir(), "install.log")
		if migrateConfig() != nil {
			os.Exit(2)
		}
		os.Exit(0)
	case strings.Contains(args, "--service-on"):
		if setServiceRunning(true) != nil {
			os.Exit(2)
		}
		os.Exit(0)
	case strings.Contains(args, "--service-off"):
		if setServiceRunning(false) != nil {
			os.Exit(2)
		}
		os.Exit(0)
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
	if !background && !samePath(exe, installedExe()) && !samePath(exe, legacyExe()) {
		upgrade(exe)
		return
	}
	if serviceQuery() != "" {
		runTrayOnly(cfg, background)
		return
	}
	runReceiver(cfg, background)
}

func samePath(a, b string) bool { return strings.EqualFold(filepath.Clean(a), filepath.Clean(b)) }

// upgrade: a newly downloaded copy was opened on a PC that's already set up. Replace the
// installed copy with it and restart.
func upgrade(exe string) {
	code, err := runElevated(exe, "--install")
	if err == nil && (code == 0 || code == 3) {
		exec.Command("schtasks", "/Run", "/TN", taskName).Run()
		msg := "ScreenLink Receiver is updated and running."
		if code == 3 {
			msg += "\n\nThe background service couldn't be set up, so UAC prompts and the sign-in screen can't be controlled. Details are in install.log."
		}
		messageBox(msg+"\n\n"+addressHelp(), appName, 0x40)
		return
	}
	// No admin rights: update the per-user copy like before.
	if err := copyFile(exe, legacyExe()); err != nil {
		messageBox("Couldn't update ScreenLink Receiver:\n\n"+err.Error(), appName, 0x10)
		return
	}
	exec.Command(legacyExe(), "--background").Start()
	messageBox("ScreenLink Receiver is updated and running.\n\nWindows permission wasn't given, so it can't control UAC prompts. Open the download again and click Yes to fix that.\n\n"+addressHelp(), appName, 0x40)
}

// ---------------------------------------------------------------------------------------
// Running

func setupLog() { setupLogAt(configDir(), "receiver.log") }

func setupLogAt(dir, name string) {
	os.MkdirAll(dir, 0o755)
	path := filepath.Join(dir, name)
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

// serviceMode: the service serves; this process is just the tray icon.
var serviceMode bool

func runTrayOnly(cfg *Config, background bool) {
	setupLogAt(userConfigDir(), "tray.log")
	mutex, _, err := pCreateMutexW.Call(0, 0, uintptr(unsafe.Pointer(u16("Local\\ScreenLinkReceiver"))))
	if mutex == 0 || err == syscall.Errno(183) {
		if !background {
			messageBox("ScreenLink Receiver is already running (look for its icon by the clock).\n\n"+addressHelp(), appName, 0x40)
		}
		return
	}
	serviceMode = true
	appCfg = cfg
	if serviceQuery() == "stopped" {
		exe, _ := os.Executable()
		if setServiceRunning(true) != nil {
			runElevated(exe, "--service-on")
		}
	}
	go func() {
		for {
			n := 0
			if st, ok := readStatus(); ok {
				n = st.Viewers
			}
			if n != trayViewers {
				setTrayTip(n)
			}
			time.Sleep(2 * time.Second)
		}
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
		addr = fmt.Sprintf("  Address: %s  (Tailscale, works anywhere)\n  Home Wi-Fi address: %s  (used at home, no Tailscale needed)", ts, lan)
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

// installedExe is where the service runs from. It has to be a folder only administrators can
// change (a service runs as SYSTEM).
func installedExe() string {
	base := os.Getenv("ProgramFiles")
	if base == "" {
		base = `C:\Program Files`
	}
	return filepath.Join(base, "ScreenLink Receiver", "ScreenLinkReceiver.exe")
}

// legacyExe is the per-user copy used when admin rights weren't given (no service).
func legacyExe() string {
	base := os.Getenv("LOCALAPPDATA")
	if base == "" {
		base = userConfigDir()
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
	exe, _ := os.Executable()
	machine := cfg.path != "" && filepath.Dir(cfg.path) == machineConfigDir()
	if err := cfg.save(); err != nil {
		if !machine {
			p("\nCouldn't save settings: %v\n", err)
			wait()
			return
		}
		// The shared settings need admin rights: save for this user, then copy them over.
		cfg.path = filepath.Join(userConfigDir(), "config.json")
		if err := cfg.save(); err != nil {
			p("\nCouldn't save settings: %v\n", err)
			wait()
			return
		}
		if changeOnly {
			p("Windows will ask for permission to update the password. Click Yes.\n")
			if code, err := runElevated(exe, "--migrate-config"); err != nil || code != 0 {
				p("\nPermission wasn't given, so the password didn't change.\n")
				wait()
				return
			}
		}
	}
	p("Password saved.\n")
	if changeOnly && (running() || serviceQuery() == "running") {
		p("\nScreenLink Receiver is running and will use the new password from now on.\n")
		wait()
		return
	}

	p("\nNext, Windows will ask for permission. Click Yes so ScreenLink can:\n")
	p("  - run in the background as a Windows service, so it can show and click\n")
	p("    UAC prompts (\"Do you want to allow this app…\"), the lock screen and sign-in\n")
	p("  - start automatically, even before you sign in\n")
	if cfg.AllowLAN {
		p("  - accept connections through the firewall (Tailscale and this network only)\n\n")
	} else {
		p("  - accept connections through the firewall (Tailscale devices only)\n\n")
	}
	code, err := runElevated(exe, "--install")
	switch {
	case err == nil && (code == 0 || code == 3):
		exec.Command("schtasks", "/Run", "/TN", taskName).Run()
		p("Done. ScreenLink Receiver is running (icon by the clock) and starts with Windows.\n")
		if code == 3 {
			p("The background service couldn't be set up, so UAC prompts can't be controlled.\n")
			p("Details: %s\n", filepath.Join(userConfigDir(), "install.log"))
		}
	default:
		if err != nil {
			p("Permission wasn't given (%v), so using a simpler setup.\n", err)
		} else {
			p("Admin setup failed (code %d), so using a simpler setup.\n", code)
		}
		p("In this mode ScreenLink can't control UAC prompts or the sign-in screen.\n")
		target := legacyExe()
		os.MkdirAll(filepath.Dir(target), 0o755)
		if err := copyFile(exe, target); err != nil {
			target = exe
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
	exec.Command("taskkill", "/F", "/IM", "ScreenLinkReceiver.exe", "/FI", fmt.Sprintf("PID ne %d", os.Getpid()),
		"/FI", fmt.Sprintf("PID ne %d", os.Getppid())).Run()
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

// installElevated runs as administrator: copies the program to Program Files, moves the settings
// to ProgramData, installs and starts the service, adds the firewall rule, and sets the tray icon
// to start at sign-in. Returns 0 on success, 3 if everything but the service worked.
func installElevated() int {
	setupLogAt(userConfigDir(), "install.log")
	src, _ := os.Executable()
	exe := installedExe()
	if m, err := mgr.Connect(); err == nil { // stop the old service so its files can be replaced
		if s, err := m.OpenService(serviceName); err == nil {
			stopService(s)
			s.Close()
		}
		m.Disconnect()
	}
	if !samePath(src, exe) {
		os.MkdirAll(filepath.Dir(exe), 0o755)
		if err := copyFile(src, exe); err != nil {
			log.Printf("copy to %s failed: %v", exe, err)
			return 2
		}
	} else {
		exec.Command("taskkill", "/F", "/IM", "ScreenLinkReceiver.exe", "/FI", fmt.Sprintf("PID ne %d", os.Getpid()),
			"/FI", fmt.Sprintf("PID ne %d", os.Getppid())).Run()
	}
	if err := migrateConfig(); err != nil {
		log.Printf("moving settings failed: %v", err)
		return 2
	}
	cfg := loadConfig()
	// The tray icon: a normal app at sign-in, with admin rights so its switches can change settings.
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
	if err := installService(exe); err != nil {
		log.Printf("service setup failed: %v", err)
		return 3
	}
	log.Print("installed: service running")
	return 0
}

// migrateConfig moves this user's settings to the shared ProgramData folder and locks it down
// (administrators and SYSTEM can change it; other users can only read it).
func migrateConfig() error {
	dir := machineConfigDir()
	user := filepath.Join(userConfigDir(), "config.json")
	machine := filepath.Join(dir, "config.json")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	exec.Command("icacls", dir, "/inheritance:r", "/grant:r", "*S-1-5-18:(OI)(CI)F", "*S-1-5-32-544:(OI)(CI)F",
		"*S-1-5-32-545:(OI)(CI)RX").Run()
	us, uerr := os.Stat(user)
	ms, merr := os.Stat(machine)
	if uerr != nil || (merr == nil && !us.ModTime().After(ms.ModTime())) {
		if merr != nil {
			return fmt.Errorf("no settings found")
		}
		return nil
	}
	b, err := os.ReadFile(user)
	if err != nil {
		return err
	}
	if err := os.WriteFile(machine, b, 0o600); err != nil {
		return err
	}
	os.Remove(user)
	log.Printf("settings moved to %s", machine)
	return nil
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
	if lan := lanIP(); ip != "" && ip != lan && lan != "" && appCfg != nil && appCfg.AllowLAN {
		add(mfGrayed, 0, fmt.Sprintf("Home Wi-Fi address: %s", lan))
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
		if serviceMode && setServiceRunning(false) != nil {
			runElevated(exe, "--service-off")
		}
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
