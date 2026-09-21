import AppKit
import SwiftUI

/// Corner radius shared by every macOS 26 (Tahoe / Golden Gate) window, measured
/// at 2x on the built-in display. The MenuBarExtra window otherwise keeps the
/// pre-Tahoe ~10pt corners.
let panelCornerRadius: CGFloat = 22

/// Clears the hosting NSWindow's own opaque background so the SwiftUI content's
/// clip shape defines the visible edge of the panel.
private struct TransparentWindowBacking: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(to: view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        apply(to: view.window)
    }

    private func apply(to window: NSWindow?) {
        guard let window, window.isOpaque || window.backgroundColor != .clear else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.masksToBounds = false
    }
}

extension View {
    /// Rounds the panel to the system window radius; call on the outermost view.
    func panelCorners() -> some View {
        clipShape(RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous))
            .background(TransparentWindowBacking())
    }
}
