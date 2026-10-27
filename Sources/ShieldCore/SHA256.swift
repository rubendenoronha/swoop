// SPDX-License-Identifier: MIT
//
// Pure-Swift SHA-256 (FIPS 180-4) so list verification and index checksums work the same
// on Linux and in the sandboxed extensions without CryptoKit/CommonCrypto.
import Foundation

public struct SHA256Digest: Equatable, CustomStringConvertible {
    public let bytes: [UInt8]
    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }
    public var description: String { hex }
}

public struct SHA256 {
    private var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    private var buffer: [UInt8] = []
    private var length: UInt64 = 0

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    public init() {}

    public static func hash<D: Sequence>(_ data: D) -> SHA256Digest where D.Element == UInt8 {
        var s = SHA256()
        s.update(Array(data))
        return s.finalize()
    }

    public static func hash(_ data: Data) -> SHA256Digest {
        var s = SHA256()
        s.update(data)
        return s.finalize()
    }

    public mutating func update(_ data: Data) {
        data.withUnsafeBytes { raw in update(raw.bindMemory(to: UInt8.self)) }
    }

    public mutating func update(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { update($0) }
    }

    public mutating func update(_ bytes: UnsafeBufferPointer<UInt8>) {
        length &+= UInt64(bytes.count)
        var i = 0
        if !buffer.isEmpty {
            let need = 64 - buffer.count
            let take = min(need, bytes.count)
            buffer.append(contentsOf: bytes[0..<take])
            i = take
            if buffer.count == 64 {
                buffer.withUnsafeBufferPointer { block($0, 0) }
                buffer.removeAll(keepingCapacity: true)
            }
        }
        while i + 64 <= bytes.count {
            block(bytes, i)
            i += 64
        }
        if i < bytes.count { buffer.append(contentsOf: bytes[i...]) }
    }

    public mutating func finalize() -> SHA256Digest {
        let bitLen = length &* 8
        var pad: [UInt8] = [0x80]
        let rem = (buffer.count + 1) % 64
        pad.append(contentsOf: [UInt8](repeating: 0, count: rem <= 56 ? 56 - rem : 120 - rem))
        for s in stride(from: 56, through: 0, by: -8) { pad.append(UInt8((bitLen >> UInt64(s)) & 0xFF)) }
        let saved = length
        update(pad)
        length = saved
        var out: [UInt8] = []
        for v in h { out += [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        return SHA256Digest(bytes: out)
    }

    private mutating func block(_ p: UnsafeBufferPointer<UInt8>, _ o: Int) {
        var w = [UInt32](repeating: 0, count: 64)
        for t in 0..<16 {
            w[t] = UInt32(p[o + 4 * t]) << 24 | UInt32(p[o + 4 * t + 1]) << 16 | UInt32(p[o + 4 * t + 2]) << 8 | UInt32(p[o + 4 * t + 3])
        }
        @inline(__always) func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        for t in 16..<64 {
            let s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
            let s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
            w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
        }
        var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
        for t in 0..<64 {
            let S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = hh &+ S1 &+ ch &+ SHA256.k[t] &+ w[t]
            let S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = S0 &+ maj
            hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
        }
        h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
    }
}
