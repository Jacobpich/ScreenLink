import Foundation

/// Lists the other machines on this Mac's tailnet using the local Tailscale app's CLI
/// (no API key needed). Windows PCs come first.
@MainActor
final class TailscalePeers: ObservableObject {
    struct Peer: Identifiable, Hashable {
        var id: String { ip }
        let name: String
        let os: String
        let ip: String
        let online: Bool
        let lanIP: String?
        var isWindows: Bool { os.lowercased() == "windows" }

        var asHost: SavedHost {
            var h = SavedHost(name: name, address: ip)
            h.homeAddress = lanIP
            return h
        }
    }

    @Published private(set) var peers: [Peer] = []
    @Published private(set) var available = true
    @Published private(set) var running = true

    private static let candidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
    ]

    func refresh() {
        guard let cli = Self.candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            available = false
            peers = []
            return
        }
        Task.detached(priority: .utility) {
            let result = Self.load(cli)
            await MainActor.run {
                self.available = true
                self.running = result.running
                self.peers = result.peers
            }
        }
    }

    nonisolated private static func load(_ cli: String) -> (running: Bool, peers: [Peer]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["status", "--json"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (false, []) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (false, []) }
        let running = (json["BackendState"] as? String) == "Running"
        let peerMap = json["Peer"] as? [String: [String: Any]] ?? [:]
        var out: [Peer] = []
        for (_, v) in peerMap {
            let os = v["OS"] as? String ?? ""
            guard ["windows", "macos"].contains(os.lowercased()) else { continue }
            guard let ip = (v["TailscaleIPs"] as? [String])?.first(where: { $0.contains(".") }) else { continue }
            let dns = (v["DNSName"] as? String ?? "").split(separator: ".").first.map(String.init)
            let name = (v["HostName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? dns ?? ip
            // Its direct endpoints include its home-network address, when Tailscale knows it.
            let addrs = (v["Addrs"] as? [String] ?? []) + [v["CurAddr"] as? String ?? ""]
            let lan = addrs.compactMap { a -> String? in
                let host = a.split(separator: ":").first.map(String.init) ?? ""
                return isPrivateIPv4(host) ? host : nil
            }.first
            out.append(Peer(name: name, os: os == "windows" ? "Windows" : os, ip: ip,
                            online: v["Online"] as? Bool ?? false, lanIP: lan))
        }
        out.sort { a, b in
            if a.isWindows != b.isWindows { return a.isWindows }
            if a.online != b.online { return a.online }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return (running, out)
    }

    nonisolated private static func isPrivateIPv4(_ s: String) -> Bool {
        let p = s.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return false }
        return p[0] == 10 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && (16...31).contains(p[1]))
    }
}
