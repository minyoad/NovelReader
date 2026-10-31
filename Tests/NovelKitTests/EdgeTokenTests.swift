import Foundation
import Testing
@testable import NovelKit

/// Vectors produced by the reference Python implementation (`edge-tts` 7.3.1).
/// The algorithm is undocumented, so these are the only contract we have: if
/// they stop matching, the token the service expects has changed.
@Suite("Edge TTS token")
struct EdgeTokenTests {
    static let vectors: [(Double, String)] = [
        (1700000000.123, "2CD23A2CA0B2595A-F3C846C370E05F9CC83ACC5F995C5F5D87A4D0F14CE8936A0F902E64099E38A2"),
        (1720000000.0, "576EF243D9E6C36D-B73D5ADB984074BAE7860791FCA9CE1D28D1F6678CE5644A7981ACCA7E3C0EF2"),
        (1751234567.789, "70FBAF57997A75DF-C44B91C312C7BED67E09D1384857C4422C3349325869A66B3BF7C8B9EC6291D0"),
    ]

    @Test("matches the reference implementation bit for bit", arguments: vectors)
    func matches(_ vector: (Double, String)) {
        let generated = EdgeToken.generate(unixTimestamp: vector.0)
        #expect(generated == vector.1, "token drifted for timestamp \(vector.0)")
    }

    @Test("timestamps inside one five-minute bucket agree")
    func bucketIsStable() {
        // The service validates the bucket, so a few seconds of clock drift
        // between the device and the server must not change the token.
        // Deliberately an exact multiple of 300 so the whole window below
        // stays inside one bucket.
        let base: Double = 1_700_000_100
        let first = EdgeToken.generate(unixTimestamp: base)
        #expect(EdgeToken.generate(unixTimestamp: base + 120) == first)
        #expect(EdgeToken.generate(unixTimestamp: base + 299) == first)
        // Crossing into the next bucket must change it.
        #expect(EdgeToken.generate(unixTimestamp: base + 300) != first)
    }

    @Test("token has the shape the service expects")
    func shape() {
        let token = EdgeToken.generate(unixTimestamp: 1_700_000_000)
        let parts = token.split(separator: "-")
        #expect(parts.count == 2)
        #expect(parts[0].count == 16)
        #expect(parts[1].count == 64)
        #expect(token.allSatisfy { $0.isHexDigit || $0 == "-" })
        #expect(token == token.uppercased())
    }

    @Test("clock skew shifts the generated token")
    func skew() {
        let timestamp: Double = 1_700_000_000
        let reference = EdgeToken.generate(unixTimestamp: timestamp)
        EdgeToken.clockSkewSeconds = 3600
        defer { EdgeToken.clockSkewSeconds = 0 }

        #expect(EdgeToken.generate(for: Date(timeIntervalSince1970: timestamp - 3600)) == reference)
    }
}
