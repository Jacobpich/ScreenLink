import SwiftUI

enum InputMode: String, CaseIterable {
    case trackpad, touch
    var label: String { self == .trackpad ? "Trackpad" : "Touch" }
    var icon: String { self == .trackpad ? "rectangle.and.hand.point.up.left" : "hand.point.up.left" }
}

enum SessionState: Equatable {
    case connecting
    case reconnecting(Int)
    case connected
    case paused
    case failed(String)
    case signIn(String)       // the Mac rejected the username/password
}

@MainActor
final class SessionModel: ObservableObject {
    @Published var state: SessionState = .connecting
    @Published var desktopName = ""
    @Published var inputMode: InputMode = InputMode(rawValue: UserDefaults.standard.string(forKey: "defaultInputMode") ?? "") ?? .trackpad
    @Published var toolbarExpanded = true
    @Published var keyboardVisible = false
    @Published var stats = ""
    @Published var showHint = false
    @Published var toast: String?
    @Published var displays: [CGRect] = []
    @Published var selectedDisplay: Int?
    @Published var displayLayoutIsManual = false
    @Published var signInUser = ""

    weak var controller: RemoteViewController?
    let hostName: String

    init(hostName: String) { self.hostName = hostName }

    func flash(_ text: String) {
        toast = text
        let t = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            if self?.toast == t { withAnimation { self?.toast = nil } }
        }
    }
}

/// Floating toolbar. Hosted in its own small view so it only captures
/// touches on its buttons; everything else goes to the remote screen.
struct SessionToolbar: View {
    @ObservedObject var model: SessionModel
    @AppStorage("showStats") private var showStats = false

    var body: some View {
        Group {
            if model.state == .connected {
                if model.toolbarExpanded { expanded } else { collapsed }
            }
        }
        .padding(.top, 6)
        .animation(.spring(duration: 0.3), value: model.toolbarExpanded)
    }

    private var expanded: some View {
        HStack(spacing: 2) {
            barButton("xmark", "Disconnect") { model.controller?.disconnect() }
            divider
            barButton(model.keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard", "Keyboard") {
                model.controller?.toggleKeyboard()
            }
            barButton(model.inputMode.icon, model.inputMode.label) {
                model.controller?.toggleInputMode()
            }
            displaysMenu
            shortcutsMenu
            divider
            barButton("chevron.up", "Hide toolbar") { model.toolbarExpanded = false }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
    }

    private var collapsed: some View {
        Button { model.toolbarExpanded = true } label: {
            Image(systemName: "chevron.compact.down")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 64, height: 26)
                .background(.black.opacity(0.4), in: Capsule())
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Show toolbar")
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 22).padding(.horizontal, 4)
    }

    private func barButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 36)
                .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .accessibilityLabel(label)
    }

    private func displayName(_ i: Int) -> String {
        let r = model.displays[i]
        return "Display \(i + 1)  ·  \(Int(r.width))×\(Int(r.height))"
    }

    private var displaysMenu: some View {
        Menu {
            Section {
                Button { model.controller?.selectDisplay(nil) } label: {
                    if model.selectedDisplay == nil { Label("All Displays", systemImage: "checkmark") }
                    else { Text("All Displays") }
                }
                ForEach(model.displays.indices, id: \.self) { i in
                    Button { model.controller?.selectDisplay(i) } label: {
                        if model.selectedDisplay == i { Label(displayName(i), systemImage: "checkmark") }
                        else { Text(displayName(i)) }
                    }
                }
            } header: {
                Text(model.displays.count > 1 ? "Show" : "Only one display found")
            }
            Section("Layout") {
                Button { model.controller?.redetectDisplays() } label: {
                    Label("Detect Displays Automatically", systemImage: model.displayLayoutIsManual ? "wand.and.stars" : "checkmark")
                }
                Menu {
                    Button("2 Side by Side") { model.controller?.setManualLayout(columns: 2, rows: 1) }
                    Button("3 Side by Side") { model.controller?.setManualLayout(columns: 3, rows: 1) }
                    Button("2 Stacked") { model.controller?.setManualLayout(columns: 1, rows: 2) }
                } label: {
                    Label("Set Layout Manually", systemImage: "rectangle.split.3x1")
                }
            }
        } label: {
            Image(systemName: model.selectedDisplay == nil ? "display.2" : "display")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 36)
                .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .accessibilityLabel("Displays")
    }

    private var shortcutsMenu: some View {
        Menu {
            Section("Mac shortcuts") {
                shortcut("Mission Control", "rectangle.3.group", Keysym.up, [Keysym.control])
                shortcut("App Switcher (⌘⇥)", "square.on.square", Keysym.tab, [Keysym.command])
                shortcut("Spotlight (⌘Space)", "magnifyingglass", Keysym.space, [Keysym.command])
                shortcut("App Exposé", "rectangle.stack", Keysym.down, [Keysym.control])
                shortcut("Show Desktop", "menubar.dock.rectangle", Keysym.function(11), [])
                shortcut("Look Up (⌃⌘D)", "text.magnifyingglass", UInt32(0x64), [Keysym.control, Keysym.command])
                shortcut("Close Window (⌘W)", "xmark.rectangle", UInt32(0x77), [Keysym.command])
                shortcut("Quit App (⌘Q)", "power", UInt32(0x71), [Keysym.command])
                shortcut("Force Quit (⌘⌥Esc)", "exclamationmark.octagon", Keysym.escape, [Keysym.command, Keysym.option])
                shortcut("Screenshot Area (⌘⇧4)", "camera.viewfinder", UInt32(0x34), [Keysym.command, Keysym.shift])
                shortcut("Lock Screen (⌃⌘Q)", "lock", UInt32(0x71), [Keysym.control, Keysym.command])
            }
            Section("Clipboard") {
                Button { model.controller?.pasteToMac() } label: {
                    Label("Paste iPhone Clipboard on Mac", systemImage: "doc.on.clipboard")
                }
                Button { model.controller?.typeClipboard() } label: {
                    Label("Type iPhone Clipboard", systemImage: "character.cursor.ibeam")
                }
            }
            Section("View") {
                Button { model.controller?.zoomToFit() } label: {
                    Label("Zoom to Fit", systemImage: "arrow.down.right.and.arrow.up.left")
                }
                Button { model.controller?.refreshScreen() } label: {
                    Label("Refresh Screen", systemImage: "arrow.clockwise")
                }
                Toggle(isOn: $showStats) { Label("Show Stats", systemImage: "speedometer") }
            }
        } label: {
            Image(systemName: "command")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 36)
                .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .accessibilityLabel("Shortcuts")
    }

    private func shortcut(_ title: String, _ icon: String, _ key: UInt32, _ mods: [UInt32]) -> some View {
        Button { model.controller?.sendShortcut(key, modifiers: mods) } label: {
            Label(title, systemImage: icon)
        }
    }
}

