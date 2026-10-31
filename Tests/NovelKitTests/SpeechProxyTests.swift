import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import NovelKit

@Suite("Speech proxy")
struct SpeechProxyTests {

    @Test("bare host:port is accepted")
    func bareHostPort() throws {
        let proxy = try #require(SpeechProxy("192.168.1.5:7890"))
        #expect(proxy.host == "192.168.1.5")
        #expect(proxy.port == 7890)
        #expect(proxy.displayName == "192.168.1.5:7890")
    }

    @Test("a scheme is tolerated, and the default port fills in")
    func schemeAndDefaults() throws {
        let http = try #require(SpeechProxy("http://10.0.0.2:1080"))
        #expect(http.host == "10.0.0.2")
        #expect(http.port == 1080)

        // A port left off is the common mistake; 7890 is what most local
        // proxy clients use, so guessing beats refusing.
        let guessed = try #require(SpeechProxy("127.0.0.1"))
        #expect(guessed.port == 7890)
    }

    @Test("paths and credentials pasted along with the address are dropped")
    func trimsNoise() throws {
        let proxy = try #require(SpeechProxy("  http://user:pass@192.168.1.5:7890/some/path  "))
        #expect(proxy.host == "192.168.1.5")
        #expect(proxy.port == 7890)
    }

    @Test("empty, malformed and unsupported values are rejected")
    func rejects() {
        #expect(SpeechProxy("") == nil)
        #expect(SpeechProxy("   ") == nil)
        // SOCKS is not supported by CFNetwork's proxy dictionary the same way,
        // so it must be reported rather than silently mangled into a hostname.
        #expect(SpeechProxy("socks5://127.0.0.1:1080") == nil)
        #expect(SpeechProxy("127.0.0.1:0") == nil)
        #expect(SpeechProxy("127.0.0.1:70000") == nil)
        #expect(SpeechProxy("127.0.0.1:abc") == nil)
    }

    @Test("the proxy dictionary enables both HTTP and HTTPS")
    func dictionary() throws {
        let proxy = try #require(SpeechProxy("10.0.0.2:3128"))
        let dictionary = proxy.dictionary
        #expect(dictionary["HTTPProxy"] as? String == "10.0.0.2")
        #expect(dictionary["HTTPPort"] as? Int == 3128)
        #expect(dictionary["HTTPSProxy"] as? String == "10.0.0.2")
        #expect(dictionary["HTTPSPort"] as? Int == 3128)
        #expect(dictionary["HTTPEnable"] as? Int == 1)
    }

    @Test("an empty setting keeps the shared session")
    func emptyKeepsSharedSession() {
        // Reusing `URLSession.shared` matters: a fresh session per utterance
        // would drop the connection cache and make every sentence re-handshake.
        #expect(SpeechSession.make(proxy: "") === URLSession.shared)
    }

    @Test("a configured proxy gets its own session, reused across calls")
    func proxyGetsOwnSession() {
        let a = SpeechSession.make(proxy: "10.0.0.2:3128")
        let b = SpeechSession.make(proxy: "10.0.0.3:3128")
        #expect(a !== URLSession.shared)
        #expect(a !== b)
        // Reusing the session keeps the proxy tunnel (and its TLS handshake)
        // warm; a new one per utterance would renegotiate every sentence.
        #expect(SpeechSession.make(proxy: "10.0.0.2:3128") === a)
        SpeechSession.reset()
    }
}
