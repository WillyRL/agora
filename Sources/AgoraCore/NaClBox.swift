import CryptoKit
import Foundation

/// Opens a NaCl `box` (X25519, XSalsa20, Poly1305): how Cloudflare's login helper seals the
/// Access token it hands back after a browser login. CryptoKit has X25519 but not the rest.
enum NaClBox {
    /// `sealed` is the 16-byte tag followed by the ciphertext; the 24-byte nonce comes separately.
    static func open(_ sealed: Data, nonce: Data, sender: Curve25519.KeyAgreement.PublicKey, recipient: Curve25519.KeyAgreement.PrivateKey) -> Data? {
        guard nonce.count == 24, sealed.count >= 16,
            let shared = try? recipient.sharedSecretFromKeyAgreement(with: sender)
        else { return nil }
        let sharedBytes = shared.withUnsafeBytes { [UInt8]($0) }
        let key = hsalsa20(key: sharedBytes, input: [UInt8](repeating: 0, count: 16))
        return secretboxOpen([UInt8](sealed), nonce: [UInt8](nonce), key: key).map { Data($0) }
    }

    static func secretboxOpen(_ sealed: [UInt8], nonce: [UInt8], key: [UInt8]) -> [UInt8]? {
        let subkey = hsalsa20(key: key, input: Array(nonce[0..<16]))
        let tag = Array(sealed[0..<16])
        let ciphertext = Array(sealed[16...])
        let stream = salsa20Stream(key: subkey, nonce: Array(nonce[16..<24]), count: 32 + ciphertext.count)
        let expected = poly1305(ciphertext, key: Array(stream[0..<32]))
        guard constantTimeEqual(expected, tag) else { return nil }
        return zip(ciphertext, stream[32...]).map { $0 ^ $1 }
    }

    // MARK: Salsa20

    static let sigma: [UInt32] = [0x6170_7865, 0x3320_646e, 0x7962_2d32, 0x6b20_6574]  // "expand 32-byte k"

