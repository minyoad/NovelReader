import Testing
import Foundation

@testable import NovelKit

@Suite("朗读：网络中断后的重试策略")
struct SpeechRetryPolicyTests {

    @Test("前两次重试很快，目标是恢复得越早越好")
    func fastAtFirst() {
        #expect(SpeechRetryRules.retryDelay(afterFailure: 1) == 500)
        #expect(SpeechRetryRules.retryDelay(afterFailure: 2) == 1_000)
    }

    @Test("重试间隔有上限，不会无限拉长")
    func delayIsCapped() {
        #expect(SpeechRetryRules.retryDelay(afterFailure: 9) == 6_000)
        #expect(SpeechRetryRules.retryDelay(afterFailure: 100) == 6_000)
    }

    @Test("间隔单调不下降")
    func delayIsMonotonic() {
        var previous = 0
        for attempt in 1...20 {
            let current = SpeechRetryRules.retryDelay(afterFailure: attempt)
            #expect(current >= previous)
            previous = current
        }
    }

    @Test("一分钟中断会经历十余次重试，而不是早早放弃")
    func aMinuteOfOutageKeepsRetrying() {
        // The old code gave up after three attempts — about 1.8 seconds total.
        var elapsed = 0
        var attempted = 0
        while elapsed < 60_000 {
            attempted += 1
            elapsed += SpeechRetryRules.retryDelay(afterFailure: attempted)
        }
        #expect(attempted >= 12)
    }

    @Test("重试永远不放弃：十分钟以上仍在重试")
    func neverGivesUp() {
        var elapsed = 0
        var attempted = 0
        while elapsed < 10 * 60_000 {
            attempted += 1
            elapsed += SpeechRetryRules.retryDelay(afterFailure: attempted)
        }
        #expect(attempted >= 100)
    }

    @Test("令牌失效和无音频不重试：等多久都不会变好")
    func permanentFailures() {
        #expect(SpeechRetryRules.isPermanent(EdgeTTSError.tokenRejected))
        #expect(SpeechRetryRules.isPermanent(EdgeTTSError.noAudio))
        #expect(!SpeechRetryRules.isPermanent(EdgeTTSError.closedEarly))
        #expect(!SpeechRetryRules.isPermanent(EdgeTTSError.transport(host: "speech.platform.bing.com", code: nil)))
        #expect(!SpeechRetryRules.isPermanent(EdgeTTSError.allEndpointsFailed(["超时", "重置"])))
    }
}
