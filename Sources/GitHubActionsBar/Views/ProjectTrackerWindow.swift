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
                    MainPopoverView(viewModel: viewModel)
                case .pullRequests:
                    PullRequestsView(tracker: tracker)
                case .issues:
                    IssuesView(tracker: tracker)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        viewModel.refresh()
                        Task { await tracker.refresh(token: viewModel.currentToken) }
                    } label: {
                        if tracker.isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .help("Refresh PRs and issues")
                }
                ToolbarItem(placement: .status) {
                    if let last = tracker.lastRefresh {
                        Text("Updated \(last, style: .relative) ago")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("GlowScript Project Tracker")
        .frame(minWidth: 800, minHeight: 500)
        .onAppear {
            tracker.startPolling { [viewModel] in viewModel.currentToken }
        }
        .onDisappear {
            tracker.stopPolling()
        }
    }
}

// MARK: - Shared pieces

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

func openInBrowser(_ url: URL) {
    NSWorkspace.shared.open(url)
}
