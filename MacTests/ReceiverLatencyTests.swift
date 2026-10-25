import XCTest

final class ReceiverLatencyTests: XCTestCase {
    func testTCPWinningRaceStillConfirmsFirstUDPDelivery() {
        var window = CursorSequenceWindow()
        XCTAssertTrue(window.receive(1, udp: false).apply)
        XCTAssertTrue(window.receive(2, udp: false).apply)
        let lateUDP = window.receive(1, udp: true)
        XCTAssertTrue(lateUDP.acknowledge)
        XCTAssertFalse(lateUDP.apply) // no visible jump backwards
        XCTAssertFalse(window.receive(2, udp: true).acknowledge)
        XCTAssertTrue(window.receive(3, udp: true).apply)
    }

    func testRebuiltUDPFlowDoesNotRewindSharedPositionFloor() {
        var window = CursorSequenceWindow()
        _ = window.receive(100, udp: true)
        window.newUDPFlow()
        let stale = window.receive(90, udp: true)
        XCTAssertFalse(stale.apply)
        XCTAssertTrue(stale.acknowledge)
        XCTAssertTrue(window.receive(101, udp: true).apply)
        window = CursorSequenceWindow() // new TCP session
        XCTAssertTrue(window.receive(1, udp: true).apply)
    }

    func testUDPWinningRaceDoesNotApplyMirroredTCPAgain() {
        var window = CursorSequenceWindow()
        let udp = window.receive(1, udp: true)
        XCTAssertTrue(udp.apply)
        XCTAssertTrue(udp.acknowledge)
        XCTAssertFalse(window.receive(1, udp: false).apply)
        XCTAssertFalse(window.receive(0, udp: true).apply)
    }

    func testDecoderCongestionDropsWholeReferenceChainUntilReadyIDR() {
        var gate = VideoDecodeAdmission()
        XCTAssertFalse(gate.admit(isSync: false, ready: true, failed: false).accept)
        XCTAssertTrue(gate.admit(isSync: true, ready: true, failed: false).accept)
        XCTAssertTrue(gate.admit(isSync: false, ready: true, failed: false).accept)
        XCTAssertFalse(gate.admit(isSync: false, ready: false, failed: false).accept)
        XCTAssertFalse(gate.admit(isSync: false, ready: true, failed: false).accept)
        XCTAssertFalse(gate.admit(isSync: true, ready: false, failed: false).accept)
        let recovery = gate.admit(isSync: true, ready: true, failed: false)
        XCTAssertTrue(recovery.accept)
        XCTAssertTrue(recovery.flush)
        let next = gate.admit(isSync: false, ready: true, failed: false)
        XCTAssertTrue(next.accept)
        XCTAssertFalse(next.flush)
    }

    func testDecodeFailureRequiresSyncEvenWhenQueueHasRoom() {
        var gate = VideoDecodeAdmission()
        _ = gate.admit(isSync: true, ready: true, failed: false)
        XCTAssertFalse(gate.admit(isSync: false, ready: true, failed: true).accept)
        XCTAssertTrue(gate.admit(isSync: true, ready: true, failed: false).accept)
        gate.invalidate()
        XCTAssertFalse(gate.admit(isSync: false, ready: true, failed: false).accept)
    }
}
