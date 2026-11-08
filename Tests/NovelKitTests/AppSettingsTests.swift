import Testing
import Foundation
@testable import NovelKit

/// `AppSettings` gains fields over time; a file written by an older build has
/// to keep opening rather than resetting everything the user chose.
@Suite("AppSettings forward compatibility")
struct AppSettingsTests {

    @Test("a file from before pinned sources existed still decodes")
    func missingPinnedSources() throws {
        let json = #"{"searchHistory":["剑来"],"searchAllSources":false}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(settings.searchHistory == ["剑来"])
        #expect(settings.searchAllSources == false)
        // Absent means an empty list, not a failure to decode the whole file.
        #expect(settings.pinnedSourceIDs.isEmpty)
    }

    @Test("pinned sources survive a round trip")
    func roundTrip() throws {
        let id = UUID()
        var settings = AppSettings()
        settings.pinnedSourceIDs = [id]
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.pinnedSourceIDs == [id])
    }
}
