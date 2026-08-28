import SwiftUI
import UIKit

/// Reports the containing window's current safe-area insets to the Springboard.
///
/// The host deliberately draws edge-to-edge, which means SwiftUI's normal safe
/// area has already been consumed by the time the home screen is laid out. A
/// UIKit probe is used here because `safeAreaInsetsDidChange()` follows the real
/// window through initial layout, rotation, and resizable iPad scenes. The value
/// remains local to the home surface; launched apps keep their existing inset
/// environment and therefore cannot receive the inset twice.
struct SpringboardSafeAreaReader: UIViewRepresentable {
    @Binding var insets: EdgeInsets?

    func makeUIView(context: Context) -> SpringboardSafeAreaProbeView {
        let view = SpringboardSafeAreaProbeView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.onInsetsChange = updateInsets
        return view
    }

    func updateUIView(_ uiView: SpringboardSafeAreaProbeView, context: Context) {
        uiView.onInsetsChange = updateInsets
        uiView.scheduleInsetsUpdate()
    }

    private func updateInsets(_ nativeInsets: UIEdgeInsets) {
        let value = EdgeInsets(
            top: nativeInsets.top,
            leading: nativeInsets.left,
            bottom: nativeInsets.bottom,
            trailing: nativeInsets.right
        )
        guard insets != value else { return }
        insets = value
    }
}

final class SpringboardSafeAreaProbeView: UIView {
    var onInsetsChange: ((UIEdgeInsets) -> Void)?

    private var pendingInsets: UIEdgeInsets?
    private var updateScheduled = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        scheduleInsetsUpdate()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        scheduleInsetsUpdate()
    }

    func scheduleInsetsUpdate() {
        guard let window else { return }
        pendingInsets = window.safeAreaInsets
        guard !updateScheduled else { return }
        updateScheduled = true

        // Coalesce UIKit layout callbacks into one SwiftUI state mutation per
        // run-loop turn. This prevents geometry feedback and the familiar
        // "tried to update multiple times per frame" diagnostic.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            guard let pendingInsets = self.pendingInsets else { return }
            self.pendingInsets = nil
            self.onInsetsChange?(pendingInsets)
        }
    }
}
