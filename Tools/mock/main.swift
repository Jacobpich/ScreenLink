import Foundation

final class D: RFBConnectionDelegate {
    var updates = 0
    let expected: Int
    var cursor: CursorImage?
    init(expected: Int) { self.expected = expected }
    func rfbDidConnect(_ c: RFBConnection, name: String, framebuffer: Framebuffer) { print("connected", name, framebuffer.width, framebuffer.height) }
    func rfbDidResize(_ c: RFBConnection, framebuffer: Framebuffer) { print("resized", framebuffer.width, framebuffer.height) }
    func rfb(_ c: RFBConnection, didUpdate fb: Framebuffer, dirty: [CGRect]) {
        updates += 1
        if updates == 1 {
            c.sendPointer(x: 11, y: 22, buttons: 1)
            c.key(0xFFE7, down: true)
            c.sendClipboard("hi")
        }
        if updates == expected {
            var out = Data()
            out.append(contentsOf: withUnsafeBytes(of: UInt32(fb.width).littleEndian, Array.init))
            out.append(contentsOf: withUnsafeBytes(of: UInt32(fb.height).littleEndian, Array.init))
            out.append(Data(bytes: fb.pixels, count: fb.width * fb.height * 4))
            try! out.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
            print("dumped after \(updates) updates; cursor:", cursor.map { "\($0.width)x\($0.height) hot \($0.hotX),\($0.hotY) px0 \(String($0.pixels[0], radix: 16)) px5 \(String($0.pixels[5], radix: 16))" } ?? "none")
            exit(0)
        }
    }
    func rfb(_ c: RFBConnection, cursorChanged cursor: CursorImage?) { self.cursor = cursor }
    func rfb(_ c: RFBConnection, clipboard text: String) { print("clipboard:", text) }
    func rfb(_ c: RFBConnection, didFail error: Error?) { print("FAILED:", error?.localizedDescription ?? "nil"); exit(1) }
}

let port = Int(CommandLine.arguments[1])!
let d = D(expected: Int(CommandLine.arguments[3])!)
let c = RFBConnection(config: ConnectionConfig(host: "127.0.0.1", port: port, username: "tester", password: "s3cret pw!", quality: .lossless))
c.delegate = d
c.start()
DispatchQueue.main.asyncAfter(deadline: .now() + 20) { print("TIMEOUT"); exit(2) }
dispatchMain()
