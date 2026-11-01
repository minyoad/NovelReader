import Foundation

/// Decides whether a horizontal drag in the reader means "leave the book".
///
/// The reader already turns pages with horizontal drags, so the back gesture
/// has to be narrow enough that it never eats a page turn. The rule the system
/// itself uses is a good one: start at the left edge, travel clearly
/// rightwards, and do not travel far vertically.
///
/// Kept out of the view because this is the part that is easy to get wrong —
/// a back gesture that also turns a page, or one that fires on a diagonal
/// scroll — and it can be tested without a device.
public enum ReaderSwipe {
    /// How far in from the left edge a drag has to begin.
    public static let edgeWidth: CGFloat = 28
    /// Horizontal travel that counts as a deliberate swipe rather than a nudge.
    public static let dismissDistance: CGFloat = 64
    /// Vertical travel past which the drag reads as a scroll.
    public static let maximumDrift: CGFloat = 90
    /// Smallest drag the gesture recognises at all.
    public static let minimumDistance: CGFloat = 24

    /// Whether a drag is the back gesture.
    ///
    /// - Parameters:
    ///   - startX: Horizontal position where the finger went down, in the
    ///     reader's own coordinate space.
    ///   - translation: Total travel of the drag; positive x is rightwards.
    ///   - barsVisible: Whether the tap-to-reveal controls are on screen. The
    ///     gesture only exists while they are: full-screen reading uses edge
    ///     drags for page turns, and stealing those would make the first page
    ///     of a chapter impossible to swipe away from.
    public static func isBackSwipe(
        startX: CGFloat,
        translation: CGSize,
        barsVisible: Bool
    ) -> Bool {
        guard barsVisible else { return false }
        guard startX <= edgeWidth else { return false }
        guard translation.width > dismissDistance else { return false }
        guard abs(translation.width) > abs(translation.height) else { return false }
        return abs(translation.height) < maximumDrift
    }

    /// Whether a drag that starts at `startX` should be left alone by the
    /// page-turn gesture, so the two never act on the same finger movement.
    ///
    /// Mirrors the origin test in `isBackSwipe` rather than the whole thing:
    /// the page turn has to stay out of the way as soon as the drag starts,
    /// which is before its final direction is known.
    public static func claimsEdge(startX: CGFloat, barsVisible: Bool) -> Bool {
        barsVisible && startX <= edgeWidth
    }
}
