import Foundation

/// Optional, deadline-limited video on the already confirmed cursor UDP flow.
/// Small datagrams avoid IP fragmentation. No packet can allocate unbounded
/// memory; session tokens, lengths and fragment counts are checked first.
enum VideoDatagrams {
    static let version = 1
    static let headerSize = 60
    static let payloadSize = 1140
    static let maxFrameSize = 1_048_576
    static let deadline = 0.080
    static let syncDeadline = 0.250
    static let magic: [UInt8] = [0x4f, 0x44, 0x56, 0x31] // ODV1

    struct Packet {
        let token: String
        let sequence: UInt64
        let total: Int
        let index: Int
        let count: Int
        let sync: Bool
        let body: Data

        var data: Data {
            var data = Data(magic)
            data.append(contentsOf: token.utf8) // canonical UUID, exactly 36 bytes
            for shift in stride(from: 56, through: 0, by: -8) {
                data.append(UInt8(truncatingIfNeeded: sequence >> shift))
            }
            for shift in stride(from: 24, through: 0, by: -8) {
                data.append(UInt8(truncatingIfNeeded: total >> shift))
            }
            for value in [index, count] {
                data.append(UInt8(truncatingIfNeeded: value >> 8))
                data.append(UInt8(truncatingIfNeeded: value))
            }
            data.append(sync ? 1 : 0)
            data.append(contentsOf: [0, 0, 0])
            data.append(body)
            return data
        }

        init?(data: Data, token: String) {
            guard data.count > headerSize, data.count <= headerSize + payloadSize else { return nil }
            let b = [UInt8](data)
            guard Array(b[0..<4]) == magic,
                  String(bytes: b[4..<40], encoding: .utf8) == token,
                  b[56] <= 1, b[57...59].allSatisfy({ $0 == 0 }) else { return nil }
            var seq: UInt64 = 0
            for byte in b[40..<48] { seq = (seq << 8) | UInt64(byte) }
            var size = 0
            for byte in b[48..<52] { size = (size << 8) | Int(byte) }
            let index = Int(b[52]) << 8 | Int(b[53])
            let count = Int(b[54]) << 8 | Int(b[55])
            guard seq > 0, size > 0, size <= maxFrameSize,
                  count == (size + payloadSize - 1) / payloadSize,
                  index < count,
                  b.count - headerSize == min(payloadSize, size - index * payloadSize) else { return nil }
            self.token = token
            sequence = seq
            total = size
            self.index = index
            self.count = count
            sync = b[56] == 1
            body = Data(b[headerSize...])
        }

        init(token: String, sequence: UInt64, total: Int, index: Int, count: Int, sync: Bool, body: Data) {
            self.token = token; self.sequence = sequence; self.total = total
            self.index = index; self.count = count; self.sync = sync; self.body = body
        }
    }

    static func split(_ frame: Data, token: String, sequence: UInt64, sync: Bool) -> [Data]? {
        guard UUID(uuidString: token) != nil, token.utf8.count == 36, sequence > 0,
              !frame.isEmpty, frame.count <= maxFrameSize else { return nil }
        let count = (frame.count + payloadSize - 1) / payloadSize
        return (0..<count).map { index in
            let start = index * payloadSize
            return Packet(token: token, sequence: sequence, total: frame.count,
                          index: index, count: count, sync: sync,
                          body: frame.subdata(in: start..<min(frame.count, start + payloadSize))).data
        }
    }
}

/// Sender queue only. Pace packets in small batches rather than bursting a
/// large keyframe into the access point. Retries share that same paced queue.
struct DeadlineVideoSendWindow {
    private struct Frame {
        let packets: [Data]
        let sentAt: Double
        let sync: Bool
        var next = 0
        var retries: Set<Int> = []
        var retryBudget: Int
    }
    private var frames: [UInt64: Frame] = [:]
    var count: Int { frames.count }
    var blocked: Bool { count >= 2 || frames.values.contains(where: { $0.sync }) }

    mutating func insert(_ packets: [Data], sequence: UInt64, at now: Double) -> Bool {
        guard !blocked, frames[sequence] == nil, !packets.isEmpty else { return false }
        frames[sequence] = Frame(packets: packets, sentAt: now, sync: packets[0].count > 56 && packets[0][56] == 1,
                                 retryBudget: packets.count)
        return true
    }

    mutating func acknowledge(_ sequence: UInt64) {
        frames = frames.filter { $0.key > sequence }
    }

