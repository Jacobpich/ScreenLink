# ScreenLink Receiver (Windows)

Lets ScreenLink on the iPhone see and control a Windows PC, the same way it uses macOS
Screen Sharing on a Mac. It's a small RFB (VNC) server written in Go with no dependencies.

## Install on the PC

Download: [ScreenLinkReceiver.exe](https://github.com/Jacobpich/ScreenLink/raw/main/Downloads/ScreenLinkReceiver.exe)
([ARM64](https://github.com/Jacobpich/ScreenLink/raw/main/Downloads/ScreenLinkReceiver-arm64.exe)). Step-by-step
instructions are in the [main README](../README.md#windows-pc-download).

1. Run `ScreenLinkReceiver.exe`. Windows SmartScreen may warn because the app isn't signed: **More info → Run anyway**.
2. Choose a password in the setup window, and answer whether iPhones on this Wi-Fi may connect
   without Tailscale.
3. Click **Yes** when Windows asks for permission. That copies it to `C:\Program Files\ScreenLink Receiver`,
   installs the **ScreenLink Receiver** Windows service, starts the tray icon at sign-in, and adds a
   firewall rule that only lets Tailscale devices (100.64.0.0/10) in, plus this network
   (`LocalSubnet`) if you said yes.
4. In ScreenLink: put the Tailscale address (100.x) in **Tailscale name or IP** and the home address
   (192.168.x.x) in **Home Wi-Fi address**, plus any username and that password. ScreenLink uses the
   home address when it answers and Tailscale otherwise.

The tray icon (by the clock) shows the address and has **Allow Devices on This Wi-Fi** (flips the
setting and the firewall rule, with a permission prompt), Change Password, Open Log and Quit.
Opening a newer `.exe` on a PC that's already set up updates the installed copy.
Settings and logs live in `C:\ProgramData\ScreenLink Receiver\`.

## How it works

- **Sign-in:** security type 30 (Diffie-Hellman + AES, the same as macOS), so ScreenLink's
  existing sign-in works. Only a salted PBKDF2 hash of the password is stored. Connections
  from outside Tailscale are refused unless "Allow Devices on This Wi-Fi" is on (then private
  network addresses are let in too, never the internet). Repeated wrong passwords are slowed
  down and then locked out.
- **Picture:** GDI capture of the whole desktop (all monitors, physical pixels), 64×64 tile
  diffing, ZRLE compression. It only sends after ScreenLink asks, like macOS. Monitor layout
  goes out as ExtendedDesktopSize, so ScreenLink's Displays button works.
- **Cursor:** the pointer shape is sent as a cursor pseudo-encoding (alpha recovered by drawing
  it on black and on white). Inverting cursors such as the text I-beam get a white outline, so
  ScreenLink's "keyboard in text fields" works.
- **Keyboard:** `keys.go` translates Mac habits. ⌘C/V/X/Z/A… → Ctrl, ⌘Tab → Alt+Tab,
  ⌘Space → Start, ⌘Q → Alt+F4, ⌘←/→ → Home/End, ⌥←/→ → Ctrl+←/→, ⌃↑ → Task View,
  ⌃←/→ → switch desktops, ⌃⌘Q → Win+L, ⌘⇧4 → Win+Shift+S. Typing goes in as Unicode, so any
  keyboard layout types correctly. Super (Win) is passed through.
- **Clipboard:** both directions, UTF-8.
- Keeps the PC awake while someone is connected.

## UAC prompts, lock screen and sign-in

Windows draws UAC prompts, the lock screen and the sign-in screen on a separate **secure desktop**
that normal apps can't see or control. Only SYSTEM can. So the receiver runs as a Windows service
(SYSTEM, `--service`), which starts a copy of itself (`--agent`) in the session on the physical screen.
The agent does the screen capture and input on one thread that follows whichever desktop has the
input (`desktop_windows.go`), so when a UAC prompt appears you see it on the iPhone and can click
**Yes**. It also works at the lock screen and after a reboot, before anyone has signed in.
When the session changes (sign out, switch user), the service restarts the agent there.

- Settings (password hash, Wi-Fi switch) live in `C:\ProgramData\ScreenLink Receiver\`, which only
  administrators can change. The agent's log is `receiver.log` there; the service's is `service.log`.
- The program lives in `C:\Program Files\ScreenLink Receiver\` (a service must run from a folder
  normal users can't write to).
- The tray icon is a separate normal app that shows status. Quit stops the service until the next
  sign-in or restart.
- If permission isn't given during setup, it falls back to the old per-user mode, which can't
  control UAC prompts or the sign-in screen.

## Limits

- **Ctrl+Alt+Delete** can't be sent. If your PC requires it at the lock screen, turn that off
  (`netplwiz` → Advanced → "Require users to press Ctrl+Alt+Delete").
- Only the session on the physical screen is shared, not Remote Desktop sessions.

## Develop

`./build.sh` builds both `.exe` files on a Mac. `.toolchain/receiver-test` runs the same server on
a Mac with a fake two-monitor desktop (`-port 5991 -password test-pass-1`), for testing
ScreenLink in the simulator:
`SIMCTL_CHILD_SCREENLINK_AUTOCONNECT=127.0.0.1:5991 SIMCTL_CHILD_SCREENLINK_PASSWORD=test-pass-1 xcrun simctl launch booted app.screenlink.remote.k7q2`