    static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }

    static func state(key: [UInt8], input: [UInt8]) -> [UInt32] {
        [
            sigma[0], le32(key, 0), le32(key, 4), le32(key, 8), le32(key, 12), sigma[1],
            le32(input, 0), le32(input, 4), le32(input, 8), le32(input, 12),
            sigma[2], le32(key, 16), le32(key, 20), le32(key, 24), le32(key, 28), sigma[3],
        ]
    }

    static func rounds(_ x: inout [UInt32]) {
        func r(_ a: Int, _ b: Int, _ c: Int, _ n: UInt32) {
            let s = x[b] &+ x[c]
            x[a] ^= (s << n) | (s >> (32 - n))
        }
        for _ in 0..<10 {
            r(4, 0, 12, 7); r(8, 4, 0, 9); r(12, 8, 4, 13); r(0, 12, 8, 18)
            r(9, 5, 1, 7); r(13, 9, 5, 9); r(1, 13, 9, 13); r(5, 1, 13, 18)
            r(14, 10, 6, 7); r(2, 14, 10, 9); r(6, 2, 14, 13); r(10, 6, 2, 18)
            r(3, 15, 11, 7); r(7, 3, 15, 9); r(11, 7, 3, 13); r(15, 11, 7, 18)
            r(1, 0, 3, 7); r(2, 1, 0, 9); r(3, 2, 1, 13); r(0, 3, 2, 18)
            r(6, 5, 4, 7); r(7, 6, 5, 9); r(4, 7, 6, 13); r(5, 4, 7, 18)
            r(11, 10, 9, 7); r(8, 11, 10, 9); r(9, 8, 11, 13); r(10, 9, 8, 18)
            r(12, 15, 14, 7); r(13, 12, 15, 9); r(14, 13, 12, 13); r(15, 14, 13, 18)
        }
    }

    static func bytes(_ words: [UInt32]) -> [UInt8] {
        words.flatMap { w in (0..<4).map { UInt8(truncatingIfNeeded: w >> (8 * $0)) } }
    }

    /// HSalsa20: a 32-byte key from a 32-byte key and a 16-byte input.
    static func hsalsa20(key: [UInt8], input: [UInt8]) -> [UInt8] {
        var x = state(key: key, input: input)
        rounds(&x)
        return bytes([x[0], x[5], x[10], x[15], x[6], x[7], x[8], x[9]])
    }

    /// `count` bytes of Salsa20 keystream from block 0.
    static func salsa20Stream(key: [UInt8], nonce: [UInt8], count: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(count + 64)
        var counter: UInt64 = 0
        while out.count < count {
            let input = nonce + (0..<8).map { UInt8(truncatingIfNeeded: counter >> (8 * UInt64($0))) }
            let start = state(key: key, input: input)
            var x = start
            rounds(&x)
            out += bytes(zip(x, start).map { $0 &+ $1 })
            counter += 1
        }
        return Array(out[0..<count])
    }

    // MARK: Poly1305 (26-bit limbs)

    static func poly1305(_ message: [UInt8], key: [UInt8]) -> [UInt8] {
        let mask: UInt32 = 0x3ff_ffff
        let r0 = le32(key, 0) & 0x3ff_ffff, r1 = (le32(key, 3) >> 2) & 0x3ff_ff03
        let r2 = (le32(key, 6) >> 4) & 0x3ff_c0ff, r3 = (le32(key, 9) >> 6) & 0x3f0_3fff
        let r4 = (le32(key, 12) >> 8) & 0x00f_ffff
        let s1 = r1 &* 5, s2 = r2 &* 5, s3 = r3 &* 5, s4 = r4 &* 5
        var h0: UInt32 = 0, h1: UInt32 = 0, h2: UInt32 = 0, h3: UInt32 = 0, h4: UInt32 = 0
        var i = 0
        while i < message.count {
            var block = Array(message[i..<min(i + 16, message.count)])
            var hibit: UInt32 = 1 << 24
            if block.count < 16 {
                block.append(1)
                block += [UInt8](repeating: 0, count: 16 - block.count)
                hibit = 0
            }
            h0 &+= le32(block, 0) & mask
            h1 &+= (le32(block, 3) >> 2) & mask
            h2 &+= (le32(block, 6) >> 4) & mask
            h3 &+= (le32(block, 9) >> 6) & mask
            h4 &+= (le32(block, 12) >> 8) | hibit
            func m(_ a: UInt32, _ b: UInt32) -> UInt64 { UInt64(a) * UInt64(b) }
            let d0 = m(h0, r0) + m(h1, s4) + m(h2, s3) + m(h3, s2) + m(h4, s1)
            var d1 = m(h0, r1) + m(h1, r0) + m(h2, s4) + m(h3, s3) + m(h4, s2)
            var d2 = m(h0, r2) + m(h1, r1) + m(h2, r0) + m(h3, s4) + m(h4, s3)
            var d3 = m(h0, r3) + m(h1, r2) + m(h2, r1) + m(h3, r0) + m(h4, s4)
            var d4 = m(h0, r4) + m(h1, r3) + m(h2, r2) + m(h3, r1) + m(h4, r0)
            var c = d0 >> 26
            h0 = UInt32(truncatingIfNeeded: d0) & mask
            d1 += c; c = d1 >> 26; h1 = UInt32(truncatingIfNeeded: d1) & mask
            d2 += c; c = d2 >> 26; h2 = UInt32(truncatingIfNeeded: d2) & mask
            d3 += c; c = d3 >> 26; h3 = UInt32(truncatingIfNeeded: d3) & mask
            d4 += c; c = d4 >> 26; h4 = UInt32(truncatingIfNeeded: d4) & mask
            h0 &+= UInt32(truncatingIfNeeded: c) &* 5
            h1 &+= h0 >> 26; h0 &= mask
            i += 16
        }
        var c = h1 >> 26; h1 &= mask
        h2 &+= c; c = h2 >> 26; h2 &= mask
        h3 &+= c; c = h3 >> 26; h3 &= mask
        h4 &+= c; c = h4 >> 26; h4 &= mask
        h0 &+= c &* 5; c = h0 >> 26; h0 &= mask
        h1 &+= c
        // h - p, kept if it didn't go negative.
        var g0 = h0 &+ 5; c = g0 >> 26; g0 &= mask
        var g1 = h1 &+ c; c = g1 >> 26; g1 &= mask
        var g2 = h2 &+ c; c = g2 >> 26; g2 &= mask
        var g3 = h3 &+ c; c = g3 >> 26; g3 &= mask
        var g4 = h4 &+ c &- (1 << 26)
        var select = (g4 >> 31) &- 1
        g0 &= select; g1 &= select; g2 &= select; g3 &= select; g4 &= select
        select = ~select
        h0 = (h0 & select) | g0; h1 = (h1 & select) | g1; h2 = (h2 & select) | g2
        h3 = (h3 & select) | g3; h4 = (h4 & select) | g4
        let w0 = h0 | (h1 << 26), w1 = (h1 >> 6) | (h2 << 20), w2 = (h2 >> 12) | (h3 << 14), w3 = (h3 >> 18) | (h4 << 8)
        var f = UInt64(w0) + UInt64(le32(key, 16))
        let o0 = UInt32(truncatingIfNeeded: f)
        f = UInt64(w1) + UInt64(le32(key, 20)) + (f >> 32)
        let o1 = UInt32(truncatingIfNeeded: f)
        f = UInt64(w2) + UInt64(le32(key, 24)) + (f >> 32)
        let o2 = UInt32(truncatingIfNeeded: f)
        f = UInt64(w3) + UInt64(le32(key, 28)) + (f >> 32)
        let o3 = UInt32(truncatingIfNeeded: f)
        return bytes([o0, o1, o2, o3])
    }

    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
