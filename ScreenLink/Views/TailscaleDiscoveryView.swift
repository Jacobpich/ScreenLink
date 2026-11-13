import SwiftUI

struct TailscaleDiscoveryView: View {
    let onPick: (TailscaleDevice) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = TailscaleAPI.apiKey ?? ""
    @State private var hasKey = (TailscaleAPI.apiKey ?? "").isEmpty == false
    @State private var devices: [TailscaleDevice] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if hasKey { deviceList } else { keyEntry }
            }
            .navigationTitle("Find on Tailscale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                if hasKey {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                            Button(role: .destructive) {
                                TailscaleAPI.apiKey = nil
                                apiKey = ""
                                hasKey = false
                                devices = []
                            } label: { Label("Forget API Key", systemImage: "key.slash") }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
            }
            .task { if hasKey { await load() } }
        }
    }

    private var keyEntry: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "network").font(.largeTitle).foregroundStyle(.tint)
                    Text("List the Macs in your tailnet").font(.headline)
                    Text("Tailscale doesn't let other apps see your devices directly, so ScreenLink can use a Tailscale API access token to list them. It's optional — you can always type the Mac's Tailscale name instead.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
            Section {
                SecureField("tskey-api-…", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Link(destination: URL(string: "https://login.tailscale.com/admin/settings/keys")!) {
                    Label("Create an API access token", systemImage: "arrow.up.right.square")
                }
            } footer: {
                Text("In the Tailscale admin console: Settings → Keys → Generate access token. The token is stored in this iPhone's Keychain and only sent to api.tailscale.com.")
            }
            Section {
                Button("Continue") {
                    TailscaleAPI.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    hasKey = true
                    Task { await load() }
                }
                .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var deviceList: some View {
        List {
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
            if loading && devices.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
            let macs = devices.filter(\.isMac)
            let others = devices.filter { !$0.isMac }
            if !macs.isEmpty {
                Section("Macs") { ForEach(macs) { row($0) } }
            }
            if !others.isEmpty {
                Section("Other devices") { ForEach(others) { row($0) } }
            }
        }
        .refreshable { await load() }
    }

    private func row(_ d: TailscaleDevice) -> some View {
        Button { onPick(d) } label: {
            HStack(spacing: 12) {
                Image(systemName: d.isMac ? "desktopcomputer" : "server.rack")
                    .font(.title3)
                    .frame(width: 32)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.hostname.isEmpty ? d.shortName : d.hostname).font(.body).foregroundStyle(.primary)
                    Text([d.shortName, d.ipv4].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(d.isOnline ? "Online" : "Offline")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(d.isOnline ? .green : .secondary)
            }
        }
    }

    private func load() async {
        guard let key = TailscaleAPI.apiKey else { return }
        loading = true
        error = nil
        do {
            devices = try await TailscaleAPI.devices(apiKey: key)
            if devices.isEmpty { error = "No devices found in this tailnet." }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}
