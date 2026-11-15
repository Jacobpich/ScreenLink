import SwiftUI

struct HostListView: View {
    @EnvironmentObject private var store: HostStore
    @State private var editing: SavedHost?
    @State private var editingIsNew = false
    @State private var showDiscovery = false
    @State private var showSettings = false
    @State private var passwordPromptHost: SavedHost?

    var body: some View {
        NavigationStack {
            Group {
                if store.hosts.isEmpty {
                    EmptyStateView(addManually: addNew, discover: { showDiscovery = true })
                } else {
                    List {
                        Section {
                            ForEach(store.hosts) { host in
                                HostRow(host: host, online: store.reachability[host.id])
                                    .contentShape(Rectangle())
                                    .onTapGesture { connect(host) }
                                    .contextMenu {
                                        Button { connect(host) } label: { Label("Connect", systemImage: "play.fill") }
                                        Button { edit(host) } label: { Label("Edit", systemImage: "pencil") }
                                        Button(role: .destructive) { store.delete(host) } label: { Label("Delete", systemImage: "trash") }
                                    }
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) { store.delete(host) } label: { Label("Delete", systemImage: "trash") }
                                        Button { edit(host) } label: { Label("Edit", systemImage: "pencil") }.tint(.gray)
                                    }
                            }
                            .onMove { store.move(from: $0, to: $1) }
                        } footer: {
                            Text("Connections run over your Tailscale network, which encrypts everything end to end. Tailscale must be connected on this iPhone.")
                        }
                    }
                    .listStyle(.insetGrouped)
                    .refreshable { store.probeAll() }
                }
            }
            .navigationTitle("ScreenLink")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(action: addNew) { Label("Add Computer Manually", systemImage: "plus") }
                        Button { showDiscovery = true } label: { Label("Find on Tailscale", systemImage: "network") }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Computer")
                }
            }
            .sheet(item: $editing) { host in
                HostEditorView(host: host, isNew: !store.hosts.contains { $0.id == host.id })
            }
            .sheet(isPresented: $showDiscovery) {
                TailscaleDiscoveryView { device in
                    showDiscovery = false
                    var h = SavedHost(name: device.hostname.isEmpty ? device.shortName : device.hostname,
                                      address: device.ipv4 ?? device.name)
                    h.username = ""
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        editingIsNew = true
                        editing = h
                    }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(item: $passwordPromptHost) { host in
                PasswordPrompt(host: host) { password, remember in
                    passwordPromptHost = nil
                    if remember { store.upsert(host, password: password) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        SessionPresenter.present(host, password: password)
                    }
                }
            }
            .onAppear {
                store.probeAll()
                #if DEBUG
                // Dev hook: SCREENLINK_AUTOCONNECT=host:port (+ SCREENLINK_PASSWORD) opens a session directly.
                if let target = ProcessInfo.processInfo.environment["SCREENLINK_AUTOCONNECT"] {
                    let parts = target.split(separator: ":")
                    var h = SavedHost(name: "Debug", address: String(parts[0]))
                    if parts.count > 1 { h.port = Int(parts[1]) ?? 5900 }
                    h.homeAddress = ProcessInfo.processInfo.environment["SCREENLINK_HOME"]
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        SessionPresenter.present(h, password: ProcessInfo.processInfo.environment["SCREENLINK_PASSWORD"] ?? "")
                    }
                }
                #endif
            }
        }
    }

    private func addNew() {
        editingIsNew = true
        editing = SavedHost(name: "", address: "")
    }

    private func edit(_ host: SavedHost) {
        editingIsNew = false
        editing = host
    }

    private func connect(_ host: SavedHost) {
        if let pw = store.password(for: host), !pw.isEmpty {
            SessionPresenter.present(host, password: pw)
        } else {
            passwordPromptHost = host
        }
    }
}

private struct HostRow: View {
    let host: SavedHost
    let online: Bool?

    var body: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: host.icon)
                    .font(.system(size: 26))
                    .foregroundStyle(.tint)
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 2))
                    .offset(x: 3, y: 3)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(host.name.isEmpty ? host.address : host.name).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
    }

    private var statusColor: Color {
        switch online {
        case .some(true): return .green
        case .some(false): return .gray
        case .none: return .yellow
        }
    }

    private var subtitle: String {
        var parts = [host.port == 5900 ? host.address : "\(host.address):\(host.port)"]
        if let home = host.home { parts[0] = "\(home) / \(parts[0])" }
        if online == false { parts.append("Not reachable") }
        else if let d = host.lastConnected {
            parts.append(d.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }
}

private struct EmptyStateView: View {
    let addManually: () -> Void
    let discover: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "display.2")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.tint)
                    .padding(.top, 40)
                VStack(spacing: 8) {
                    Text("Control your Mac or PC from anywhere").font(.title2.bold()).multilineTextAlignment(.center)
                    Text("ScreenLink connects to macOS Screen Sharing, or to ScreenLink Receiver on Windows, over Tailscale.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                VStack(alignment: .leading, spacing: 16) {
                    step(1, "On a Mac, open System Settings → General → Sharing and turn on **Screen Sharing**. On a Windows PC, run **ScreenLink Receiver** and choose a password.")
                    step(2, "Make sure **Tailscale** is running on the computer and connected on this iPhone.")
                    step(3, "Add the computer using its Tailscale name (like `mac-studio`) or its 100.x.y.z address.")
                }
                .padding(20)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))

                VStack(spacing: 12) {
                    Button(action: addManually) {
                        Label("Add Computer", systemImage: "plus").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Button(action: discover) {
                        Label("Find Computers on Tailscale", systemImage: "network").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
            .padding(24)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.accentColor))
            Text(text).font(.subheadline)
        }
    }
}

private struct PasswordPrompt: View {
    let host: SavedHost
    let onConnect: (String, Bool) -> Void
    @State private var password = ""
    @State private var remember = true
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("User", value: host.username.isEmpty ? "—" : host.username)
                    SecureField("Password", text: $password)
                        .focused($focused)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .onSubmit(go)
                    Toggle("Remember in Keychain", isOn: $remember)
                } footer: {
                    Text("The password for \(host.name.isEmpty ? "this computer" : host.name): your Mac login password, or the one you chose in ScreenLink Receiver on a PC.")
                }
            }
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect", action: go).disabled(password.isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }

    private func go() {
        guard !password.isEmpty else { return }
        onConnect(password, remember)
    }
}
