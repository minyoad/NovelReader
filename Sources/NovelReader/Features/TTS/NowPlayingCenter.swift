#if canImport(MediaPlayer) && canImport(UIKit)
import MediaPlayer
import UIKit

/// Mirrors playback into the system, and lets the system drive playback.
///
/// Two directions live here because they share the same state:
/// `MPNowPlayingInfoCenter` publishes what is being read so the Lock Screen,
/// Control Center and CarPlay show a title and a progress bar, while
/// `MPRemoteCommandCenter` turns the buttons there — and the ones on a Bluetooth
/// headset — into calls on the reader.
///
/// Chapters and sentences are separate commands on purpose. Headphone buttons
/// offer one forward/back pair, and for a novel the useful unit there is the
/// chapter, so `nextTrack`/`previousTrack` move between chapters. Single
/// sentences stay on the skip buttons, which is where a system UI already
/// expects a fine-grained jump.
@MainActor
final class NowPlayingCenter {
    struct Track: Equatable {
        var title: String
        var artist: String
        /// Not rendered by the system Now Playing card.
        ///
        /// The card draws only the title and the artist/subtitle lines. This
        /// field exists for completeness and for anything that reads the full
        /// media item; do not put information here expecting it to be seen.
        var album: String
        var artworkURL: String?

        static let empty = Track(title: "", artist: "", album: "", artworkURL: nil)
    }

    // MARK: - Reader callbacks

    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onTogglePlayPause: (() -> Void)?
    var onNextChapter: (() -> Void)?
    var onPreviousChapter: (() -> Void)?
    var onNextSentence: (() -> Void)?
    var onPreviousSentence: (() -> Void)?
    /// Called with the absolute position, in seconds, the user dragged to.
    var onSeek: ((Double) -> Void)?

    // MARK: - State

    private var track: Track = .empty
    private var artwork: MPMediaItemArtwork?
    private var artworkSource: String?
    private var artworkTask: Task<Void, Never>?
    private var didRegisterCommands = false

    /// Last published playback state.
    ///
    /// Kept so a partial update — a new chapter title, say — republishes the
    /// whole dictionary. Writing only the title would drop the playback rate
    /// and freeze the system's progress bar until the next sentence.
    private var elapsed: Double = 0
    private var duration: Double = 0
    private var isPlaying = false
    /// Current sentence, shown under the title on the Lock Screen.
    private var subtitle = ""

    // MARK: - Registry

