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
3. Click **Yes** when Windows asks for permission. That sets it to start at sign-in with admin
   rights (so it can control admin apps) and adds a firewall rule that only lets Tailscale devices
   (100.64.0.0/10) in, plus this network (`LocalSubnet`) if you said yes.
4. In ScreenLink: put the Tailscale address (100.x) in **Tailscale name or IP** and the home address
   (192.168.x.x) in **Home Wi-Fi address**, plus any username and that password. ScreenLink uses the
   home address when it answers and Tailscale otherwise.

The tray icon (by the clock) shows the address and has **Allow Devices on This Wi-Fi** (flips the
setting and the firewall rule, with a permission prompt), Change Password, Open Log and Quit.
Opening a newer `.exe` on a PC that's already set up updates the installed copy.
Settings and the log live in `%APPDATA%\ScreenLink Receiver\`.

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

## Limits

- It runs in your signed-in session. Windows shows its sign-in screen, lock screen and UAC
  prompts on a separate secure desktop that normal apps can't see or control. So after a
  reboot, while the PC is locked, or during a UAC prompt, ScreenLink can't sign in for you.

## Develop

`./build.sh` builds both `.exe` files on a Mac. `.toolchain/receiver-test` runs the same server on
a Mac with a fake two-monitor desktop (`-port 5991 -password test-pass-1`), for testing
ScreenLink in the simulator:
`SIMCTL_CHILD_SCREENLINK_AUTOCONNECT=127.0.0.1:5991 SIMCTL_CHILD_SCREENLINK_PASSWORD=test-pass-1 xcrun simctl launch booted app.screenlink.remote.k7q2`
