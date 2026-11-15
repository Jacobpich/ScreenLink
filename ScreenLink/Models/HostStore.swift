import Foundation
import Security
import SwiftUI

struct SavedHost: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var address: String
    /// Optional address on the home network (like 192.168.1.20). Tried first; `address`
    /// (usually Tailscale) is used when it doesn't answer, e.g. away from home.
    var homeAddress: String?
    var port: Int = 5900
    var username: String = ""
    var quality: StreamQuality = .lossless
    var lastConnected: Date?

    /// The home address, trimmed, or nil if none is set.
    var home: String? {
        let h = (homeAddress ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return h.isEmpty ? nil : h
    }

    var icon: String {
        let n = (name + " " + address).lowercased()
        if n.contains("book") || n.contains("laptop") { return "laptopcomputer" }
        if n.contains("studio") { return "macstudio" }
        if n.contains("mini") { return "macmini" }
        return "desktopcomputer"
    }
}

@MainActor
final class HostStore: ObservableObject {
    static let shared = HostStore()

    @Published private(set) var hosts: [SavedHost] = []
    @Published var reachability: [UUID: Bool] = [:]

    private let key = "savedHosts.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([SavedHost].self, from: data) {
            hosts = decoded
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(hosts) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func upsert(_ host: SavedHost, password: String?) {
        if let i = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[i] = host
        } else {
            hosts.append(host)
        }
        if let password {
            if password.isEmpty { Keychain.delete(host.id.uuidString) }
            else { Keychain.set(password, for: host.id.uuidString) }
        }
        persist()
        probe(host)
    }

    func delete(_ host: SavedHost) {
        hosts.removeAll { $0.id == host.id }
        Keychain.delete(host.id.uuidString)
        persist()
    }

    func move(from: IndexSet, to: Int) {
        hosts.move(fromOffsets: from, toOffset: to)
        persist()
    }

    func markConnected(_ id: UUID) {
        guard let i = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts[i].lastConnected = Date()
        reachability[id] = true
        persist()
    }

    func password(for host: SavedHost) -> String? {
        Keychain.get(host.id.uuidString)
    }

    func probeAll() {
        for h in hosts { probe(h) }
    }

    nonisolated static func probeEither(home: String?, addr: String, port: Int) -> Bool {
        if let home {
            let ok = TCPSocket.probe(host: home, port: port, timeout: 1.5)
            ConnLog.write("probe home \(home):\(port) \(ok ? "reachable" : "NOT reachable")")
            if ok { return true }
        }
        let ok = TCPSocket.probe(host: addr, port: port, timeout: 2.5)
        ConnLog.write("probe \(addr):\(port) \(ok ? "reachable" : "NOT reachable")")
        return ok
    }

    func probe(_ host: SavedHost) {
        let addr = host.address.trimmingCharacters(in: .whitespaces)
        let home = host.home
        let port = host.port
        let id = host.id
        Task.detached(priority: .utility) {
            let ok = HostStore.probeEither(home: home, addr: addr, port: port)
            await MainActor.run { HostStore.shared.reachability[id] = ok }
        }
    }
}

enum Keychain {
    private static let service = "ScreenLink"

    static func set(_ value: String, for account: String) {
        delete(account)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete(_ account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}
