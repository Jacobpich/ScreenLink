package main

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
)

// Service mode: the "ScreenLink Receiver" Windows service runs as SYSTEM and starts an
// "agent" copy of this program in the console session, also as SYSTEM. Only SYSTEM may use the
// secure desktop, so the agent can show and click UAC prompts, the lock screen and the
// sign-in screen. The tray icon is a separate, normal app that only shows status.

const serviceName = "ScreenLinkReceiver"

func runService() {
	setupLogAt(machineConfigDir(), "service.log")
	if err := svc.Run(serviceName, agentService{}); err != nil {
		log.Printf("service failed: %v", err)
	}
}

type agentService struct{}

func (agentService) Execute(args []string, req <-chan svc.ChangeRequest, status chan<- svc.Status) (bool, uint32) {
	status <- svc.Status{State: svc.StartPending}
	stop := make(chan struct{})
	poke := make(chan struct{}, 1)
	done := make(chan struct{})
	go func() {
		superviseAgent(stop, poke)
		close(done)
	}()
	status <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown | svc.AcceptSessionChange}
	log.Print("service running")
	for c := range req {
		switch c.Cmd {
		case svc.Interrogate:
			status <- c.CurrentStatus
		case svc.SessionChange:
			select {
			case poke <- struct{}{}:
			default:
			}
		case svc.Stop, svc.Shutdown:
			status <- svc.Status{State: svc.StopPending}
			close(stop)
			<-done
			log.Print("service stopped")
			return false, 0
		}
	}
	return false, 0
}

// superviseAgent keeps one agent running in whichever session owns the physical screen.
func superviseAgent(stop, poke <-chan struct{}) {
	var proc windows.Handle
	session := ^uint32(0)
	kill := func() {
		if proc != 0 {
			windows.TerminateProcess(proc, 0)
			windows.WaitForSingleObject(proc, 3000)
			windows.CloseHandle(proc)
			proc = 0
		}
	}
	defer kill()
	failures := 0
	for {
		want := windows.WTSGetActiveConsoleSessionId()
		running := proc != 0
		if running {
			if ev, _ := windows.WaitForSingleObject(proc, 0); ev == windows.WAIT_OBJECT_0 {
				var code uint32
				windows.GetExitCodeProcess(proc, &code)
				log.Printf("agent exited (code %d)", code)
				windows.CloseHandle(proc)
				proc, running = 0, false
				failures++
			}
		}
		if running && want != session {
			log.Printf("console moved to session %d; restarting agent", want)
			kill()
			running = false
		}
		if !running && want != 0xFFFFFFFF {
			p, err := launchAgent(want)
			if err != nil {
				log.Printf("couldn't start agent in session %d: %v", want, err)
				failures++
			} else {
				proc, session = p, want
				log.Printf("agent started in session %d", want)
			}
		}
		wait := 2 * time.Second
		if failures > 3 {
			wait = 10 * time.Second // something's wrong; don't spin
		}
		if proc != 0 {
			failures = 0
		}
		select {
		case <-stop:
			return
		case <-poke:
			time.Sleep(500 * time.Millisecond) // let the session switch settle
		case <-time.After(wait):
		}
	}
}

// launchAgent starts "<exe> --agent" as SYSTEM inside the given session.
func launchAgent(session uint32) (windows.Handle, error) {
	var self windows.Token
	if err := windows.OpenProcessToken(windows.CurrentProcess(), windows.TOKEN_ALL_ACCESS, &self); err != nil {
		return 0, fmt.Errorf("open token: %w", err)
	}
	defer self.Close()
	var tok windows.Token
	if err := windows.DuplicateTokenEx(self, windows.MAXIMUM_ALLOWED, nil, windows.SecurityImpersonation, windows.TokenPrimary, &tok); err != nil {
		return 0, fmt.Errorf("duplicate token: %w", err)
	}
	defer tok.Close()
	if err := windows.SetTokenInformation(tok, windows.TokenSessionId, (*byte)(unsafe.Pointer(&session)), 4); err != nil {
		return 0, fmt.Errorf("set session: %w", err)
	}
	exe, _ := os.Executable()
	cmd, _ := windows.UTF16PtrFromString(fmt.Sprintf(`"%s" --agent`, exe))
	si := windows.StartupInfo{Desktop: u16(`winsta0\default`)}
	si.Cb = uint32(unsafe.Sizeof(si))
	var pi windows.ProcessInformation
	const createNoWindow = 0x08000000
	if err := windows.CreateProcessAsUser(tok, nil, cmd, nil, nil, false, createNoWindow, nil, nil, &si, &pi); err != nil {
		return 0, fmt.Errorf("create process: %w", err)
	}
	windows.CloseHandle(pi.Thread)
	return pi.Process, nil
}

