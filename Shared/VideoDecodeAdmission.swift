import Foundation

/// Bound decoder backlog without feeding dependent P-frames after a dropped
/// reference. Hold the last image, then resume at an independently decodable
/// frame. The caller rate-limits keyframe requests while waiting.
struct VideoDecodeAdmission {
    private(set) var needsSync = true

    mutating func invalidate() { needsSync = true }

    mutating func admit(isSync: Bool, ready: Bool, failed: Bool) -> (accept: Bool, flush: Bool) {
        if failed || !ready { needsSync = true }
        guard ready, !needsSync || isSync else { return (false, false) }
        let flush = needsSync
        needsSync = false
        return (true, flush)
    }
}
