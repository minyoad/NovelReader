import Testing
import Foundation
@testable import NovelKit

@Suite("SHA-256 and HMAC")
struct CryptoPrimitiveTests {

    @Test("sha256 matches known vectors")
    func knownVectors() {
        // FIPS 180-2 test vectors. A wrong hash silently breaks every S3
        // signature with a 403, so these are the cheapest possible guard.
        #expect(S3Transport.sha256Hex(Data()) ==
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(S3Transport.sha256Hex(Data("abc".utf8)) ==
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(S3Transport.sha256Hex(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)) ==
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    @Test("sha256 handles block boundaries")
    func blockBoundaries() {
        // 55, 56, 64 and 65 bytes are exactly where the padding logic branches.
        for length in [55, 56, 63, 64, 65, 119, 120] {
            let data = Data(repeating: 0x61, count: length)
            let hex = S3Transport.sha256Hex(data)
            #expect(hex.count == 64)
            // Deterministic and distinct per length.
            #expect(S3Transport.sha256Hex(data) == hex)
        }
        let a = S3Transport.sha256Hex(Data(repeating: 0x61, count: 64))
        let b = S3Transport.sha256Hex(Data(repeating: 0x61, count: 65))
        #expect(a != b)
    }

    @Test("hmac-sha256 matches the RFC 4231 vector")
    func hmacVector() {
        // RFC 4231 case 2: key "Jefe", data "what do ya want for nothing?".
        let key = Data("Jefe".utf8)
        let data = Data("what do ya want for nothing?".utf8)
        #expect(S3Transport.hmacHex(key: key, data: data) ==
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
    }

    @Test("the signing key follows the AWS derivation chain")
    func signingKey() {
        // AWS documentation example (20130524 / us-east-1 / s3), so any
        // mistake in the HMAC chain shows up here rather than as a 403.
        let key = S3Transport.signingKey(
            secret: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            dateStamp: "20130524",
            region: "us-east-1"
        )
        let hex = key.map { String(format: "%02x", $0) }.joined()
        #expect(hex == "dbb893acc010964918f1fd433add87c70e8b0db6be30c1fbeafefa5ec6ba8378")
    }
}

@Suite("SigV4 canonicalisation")
struct SigV4CanonicalisationTests {

    @Test("paths are percent-encoded per segment, slashes kept")
    func canonicalPath() {
        // SigV4 signs the encoded path exactly as sent. A space becoming "%20"
        // in one place and "+" in another produces a 403 that looks like a
        // credential problem.
        let url = URL(string: "https://example.com/my bucket/夜读.json")!
        let path = S3Transport.canonicalPath(url)
        #expect(path.hasPrefix("/my%20bucket/"))
        #expect(path.hasSuffix(".json"))
        // Non-ASCII must be percent-encoded, not passed through.
        #expect(!path.contains("夜"))
    }

    @Test("query parameters are sorted and encoded")
    func canonicalQuery() {
        let url = URL(string: "https://example.com/a?b=2&a=1&a=0")!
        #expect(S3Transport.canonicalQuery(url) == "a=0&a=1&b=2")
        let none = URL(string: "https://example.com/a")!
        #expect(S3Transport.canonicalQuery(none) == "")
    }

    @Test("unreserved characters survive percent-encoding")
    func percentEncode() {
        #expect(S3Transport.percentEncode("aZ09-._~") == "aZ09-._~")
        #expect(S3Transport.percentEncode("a b") == "a%20b")
        #expect(S3Transport.percentEncode("a+b") == "a%2Bb")
    }
}
