import Foundation

/// Tiny connection diagnostics log: Documents/connection.log (kept short) plus NSLog.
/// Lets us see from a Mac (via Xcode/devicectl) why a connection failed on the phone.
enum ConnLog {
    private static let queue = DispatchQueue(label: "ConnLog")
    private static let url: URL? = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
        .appendingPathComponent("connection.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f
    }()

    static func write(_ message: String) {
        NSLog("[ScreenLink] %@", message)
        let line = "\(stamp.string(from: Date())) \(message)\n"
        queue.async {
            guard let url else { return }
            var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            text += line
            if text.count > 60_000 { text = String(text.suffix(40_000)) }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
