import Foundation

/// TCP may beat its mirrored UDP packet. Confirm UDP delivery independently
/// of whether that position is still new enough to draw.
struct CursorSequenceWindow {
    private(set) var sequence: UInt64 = 0
    private(set) var udpConfirmed = false

    mutating func newUDPFlow() { udpConfirmed = false }

    mutating func receive(_ next: UInt64, udp: Bool) -> (apply: Bool, acknowledge: Bool) {
        guard next > 0 else { return (false, false) }
        let acknowledge = udp && !udpConfirmed
        if udp { udpConfirmed = true }
        guard next > sequence else { return (false, acknowledge) }
        sequence = next
        return (true, acknowledge)
    }
}
