import Foundation

/// Generates the `Sec-MS-GEC` token that Microsoft's Edge read-aloud endpoint
/// requires on every connection.
///
/// This is a port of the reference implementation in the `edge-tts` project. It
/// is deliberately kept byte-for-byte equivalent rather than simplified: the
/// service rejects anything that does not match, and there is no public
/// specification. The odd-looking constants below are part of the wire format,
/// not an oversight.
///
/// Two notes for anyone tempted to "clean this up":
///  * The digest is *not* plain SHA-256. It uses a custom initial state and a
///    modified round constant for the first block, so standard hashing code
///    cannot be substituted.
///  * The token is a pair `<cs64>-<sha256>`. Only the second half is a hash; the
///    first is a separate 64-bit construction seeded from the same digest.
public enum EdgeToken {
    /// Clock skew reported by the server, in seconds. Adjusted when a 403 comes
    /// back with a `Date` header, which is how the service signals a drifting
    /// device clock rather than a bad request.
    nonisolated(unsafe) public static var clockSkewSeconds: Double = 0

    static let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    /// Sent as `Sec-MS-GEC-Version`. Tied to the Chromium build the algorithm
    /// was derived from; bumping it changes the token the service expects.
    public static let version = "2-143.0.3650.75"

    /// Seconds between the Unix epoch and the Windows file-time epoch.
    static let windowsEpoch: Double = 11_644_473_600
    /// The token is valid in 5-minute buckets.
    static let bucketSeconds: Double = 300

    public static func generate(for date: Date = Date()) -> String {
        generate(unixTimestamp: date.timeIntervalSince1970 + clockSkewSeconds)
    }

