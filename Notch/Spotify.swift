import AppKit
import Foundation
import Observation

/// A snapshot of what Spotify is playing right now.
struct Track: Equatable {
    var title: String
    var artist: String
    var artworkURL: URL?
    var isPlaying: Bool

    static let idle = Track(title: "Spotify", artist: "Nothing playing", artworkURL: nil, isPlaying: false)
}

/// Reads and controls Spotify over Apple events.
///
/// Spotify's scripting dictionary hands back a real AppleScript list, so fields
/// come out of the descriptor by index rather than by splitting a delimited
/// string — there's no separator to collide with song titles full of punctuation.
@Observable
final class SpotifyController {
    private(set) var track = Track.idle

    /// Buttons only ever pass one of these, so no caller-supplied text reaches
    /// the script source.
    private enum Command: String {
        case playPause = "playpause"
        case next = "next track"
        case previous = "previous track"
    }

    /// Every Apple event runs here, never on the main thread: a round-trip to
    /// Spotify is tens to hundreds of milliseconds, and on hover that lands
    /// exactly on the frames the animation needs.
    ///
    /// ponytail: NSAppleScript isn't thread-safe, so confinement to this one
    /// serial queue is what makes it safe — don't touch `reader` from anywhere
    /// else.
    @ObservationIgnored private let queue = DispatchQueue(label: "notch.spotify")

    @ObservationIgnored private let reader = NSAppleScript(source: """
        try
            if application id "com.spotify.client" is running then
                tell application id "com.spotify.client"
                    return {name of current track, artist of current track, artwork url of current track, player state as text}
                end tell
            end if
        end try
        return {}
        """)

    init() {
        // Spotify broadcasts this on every play, pause, and skip — no polling timer.
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.refresh() }
        refresh()
    }

    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            let fresh = self.read() ?? .idle
            DispatchQueue.main.async { self.apply(fresh) }
        }
    }

    /// Publish real changes only. A redundant assignment mid-animation makes
    /// SwiftUI re-render for nothing, which is visible as a stutter.
    private func apply(_ fresh: Track) {
        if track != fresh { track = fresh }
    }

    /// Flips the icon before the Apple event round-trips so the button feels
    /// instant; the follow-up `refresh()` corrects it if Spotify disagrees.
    func playPause() {
        track.isPlaying.toggle()
        run(.playPause)
    }

    func next() { run(.next) }
    func previous() { run(.previous) }

    /// Called on `queue` only.
    private func read() -> Track? {
        var error: NSDictionary?
        guard let result = reader?.executeAndReturnError(&error), error == nil,
              result.numberOfItems >= 4 else { return nil }
        let field = { (index: Int) in result.atIndex(index)?.stringValue ?? "" }
        return Track(
            title: field(1),
            artist: field(2),
            artworkURL: URL(string: field(3)),
            isPlaying: field(4) == "playing"
        )
    }

    private func run(_ command: Command) {
        queue.async { [weak self] in
            var error: NSDictionary?
            NSAppleScript(source: "tell application id \"com.spotify.client\" to \(command.rawValue)")?
                .executeAndReturnError(&error)
            // Spotify settles on the new track slightly after acknowledging the
            // command, so read back rather than trusting the optimistic flip.
            self?.queue.asyncAfter(deadline: .now() + 0.15) { self?.refresh() }
        }
    }
}
