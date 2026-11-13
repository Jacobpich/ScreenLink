import Foundation
import CommonCrypto
import CryptoKit
import Security

enum AuthError: LocalizedError {
    case failed(String)
    case unsupported([UInt8])
    case needsPassword
    case needsUsername

    var errorDescription: String? {
        switch self {
        case .failed(let m): return m.isEmpty ? "Authentication failed. Check your username and password." : m
        case .unsupported(let t):
            return "This Mac doesn't offer a sign-in method ScreenLink supports (offered: \(t.map(String.init).joined(separator: ", "))). In System Settings → General → Sharing → Screen Sharing, make sure Screen Sharing is on."
        case .needsPassword: return "A password is required."
        case .needsUsername: return "This Mac requires your macOS username and password."
        }
    }
}

// MARK: - Apple Remote Desktop authentication (security type 30)
//
// Diffie-Hellman key agreement; MD5(shared secret) is used as an AES-128 key
// to encrypt a 128-byte block containing the username and password.

enum AppleAuth {
    static func response(generator: [UInt8], prime: [UInt8], serverPublic: [UInt8],
                         username: String, password: String) throws -> [UInt8] {
        let keyLen = prime.count
        var privBytes = [UInt8](repeating: 0, count: keyLen)
        _ = SecRandomCopyBytes(kSecRandomDefault, keyLen, &privBytes)

        let mod = Montgomery(modulus: BigUInt(bytes: prime))
        let priv = BigUInt(bytes: privBytes)
        let g = BigUInt(bytes: generator)
        let ys = BigUInt(bytes: serverPublic)

        let clientPublic = mod.pow(g, priv).bytes(length: keyLen)
        let shared = mod.pow(ys, priv).bytes(length: keyLen)

        let key = Array(Insecure.MD5.hash(data: Data(shared)))

        var creds = [UInt8](repeating: 0, count: 128)
        _ = SecRandomCopyBytes(kSecRandomDefault, 128, &creds)
        let u = Array(username.utf8.prefix(63))
        let p = Array(password.utf8.prefix(63))
        for (i, b) in u.enumerated() { creds[i] = b }
        creds[u.count] = 0
        for (i, b) in p.enumerated() { creds[64 + i] = b }
        creds[64 + p.count] = 0

        let encrypted = try aesECB(key: key, data: creds)
        return encrypted + clientPublic
    }

    private static func aesECB(key: [UInt8], data: [UInt8]) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES128),
                             CCOptions(kCCOptionECBMode), key, key.count, nil,
                             data, data.count, &out, out.count, &moved)
        guard status == kCCSuccess else { throw AuthError.failed("Encryption failed (\(status)).") }
        return Array(out.prefix(moved))
    }
}

// MARK: - Classic VNC password authentication (security type 2)

enum VNCAuth {
    static func response(challenge: [UInt8], password: String) throws -> [UInt8] {
        var key = [UInt8](repeating: 0, count: 8)
        for (i, b) in Array(password.utf8.prefix(8)).enumerated() {
            // VNC uses the bits of each key byte in reverse order.
            var r: UInt8 = 0
            for bit in 0..<8 where b & (1 << bit) != 0 { r |= 1 << (7 - bit) }
            key[i] = r
        }
        var out = [UInt8](repeating: 0, count: 16 + kCCBlockSizeDES)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES),
                             CCOptions(kCCOptionECBMode), key, 8, nil,
                             challenge, 16, &out, out.count, &moved)
        guard status == kCCSuccess else { throw AuthError.failed("Encryption failed (\(status)).") }
        return Array(out.prefix(16))
    }
}

// MARK: - Minimal big integer support for DH (Montgomery modular exponentiation)

struct BigUInt {
    /// Little-endian 32-bit limbs.
    var limbs: [UInt32]

    init(limbs: [UInt32]) { self.limbs = limbs }

    init(bytes: [UInt8]) {
        var l = [UInt32](repeating: 0, count: max(1, (bytes.count + 3) / 4))
        for (i, b) in bytes.reversed().enumerated() {
            l[i / 4] |= UInt32(b) << (8 * UInt32(i % 4))
        }
        limbs = l
    }

