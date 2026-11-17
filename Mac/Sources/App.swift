import SwiftUI
import AppKit

@main
struct ScreenLinkMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("ScreenLink", id: "computers") {
            ComputersView()
                .environmentObject(HostStore.shared)
                .frame(minWidth: 460, minHeight: 360)
        }
        .defaultSize(width: 560, height: 520)
        .commands {
            CommandGroup(replacing: .newItem) {}
            ComputerCommands()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        KeyCapture.install()
        #if DEBUG
        // Dev hook: SCREENLINK_AUTOCONNECT=host:port (+ SCREENLINK_PASSWORD, SCREENLINK_HOME).
        let env = ProcessInfo.processInfo.environment
        if let target = env["SCREENLINK_AUTOCONNECT"] {
            let parts = target.split(separator: ":")
            var h = SavedHost(name: "Debug", address: String(parts[0]))
            if parts.count > 1 { h.port = Int(parts[1]) ?? 5900 }
            h.homeAddress = env["SCREENLINK_HOME"]
            SessionController.open(h, password: env["SCREENLINK_PASSWORD"] ?? "")
            if env["SCREENLINK_FULLSCREEN"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    NSApp.windows.first { $0.windowController is SessionController }?.toggleFullScreen(nil)
                }
                if env["SCREENLINK_FULLSCREEN"] == "2" { // in and back out again
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                        NSApp.windows.first { $0.windowController is SessionController }?.toggleFullScreen(nil)
                    }
                }
            }
        }
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            for w in NSApp.windows where w.identifier?.rawValue.contains("computers") == true {
                w.makeKeyAndOrderFront(nil)
                return false
            }
        }
        return true
    }
}

/// The Computer menu: shortcuts macOS would otherwise keep for itself (⌘Tab, ⌘Space…).
struct ComputerCommands: Commands {
    @AppStorage("classicMacModifiers") private var classicMacModifiers = false
    private func send(_ key: UInt32, _ mods: [UInt32] = []) {
        SessionController.current?.sendShortcut(key, modifiers: mods)
    }
    private func ch(_ c: Character) -> UInt32 { UInt32(c.asciiValue ?? 0) }

    var body: some Commands {
        CommandMenu("Computer") {
            Section("Windows PC") {
                Button("Start Menu") { send(Keysym.superL) }
                Button("Task View") { send(Keysym.tab, [Keysym.superL]) }
                Button("Switch Apps (Alt+Tab)") { send(Keysym.tab, [Keysym.option]) }
                Button("Show Desktop") { send(ch("d"), [Keysym.superL]) }
                Button("File Explorer") { send(ch("e"), [Keysym.superL]) }
                Button("Settings") { send(ch("i"), [Keysym.superL]) }
                Button("Close Window (Alt+F4)") { send(Keysym.function(4), [Keysym.option]) }
                Button("Task Manager") { send(Keysym.escape, [Keysym.control, Keysym.shift]) }
                Button("Screenshot Area") { send(ch("s"), [Keysym.superL, Keysym.shift]) }
                Button("Lock PC") { send(ch("l"), [Keysym.superL]) }
            }
            Section("Mac") {
                Button("Mission Control") { send(Keysym.up, [Keysym.control]) }
                Button("Spotlight") { send(Keysym.space, [Keysym.command]) }
                Button("App Switcher") { send(Keysym.tab, [Keysym.command]) }
                Button("Force Quit…") { send(Keysym.escape, [Keysym.command, Keysym.option]) }
            }
            Divider()
            Toggle("Older Mac: Classic ⌘ and ⌥ Keys", isOn: $classicMacModifiers)
            Divider()
            Button("Paste My Clipboard as Typing") { SessionController.current?.typeClipboard() }
            Button("Refresh Screen") { SessionController.current?.connection?.refresh() }
            Button("Disconnect") { SessionController.current?.window?.performClose(nil) }
        }
        CommandMenu("Displays") {
            DisplaysMenuContent()
        }
    }
}
