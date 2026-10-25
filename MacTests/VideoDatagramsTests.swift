import XCTest

final class VideoDatagramsTests: XCTestCase {
    private let token = "A5E10574-8568-4984-8F26-08B48B4D1C22"
    private func packets(_ seq: UInt64, sync: Bool = false, size: Int = 4000) -> [Data] {
        VideoDatagrams.split(Data(repeating: UInt8(truncatingIfNeeded: seq), count: size),
                             token: token, sequence: seq, sync: sync)!
    }

    func testFragmentReorderingAndDuplicatesReassembleExactlyOnce() {
        var receiver = DeadlineVideoAssembler(token: token)
        let fragments = packets(1, sync: true)
        var output: [DeadlineVideoAssembler.Frame] = []
        for packet in fragments.reversed() {
            output += receiver.receive(packet, at: 0)
            output += receiver.receive(packet, at: 0.001)
        }
        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output.first?.data, Data(repeating: 1, count: 4000))
        XCTAssertEqual(receiver.expected, 2)
        XCTAssertEqual(receiver.bufferedFrames, 0)
    }

    func testLossRetransmitsOnlyMissingFragmentBeforeDeadline() {
        var sender = DeadlineVideoSendWindow()
        var receiver = DeadlineVideoAssembler(token: token)
        let fragments = packets(1, sync: true)
        XCTAssertTrue(sender.insert(fragments, sequence: 1, at: 0))
        let sent = sender.take(maximum: 10)
        for (index, packet) in sent.enumerated() where index != 1 {
            XCTAssertTrue(receiver.receive(packet, at: 0.002).isEmpty)
        }
        let feedback = receiver.poll(at: 0.020)
        XCTAssertEqual(feedback.missing.count, 1)
        XCTAssertEqual(feedback.missing.first?.indices, [1])
        sender.request(sequence: 1, missing: feedback.missing[0].indices)
        let retry = sender.take(maximum: 3)
        XCTAssertEqual(retry.count, 1)
        let ready = receiver.receive(retry[0], at: 0.025)
        XCTAssertEqual(ready.first?.sequence, 1)
        sender.acknowledge(1)
        XCTAssertEqual(sender.count, 0)
    }

    func testMissingReferenceCannotReleaseNewerPFrame() {
        var receiver = DeadlineVideoAssembler(token: token)
        for p in packets(1, sync: true) { _ = receiver.receive(p, at: 0) }
        // Entire frame 2 disappeared. Frame 3 is complete but cannot decode.
        for p in packets(3) { XCTAssertTrue(receiver.receive(p, at: 0.010).isEmpty) }
        XCTAssertTrue(receiver.poll(at: 0.100).recover)
        XCTAssertTrue(receiver.needsSync)
        for p in packets(4) { XCTAssertTrue(receiver.receive(p, at: 0.110).isEmpty) }
        var recovered: [DeadlineVideoAssembler.Frame] = []
        for p in packets(5, sync: true) { recovered += receiver.receive(p, at: 0.120) }
        XCTAssertEqual(recovered.map(\.sequence), [5])
        for p in packets(2) { XCTAssertTrue(receiver.receive(p, at: 0.130).isEmpty) }
    }

    func testFrameReorderingPreservesDecodeOrder() {
        var receiver = DeadlineVideoAssembler(token: token)
        for p in packets(1, sync: true) { _ = receiver.receive(p, at: 0) }
        for p in packets(3) { XCTAssertTrue(receiver.receive(p, at: 0.005).isEmpty) }
        var ready: [DeadlineVideoAssembler.Frame] = []
        for p in packets(2) { ready += receiver.receive(p, at: 0.010) }
        XCTAssertEqual(ready.map(\.sequence), [2, 3])
    }

    func testNewKeyframeSkipsIncompleteOlderGOPWithoutWaiting() {
        var receiver = DeadlineVideoAssembler(token: token)
        _ = receiver.receive(packets(1, sync: true)[0], at: 0)
        var ready: [DeadlineVideoAssembler.Frame] = []
        for p in packets(4, sync: true) { ready += receiver.receive(p, at: 0.020) }
        XCTAssertEqual(ready.map(\.sequence), [4])
        XCTAssertEqual(receiver.bufferedFrames, 0)
        for p in packets(1, sync: true) { XCTAssertTrue(receiver.receive(p, at: 0.03).isEmpty) }
    }

    func testDeadlineAbandonsAllDependentSendsAndBoundsMemory() {
        var sender = DeadlineVideoSendWindow()
        XCTAssertTrue(sender.insert(packets(1), sequence: 1, at: 0))
        XCTAssertTrue(sender.insert(packets(2), sequence: 2, at: 0.016))
        XCTAssertFalse(sender.insert(packets(3), sequence: 3, at: 0.032))
        XCTAssertEqual(sender.take(maximum: 3).count, 3)
        XCTAssertFalse(sender.expire(at: 0.079))
        XCTAssertTrue(sender.expire(at: 0.081))
        XCTAssertEqual(sender.count, 0)
        XCTAssertTrue(sender.take(maximum: 3).isEmpty)
    }

    func testRecoveryKeyframeHasLongerBudgetAndNoDependentFramesQueueBehindIt() {
        var sender = DeadlineVideoSendWindow()
        XCTAssertTrue(sender.insert(packets(1, sync: true), sequence: 1, at: 0))
        XCTAssertTrue(sender.blocked)
        XCTAssertFalse(sender.insert(packets(2), sequence: 2, at: 0.016))
        XCTAssertFalse(sender.expire(at: 0.100))
        XCTAssertFalse(sender.expire(at: 0.249))
        XCTAssertTrue(sender.expire(at: 0.251))
        XCTAssertFalse(sender.blocked)
    }

    func testMalformedForeignAndOversizedPacketsAreRejected() {
        let good = packets(1, sync: true)[0]
        XCTAssertNil(VideoDatagrams.Packet(data: good, token: UUID().uuidString))
        XCTAssertNil(VideoDatagrams.Packet(data: Data(good.prefix(59)), token: token))
        for index in [0, 48, 54, 57] {
            var bad = good
            bad[index] = 255
            XCTAssertNil(VideoDatagrams.Packet(data: bad, token: token), "offset \(index)")
        }
        var short = good; short.removeLast()
        XCTAssertNil(VideoDatagrams.Packet(data: short, token: token))
        XCTAssertNil(VideoDatagrams.split(Data(count: VideoDatagrams.maxFrameSize + 1),
                                         token: token, sequence: 1, sync: true))
    }

    func testRetransmissionRequestsAreBoundedAndCannotSendArbitraryIndices() {
        var sender = DeadlineVideoSendWindow()
        _ = sender.insert(packets(1, sync: true), sequence: 1, at: 0)
        let original = sender.take(maximum: 100)
        for _ in 0..<100 { sender.request(sequence: 1, missing: [-1, 0, 1, 2, 3, Int.max]) }
        XCTAssertLessThanOrEqual(sender.take(maximum: 100).count, original.count)
        sender.request(sequence: 1, missing: [0, 1, 2, 3])
        XCTAssertTrue(sender.take(maximum: 100).isEmpty)
    }

    func testNoRecoveryTrafficBeforeFirstVideoPacket() {
        var receiver = DeadlineVideoAssembler(token: token)
        XCTAssertFalse(receiver.poll(at: 100).recover)
        _ = receiver.receive(packets(2)[0], at: 101)
        XCTAssertTrue(receiver.poll(at: 101.01).recover)
        XCTAssertFalse(receiver.poll(at: 101.02).recover)
    }
}
