import CoreGraphics
import XCTest

final class CaptureSourceCheckTests: XCTestCase {
    private let iMac = CGRect(x: -198, y: -1_152, width: 2_048, height: 1_152)
    private let pixel = CGRect(x: -1_080, y: 0, width: 1_080, height: 2_424)
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    func testOwnDisplayNeverTrips() {
        var check = CaptureSourceCheck()
        for second in 0..<10 {
            XCTAssertFalse(check.frame(screenRect: iMac, expected: iMac, now: t0 + Double(second)))
        }
    }

    /// Observed on an iPhone's 562x1000-point virtual display: SCK reported
    /// 1000.0000000000001 for the height and triggered three capture restarts.
    func testFractionalHeightFromScreenCaptureKitNeverTrips() {
        var check = CaptureSourceCheck()
        let expected = CGRect(x: -562, y: 0, width: 562, height: 1000)
        let captured = CGRect(x: -562, y: 0, width: 562, height: 1000.0000000000001)

        for second in 0..<10 {
            XCTAssertFalse(check.frame(screenRect: captured, expected: expected,
                                       now: t0 + Double(second)))
        }
    }

    func testRoundingNoiseOnEveryComponentNeverTrips() {
        let expected = CGRect(x: -562, y: -1000, width: 562, height: 1000)
        for component in 0..<4 {
            for error: CGFloat in [-0.0001, 0.0001] {
                var values: [CGFloat] = [-562, -1000, 562, 1000]
                values[component] += error
                let captured = CGRect(x: values[0], y: values[1],
                                      width: values[2], height: values[3])
                var check = CaptureSourceCheck()
                XCTAssertFalse(check.frame(screenRect: captured, expected: expected, now: t0))
                XCTAssertFalse(check.frame(screenRect: captured, expected: expected, now: t0 + 2))
            }
        }
    }

    func testRoundingEquivalentFrameClearsPendingMismatch() {
        var check = CaptureSourceCheck()
        let expected = CGRect(x: -562, y: 0, width: 562, height: 1000)
        let rounded = CGRect(x: -562, y: 0, width: 562, height: 1000.0000000000001)

        XCTAssertFalse(check.frame(screenRect: pixel, expected: expected, now: t0))
        XCTAssertFalse(check.frame(screenRect: rounded, expected: expected, now: t0 + 1))
        XCTAssertFalse(check.frame(screenRect: pixel, expected: expected, now: t0 + 2))
        XCTAssertTrue(check.frame(screenRect: pixel, expected: expected, now: t0 + 4))
    }

    /// Keep the wrong-display guard sensitive to real subpoint geometry
    /// differences; rounding whole coordinates would hide these.
    func testRealGeometryChangesStillTripOnEveryComponent() {
        let expected = CGRect(x: -562, y: -1000, width: 562, height: 1000)
        for component in 0..<4 {
            for change: CGFloat in [-0.25, 0.25] {
                var values: [CGFloat] = [-562, -1000, 562, 1000]
                values[component] += change
                let captured = CGRect(x: values[0], y: values[1],
                                      width: values[2], height: values[3])
                var check = CaptureSourceCheck()
                XCTAssertFalse(check.frame(screenRect: captured, expected: expected, now: t0))
                XCTAssertTrue(check.frame(screenRect: captured, expected: expected, now: t0 + 2))
            }
        }
    }

    /// #391: after sleep the iMac's stream kept delivering the Pixel's display.
    func testSustainedOtherDisplayTripsOnce() {
        var check = CaptureSourceCheck()

        XCTAssertFalse(check.frame(screenRect: pixel, expected: iMac, now: t0))
        XCTAssertFalse(check.frame(screenRect: pixel, expected: iMac, now: t0 + 1))
        XCTAssertTrue(check.frame(screenRect: pixel, expected: iMac, now: t0 + 2))
        // Re-armed: the next trip needs another sustained stretch.
        XCTAssertFalse(check.frame(screenRect: pixel, expected: iMac, now: t0 + 2.1))
    }

    func testResizeTransientDoesNotTrip() {
        var check = CaptureSourceCheck()
        let resized = CGRect(x: -198, y: -900, width: 1_600, height: 900)

        // Frames still carry the old size for a moment after a mode change.
        XCTAssertFalse(check.frame(screenRect: iMac, expected: resized, now: t0))
        XCTAssertFalse(check.frame(screenRect: iMac, expected: resized, now: t0 + 0.5))
        XCTAssertFalse(check.frame(screenRect: resized, expected: resized, now: t0 + 0.6))
        XCTAssertFalse(check.frame(screenRect: iMac, expected: resized, now: t0 + 2))
    }

    func testEmptyRectsAreIgnored() {
        var check = CaptureSourceCheck()

        XCTAssertFalse(check.frame(screenRect: .zero, expected: iMac, now: t0))
        XCTAssertFalse(check.frame(screenRect: .zero, expected: iMac, now: t0 + 5))
    }
}
