// SPDX-License-Identifier: MIT
import Foundation

/// A Bloom filter over hostnames, used as a fast "definitely not listed" check before the
/// trie walk. Double hashing (Kirsch–Mitzenmacher) over two 64-bit FNV-1a variants.
public struct BloomFilter: Equatable {
    public private(set) var bits: [UInt8]
    public let bitCount: Int
    public let hashCount: Int

    /// Sized for `capacity` items at roughly `falsePositiveRate`.
    public init(capacity: Int, falsePositiveRate: Double = 0.01) {
        let n = Double(max(1, capacity))
        let m = max(64, Int((-n * log(falsePositiveRate) / (log(2) * log(2))).rounded(.up)))
        let k = max(1, min(16, Int((Double(m) / n * log(2)).rounded())))
        bitCount = (m + 7) / 8 * 8
        hashCount = k
        bits = [UInt8](repeating: 0, count: bitCount / 8)
    }

    public init(bits: [UInt8], hashCount: Int) {
        self.bits = bits
        self.bitCount = bits.count * 8
        self.hashCount = max(1, hashCount)
    }

    @inline(__always)
    static func hashes<S: Sequence>(_ bytes: S) -> (UInt64, UInt64) where S.Element == UInt8 {
        var h1: UInt64 = 0xcbf2_9ce4_8422_2325
        var h2: UInt64 = 0x84222325_cbf29ce4
        for b in bytes {
            h1 = (h1 ^ UInt64(b)) &* 0x0000_0100_0000_01b3
            h2 = (h2 &+ UInt64(b)) &* 0x9E37_79B9_7F4A_7C15
            h2 ^= h2 >> 29
        }
        return (h1, h2 | 1)
    }

    public mutating func insert(_ s: String) { insert(bytes: Array(s.utf8)) }

    public mutating func insert<S: Sequence>(bytes: S) where S.Element == UInt8 {
        let (a, b) = BloomFilter.hashes(bytes)
        let m = UInt64(bitCount)
        for i in 0..<UInt64(hashCount) {
            let bit = Int((a &+ i &* b) % m)
            bits[bit >> 3] |= 1 << UInt8(bit & 7)
        }
    }

    public func mightContain(_ s: Substring) -> Bool { mightContain(bytes: s.utf8) }
    public func mightContain(_ s: String) -> Bool { mightContain(bytes: s.utf8) }

    public func mightContain<S: Sequence>(bytes: S) -> Bool where S.Element == UInt8 {
        let (a, b) = BloomFilter.hashes(bytes)
        let m = UInt64(bitCount)
        for i in 0..<UInt64(hashCount) {
            let bit = Int((a &+ i &* b) % m)
            if bits[bit >> 3] & (1 << UInt8(bit & 7)) == 0 { return false }
        }
        return true
    }
}