// runAgent is the actual screen server when the service is in use.
func runAgent() {
	setupLogAt(machineConfigDir(), "receiver.log")
	cfg := loadConfig()
	if !cfg.configured() {
		log.Print("agent: no password set; exiting")
		return
	}
	startClipboardWindow()
	l, err := listen(cfg)
	if err != nil {
		log.Print(err)
		time.Sleep(5 * time.Second) // the old copy may still be letting go of the port
		os.Exit(1)
	}
	log.Printf("agent listening on port %d (Tailscale IP %q, Wi-Fi %q, Wi-Fi allowed %v)", cfg.Port, tailscaleIP(), lanIP(), cfg.AllowLAN)
	plat := newWinPlatform(cfg)
	srv := NewServer(cfg, plat)
	awake := make(chan bool, 4)
	go keepAwake(awake)
	writeStatus(0)
	srv.OnViewers = func(n int) {
		awake <- n > 0
		writeStatus(n)
	}
	go func() { // pick up settings changed from the tray (password, Wi-Fi switch)
		for range time.Tick(3 * time.Second) {
			cfg.reload()
		}
	}()
	err = srv.Serve(l)
	log.Printf("server stopped: %v", err)
	os.Exit(1)
}

type agentStatus struct {
	Viewers int       `json:"viewers"`
	Updated time.Time `json:"updated"`
}

func statusPath() string { return filepath.Join(machineConfigDir(), "status.json") }

func writeStatus(n int) {
	b, _ := json.Marshal(agentStatus{Viewers: n, Updated: time.Now()})
	os.WriteFile(statusPath(), b, 0o644)
}

func readStatus() (agentStatus, bool) {
	var s agentStatus
	b, err := os.ReadFile(statusPath())
	if err != nil || json.Unmarshal(b, &s) != nil {
		return s, false
	}
	return s, true
}

// ---------------------------------------------------------------------------------------
// Installing and controlling the service (needs administrator rights)

// serviceQuery asks the SCM with minimal rights (works for normal users), returning the state
// ("running", "stopped"…) or "" if the service doesn't exist.
func serviceQuery() string {
	scm, err := windows.OpenSCManager(nil, nil, windows.SC_MANAGER_CONNECT)
	if err != nil {
		return ""
	}
	defer windows.CloseServiceHandle(scm)
	h, err := windows.OpenService(scm, u16(serviceName), windows.SERVICE_QUERY_STATUS)
	if err != nil {
		return ""
	}
	defer windows.CloseServiceHandle(h)
	var st windows.SERVICE_STATUS
	if windows.QueryServiceStatus(h, &st) != nil {
		return "unknown"
	}
	switch st.CurrentState {
	case windows.SERVICE_RUNNING:
		return "running"
	case windows.SERVICE_STOPPED:
		return "stopped"
	default:
		return "changing"
	}
}

// installService creates (or updates) the service to run exe, and starts it.
func installService(exe string) error {
	m, err := mgr.Connect()
	if err != nil {
		return err
	}
	defer m.Disconnect()
	conf := mgr.Config{
		DisplayName:  appName,
		Description:  "Lets ScreenLink on your iPhone or Mac see and control this PC, including UAC prompts and the sign-in screen.",
		StartType:    mgr.StartAutomatic,
		ErrorControl: mgr.ErrorNormal,
	}
	s, err := m.OpenService(serviceName)
	if err == nil {
		stopService(s)
		conf.BinaryPathName = fmt.Sprintf(`"%s" --service`, exe)
		if err := s.UpdateConfig(conf); err != nil {
			s.Close()
			return fmt.Errorf("update service: %w", err)
		}
	} else {
		s, err = m.CreateService(serviceName, exe, conf, "--service")
		if err != nil {
			return fmt.Errorf("create service: %w", err)
		}
	}
	defer s.Close()
	s.SetRecoveryActions([]mgr.RecoveryAction{
		{Type: mgr.ServiceRestart, Delay: 2 * time.Second},
		{Type: mgr.ServiceRestart, Delay: 5 * time.Second},
		{Type: mgr.ServiceRestart, Delay: 30 * time.Second},
	}, 3600)
	if err := s.Start(); err != nil {
		return fmt.Errorf("start service: %w", err)
	}
	return nil
}

func stopService(s *mgr.Service) {
	st, err := s.Control(svc.Stop)
	if err != nil {
		return
	}
	for i := 0; i < 50 && st.State != svc.Stopped; i++ {
		time.Sleep(200 * time.Millisecond)
		if st, err = s.Query(); err != nil {
			return
		}
	}
}

// setServiceRunning starts or stops the installed service (admin).
func setServiceRunning(on bool) error {
	m, err := mgr.Connect()
	if err != nil {
		return err
	}
	defer m.Disconnect()
	s, err := m.OpenService(serviceName)
	if err != nil {
		return err
	}
	defer s.Close()
	if on {
		err = s.Start()
		if errno, ok := err.(syscall.Errno); ok && errno == windows.ERROR_SERVICE_ALREADY_RUNNING {
			err = nil
		}
		return err
	}
	stopService(s)
	return nil
}