    /// Registers the remote commands.
    ///
    /// Safe to call repeatedly: the targets are installed once, so they never
    /// stack up into double-handled presses.
    func activate() {
        guard !didRegisterCommands else { return }
        didRegisterCommands = true

        let center = MPRemoteCommandCenter.shared()

        // Legacy but still meaningful: for audio that does not come from
        // `AVPlayer` (here `AVAudioPlayer` and `AVSpeechSynthesizer`), some iOS
        // versions only route Lock Screen presses to the app after this call.
        // Harmless when redundant.
        UIApplication.shared.beginReceivingRemoteControlEvents()

        // All of these matter for a headset: a single click arrives as
        // `togglePlayPause`, while Control Center and CarPlay send explicit
        // play/pause once they know the state.
        for command in [
            center.playCommand,
            center.pauseCommand,
            center.togglePlayPauseCommand,
            center.stopCommand,
            center.nextTrackCommand,
            center.previousTrackCommand,
            center.seekForwardCommand,
            center.seekBackwardCommand,
            center.changePlaybackPositionCommand,
        ] {
            command.isEnabled = true
            // The command center is shared process-wide, so a previous reader
            // (or a previous book) may have left handlers behind. Clearing them
            // keeps one library from answering another's presses twice.
            command.removeTarget(nil)
        }

        center.playCommand.addTarget { [weak self] _ in
            Self.accept { self?.onPlay?() }
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Self.accept { self?.onPause?() }
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Self.accept { self?.onTogglePlayPause?() }
        }
        // "Stop" on a headset long-press is better treated as pause than as a
        // full teardown: the reader keeps its place and can resume.
        center.stopCommand.addTarget { [weak self] _ in
            Self.accept { self?.onPause?() }
        }

        center.nextTrackCommand.addTarget { [weak self] _ in
            Self.accept { self?.onNextChapter?() }
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Self.accept { self?.onPreviousChapter?() }
        }

        center.seekForwardCommand.addTarget { [weak self] _ in
            Self.accept { self?.onNextSentence?() }
        }
        center.seekBackwardCommand.addTarget { [weak self] _ in
            Self.accept { self?.onPreviousSentence?() }
        }

        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = event.positionTime
            return Self.accept { self?.onSeek?(position) }
        }
    }

    /// Hands a command to the main actor and tells the system it was accepted.
    ///
    /// The handler has to answer synchronously, so the work is scheduled rather
    /// than awaited — the delay is one run-loop turn, imperceptible on a press.
    private static func accept(_ work: @escaping @MainActor () -> Void) -> MPRemoteCommandHandlerStatus {
        Task { @MainActor in work() }
        return .success
    }

    // MARK: - Publishing

    /// Sets what the system should display.
    ///
    /// Repeated calls with an unchanged track are ignored so artwork is not
    /// re-downloaded on every sentence.
    func setTrack(_ newTrack: Track) {
        guard newTrack != track else { return }
        track = newTrack
        if newTrack.artworkURL != artworkSource {
            loadArtwork(newTrack.artworkURL)
        }
        push()
    }

    /// The sentence currently being read.
    ///
    /// Becomes the second line of the system card, replacing the author while
    /// reading. That line is the only one the card gives up for detail, so it
    /// goes to the sentence: the reader already shows the chapter heading and
    /// highlights the sentence in the page, but neither is visible on a locked
    /// screen. Changes on every sentence, which is why it is separate from
    /// `setTrack`.
    func setSubtitle(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != subtitle else { return }
        subtitle = trimmed
        push()
    }

    /// Publishes position and state.
    ///
    /// Called on every sentence change: frequent enough that the progress bar
    /// stays in step, rare enough that it costs nothing.
    func update(elapsed: Double, duration: Double, isPlaying: Bool) {
        self.elapsed = max(elapsed, 0)
        self.duration = max(duration, 0)
        self.isPlaying = isPlaying
        push()
    }

    /// Clears the system UI, e.g. when reading stops.
    func deactivate() {
        artworkTask?.cancel()
        artworkTask = nil
        elapsed = 0
        duration = 0
        isPlaying = false
        subtitle = ""
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    // MARK: - Internals

    private func push() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            // Audio, not music, so the system does not offer Apple Music
            // specific actions in contexts that read this field.
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            // The system advances the bar from the rate, so this does not have
            // to be rewritten several times a second. The rate stays 1.0
            // because the duration already reflects the chosen speed.
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]

        // The system Now Playing card renders exactly two lines of text: the
        // title and the artist/subtitle. Album is *not* drawn there — it only
        // surfaces in apps like Music that read it themselves — so putting the
        // sentence in `MPMediaItemPropertyAlbumTitle` publishes it to a field
        // nobody displays, and the Lock Screen shows the book and author with
        // no indication of what is being read.
        //
        // So the two rendered lines are spent on: what book, and what is being
        // read right now. The author moves to the album field, where it does
        // not cost one of the visible lines, and takes the second line back
        // when nothing is being read.
        let secondLine = subtitle.isEmpty ? track.artist : subtitle
        if !secondLine.isEmpty {
            info[MPMediaItemPropertyArtist] = secondLine
        }
        if !track.artist.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = track.artist
        }

        if let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    private func loadArtwork(_ urlString: String?) {
        artworkTask?.cancel()
        artwork = nil
        artworkSource = urlString

        guard let urlString, let url = URL(string: urlString) else { return }

        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data),
                  !Task.isCancelled else { return }
            // `MPMediaItemArtwork` asks for the image on an arbitrary queue, so
            // it has to cross that boundary in a box rather than capture the
            // UIImage directly under strict concurrency checking.
            let box = ImageBox(image)
            self?.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in box.image }
            self?.push()
        }
    }
}

/// Carries a `UIImage` across the artwork closure.
///
/// `UIImage` is immutable in practice — it is handed to the system and only
/// read — so the unchecked conformance is sound here.
private final class ImageBox: @unchecked Sendable {
    let image: UIImage

    init(_ image: UIImage) {
        self.image = image
    }
}
#endif
