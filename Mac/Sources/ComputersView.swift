import SwiftUI
import Combine
import AppKit

struct ComputersView: View {
    @EnvironmentObject private var store: HostStore
    @StateObject private var tailscale = TailscalePeers()
    @State private var editing: EditRequest?
    @State private var selection: UUID?

    private let ticker = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    var body: some View {
        List(selection: $selection) {
            Section("My Computers") {
                if store.hosts.isEmpty {
                    Text("No computers yet. Add one with + or pick one from your Tailscale below.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                }
                ForEach(store.hosts) { host in
                    HostRow(host: host, online: store.reachability[host.id])
                        .tag(host.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { SessionController.open(host) }
                        .contextMenu {
                            Button("Connect") { SessionController.open(host) }
                            Button("Edit…") { edit(host, isNew: false) }
                            Divider()
                            Button("Delete", role: .destructive) { store.delete(host) }
                        }
                }
                .onMove { store.move(from: $0, to: $1) }
            }

            let saved = Set(store.hosts.map { $0.address })
            let peers = tailscale.peers.filter { !saved.contains($0.ip) }
            if !peers.isEmpty {
                Section("On Your Tailscale") {
                    ForEach(peers) { peer in
                        HStack(spacing: 12) {
                            Image(systemName: peer.isWindows ? "pc" : "desktopcomputer")
                                .font(.title2).frame(width: 34)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(peer.name).font(.headline)
                                Text("\(peer.os) · \(peer.ip)\(peer.online ? "" : " · offline")")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Add…") { edit(peer.asHost, isNew: true) }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(footer).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Connect") { connectSelected() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedHost == nil)
            }
            .padding(10)
            .background(.bar)
        }
        .toolbar {
            ToolbarItemGroup {
                Button { if let h = selectedHost { edit(h, isNew: false) } } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .disabled(selectedHost == nil)
                Button { edit(SavedHost(name: "", address: ""), isNew: true) } label: {
                    Label("Add Computer", systemImage: "plus")
                }
            }
        }
        .navigationTitle("ScreenLink")
        .sheet(item: $editing) { req in
            HostEditor(host: req.host, isNew: req.isNew).environmentObject(store)
        }
        .onAppear {
            store.probeAll()
            tailscale.refresh()
        }
        .onReceive(ticker) { _ in
            store.probeAll()
            tailscale.refresh()
        }
    }

    private var selectedHost: SavedHost? { store.hosts.first { $0.id == selection } }

    private var footer: String {
        if !tailscale.available { return "Tailscale isn't installed on this Mac; you can still connect on your home Wi-Fi." }
        if !tailscale.running { return "Tailscale is off on this Mac, so only home Wi-Fi addresses will work." }
        return "Double-click a computer to connect."
    }

    private func connectSelected() {
        if let h = selectedHost { SessionController.open(h) }
    }

    private func edit(_ host: SavedHost, isNew: Bool) {
        editing = EditRequest(host: host, isNew: isNew)
    }
}

private struct EditRequest: Identifiable {
    let id = UUID()
    let host: SavedHost
    let isNew: Bool
}

private struct HostRow: View {
    let host: SavedHost
    let online: Bool?

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: host.icon)
                    .font(.title2).frame(width: 34, height: 30)
                    .foregroundStyle(.tint)
                Circle()
                    .fill(online == true ? Color.green : online == false ? Color.gray : Color.yellow)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name.isEmpty ? host.address : host.name).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Connect") { SessionController.open(host) }
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        var parts = [host.port == 5900 ? host.address : "\(host.address):\(host.port)"]
        if let home = host.home { parts[0] = "\(home) / \(parts[0])" }
        if online == false { parts.append("Not reachable") }
        else if let d = host.lastConnected { parts.append(d.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: " · ")
    }
}

struct HostEditor: View {
    @EnvironmentObject private var store: HostStore
    @Environment(\.dismiss) private var dismiss
    @State private var host: SavedHost
    @State private var password: String
    @State private var portText: String
    @State private var testResult: String?
    @State private var testing = false
    let isNew: Bool

    init(host: SavedHost, isNew: Bool) {
        _host = State(initialValue: host)
        _password = State(initialValue: Keychain.get(host.id.uuidString) ?? "")
        _portText = State(initialValue: String(host.port))
        self.isNew = isNew
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $host.name, prompt: Text("Gaming PC"))
                    TextField("Tailscale name or IP", text: $host.address, prompt: Text("100.x.y.z"))
                    TextField("Home Wi-Fi address", text: Binding(
                        get: { host.homeAddress ?? "" }, set: { host.homeAddress = $0 }),
                              prompt: Text("192.168.x.x (optional)"))
                } footer: {
                    Text("At home, ScreenLink uses the home Wi-Fi address, so Tailscale can be off. Anywhere else it uses the Tailscale address. ScreenLink Receiver shows both by its tray icon on the PC.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    TextField("Username", text: $host.username, prompt: Text("Mac only; any name for a PC"))
                    SecureField("Password", text: $password)
                } footer: {
                    Text("Windows PC: the password you chose in ScreenLink Receiver. Mac: your account name and password. Saved in this Mac's Keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    TextField("Port", text: $portText)
                    HStack {
                        Button("Test Connection", action: test).disabled(host.address.isEmpty || testing)
                        if testing { ProgressView().controlSize(.small) }
                        if let testResult { Text(testResult).foregroundStyle(.secondary) }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) { store.delete(host); dismiss() }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(host.address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 460)
    }

    private func save() {
        host.port = Int(portText) ?? 5900
        host.address = host.address.trimmingCharacters(in: .whitespacesAndNewlines)
        host.homeAddress = host.home
        if host.name.trimmingCharacters(in: .whitespaces).isEmpty {
            host.name = host.address.split(separator: ".").first.map(String.init) ?? host.address
        }
        store.upsert(host, password: password)
        dismiss()
    }

    private func test() {
        testing = true
        testResult = nil
        let addr = host.address.trimmingCharacters(in: .whitespaces)
        let home = host.home
        let port = Int(portText) ?? 5900
        Task.detached {
            let ok = TCPSocket.probe(host: addr, port: port, timeout: 4)
            let homeOK = home.map { TCPSocket.probe(host: $0, port: port, timeout: 2) } ?? false
            await MainActor.run {
                testing = false
                testResult = home == nil ? (ok ? "✓ Reachable" : "✗ Not reachable")
                    : "Home \(homeOK ? "✓" : "✗") · Tailscale \(ok ? "✓" : "✗")"
            }
        }
    }
}