    mutating func request(sequence: UInt64, missing: [Int]) {
        guard var frame = frames[sequence] else { return }
        for index in missing.prefix(64) where index >= 0 && index < frame.next {
            if frame.retryBudget > 0, frame.retries.insert(index).inserted {
                frame.retryBudget -= 1
            }
        }
        frames[sequence] = frame
    }

    /// Any expired reference invalidates the whole pending chain. The caller
    /// abandons its credits and forces a NEW keyframe from the latest pixels.
    mutating func expire(at now: Double) -> Bool {
        guard frames.values.contains(where: { now - $0.sentAt >= ($0.sync ? VideoDatagrams.syncDeadline : VideoDatagrams.deadline) }) else { return false }
        frames.removeAll()
        return true
    }

    mutating func take(maximum: Int) -> [Data] {
        var result: [Data] = []
        for sequence in frames.keys.sorted() {
            guard var frame = frames[sequence] else { continue }
            while result.count < maximum {
                if let retry = frame.retries.min() {
                    frame.retries.remove(retry)
                    result.append(frame.packets[retry])
                } else if frame.next < frame.packets.count {
                    result.append(frame.packets[frame.next])
                    frame.next += 1
                } else { break }
            }
            frames[sequence] = frame
            if result.count >= maximum { break }
        }
        return result
    }
}

/// Receiver queue only. Reorder fragments and frames within a bounded time
/// window. After loss, never deliver dependent pictures until a sync frame.
struct DeadlineVideoAssembler {
    struct Frame {
        let sequence: UInt64
        let sync: Bool
        let data: Data
    }
    struct Feedback {
        var missing: [(sequence: UInt64, indices: [Int])] = []
        var recover = false
    }
    private struct Partial {
        let firstAt: Double
        let total: Int
        let sync: Bool
        var parts: [Data?]
        var received = 0
        var lastNACK: Double
    }
    let token: String
    private var frames: [UInt64: Partial] = [:]
    private(set) var expected: UInt64 = 1
    private(set) var needsSync = true
    private var lastRecovery = -Double.infinity
    private var observedPackets = false
    var bufferedFrames: Int { frames.count }

    mutating func receive(_ data: Data, at now: Double) -> [Frame] {
        guard let packet = VideoDatagrams.Packet(data: data, token: token),
              packet.sequence >= expected else { return [] }
        observedPackets = true
        if needsSync && !packet.sync { return [] }
        if frames[packet.sequence] == nil {
            if frames.count >= 3 {
                // A newer keyframe may supersede all of an abandoned GOP.
                guard packet.sync else { return [] }
                frames.removeAll()
                needsSync = true
            }
            frames[packet.sequence] = Partial(firstAt: now, total: packet.total, sync: packet.sync,
                parts: Array(repeating: nil, count: packet.count), lastNACK: now)
        }
        guard var frame = frames[packet.sequence], frame.total == packet.total,
              frame.sync == packet.sync, frame.parts.count == packet.count else { return [] }
        if frame.parts[packet.index] == nil {
            frame.parts[packet.index] = packet.body
            frame.received += 1
            frames[packet.sequence] = frame
        }
        // Complete sync pictures supersede missing references immediately.
        if packet.sync, frame.received == frame.parts.count {
            frames = frames.filter { $0.key >= packet.sequence }
            expected = packet.sequence
            needsSync = false
        }
        var ready: [Frame] = []
        while !needsSync, let next = frames[expected], next.received == next.parts.count {
            var body = Data(capacity: next.total)
            next.parts.forEach { body.append($0!) }
            ready.append(Frame(sequence: expected, sync: next.sync, data: body))
            frames.removeValue(forKey: expected)
            expected += 1
        }
        return ready
    }

    mutating func poll(at now: Double) -> Feedback {
        var feedback = Feedback()
        if frames.values.contains(where: { now - $0.firstAt >= ($0.sync ? VideoDatagrams.syncDeadline : VideoDatagrams.deadline) }) {
            if let newest = frames.keys.max() { expected = max(expected, newest + 1) }
            frames.removeAll()
            needsSync = true
        }
        if observedPackets, needsSync, frames.isEmpty, now - lastRecovery >= 0.1 {
            lastRecovery = now
            feedback.recover = true
        }
        for seq in frames.keys.sorted() {
            guard var frame = frames[seq], frame.received < frame.parts.count,
                  now - frame.firstAt >= 0.008, now - frame.lastNACK >= 0.012 else { continue }
            frame.lastNACK = now
            feedback.missing.append((seq, Array(frame.parts.indices.filter { frame.parts[$0] == nil }.prefix(64))))
            frames[seq] = frame
        }
        return feedback
    }
}
