import Foundation

/// Receiver-driven admission for Fast/WiFi. NW's contentProcessed only means
/// the local stack consumed the buffer; it cannot bound the remote backlog.
/// Keep at most two frames on the wire. Captures rejected BEFORE encoding are
/// replaced by the latest pixel buffer, preserving the codec reference chain.
/// All times are sender monotonic seconds; no clock synchronization is needed.
struct InteractiveVideoFlow {
    static let version = 1
    static let frameLimit = 2
    private(set) var enabled = false
    private(set) var token = UUID().uuidString
    private(set) var bitrate = 0
    private(set) var lastRTT: Double = 0
    private(set) var nextSequence: UInt64 = 1
    private var outstanding: [(sequence: UInt64, sentAt: Double)] = []
    private var ceiling = 0
    private var lastReduction = -Double.infinity
    private var healthySince: Double?
    private var healthyACKs = 0

    var inFlight: Int { outstanding.count }
    var blocked: Bool { enabled && inFlight >= Self.frameLimit }
    private var floor: Int { min(750_000, ceiling) }

    mutating func configure(enabled: Bool, ceiling: Int) {
        let ceiling = max(1, ceiling)
        if self.enabled != enabled {
            self = Self()
            self.enabled = enabled
            self.ceiling = ceiling
            bitrate = enabled ? min(3_000_000, ceiling) : ceiling
        } else {
            self.ceiling = ceiling
            bitrate = enabled ? min(max(floor, bitrate), ceiling) : ceiling
        }
    }

    /// Reserve only when the encoded frame is handed to the socket. The
    /// single-encode limiter prevents another submission from stealing a slot.
    mutating func sent(at now: Double) -> UInt64? {
        guard enabled, !blocked else { return nil }
        let sequence = nextSequence
        nextSequence += 1
        outstanding.append((sequence, now))
        return sequence
    }

    /// TCP is ordered, so an ACK is cumulative. Duplicate, future and retired
    /// session ACKs must neither release credit nor change the bitrate.
    @discardableResult
    mutating func acknowledge(token: String, sequence: UInt64, at now: Double) -> Bool {
        guard enabled, token == self.token,
              let frame = outstanding.first(where: { $0.sequence == sequence }),
              now >= frame.sentAt else { return false }
        lastRTT = now - frame.sentAt
        outstanding.removeAll { $0.sequence <= sequence }
        if lastRTT > 0.050 {
            reduce(at: now)
        } else if lastRTT < 0.025 {
            // Slow recovery, only during sustained healthy traffic. Silence is
            // not evidence that the link has recovered.
            if healthySince == nil { healthySince = now }
            healthyACKs += 1
            if now - healthySince! >= 2, healthyACKs >= 30 {
                bitrate = min(ceiling, bitrate + max(100_000, bitrate / 10))
                healthySince = now
                healthyACKs = 0
            }
        } else {
            healthySince = nil
            healthyACKs = 0
        }
        return true
    }

    /// With no receipts we stop sending, rather than queue more video. Reduce
    /// early, and redial a peer that advertises ACKs but never supplies them.
    /// A normal sub-second radio stall never tears down the display/session.
    mutating func tick(at now: Double) -> Bool {
        guard enabled, let oldest = outstanding.first else { return false }
        if now - oldest.sentAt > 0.080 { reduce(at: now) }
        return now - oldest.sentAt > 2
    }

    mutating func abandon(at now: Double) {
        outstanding.removeAll()
        reduce(at: now)
    }

    private mutating func reduce(at now: Double) {
        healthySince = nil
        healthyACKs = 0
        guard now - lastReduction >= 0.5 else { return }
        lastReduction = now
        bitrate = max(floor, bitrate / 2)
    }
}
