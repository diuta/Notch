import AppKit
import Observation
import SwiftUI

@main
enum Notch {
    /// `NSApplication.delegate` is weak, so the app delegate lives here.
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NotchPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        Layout.selfCheck()
        #endif
        guard let screen = NSScreen.builtIn else { return }
        panel = NotchPanel(screen: screen)
        panel?.orderFrontRegardless()
    }
}

/// Whether the notch is currently showing its card.
@Observable
final class NotchState {
    var expanded = false
}

// MARK: - Geometry

enum Layout {
    static let card = CGSize(width: 340, height: 95)

    /// Extra height below the notch. The pointer can't sit inside the physical
    /// cutout, so the collapsed hover strip has to reach into visible screen to
    /// ever be entered.
    static let hoverBleed: CGFloat = 4

    /// Size of the physical notch, or a sane strip on displays that have none.
    static func notchSize(screenWidth: CGFloat, left: CGFloat?, right: CGFloat?, safeTop: CGFloat) -> CGSize {
        guard let left, let right, safeTop > 0 else { return CGSize(width: 200, height: 32) }
        return CGSize(width: screenWidth - left - right, height: safeTop)
    }

    /// The window is this size for the app's whole life and never resizes —
    /// resizing per hover is what made the animation snap. Wide enough to hold
    /// the card, and never narrower than the notch it has to listen over.
    static func windowSize(notch: CGSize) -> CGSize {
        CGSize(width: max(card.width, notch.width), height: card.height)
    }

    /// Flush with the top edge of the given screen, horizontally centred on it.
    static func topCentered(_ size: CGSize, in screen: CGRect) -> CGRect {
        CGRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height,
               width: size.width, height: size.height)
    }

    /// Hover strip while collapsed, in content-view coordinates.
    static func collapsedRect(in bounds: CGRect, notch: CGSize) -> CGRect {
        let height = notch.height + hoverBleed
        return CGRect(x: bounds.midX - notch.width / 2, y: bounds.maxY - height,
                      width: notch.width, height: height)
    }

    /// The card while expanded, in content-view coordinates.
    static func cardRect(in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.midX - card.width / 2, y: bounds.maxY - card.height,
               width: card.width, height: card.height)
    }

    static func notchSize(for screen: NSScreen) -> CGSize {
        notchSize(
            screenWidth: screen.frame.width,
            left: screen.auxiliaryTopLeftArea?.width,
            right: screen.auxiliaryTopRightArea?.width,
            safeTop: screen.safeAreaInsets.top
        )
    }
}

extension NSScreen {
    /// The notched built-in display, falling back to whichever screen is active.
    static var builtIn: NSScreen? {
        screens.first { $0.safeAreaInsets.top > 0 } ?? main
    }
}

// MARK: - Panel

final class NotchPanel: NSPanel {
    private let spotify = SpotifyController()
    private let state = NotchState()
    private let hover = HoverView()
    private let notch: CGSize

    init(screen: NSScreen) {
        notch = Layout.notchSize(for: screen)
        super.init(
            contentRect: Layout.topCentered(Layout.windowSize(notch: notch), in: screen.frame),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar  // above the menu bar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        hover.onHover = { [weak self] inside in self?.setExpanded(inside) }
        let content = NSHostingView(rootView: NotchView(spotify: spotify, state: state))
        content.frame = hover.bounds
        content.autoresizingMask = [.width, .height]
        hover.addSubview(content)
        contentView = hover
        hover.activeRect = Layout.collapsedRect(in: hover.bounds, notch: notch)
    }

    /// Key without activating, so the buttons take clicks but the frontmost app
    /// keeps focus.
    override var canBecomeKey: Bool { true }

    /// Flips state only. The window frame never changes, so the whole
    /// expand/collapse is a Core Animation job with nothing on the main thread
    /// to fight it.
    private func setExpanded(_ expanded: Bool) {
        guard state.expanded != expanded else { return }
        state.expanded = expanded
        hover.activeRect = expanded
            ? Layout.cardRect(in: hover.bounds)
            : Layout.collapsedRect(in: hover.bounds, notch: notch)
        if expanded { spotify.refresh() }
    }
}

/// Transparent lid over the notch. Reports pointer enter/exit for whichever
/// region is live, and is a hole everywhere else.
final class HoverView: NSView {
    var onHover: (Bool) -> Void = { _ in }

