import AppKit
import SwiftUI

enum TrackerSection: String, CaseIterable, Identifiable {
    case ci = "CI"
    case pullRequests = "Pull Requests"
    case issues = "Issues"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .ci: return "gearshape.2"
        case .pullRequests: return "arrow.triangle.pull"
        case .issues: return "exclamationmark.circle"
        }
    }
}

struct ProjectTrackerWindow: View {
    @Bindable var viewModel: WorkflowViewModel
    @State private var tracker = ProjectTrackerViewModel()
    @State private var section: TrackerSection? = .ci
    @State private var sectionSubtitle = ""
    private let router = DeepLinkRouter.shared

    var body: some View {
        NavigationSplitView {
            List(TrackerSection.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 240)
        } detail: {
            Group {
                switch section ?? .ci {
                case .ci:
                    // The dashboard otherwise lays out taller than the pane and clips its footer.
                    GeometryReader { geo in
                        MainPopoverView(viewModel: viewModel, embedded: true)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                case .pullRequests:
                    PullRequestsView(tracker: tracker)
                case .issues:
                    IssuesView(tracker: tracker)
                }
            }
            .onPreferenceChange(TrackerSubtitleKey.self) { sectionSubtitle = $0 }
            .modifier(AlignedTitle(title: "GlowScript Project Tracker", subtitle: subtitle))
            .toolbar {
                ToolbarItem(placement: .status) {
                    if let last = lastUpdated {
                        HStack(spacing: 4) {
                            Text("Updated")
                            RelativeAgoText(date: last)
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        viewModel.refresh()
                        Task { await tracker.refresh(token: viewModel.currentToken) }
                    } label: {
                        if isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .help("Refresh")
                }
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: settingsShown) {
                        Image(systemName: "gearshape")
                    }
                    .help("Settings")
                }
            }
        }
        .navigationTitle("GlowScript Project Tracker")
        .frame(minWidth: 800, minHeight: 500)
        .onAppear {
            tracker.startPolling { [viewModel] in viewModel.currentToken }
            applyDeepLink(router.trackerLink)
        }
        .onChange(of: router.trackerLink) { _, link in
            applyDeepLink(link)
        }
        .onDisappear {
            tracker.stopPolling()
        }
    }

    private var subtitle: String {
        if section == .ci {
            return viewModel.showSettings ? "Settings" : ""
        }
        return sectionSubtitle
    }

    private var lastUpdated: Date? {
        section == .ci ? viewModel.lastRefresh : tracker.lastRefresh
    }

    private var isLoading: Bool {
        section == .ci ? viewModel.isLoading : tracker.isLoading
    }

    /// Settings live in the CI pane, so opening them from another section switches to CI first.
    private var settingsShown: Binding<Bool> {
        Binding {
            section == .ci && viewModel.showSettings
        } set: { shown in
            if shown {
                section = .ci
                viewModel.showSettings = true
            } else {
                viewModel.showSettings = false
                viewModel.refresh()
            }
        }
    }

    private func applyDeepLink(_ link: TrackerDeepLink?) {
        guard let link else { return }
        if let target = link.section { section = target }
        router.bringTrackerWindowForward()
    }
}

// MARK: - Shared pieces

/// Section views publish the "39 of 39 open" line shown under the window title.
struct TrackerSubtitleKey: PreferenceKey {
    static let defaultValue = ""
    static func reduce(value: inout String, nextValue: () -> String) { value = nextValue() }
}

extension View {
    func trackerSubtitle(_ text: String) -> some View {
        preference(key: TrackerSubtitleKey.self, value: text)
            .navigationSubtitle(text)
    }
}

/// AppKit insets the native toolbar title about 10pt from the sidebar divider while the
/// detail content uses 16pt, so the two left edges never line up. On macOS 15+ the native
/// title is removed and drawn as a toolbar item padded to the content inset instead.
/// macOS 14 keeps the native title and subtitle.
private struct AlignedTitle: ViewModifier {
    let title: String
    let subtitle: String

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                .toolbar(removing: .title)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title).font(.headline)
                            if !subtitle.isEmpty {
                                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.leading, 14)
                    }
                }
        } else {
            content
        }
    }
}

/// "#2531" rather than the locale-grouped "#2,531" that `Text("\(Int)")` produces.
func issueNumberText(_ number: Int) -> String { "#" + String(number) }

/// Compact "3m ago" style used in list rows and the toolbar.
struct RelativeAgoText: View {
    let date: Date
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        f.dateTimeStyle = .numeric
        return f
    }()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if context.date.timeIntervalSince(date) < 60 {
                Text("just now")
            } else {
                Text(Self.formatter.localizedString(for: date, relativeTo: context.date))
            }
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

struct TrackerNotice: View {
    let message: String
    var tint: Color = .yellow

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle.fill").foregroundStyle(tint)
            Text(message).lineLimit(2)
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(tint.opacity(0.1))
    }
}

/// Fills the remaining pane so notices above it stay pinned to the top.
struct TrackerEmptyState: View {
    let isLoading: Bool
    let error: String?
    let loadingTitle: String
    let emptyTitle: String
    let failedTitle: String
    let systemImage: String

    var body: some View {
        Group {
            if isLoading {
                ContentUnavailableView(loadingTitle, systemImage: systemImage)
            } else if let error {
                ContentUnavailableView(failedTitle, systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ContentUnavailableView(emptyTitle, systemImage: systemImage)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

func openInBrowser(_ url: URL) {
    NSWorkspace.shared.open(url)
}
