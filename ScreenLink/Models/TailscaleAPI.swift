import Foundation

/// Optional device discovery via the Tailscale API (needs an API access key
/// from login.tailscale.com/admin/settings/keys). The phone still connects
/// over the Tailscale VPN app; this just lists the machines in your tailnet.
struct TailscaleDevice: Identifiable, Decodable, Hashable {
    let id: String
    let name: String          // full MagicDNS name, e.g. mac-studio.tail1234.ts.net
    let hostname: String
    let os: String
    let addresses: [String]
    let lastSeen: String?
    let connectedToControl: Bool?

    var shortName: String { name.split(separator: ".").first.map(String.init) ?? hostname }
    var ipv4: String? { addresses.first { $0.contains(".") } }
    var isMac: Bool { os.lowercased() == "macos" }
    var isWindows: Bool { os.lowercased() == "windows" }

    var isOnline: Bool {
        if let c = connectedToControl { return c }
        guard let lastSeen, let d = ISO8601DateFormatter().date(from: lastSeen) else { return false }
        return Date().timeIntervalSince(d) < 300
    }

    enum CodingKeys: String, CodingKey {
        case id, name, hostname, os, addresses, lastSeen, connectedToControl
    }
}

enum TailscaleAPI {
    static let keyAccount = "tailscale.apiKey"

    static var apiKey: String? {
        get { Keychain.get(keyAccount) }
        set {
            if let v = newValue, !v.isEmpty { Keychain.set(v, for: keyAccount) }
            else { Keychain.delete(keyAccount) }
        }
    }

    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func devices(apiKey: String) async throws -> [TailscaleDevice] {
        var req = URLRequest(url: URL(string: "https://api.tailscale.com/api/v2/tailnet/-/devices")!)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            if code == 401 || code == 403 {
                throw APIError(message: "Tailscale rejected the API key. Make sure it's an API access token (starts with tskey-api-) and hasn't expired.")
            }
            throw APIError(message: "Tailscale returned an error (HTTP \(code)).")
        }
        struct Wrapper: Decodable { let devices: [TailscaleDevice] }
        return try JSONDecoder().decode(Wrapper.self, from: data).devices
            .sorted { ($0.isMac ? 0 : 1, $0.isOnline ? 0 : 1, $0.shortName) < ($1.isMac ? 0 : 1, $1.isOnline ? 0 : 1, $1.shortName) }
    }
}
