# ScreenLink

A fast iPhone/iPad client for macOS Screen Sharing, built to be used over Tailscale.

## Windows PC: download

ScreenLink can control a Windows PC too. The PC needs one small app, **ScreenLink Receiver**.

**[⬇ Download ScreenLink Receiver for Windows](https://github.com/Jacobpich/ScreenLink/raw/main/Downloads/ScreenLinkReceiver.exe)**
(Snapdragon / ARM PCs: [ARM64 version](https://github.com/Jacobpich/ScreenLink/raw/main/Downloads/ScreenLinkReceiver-arm64.exe))

1. Open this page on the PC and click the download link above.
   - If the browser says the file "isn't commonly downloaded", choose **Keep** (in Edge: **⋯ → Keep → Keep anyway**).
2. Open **ScreenLinkReceiver.exe** from your Downloads folder.
   - If a blue "Windows protected your PC" box appears, click **More info → Run anyway**. (The app isn't signed, so Windows doesn't recognize it yet.)
3. A setup window opens. Type a password, press Enter, then type it again.
4. It asks whether iPhones on this Wi-Fi may connect without Tailscale. Type **y** for an at-home setup with no Tailscale, or **n** if you use Tailscale. Press Enter.
5. Windows asks for permission. Click **Yes**.
6. The window shows the address to use. On the iPhone, open ScreenLink, tap **+**, and enter that address, any username, and your password.

That's it. The receiver starts when you sign in to the PC; its icon is by the clock. Right-click the icon to see the address again, change the password, or turn **Allow Devices on This Wi-Fi** on or off.

**Tailscale or Wi-Fi?** With [Tailscale](https://tailscale.com/download/windows) on the PC (signed in to the same account as the iPhone), ScreenLink works from anywhere and the whole connection is encrypted. Without it, the iPhone must be on the same Wi-Fi. The password is still protected, but the screen picture isn't encrypted, so only use that on your home network.

More detail: [Receiver/README.md](Receiver/README.md).

## Building
Open `ScreenLink.xcodeproj` in Xcode (iOS 17+). Under **Signing & Capabilities**, pick your own team and change the bundle identifier to something unique, then run on your iPhone. No third-party dependencies.

`Tools/mock/` has small Python VNC servers for testing without a Mac (`python3 Tools/mock/live.py`, then connect to `127.0.0.1:5999` from the simulator).

## Mac setup
1. **System Settings → General → Sharing → Screen Sharing**: turn it on and make sure your user is allowed.
2. Run **Tailscale** on the Mac and on the iPhone (same tailnet).
3. In ScreenLink, add the Mac by its Tailscale name (`mac-studio`), MagicDNS name, or `100.x.y.z` address. Sign in with your Mac account's short name and password.

Optional: **Find on Tailscale** lists your tailnet's Macs using a Tailscale API access token (stored in the Keychain).

## Controls
| Gesture | Does |
|---|---|
| One finger slide | Move the pointer (trackpad mode) / pan (touch mode) |
| Tap · two-finger tap | Click · right-click |
| Touch & hold, then slide | Drag |
| Two-finger swipe | Scroll, with momentum and axis lock |
| Pinch | Zoom the iPhone view |
| Three-finger swipe up / down | Mission Control / App Exposé (swipe the other way to close) |
| Three-finger swipe left / right | Next / previous Space or full-screen app |
| Three-finger tap | Look Up (⌃⌘D) |
| Swipe in from right edge | Notification Center |
| Spread / pinch four fingers | Show Desktop (F11) / Apps |
| Four-finger swipe left / right | Next / previous display |
| Four-finger tap | Keyboard |

**Multiple displays:** macOS sends every display as one wide image. The toolbar's Displays button finds each display, from the seams and black filler in that image, and zooms to the one you pick. While one display is shown, the pointer stays on it. If detection gets it wrong, use Displays → Set Layout Manually. Your choice is remembered for each Mac.

Clicking into a text field on the Mac brings up the keyboard automatically (ScreenLink watches for the Mac's I-beam text cursor; turn it off in Settings). The keyboard bar has sticky ⌘ ⌥ ⌃ ⇧ (tap once for the next key, double-tap to lock), Esc, Tab, arrows and F-keys. The ⌘ toolbar menu has Mission Control, App Switcher, Spotlight, Force Quit, clipboard paste and more. Hardware keyboards work too.

## How it's built
- `ScreenLink/VNC`: an RFB 3.8 client written from scratch. It handles Apple's Diffie-Hellman sign-in (security type 30) and classic VNC passwords, and decodes ZRLE, Tight (including JPEG), Hextile, Zlib, RRE, CopyRect and Raw, plus cursor and desktop-size updates. It uses a blocking socket on its own thread with TCP_NODELAY.
- `ScreenLink/Session`: a Metal renderer that uploads only the changed regions of the screen (with mipmaps for clean zoomed-out text). The cursor is drawn locally, so the pointer moves at the full 120 Hz frame rate no matter the network latency.
- `Tools/mock`: `run-protocol-test.sh` runs the real protocol code against a mock Screen Sharing server and checks the result pixel by pixel. `live.py` serves a fake desktop on port 5999 for testing in the simulator (Debug builds: launch with `SIMCTL_CHILD_SCREENLINK_AUTOCONNECT=127.0.0.1:5999`).

`slowmac.py` is a deliberately slow, busy mock Mac for stress-testing the input flow control: a fast scroll flood must not stop screen updates.

**Networking design:** one thread reads the Mac's data and never blocks on sending. A separate writer thread does all the sending. Pointer moves collapse to the latest position, scroll steps are paced (at most 250/s), and input is held back if the Mac falls behind. "Behind" is measured with tiny requests the Mac must answer at once, and the next frame is only requested after the current one is read. A watchdog reconnects if the Mac stops answering for about 10 seconds. Together these stop a busy Mac from freezing every Screen Sharing viewer connected to it.

macOS refuses Screen Sharing connections from the same Mac, so real-world testing needs a second machine (the iPhone).
