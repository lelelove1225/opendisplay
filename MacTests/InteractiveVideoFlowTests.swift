import XCTest

final class InteractiveVideoFlowTests: XCTestCase {
    private func flow() -> InteractiveVideoFlow {
        var flow = InteractiveVideoFlow()
        flow.configure(enabled: true, ceiling: 6_000_000)
        return flow
    }

    func testRadioStallBoundsBacklogAndResumesWithLatestCapture() {
        var flow = flow()
        var latest = 0
        var sent: [(sequence: UInt64, capture: Int)] = []
        // 30 changed captures during a half-second outage; the socket may
        // accept everything immediately, but only receiver ACKs free slots.
        for frame in 0..<30 {
            latest = frame
            if let sequence = flow.sent(at: Double(frame) / 60) {
                sent.append((sequence, frame))
            }
            XCTAssertLessThanOrEqual(flow.inFlight, 2)
        }
        XCTAssertEqual(sent.map(\.capture), [0, 1])
        XCTAssertTrue(flow.blocked)
        XCTAssertTrue(flow.acknowledge(token: flow.token, sequence: 2, at: 0.5))
        // The cached final changed frame survives even when capture goes idle.
        XCTAssertNotNil(flow.sent(at: 0.501))
        XCTAssertEqual(latest, 29)
        XCTAssertFalse(flow.blocked)
        XCTAssertEqual(flow.bitrate, 1_500_000)
    }

    func testHealthyEightMillisecondLinkSustainsSixtyFPS() {
        var flow = flow()
        for frame in 0..<600 {
            let now = Double(frame) / 60
            let seq = flow.sent(at: now)
            XCTAssertNotNil(seq)
            XCTAssertTrue(flow.acknowledge(token: flow.token, sequence: seq!, at: now + 0.008))
        }
        XCTAssertEqual(flow.inFlight, 0)
        XCTAssertGreaterThan(flow.bitrate, 3_000_000)
        XCTAssertLessThanOrEqual(flow.bitrate, 6_000_000)
    }

    func testOldDuplicateAndFutureACKsCannotGrantCreditOrChangeRate() {
        var flow = flow()
        let oldToken = flow.token
        _ = flow.sent(at: 0)
        XCTAssertFalse(flow.acknowledge(token: oldToken, sequence: 20, at: 0.1))
        XCTAssertEqual(flow.inFlight, 1)
        XCTAssertTrue(flow.acknowledge(token: oldToken, sequence: 1, at: 0.01))
        XCTAssertFalse(flow.acknowledge(token: oldToken, sequence: 1, at: 1))
        flow = self.flow()
        _ = flow.sent(at: 1)
        XCTAssertFalse(flow.acknowledge(token: oldToken, sequence: 1, at: 1.01))
        XCTAssertEqual(flow.inFlight, 1)
        XCTAssertEqual(flow.bitrate, 3_000_000)
    }

    func testNoReceiptsReduceRateWithoutOpeningWindowAndEventuallyRedial() {
        var flow = flow()
        _ = flow.sent(at: 0)
        _ = flow.sent(at: 0.016)
        XCTAssertFalse(flow.tick(at: 0.09))
        XCTAssertEqual(flow.bitrate, 1_500_000)
        XCTAssertFalse(flow.tick(at: 0.1))
        XCTAssertEqual(flow.bitrate, 1_500_000) // cooldown, not halved per tick
        XCTAssertFalse(flow.tick(at: 0.6))
        XCTAssertEqual(flow.bitrate, 750_000)
        XCTAssertFalse(flow.tick(at: 1.9))
        XCTAssertTrue(flow.tick(at: 2.01))
        XCTAssertTrue(flow.blocked)
    }

    func testIdleTimeDoesNotRaiseBitrate() {
        var flow = flow()
        _ = flow.sent(at: 0)
        flow.acknowledge(token: flow.token, sequence: 1, at: 0.2)
        for second in 1...20 { XCTAssertFalse(flow.tick(at: Double(second))) }
        XCTAssertEqual(flow.bitrate, 1_500_000)
    }

    func testRepeatedHelloKeepsCreditsAndRotationKeepsSequence() {
        var flow = flow()
        let token = flow.token
        _ = flow.sent(at: 0)
        _ = flow.sent(at: 0.016)
        flow.configure(enabled: true, ceiling: 6_000_000)
        XCTAssertEqual(flow.token, token)
        XCTAssertTrue(flow.blocked)
        flow.configure(enabled: true, ceiling: 2_000_000)
        XCTAssertEqual(flow.bitrate, 2_000_000)
        XCTAssertTrue(flow.acknowledge(token: token, sequence: 2, at: 0.03))
        XCTAssertEqual(flow.sent(at: 0.04), 3)
    }

    func testLegacyAndCableDoNotRequireReceipts() {
        var flow = flow()
        _ = flow.sent(at: 0)
        _ = flow.sent(at: 0.016)
        flow.configure(enabled: false, ceiling: 6_000_000)
        XCTAssertFalse(flow.blocked)
        XCTAssertEqual(flow.inFlight, 0)
        XCTAssertEqual(flow.bitrate, 6_000_000)
        XCTAssertFalse(flow.tick(at: 100))
    }

    func testCumulativeACKRemovesOnlyDeliveredFrames() {
        var flow = flow()
        _ = flow.sent(at: 0)
        _ = flow.sent(at: 0.016)
        flow.acknowledge(token: flow.token, sequence: 1, at: 0.020)
        XCTAssertEqual(flow.inFlight, 1)
        XCTAssertEqual(flow.sent(at: 0.021), 3)
        XCTAssertTrue(flow.blocked)
        flow.acknowledge(token: flow.token, sequence: 2, at: 0.025)
        XCTAssertEqual(flow.inFlight, 1)
    }
}