/// Full-screen layer for connection status, tips, toasts and stats.
/// Only receives touches while a status card or the tips card is showing.
struct SessionOverlay: View {
    @ObservedObject var model: SessionModel
    @AppStorage("showStats") private var showStats = false

    var body: some View {
        ZStack {
            VStack {
                Spacer()
                if let toast = model.toast {
                    Text(toast)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        .padding(.bottom, 40)
                }
            }

            if showStats && model.state == .connected && !model.stats.isEmpty {
                VStack {
                    Spacer()
                    HStack {
                        Text(model.stats)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                        Spacer()
                    }
                }
                .padding(10)
            }

            statusCard

            if model.showHint { hintCard }
        }
        .animation(.easeInOut(duration: 0.2), value: model.state)
        .animation(.easeInOut(duration: 0.2), value: model.toast)
    }

    // MARK: Status

    @ViewBuilder private var statusCard: some View {
        switch model.state {
        case .connecting, .reconnecting, .paused:
            VStack(spacing: 14) {
                ProgressView().controlSize(.large).tint(.white)
                Text(statusText).font(.headline)
                Text(model.hostName).font(.subheadline).foregroundStyle(.secondary)
                Button("Cancel") { model.controller?.disconnect() }
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
            }
            .padding(28)
            .frame(maxWidth: 300)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        case .failed(let message):
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 34)).foregroundStyle(.yellow)
                Text("Couldn't Connect").font(.headline)
                Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack {
                    Button("Close") { model.controller?.disconnect() }.buttonStyle(.bordered)
                    Button("Try Again") { model.controller?.connect() }.buttonStyle(.borderedProminent)
                }
                .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: 340)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            .padding()
        case .signIn(let message):
            SignInCard(model: model, message: message)
        case .connected:
            EmptyView()
        }
    }

    private var statusText: String {
        switch model.state {
        case .reconnecting(let n): return n > 1 ? "Reconnecting (\(n))…" : "Reconnecting…"
        case .paused: return "Resuming…"
        default: return "Connecting…"
        }
    }

    private var hintCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Works like your Mac's trackpad").font(.headline)
            hint("hand.draw", "Slide one finger to move the pointer")
            hint("hand.tap", "Tap to click · two-finger tap to right-click")
            hint("hand.point.up.left.and.text", "Touch and hold, then slide to drag")
            hint("arrow.up.and.down", "Two fingers to scroll · pinch to zoom")
            hint("rectangle.3.group", "Three-finger swipe: Mission Control, App Exposé, Spaces")
            hint("text.magnifyingglass", "Three-finger tap: Look Up")
            hint("display.2", "Four-finger swipe sideways: switch displays")
            hint("keyboard", "Four-finger tap: keyboard")
            Button {
                model.showHint = false
                UserDefaults.standard.set(true, forKey: "seenHint")
            } label: {
                Text("Got it").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .padding(22)
        .frame(maxWidth: 340)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .padding()
    }

    private func hint(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 26).foregroundStyle(.tint)
            Text(text).font(.subheadline)
        }
    }
}

/// Shown when the Mac rejects the saved credentials (for example after a password change).
private struct SignInCard: View {
    @ObservedObject var model: SessionModel
    let message: String
    @State private var user = ""
    @State private var password = ""
    @FocusState private var focus: Field?
    private enum Field { case user, password }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill").font(.system(size: 30)).foregroundStyle(.yellow)
            Text("Sign In to \(model.hostName)").font(.headline)
            Text("The Mac didn't accept the saved password. If you changed your Mac's password, enter the new one.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            TextField("Mac username", text: $user)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: .user)
                .submitLabel(.next)
                .onSubmit { focus = .password }
                .textFieldStyle(.roundedBorder)
            SecureField("Password", text: $password)
                .textContentType(.password)
                .focused($focus, equals: .password)
                .submitLabel(.go)
                .onSubmit(submit)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Close") { model.controller?.disconnect() }.buttonStyle(.bordered)
                Button("Sign In", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(user.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: 340)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .padding()
        .onAppear {
            user = model.signInUser
            focus = user.isEmpty ? .user : .password
        }
    }

    private func submit() {
        guard !user.trimmingCharacters(in: .whitespaces).isEmpty, !password.isEmpty else { return }
        model.controller?.signIn(username: user, password: password)
    }
}