    /// Exposed for tests: the reference vectors are stated in Unix seconds.
    public static func generate(unixTimestamp: Double) -> String {
        // Windows file time, in 100ns ticks, floored to the current 5-minute
        // bucket. The service validates the bucket, so both ends have to agree
        // even when the device clock is a few seconds off.
        var ticks = unixTimestamp + windowsEpoch
        ticks -= ticks.truncatingRemainder(dividingBy: bucketSeconds)
        // Seconds to 100ns ticks is 1e9/100 = 1e7. Kept as floating point, and
        // formatted rather than converted to Int64: the value exceeds 2^53, so
        // the reference implementation's rounding is part of the token.
        ticks *= 10_000_000

        let material = Array("\(String(format: "%.0f", ticks))\(trustedClientToken)".utf8)
        let digest = sha256Digest(material)
        let cs64 = cs64Digest(material, digest: digest)

        // The reference implementation packs the pair as little-endian u32 and
        // hex-encodes the bytes, so the text is byte-swapped relative to the
        // numeric values. Formatting them as `<08X>` would produce a token the
        // service rejects.
        let cs64Text = [cs64.0, cs64.1]
            .flatMap { word in
                [UInt8(truncatingIfNeeded: word), UInt8(truncatingIfNeeded: word >> 8),
                 UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 24)]
            }
            .map { String(format: "%02X", $0) }
            .joined()
        let digestText = digest.map { String(format: "%02X", $0) }.joined()
        return "\(cs64Text)-\(digestText)"
    }

    // MARK: - SHA-256 variant

    static let initial: [UInt32] = [
        0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
        0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
    ]

    /// State the first block starts from. Differs from `initial`, which is why
    /// the result does not match stock SHA-256.
    static let blockState: [UInt32] = [
        0xFD9FBEA2, 0x91243CE7, 0xBE499094, 0xCD2E1E0A,
        0x6C006F49, 0x04BD35AB, 0xFEB0A7E4, 0x03EFFBD2,
    ]

    static let scheduleSeed: [UInt32] = [
        0xEB24BF9E, 0x1558691F, 0xA0C09EE2, 0x0CFA32BA,
        0xA622EE8C, 0xD1DD9491, 0xC0DD25A0, 0xF9E70AB6,
        0xF0C31573, 0x7058CE4E, 0x7188E606, 0x00E5AB33,
        0xD258B060, 0x72766564,
    ]

    static let roundConstants: [UInt32] = [
        0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
        0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3, 0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
        0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
        0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
        0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13, 0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
        0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
        0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
        0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208, 0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
    ]

    /// `roundConstants` with one entry swapped. The service depends on it.
    static let adjustedConstants: [UInt32] = {
        var values = roundConstants
        values[14] = 0xC9DC06A7
        return values
    }()

    static func rotr(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }

    /// `(value >>> 6) ^ (value >>> 11) ^ (value >>> 25)`.
    ///
    /// Computed in 64 bits as `value * 2^32 + value`, which repeats the word on
    /// both halves so a *logical* shift yields the rotate in the low 32 bits.
    /// This mirrors the reference implementation exactly — a plain 32-bit
    /// rotate here produces a different token.
    static func bigSigma1(_ value: UInt32) -> UInt32 {
        let wide = UInt64(value) * 0x1_0000_0001
        return UInt32(truncatingIfNeeded: (wide >> 6) ^ (wide >> 11) ^ (wide >> 25))
    }

    /// `(value >>> 2) ^ (value >>> 13) ^ (value >>> 22)`.
    static func bigSigma0(_ value: UInt32) -> UInt32 {
        let wide = UInt64(value) * 0x1_0000_0001
        return UInt32(truncatingIfNeeded: (wide >> 2) ^ (wide >> 13) ^ (wide >> 22))
    }

    static func sigma0(_ value: UInt32) -> UInt32 {
        rotr(value, 7) ^ rotr(value, 18) ^ (value >> 3)
    }

    static func sigma1(_ value: UInt32) -> UInt32 {
        rotr(value, 17) ^ rotr(value, 19) ^ (value >> 10)
    }

    /// Runs the compression rounds over `words`.
    ///
    /// `firstRound` is 14 for the first block: rounds 0–13 are implied by
    /// `blockState`, and round 14 onward uses a swapped constant.
    static func rounds(_ state: [UInt32], words: [UInt32], firstRound: Int = 0) -> [UInt32] {
        let constants = firstRound == 14 ? adjustedConstants : roundConstants
        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]

        for index in firstRound..<64 {
            let t1 = h &+ bigSigma1(e) &+ (g ^ (e & (f ^ g))) &+ constants[index] &+ words[index]
            let t2 = bigSigma0(a) &+ ((a & b) | (c & (a | b)))
            h = g
            g = f
            f = e
            e = d &+ t1
            d = c
            c = b
            b = a
            a = t1 &+ t2
        }
        return [a, b, c, d, e, f, g, h]
    }
    static func expandSchedule(_ words: [UInt32], from first: Int) -> [UInt32] {
        var words = words
        for index in first..<64 {
            let x = words[index - 2]
            let y = words[index - 15]
            let s1 = (x >> 17) ^ (x << 15) ^ (x >> 19) ^ (x << 13) ^ (x >> 10)
            let s0 = (y >> 7) ^ (y << 25) ^ (y >> 18) ^ (y << 14) ^ (y >> 3)
            words.append(s1 &+ words[index - 7] &+ s0 &+ words[index - 16])
        }
        return words
    }

    /// Seeds the block from the first seven bytes of `data`.
    ///
    /// This is where the variant diverges most from SHA-256: instead of the
    /// standard padding, the leading bytes are packed into the schedule itself.
    static func initialWords(_ data: [UInt8]) -> [UInt32] {
        func bigEndian(_ slice: ArraySlice<UInt8>) -> UInt32 {
            slice.reduce(0) { $0 << 8 | UInt32($1) }
        }

        var words = [UInt32](repeating: 0, count: 14)
        words.append(bigEndian(data[0..<3]))
        words.append(bigEndian(data[3..<7]))

        for index in 16..<30 {
            var value = scheduleSeed[index - 16]
            if index - 2 >= 14 {
                value &+= index == 16 ? (sigma1(words[index - 2]) ^ 0x000B_92C0) : sigma1(words[index - 2])
            }
            if index - 7 >= 14 {
                value &+= words[index - 7]
            }
            if index - 15 >= 14 {
                value &+= index == 29 ? (sigma0(words[index - 15]) ^ 0x059C_0B80) : sigma0(words[index - 15])
            }
            words.append(value)
        }

        words.append(
            sigma1(words[28])
                &+ words[23]
                &+ sigma0(words[15])
                &+ words[14]
                &+ 0xC9DC_06A7
                &- roundConstants[14]
        )
        return expandSchedule(words, from: 31)
    }

    static func sha256Digest(_ data: [UInt8]) -> [UInt8] {
        precondition(data.count >= 7, "token material is always long enough")

        // Length of the *whole* material, though only `data[7...]` is hashed;
        // the prefix reaches the digest through `initialWords`.
        let length = 57 + data.count
        var padded = Array(data[7...])
        padded.append(0x80)
        // Swift's `%` keeps the sign of the dividend, unlike Python's, so the
        // pad count has to be normalised before it can be used as a length.
        let padCount = ((55 - length) % 64 + 64) % 64
        padded.append(contentsOf: [UInt8](repeating: 0, count: padCount))
        let bits = UInt64(length * 8)
        padded.append(contentsOf: (0..<8).reversed().map { UInt8(truncatingIfNeeded: bits >> (UInt64($0) * 8)) })

        // The seed already includes the standard initial values: the custom
        // state runs over the header block and H0 is folded in, which is how
        // the prefix bytes reach the digest. Adding H0 again here would be
        // double-counting.
        var state = rounds(blockState, words: initialWords(Array(data[0..<7])), firstRound: 14)
        state = zip(initial, state).map { $0 &+ $1 }

        var offset = 0
        while offset < padded.count {
            let block = Array(padded[offset..<(offset + 64)])
            var words: [UInt32] = []
            words.reserveCapacity(64)
            for index in 0..<16 {
                let base = index * 4
                words.append(
                    UInt32(block[base]) << 24
                        | UInt32(block[base + 1]) << 16
                        | UInt32(block[base + 2]) << 8
                        | UInt32(block[base + 3])
                )
            }
            words = expandSchedule(words, from: 16)
            // Standard Merkle–Damgård compression: the chaining value is added
            // back into the round output.
            state = zip(state, rounds(state, words: words)).map { $0 &+ $1 }
            offset += 64
        }

        return state.flatMap { word in
            [UInt8(truncatingIfNeeded: word >> 24), UInt8(truncatingIfNeeded: word >> 16),
             UInt8(truncatingIfNeeded: word >> 8), UInt8(truncatingIfNeeded: word)]
        }
    }

    // MARK: - cs64

    static let cs64Coefficients: [(UInt32, UInt32)] = [
        (0xE82E91B1, 0xB32700D0), (0x44DE24C6, 0x88DFF51D), (0x3BEB65BC, 0x29514038),
        (0xC89C5933, 0xB328CBDF), (0x8D1EC211, 0xD405B4D5), (0x314EF5D5, 0x26E55F3C),
        (0xE92491B1, 0x607801C6), (0xF0A5B9D5, 0x82B2C1FB), (0x06064CF3, 0xFA51A3DA),
        (0xDA79FA60, 0x207CC464), (0xBED20560, 0x3C3C74F3), (0x89F9C9F8, 0xD2D14B61),
        (0x35FA38C6, 0xBB04A2C1), (0xCB49E3C6, 0xC5626167),
    ]

    static func rol16(_ value: UInt32) -> UInt32 {
        (value << 16) | (value >> 16)
    }

    static func wordsLE(_ data: [UInt8]) -> [UInt32] {
        var padded = data
        if padded.count % 4 != 0 {
            padded.append(contentsOf: [UInt8](repeating: 0, count: 4 - padded.count % 4))
        }
        guard !padded.isEmpty else { return [] }
        var words: [UInt32] = []
        words.reserveCapacity(padded.count / 4)
        for index in stride(from: 0, to: padded.count, by: 4) {
            words.append(
                UInt32(padded[index])
                    | UInt32(padded[index + 1]) << 8
                    | UInt32(padded[index + 2]) << 16
                    | UInt32(padded[index + 3]) << 24
            )
        }
        if words.count % 2 != 0 { words.append(0) }
        return words
    }

    static func cs64Digest(_ data: [UInt8], digest: [UInt8]) -> (UInt32, UInt32) {
        var keyA = UInt32(digest[0]) | UInt32(digest[1]) << 8 | UInt32(digest[2]) << 16 | UInt32(digest[3]) << 24
        var keyB = UInt32(digest[4]) | UInt32(digest[5]) << 8 | UInt32(digest[6]) << 16 | UInt32(digest[7]) << 24
        keyA |= 1
        keyB |= 1

        let factor = UInt32(0x8289_3933)
        let factors = [keyA &* factor, keyB &* factor]

        var terms: [UInt32] = []
        var offsets: [UInt32] = []
        terms.reserveCapacity(cs64Coefficients.count * 2 + 16)
        for (index, coefficient) in cs64Coefficients.enumerated() {
            terms.append(coefficient.0 &* factors[index % 2])
            offsets.append(coefficient.1)
        }

        for (index, word) in wordsLE([0] + data).enumerated() {
            var term = word &* (index % 2 == 0 ? keyA : keyB)
            var offset = rol16(word) &* (index % 2 == 0 ? 0xEF05_69FB : 0xC317_13DB)
            if index == 0 {
                term = term &+ 0xF2F9_0B1A &* factors[0]
                offset = offset &+ 0x0B1A_0000
            }
            terms.append(term)
            offsets.append(offset)
        }

        var swapAcc: UInt32 = 0
        var swapLast: UInt32 = 0
        var state: UInt32 = 0
        var acc: UInt32 = 0

        for index in stride(from: 0, to: terms.count, by: 2) {
            let x = terms[index]
            let y = terms[index + 1]

            var t = rol16(offsets[index] &+ x)
            var q = t &* 0x76F5_0F34
            swapAcc &+= rol16(q) &* 0xC3EF_EA97 &+ q

            t = rol16(offsets[index + 1] &+ y)
            q = t &* 0x1881_CE3C
            swapLast = rol16(q) &* 0x35BD_1EC9 &+ q
            swapAcc &+= swapLast

            state = state &* keyA &+ x
            state = rol16(state) &* 0xCF98_B111
            state = rol16(state) &* 0x8708_5B9F
            state = rol16(state) &* 0x12CE_B96D
            state = rol16(state) &* 0x257E_1D83
            acc &+= state

            var t2 = state &* keyB &+ y
            t2 = rol16(t2) &* 0xA274_16F5
            t2 = rol16(t2) &* 0xD383_96FF
            state = rol16(rol16(t2) &* 0x7C93_2B89) &* 0xBFA4_9F69
            acc &+= state
        }

        return (swapLast ^ state, swapAcc ^ acc)
    }
}
