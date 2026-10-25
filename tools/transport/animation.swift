// A repeatable changing screen for transport measurements, not a latency
// measurement by itself. Draws only in the named auxiliary display and exits.
// swiftc -parse-as-library tools/transport/animation.swift -o /tmp/od-animation
// /tmp/od-animation <display-name> [seconds]
import AppKit
import QuartzCore

final class PatternView: NSView {
    let started = CACurrentMediaTime()
    var frames = 0
    override func draw(_ dirtyRect: NSRect) {
        let t = CACurrentMediaTime() - started
        NSColor(calibratedWhite: 0.06, alpha: 1).setFill()
        bounds.fill()
        let offset = CGFloat(t * 160).truncatingRemainder(dividingBy: 34)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 19, weight: .regular),
            .foregroundColor: NSColor.white
        ]
        for row in -1..<Int(bounds.height / 34) + 1 {
            let number = row + Int(t * 160 / 34)
            let text = String(format: "%05d   OpenDisplay WiFi   abcdefghijklmnopqrstuvwxyz   0123456789", number)
            text.draw(at: NSPoint(x: 25, y: CGFloat(row) * 34 - offset), withAttributes: attributes)
        }
        NSColor.systemTeal.setFill()
        let x = (CGFloat(t * 230).truncatingRemainder(dividingBy: max(1, bounds.width - 80)))
        NSBezierPath(roundedRect: NSRect(x: x, y: bounds.midY - 45, width: 80, height: 90),
                     xRadius: 12, yRadius: 12).fill()
        frames += 1
    }
}

@main
final class AnimationHarness: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var timer: Timer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        guard args.count >= 2,
              let screen = NSScreen.screens.first(where: { $0.localizedName == args[1] }),
              screen != NSScreen.screens.first else {
            fputs("Specify an existing auxiliary display name. Available: \(NSScreen.screens.map(\.localizedName))\n", stderr)
            NSApp.terminate(nil)
            return
        }
        let duration = args.count > 2 ? (Double(args[2]) ?? 20) : 20
        let rect = screen.frame.insetBy(dx: 15, dy: 15)
        let w = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        let view = PatternView(frame: NSRect(origin: .zero, size: rect.size))
        w.contentView = view
        w.isReleasedWhenClosed = false
        w.ignoresMouseEvents = true
        window = w
        w.orderFrontRegardless()
        let started = CACurrentMediaTime()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            if CACurrentMediaTime() - started >= duration {
                timer.invalidate()
                print("Animation finished: \(view.frames) draws in \(duration)s on \(args[1])")
                self?.window?.close()
                NSApp.terminate(nil)
            } else { view.needsDisplay = true }
        }
        print("Animation started on \(screen.localizedName), \(Int(rect.width))x\(Int(rect.height)), \(duration)s")
    }
    static func main() {
        let delegate = AnimationHarness()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
