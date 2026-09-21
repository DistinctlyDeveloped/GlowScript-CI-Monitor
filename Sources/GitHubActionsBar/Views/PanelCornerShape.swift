import AppKit
import SwiftUI

/// Corner radius shared by every macOS 26 (Tahoe / Golden Gate) window, measured
/// at 2x on the built-in display. The MenuBarExtra window otherwise keeps the
/// pre-Tahoe ~10pt corners.
let panelCornerRadius: CGFloat = 22

/// The MenuBarExtra panel draws its backing (frame view + visual-effect view)
/// outside the SwiftUI content, so clipping the content alone leaves a square
/// backing visible behind the rounded corners. This masks every ancestor layer
/// and the window itself. Re-applied whenever the view lands in a window because
/// the panel is rebuilt each time it opens.
private final class WindowCornerView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyCorners()
        DispatchQueue.main.async { [weak self] in self?.applyCorners() }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        applyCorners()
    }

    func applyCorners() {
        guard let window else { return }
        var windows: [NSWindow] = [window]
        if let parent = window.parent { windows.append(parent) }
        windows.append(contentsOf: window.childWindows ?? [])
        for w in windows {
            w.isOpaque = false
            w.backgroundColor = .clear
            guard let frameView = w.contentView?.superview else { continue }
            Self.setNativeCornerRadius(on: w, frameView: frameView)
            let panelSize = frameView.bounds.size
            // SwiftUI hosts materials as full-size AppKit views that ignore
            // clipShape; round only views spanning the whole panel so text and
            // cards are never clipped.
            func visit(_ v: NSView) {
                if v.frame.size == panelSize {
                    v.wantsLayer = true
                    v.layer?.cornerRadius = panelCornerRadius
                    v.layer?.cornerCurve = .continuous
                    v.layer?.masksToBounds = true
                    // AppKit re-sets the frame layer's cornerRadius after layout on
                    // Tahoe; a shape mask survives that.
                    let mask = (v.layer?.mask as? CAShapeLayer) ?? CAShapeLayer()
                    mask.frame = v.bounds
                    mask.path = CGPath(roundedRect: v.bounds, cornerWidth: panelCornerRadius, cornerHeight: panelCornerRadius, transform: nil)
                    v.layer?.mask = mask
                    if let effect = v as? NSVisualEffectView { effect.maskImage = Self.roundedMask }
                }
                v.subviews.forEach(visit)
            }
            visit(frameView)
            w.invalidateShadow()
        }
        // The shadow is rasterised from the window alpha at invalidation time, so
        // it must be recomputed after the mask layers commit and again once the
        // panel has fully appeared.
        CATransaction.setCompletionBlock { windows.forEach { $0.invalidateShadow() } }
        for delay in [0.05, 0.25, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { windows.forEach { $0.invalidateShadow() } }
        }
        if !observing {
            observing = true
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didExposeNotification, NSWindow.didUpdateNotification] {
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
                    window?.invalidateShadow()
                }
            }
        }
    }

    private var observing = false

    /// AppKit rounds the frame and shapes the window shadow from a private
    /// corner-radius property (present on macOS 26). Set it when available;
    /// the layer masks above remain as the fallback.
    private static func setNativeCornerRadius(on window: NSWindow, frameView: NSView) {
        for target in [window as NSObject, frameView as NSObject] {
            for selector in ["setCornerRadius:", "_setCornerRadius:"] {
                let sel = NSSelectorFromString(selector)
                if target.responds(to: sel) { target.perform(sel, with: panelCornerRadius as NSNumber) }
            }
        }
    }

    private static let roundedMask: NSImage = {
        let radius = panelCornerRadius
        let size = NSSize(width: radius * 2 + 1, height: radius * 2 + 1)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }()
}

private struct WindowCornerBacking: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowCornerView { WindowCornerView() }
    func updateNSView(_ view: WindowCornerView, context: Context) { view.applyCorners() }
}

extension View {
    /// Rounds the panel to the system window radius; call on the outermost view.
    func panelCorners() -> some View {
        clipShape(RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous))
            .background(WindowCornerBacking())
    }
}
