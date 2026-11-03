import Foundation
#if canImport(os)
import os
#endif

/// Diagnostic logging for the discover page.
///
/// Two sinks, because neither is reliable on its own:
///
/// - `idevicesyslog` never delivered this app's messages on iOS 26 — the
///   stream connects and then stays silent — so the primary sink is a plain
///   file in `Documents`, which can be pulled out of the app container.
/// - `os_log` is kept for Console.app users on a Mac.
///
/// Temporary scaffolding for chasing a third-party source format. Remove once
/// the discover page is trusted.
public enum ExploreLog {
    #if canImport(os)
    private static let logger = Logger(subsystem: "com.yang.NovelReader", category: "explore")
    #endif

    /// Serialises appends; the engine logs from several tasks at once.
    private static let queue = DispatchQueue(label: "com.yang.NovelReader.explorelog")

    private static var fileURL: URL? {
        guard let directory = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return directory.appendingPathComponent("explore.log")
    }

    /// Where the log lives, so the UI can show it to the reader.
    public static var currentFileURL: URL? { fileURL }

    public static func line(_ message: String) {
        #if canImport(os)
        logger.notice("NovelReaderExplore \(message, privacy: .public)")
        #endif
        let entry = "\(timestamp()) NovelReaderExplore \(message)\n"
        queue.sync {
            guard let url = fileURL else { return }
            guard let data = entry.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Multi-line text, split so each line stands on its own.
    public static func block(_ label: String, _ text: String) {
        line("\(label) (len=\(text.count))")
        for (index, row) in text.components(separatedBy: .newlines).enumerated() {
            line("\(label)[\(index)] \(row)")
        }
    }

    /// Empties the file so one session's log is not buried under earlier ones.
    public static func reset() {
        queue.sync {
            guard let url = fileURL else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static func timestamp() -> String {
        formatter.string(from: Date())
    }
}
