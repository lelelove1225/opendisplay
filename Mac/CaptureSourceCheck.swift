import CoreGraphics
import Foundation

/// Watches that a running capture still delivers its own display (#391).
///
/// After a sleep with two receivers, a stream started on one virtual display
/// kept running but delivered the other display's picture, aspect-fit into
/// its own output size. Nothing on our side errors when that happens, so the
/// only witness is SCK's per-frame `screenRect`: the global desktop rect the
/// frame was captured from. Brief disagreement is normal while a display is
/// resized or dragged (the frame and `CGDisplayBounds` update a moment
/// apart); only a mismatch that outlasts `tolerance` counts.
struct CaptureSourceCheck {
    static let tolerance: TimeInterval = 1.5
    // SCK derives screenRect through scaling and can report e.g.
    // 1000.0000000000001 where CGDisplayBounds reports 1000. Compare in
    // desktop points with an absolute, far-subpixel tolerance: exact CGRect
    // equality turns harmless rounding into repeated capture restarts.
    private static let geometryTolerance: CGFloat = 0.001

    private var mismatchSince: Date?

    /// Feed one complete frame. Returns true once, when the stream has been
    /// delivering some other rect for longer than `tolerance`; the caller
    /// then re-attaches capture and should start a fresh check.
    mutating func frame(screenRect: CGRect, expected: CGRect, now: Date = Date()) -> Bool {
        guard !screenRect.isEmpty, !expected.isEmpty,
              !Self.sameGeometry(screenRect, expected) else {
            mismatchSince = nil
            return false
        }
        guard let since = mismatchSince else {
            mismatchSince = now
            return false
        }
        guard now.timeIntervalSince(since) >= Self.tolerance else { return false }
        mismatchSince = nil
        return true
    }

    private static func sameGeometry(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= geometryTolerance
            && abs(lhs.origin.y - rhs.origin.y) <= geometryTolerance
            && abs(lhs.width - rhs.width) <= geometryTolerance
            && abs(lhs.height - rhs.height) <= geometryTolerance
    }
}
