import SwiftUI

struct IssuesView: View {
    @Bindable var tracker: ProjectTrackerViewModel
    @State private var searchText = ""
    @State private var labelFilter = ""
    private let router = DeepLinkRouter.shared

    private var allLabels: [String] {
        Array(Set(tracker.issues.flatMap { $0.labels.map(\.name) })).sorted()
    }

    private var filtered: [TrackedIssue] {
        tracker.issues.filter { issue in
            let matchesText = searchText.isEmpty
                || issue.title.localizedCaseInsensitiveContains(searchText)
                || issueNumberText(issue.number).contains(searchText)
                || issue.assignees.contains { $0.login.localizedCaseInsensitiveContains(searchText) }
            let matchesLabel = labelFilter.isEmpty || issue.labels.contains { $0.name == labelFilter }
            return matchesText && matchesLabel
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("Filter by title, number, or assignee", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Picker("Label", selection: $labelFilter) {
                    Text("All labels").tag("")
                    ForEach(allLabels, id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 240)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if tracker.usingGhCLIToken {
                TrackerNotice(message: "The stored token cannot read pull requests or issues. Using the token from `gh auth token` instead.")
            }
            if let error = tracker.issuesError {
                TrackerNotice(message: error, tint: .orange)
            }

            if filtered.isEmpty {
                TrackerEmptyState(
                    isLoading: tracker.isLoading && tracker.lastRefresh == nil,
                    error: tracker.issues.isEmpty ? tracker.issuesError : nil,
                    loadingTitle: "Loading issues…",
                    emptyTitle: tracker.issues.isEmpty ? "No open issues" : "No matching issues",
                    failedTitle: "Could not load issues",
                    systemImage: "exclamationmark.circle")
            } else {
                List(filtered) { issue in
                    IssueRow(issue: issue)
                        .contentShape(Rectangle())
                        .onTapGesture { openInBrowser(issue.htmlUrl) }
                }
                .listStyle(.inset)
            }
        }
        .navigationSubtitle("\(filtered.count) of \(tracker.issues.count) open issues")
        .onAppear { applyDeepLink(router.trackerLink) }
        .onChange(of: router.trackerLink) { _, link in applyDeepLink(link) }
    }

    private func applyDeepLink(_ link: TrackerDeepLink?) {
        guard let link, link.section == .issues else { return }
        if let filter = link.filter { searchText = filter }
        if let label = link.label { labelFilter = label }
    }
}

struct IssueRow: View {
    let issue: TrackedIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(issueNumberText(issue.number))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(issue.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer()
                if issue.comments > 0 {
                    Label("\(issue.comments)", systemImage: "bubble.left")
                        .font(.caption).foregroundStyle(.secondary)
                }
                RelativeAgoText(date: issue.updatedAt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(issue.labels, id: \.name) { label in
                    Badge(text: label.name, color: Color(hex: label.color))
                }
                if !issue.assignees.isEmpty {
                    Text(issue.assignees.map { "@\($0.login)" }.joined(separator: " "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Unassigned").font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }
}

extension Color {
    /// GitHub label colors arrive as 6 hex digits without a leading hash.
    init(hex: String) {
        var value: UInt64 = 0
        guard hex.count == 6, Scanner(string: hex).scanHexInt64(&value) else {
            self = .gray
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}