    func bytes(length: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: length)
        for i in 0..<length {
            let li = i / 4
            guard li < limbs.count else { break }
            out[length - 1 - i] = UInt8((limbs[li] >> (8 * UInt32(i % 4))) & 0xff)
        }
        return out
    }

    func padded(_ n: Int) -> [UInt32] {
        var l = limbs
        if l.count < n { l += [UInt32](repeating: 0, count: n - l.count) }
        return Array(l.prefix(n))
    }

    var bitWidth: Int {
        for i in stride(from: limbs.count - 1, through: 0, by: -1) where limbs[i] != 0 {
            return i * 32 + (32 - limbs[i].leadingZeroBitCount)
        }
        return 0
    }

    func bit(_ i: Int) -> Bool {
        let li = i / 32
        guard li < limbs.count else { return false }
        return (limbs[li] >> UInt32(i % 32)) & 1 == 1
    }
}

struct Montgomery {
    let n: [UInt32]
    let count: Int
    let nPrime: UInt32
    let r2: [UInt32]  // R^2 mod n

    init(modulus: BigUInt) {
        var m = modulus.limbs
        while m.count > 1 && m.last == 0 { m.removeLast() }
        n = m
        count = m.count
        // nPrime = -n^{-1} mod 2^32 via Newton iteration (n must be odd).
        var inv: UInt32 = 1
        for _ in 0..<5 { inv = inv &* (2 &- m[0] &* inv) }
        nPrime = 0 &- inv
        // R^2 mod n by repeated doubling of 1.
        var x = [UInt32](repeating: 0, count: m.count)
        x[0] = 1
        for _ in 0..<(2 * 32 * m.count) {
            x = Montgomery.modDouble(x, m)
        }
        r2 = x
    }

    private static func geq(_ a: [UInt32], _ carry: UInt32, _ b: [UInt32]) -> Bool {
        if carry != 0 { return true }
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            if a[i] != b[i] { return a[i] > b[i] }
        }
        return true
    }

    private static func sub(_ a: inout [UInt32], _ b: [UInt32]) {
        var borrow: UInt64 = 0
        for i in 0..<a.count {
            let d = UInt64(a[i]) &- UInt64(b[i]) &- borrow
            a[i] = UInt32(truncatingIfNeeded: d)
            borrow = (d >> 63) & 1
        }
    }

    private static func modDouble(_ x: [UInt32], _ m: [UInt32]) -> [UInt32] {
        var out = x
        var carry: UInt32 = 0
        for i in 0..<x.count {
            let v = x[i]
            out[i] = (v << 1) | carry
            carry = v >> 31
        }
        if geq(out, carry, m) { sub(&out, m) }
        return out
    }

    func mul(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        let s = count
        var t = [UInt32](repeating: 0, count: s + 2)
        for i in 0..<s {
            var c: UInt64 = 0
            let bi = UInt64(b[i])
            for j in 0..<s {
                let v = UInt64(t[j]) + UInt64(a[j]) * bi + c
                t[j] = UInt32(truncatingIfNeeded: v)
                c = v >> 32
            }
            var v = UInt64(t[s]) + c
            t[s] = UInt32(truncatingIfNeeded: v)
            t[s + 1] = UInt32(v >> 32)

            let m = UInt64(t[0] &* nPrime)
            v = UInt64(t[0]) + m * UInt64(n[0])
            c = v >> 32
            for j in 1..<s {
                v = UInt64(t[j]) + m * UInt64(n[j]) + c
                t[j - 1] = UInt32(truncatingIfNeeded: v)
                c = v >> 32
            }
            v = UInt64(t[s]) + c
            t[s - 1] = UInt32(truncatingIfNeeded: v)
            t[s] = t[s + 1] + UInt32(v >> 32)
        }
        var res = Array(t[0..<s])
        if Montgomery.geq(res, t[s], n) { Montgomery.sub(&res, n) }
        return res
    }

    func pow(_ base: BigUInt, _ exp: BigUInt) -> BigUInt {
        // Reduce base below n first (base * R^2 * R^-1 = base*R mod n needs base < n*R, always true here).
        let b = mul(base.padded(count), r2)          // base in Montgomery form
        var one = [UInt32](repeating: 0, count: count); one[0] = 1
        var acc = mul(one, r2)                         // 1 in Montgomery form
        let bits = exp.bitWidth
        if bits > 0 {
            for i in stride(from: bits - 1, through: 0, by: -1) {
                acc = mul(acc, acc)
                if exp.bit(i) { acc = mul(acc, b) }
            }
        }
        return BigUInt(limbs: mul(acc, one))
    }
}
