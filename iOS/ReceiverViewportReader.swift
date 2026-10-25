import SwiftUI
import UIKit

/// Observes the hosting window even while the receiver is showing its idle UI.
/// Measures either the edge-to-edge window or the inset video's own bounds,
/// following rotation, inner/outer displays and Split View in either mode.
struct ReceiverViewportReader: UIViewRepresentable {
    var usesFullWindow: Bool
    var onChange: (ReceiverViewport) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.usesFullWindow = usesFullWindow
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.usesFullWindow = usesFullWindow
        view.onChange = onChange
        view.observeViewport()
    }

    static func dismantleUIView(_ view: ProbeView, coordinator: ()) {
        view.cancelPendingUpdate()
    }

    final class ProbeView: UIView {
        var usesFullWindow = true
        var onChange: ((ReceiverViewport) -> Void)?
        private var lastDelivered: ReceiverViewport?
        private var candidate: ReceiverViewport?
        private var pending: DispatchWorkItem?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { cancelPendingUpdate() }
            else { observeViewport() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            observeViewport()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            setNeedsLayout()
        }

        override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
            super.traitCollectionDidChange(previousTraitCollection)
            observeViewport()
        }

        func cancelPendingUpdate() {
            pending?.cancel()
            pending = nil
            candidate = nil
        }

        private func viewport() -> ReceiverViewport? {
            guard let window, let scene = window.windowScene else { return nil }
            // Never UIScreen.main: on Duo it can describe the other display.
            let screen = scene.screen
            return ReceiverViewport(points: usesFullWindow ? window.bounds.size : bounds.size,
                                    scale: Double(screen.nativeScale),
                                    maximumFramesPerSecond: screen.maximumFramesPerSecond)
        }

        func observeViewport() {
            guard let next = viewport() else { return }
            guard next != lastDelivered else { cancelPendingUpdate(); return }
            guard next != candidate else { return }
            cancelPendingUpdate()
            candidate = next
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.candidate == next else { return }
                // Re-read after the transition; don't commit an intermediate
                // fold/resize size if UIKit has already moved on.
                guard self.viewport() == next else {
                    self.cancelPendingUpdate()
                    self.observeViewport()
                    return
                }
                self.lastDelivered = next
                self.pending = nil
                self.candidate = nil
                self.onChange?(next)
            }
            pending = work
            // Coalesce animated layouts instead of restarting capture on
            // every animation step. The first valid size can start at once.
            DispatchQueue.main.asyncAfter(deadline: .now() + (lastDelivered == nil ? 0 : 0.2),
                                          execute: work)
        }
    }
}