    /// The only region that takes clicks and reports hover.
    var activeRect: CGRect = .zero {
        didSet {
            guard activeRect != oldValue else { return }
            updateTrackingAreas()
        }
    }

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: activeRect, options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    /// Clicks outside the live region fall through to the menu bar. This is what
    /// lets the window stay one size: it used to shrink to free the menu bar up,
    /// and that resize is what destroyed the collapse animation.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard activeRect.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Card

struct NotchView: View {
    let spotify: SpotifyController
    let state: NotchState

    var body: some View {
        VStack(spacing: 0) {
            if state.expanded { card }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(duration: 0.34, bounce: 0.18), value: state.expanded)
    }

    private var card: some View {
        HStack(spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                Text(spotify.track.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(spotify.track.artist)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            controls
        }
        .padding(.horizontal, 14)
        .frame(width: Layout.card.width, height: Layout.card.height, alignment: .leading)
        .foregroundStyle(.white)
        .background(.black, in: UnevenRoundedRectangle(cornerRadii: .init(bottomLeading: 22, bottomTrailing: 22)))
        // Slides down out from behind the notch: the window clips whatever is
        // above its top edge, so "off the top" reads as "inside the notch".
        .transition(.move(edge: .top).combined(with: .opacity))
        .contextMenu { Button("Quit Notch") { NSApp.terminate(nil) } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spotify: \(spotify.track.title) by \(spotify.track.artist)")
    }

    private var artwork: some View {
        AsyncImage(url: spotify.track.artworkURL) { image in
            image.resizable()
        } placeholder: {
            Image(systemName: "music.note")
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(width: 54, height: 54)
        .background(.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }

    private var controls: some View {
        HStack(spacing: 14) {
            control("backward.fill", "Previous track", spotify.previous)
            control(spotify.track.isPlaying ? "pause.fill" : "play.fill",
                    spotify.track.isPlaying ? "Pause" : "Play",
                    spotify.playPause)
            control("forward.fill", "Next track", spotify.next)
        }
    }

    private func control(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .frame(width: 24, height: 24)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}

// MARK: - Check

#if DEBUG
extension Layout {
    /// Runs at launch in debug builds. Covers the only branching logic here:
    /// turning screen metrics into window frames.
    static func selfCheck() {
        // A display with no notch must fall back, not produce a full-width strip.
        assert(notchSize(screenWidth: 1920, left: nil, right: nil, safeTop: 0) == CGSize(width: 200, height: 32))
        // Aux areas present but no safe-area inset is still notch-less.
        assert(notchSize(screenWidth: 1920, left: 800, right: 800, safeTop: 0).height == 32)
        // Built-in display: the notch is what the menu bar halves don't cover.
        assert(notchSize(screenWidth: 1512, left: 656, right: 656, safeTop: 38) == CGSize(width: 200, height: 38))

        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let frame = topCentered(windowSize(notch: CGSize(width: 200, height: 38)), in: screen)
        assert(frame.maxY == screen.maxY, "window must sit flush with the top edge")
        assert(frame.midX == screen.midX, "window must be centred")

        // A screen left of the origin has a negative x; the frame must follow it
        // instead of assuming the screen starts at zero.
        let secondary = CGRect(x: -1512, y: 0, width: 1512, height: 982)
        assert(topCentered(card, in: secondary).midX == -756)

        // A notch wider than the card must widen the window, or the hover strip
        // gets clipped and the panel never opens.
        assert(windowSize(notch: CGSize(width: 400, height: 38)).width == 400)
        assert(windowSize(notch: CGSize(width: 200, height: 38)).width == card.width)

        // Both live regions hug the top edge and are centred, so the pointer
        // crosses from strip into card without ever leaving a tracked rect.
        let bounds = CGRect(origin: .zero, size: windowSize(notch: CGSize(width: 200, height: 38)))
        let strip = collapsedRect(in: bounds, notch: CGSize(width: 200, height: 38))
        assert(strip.maxY == bounds.maxY, "hover strip must reach the top edge")
        assert(strip.midX == bounds.midX)
        assert(strip.height == 38 + hoverBleed, "strip must bleed below the cutout to be hoverable")
        let open = cardRect(in: bounds)
        assert(open.maxY == bounds.maxY && open.midX == bounds.midX)
        assert(open.contains(strip), "expanded region must cover the strip it replaces")
    }
}
#endif
