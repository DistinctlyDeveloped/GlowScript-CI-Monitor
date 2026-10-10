import AppKit
import Observation
import SwiftUI

/// Deep links let scripts (and UI verification) drive the app without accessibility access.
///
///   glowscript-ci://popover
///   glowscript-ci://tracker?section=ci|pulls|issues&filter=<text>&label=<name>
struct TrackerDeepLink: Equatable {
    var section: TrackerSection?
    var filter: String?
    var label: String?
    /// Distinguishes two identical requests so `onChange` still fires.
    var sequence: Int = 0
}

@Observable
@MainActor
final class DeepLinkRouter {
    static let shared = DeepLinkRouter()

    /// Incremented each time the tracker window should be opened or brought forward.
    private(set) var openTrackerRequest = 0
    /// Most recent tracker deep link. Consumers read it when the window appears or when it changes.
    private(set) var trackerLink: TrackerDeepLink?

    private var sequence = 0

    func handle(_ url: URL) {
        guard url.scheme == "glowscript-ci" else { return }
        switch url.host {
        case "popover":
            openPopover()
        case "tracker":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            // A present-but-empty parameter (filter=) clears that field; an absent one leaves it alone.
            func value(_ name: String) -> String? {
                items.first { $0.name == name }.map { $0.value ?? "" }
            }
            sequence += 1
            trackerLink = TrackerDeepLink(
                section: TrackerSection(deepLinkName: value("section")),
                filter: value("filter"),
                label: value("label"),
                sequence: sequence)
            openTrackerRequest += 1
            bringTrackerWindowForward()
        default:
            break
        }
    }

    /// The MenuBarExtra has no public API to open it; clicking its status bar button does the job.
    private func openPopover() {
        let candidates = NSApp.windows
            .filter { $0.className.contains("NSStatusBarWindow") }
            .map { ($0, findStatusBarButton(in: $0.contentView)) }
        // SwiftUI keeps spare zero-width status windows around; only the visible one has the extra.
        let target = candidates.first { window, button in
            window.isVisible && window.frame.width > 1 && button != nil
        } ?? candidates.first { $0.1 != nil }
        target?.1?.performClick(nil)
    }


    private func findStatusBarButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for sub in view.subviews {
            if let found = findStatusBarButton(in: sub) { return found }
        }
        return nil
    }

    /// macOS 14 only honours `activate` cooperatively, so also order the window up regardless.
    func bringTrackerWindowForward() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.identifier?.rawValue.hasPrefix("project-tracker") == true {
            window.orderFrontRegardless()
            window.makeKey()
        }
    }
}

extension TrackerSection {
    init?(deepLinkName: String?) {
        switch deepLinkName?.lowercased() {
        case "ci": self = .ci
        case "pulls", "prs", "pullrequests", "pull-requests": self = .pullRequests
        case "issues": self = .issues
        default: return nil
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// SwiftUI installs its own GetURL handler and routes every URL to a Window scene, so the
    /// popover link would open the tracker instead. Registering after launch takes precedence.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:replyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else { return }
        DeepLinkRouter.shared.handle(url)
    }
}

/// Invisible view that lives in the always-present menu bar label so it can call `openWindow`
/// in response to deep links even when no other window exists.
struct DeepLinkWindowOpener: View {
    @Environment(\.openWindow) private var openWindow
    private let router = DeepLinkRouter.shared

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: router.openTrackerRequest) { _, _ in
                openWindow(id: "project-tracker")
                router.bringTrackerWindowForward()
            }
    }
}
