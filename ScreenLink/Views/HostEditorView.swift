import SwiftUI

struct HostEditorView: View {
    @EnvironmentObject private var store: HostStore
    @Environment(\.dismiss) private var dismiss

    @State private var host: SavedHost
    @State private var password: String
    @State private var portText: String
    @State private var testing = false
    @State private var testResult: Bool?
    let isNew: Bool

    init(host: SavedHost, isNew: Bool) {
        _host = State(initialValue: host)
        _password = State(initialValue: Keychain.get(host.id.uuidString) ?? "")
        _portText = State(initialValue: String(host.port))
        self.isNew = isNew
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. Mac Studio or Gaming PC)", text: $host.name)
                    TextField("Tailscale name or IP", text: $host.address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onChange(of: host.address) { _, _ in testResult = nil }
                } header: {
                    Text("Computer")
                } footer: {
                    Text("Use the computer's Tailscale machine name (like **mac-studio**), its MagicDNS name, or its **100.x.y.z** address from the Tailscale app. For a Windows PC, install ScreenLink Receiver on it first.")
                }

                Section {
                    TextField("Username", text: $host.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                } header: {
                    Text("Sign in")
                } footer: {
                    Text("Mac: the account name and password you log in with. Windows PC: the password you chose in ScreenLink Receiver (any username works). The password is stored in this iPhone's Keychain. Leave it blank to be asked each time.")
                }

                Section("Picture") {
                    Picker("Quality", selection: $host.quality) {
                        ForEach(StreamQuality.allCases) { q in
                            VStack(alignment: .leading) {
                                Text(q.label)
                                Text(q.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(q)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section("Advanced") {
                    LabeledContent("Port") {
                        TextField("5900", text: $portText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    Button {
                        test()
                    } label: {
                        HStack {
                            Text("Test Connection")
                            Spacer()
                            if testing { ProgressView() }
                            else if let r = testResult {
                                Image(systemName: r ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(r ? .green : .red)
                                Text(r ? "Reachable" : "Not reachable").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(host.address.isEmpty || testing)
                }

                if !isNew {
                    Section {
                        Button("Delete Computer", role: .destructive) {
                            store.delete(host)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "Add Computer" : "Edit Computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(host.address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        host.port = Int(portText) ?? 5900
        host.address = host.address.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let port = Int(portText) ?? 5900
        Task.detached {
            let ok = TCPSocket.probe(host: addr, port: port, timeout: 4)
            await MainActor.run {
                testing = false
                testResult = ok
            }
        }
    }
}
