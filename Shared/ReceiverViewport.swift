import Foundation

/// The pixels available to this window, not a cached device-wide screen.
/// Opening a foldable phone can change both axes without changing orientation.
struct ReceiverViewport: Equatable {
    let pixelsWide: Int
    let pixelsHigh: Int
    let scale: Double
    let maximumFramesPerSecond: Int

    init?(points: CGSize, scale: Double, maximumFramesPerSecond: Int) {
        let width = Double(points.width) * scale
        let height = Double(points.height) * scale
        guard scale.isFinite, scale > 0, width.isFinite, height.isFinite,
              width >= 2, height >= 2, width <= 32_768, height <= 32_768 else { return nil }
        pixelsWide = Int(width.rounded())
        pixelsHigh = Int(height.rounded())
        self.scale = scale
        self.maximumFramesPerSecond = max(1, maximumFramesPerSecond)
    }
}
