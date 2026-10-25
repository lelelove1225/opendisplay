import XCTest

final class ReceiverViewportTests: XCTestCase {
    private func viewport(_ width: Double, _ height: Double, scale: Double = 3) throws -> ReceiverViewport {
        try XCTUnwrap(ReceiverViewport(points: CGSize(width: width, height: height),
                                      scale: scale, maximumFramesPerSecond: 120))
    }

    func testOpeningWithoutRotationChangesBothAxes() throws {
        let outer = try viewport(466, 678)
        let inner = try viewport(650, 900)
        XCTAssertEqual(outer.pixelsWide, 1398)
        XCTAssertEqual(outer.pixelsHigh, 2034)
        XCTAssertEqual(inner.pixelsWide, 1950)
        XCTAssertEqual(inner.pixelsHigh, 2700)
        XCTAssertNotEqual(inner, outer)
    }

    func testRotationUsesTheActualWindowAxes() throws {
        let portrait = try viewport(650, 900)
        let landscape = try viewport(900, 650)
        XCTAssertEqual(landscape.pixelsWide, portrait.pixelsHigh)
        XCTAssertEqual(landscape.pixelsHigh, portrait.pixelsWide)
    }

    func testSplitViewUsesWindowRatherThanFullPanel() throws {
        let split = try viewport(420, 650, scale: 2)
        XCTAssertEqual(split.pixelsWide, 840)
        XCTAssertEqual(split.pixelsHigh, 1300)
        XCTAssertEqual(split.scale, 2)
    }

    func testSubpixelLayoutNoiseDoesNotReannounceIdenticalPixels() throws {
        XCTAssertEqual(try viewport(650, 900), try viewport(650.00000001, 900.00000001))
    }

    func testInvalidTransitionSizesAreIgnored() {
        for (size, scale) in [(CGSize.zero, 3.0),
                              (CGSize(width: -1, height: 900), 3.0),
                              (CGSize(width: 650, height: 900), Double.nan),
                              (CGSize(width: 650, height: 900), 0.0),
                              (CGSize(width: CGFloat.infinity, height: 900), 3.0),
                              (CGSize(width: 100_000, height: 900), 3.0)] {
            XCTAssertNil(ReceiverViewport(points: size, scale: scale, maximumFramesPerSecond: 120))
        }
    }

    func testUnfoldedWindowFitsDesktopAndFullResolutionStream() throws {
        let inner = try viewport(900, 650)
        let facts = PanelFacts(pixelsWide: inner.pixelsWide, pixelsHigh: inner.pixelsHigh,
                               scale: inner.scale, pointsWide: nil, pointsHigh: nil)
        let plan = DesktopPolicy.plan(facts: facts)
        let config = try VideoStreamConfiguration.make(source: plan.desktopPixels,
            quality: .best, codec: "hevc",
            receiverCapabilities: [VideoCapability(codec: "hevc", maxWidth: 2700,
                maxHeight: 2700, maxFrameRate: 60)],
            displayMaxFrameRate: inner.maximumFramesPerSecond, presentable: plan.presentable)
        XCTAssertEqual(config.framesPerSecond, 60)
        XCTAssertLessThanOrEqual(config.encodedSize.width, inner.pixelsWide)
        XCTAssertLessThanOrEqual(config.encodedSize.height, inner.pixelsHigh)
        XCTAssertGreaterThan(config.encodedSize.width, 2600)
    }
}
