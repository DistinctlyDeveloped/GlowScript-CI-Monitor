import SwiftUI

struct PullRequestsView: View {
    @Bindable var tracker: ProjectTrackerViewModel
    @State private var searchText = ""
    private let router = DeepLinkRouter.shared

    private var filtered: [TrackedPullRequest] {
        guard !searchText.isEmpty else { return tracker.pullRequests }
        return tracker.pullRequests.filter { pr in
            pr.title.localizedCaseInsensitiveContains(searchText)
                || issueNumberText(pr.number).contains(searchText)
                || pr.authorLogin.localizedCaseInsensitiveContains(searchText)
                || pr.closingIssueNumbers.contains { issueNumberText($0).contains(searchText) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter by title, number, author, or closed issue", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            if tracker.usingGhCLIToken {
                TrackerNotice(message: "The stored token cannot read pull requests or issues. Using the token from `gh auth token` instead.")
            }
            if let error = tracker.pullRequestError {
                TrackerNotice(message: error, tint: .orange)
            }
            if filtered.isEmpty {
                TrackerEmptyState(
                    isLoading: tracker.isLoading && tracker.lastRefresh == nil,
                    error: tracker.pullRequests.isEmpty ? tracker.pullRequestError : nil,
                    loadingTitle: "Loading pull requests…",
                    emptyTitle: tracker.pullRequests.isEmpty ? "No open pull requests" : "No matching pull requests",
                    failedTitle: "Could not load pull requests",
                    systemImage: "arrow.triangle.pull")
            } else {
                List(filtered) { pr in
                    PullRequestRow(pr: pr)
                        .contentShape(Rectangle())
                        .onTapGesture { openInBrowser(pr.url) }
                }
                .listStyle(.inset)
            }
        }
        .trackerSubtitle("\(filtered.count) of \(tracker.pullRequests.count) open in \(ProjectTrackerViewModel.owner)/\(ProjectTrackerViewModel.repo)")
        .onAppear { applyDeepLink(router.trackerLink) }
        .onChange(of: router.trackerLink) { _, link in applyDeepLink(link) }
    }

    private func applyDeepLink(_ link: TrackerDeepLink?) {
        guard let link, link.section == .pullRequests, let filter = link.filter else { return }
        searchText = filter
    }
}

struct PullRequestRow: View {
    let pr: TrackedPullRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(issueNumberText(pr.number))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(pr.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer()
                RelativeAgoText(date: pr.updatedAt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text("@\(pr.authorLogin)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if pr.isDraft {
                    Badge(text: "Draft", color: .gray)
                }
                // GitHub returns no decision when the repo requires no reviews; a chip for that is noise.
                if let decision = pr.reviewDecision, !decision.isEmpty {
                    Badge(text: reviewLabel, color: reviewColor)
                }
                Badge(text: checksLabel, color: checksColor)
                    .help(pr.checkState == nil
                          ? "GitHub returned no check rollup. A fine-grained token needs Checks and Commit statuses read access to see CI results."
                          : "Combined status of the latest commit's checks")
                Badge(text: mergeLabel, color: mergeColor)
                if !pr.closingIssueNumbers.isEmpty {
                    Badge(text: "Closes " + pr.closingIssueNumbers.map { "#\($0)" }.joined(separator: ", "), color: .purple)
                }
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }

    private var reviewLabel: String {
        switch pr.reviewDecision {
        case "APPROVED": return "Approved"
        case "CHANGES_REQUESTED": return "Changes requested"
        case "REVIEW_REQUIRED": return "Review required"
        default: return "No review"
        }
    }

    private var reviewColor: Color {
        switch pr.reviewDecision {
        case "APPROVED": return .green
        case "CHANGES_REQUESTED": return .red
        case "REVIEW_REQUIRED": return .yellow
        default: return .gray
        }
    }

    private var checksLabel: String {
        switch pr.checkState {
        case "SUCCESS": return "Checks passing"
        case "FAILURE", "ERROR": return "Checks failing"
        case "PENDING", "EXPECTED": return "Checks running"
        case nil: return "Checks unavailable"
        case .some(let other): return other.capitalized
        }
    }

    private var checksColor: Color {
        switch pr.checkState {
        case "SUCCESS": return .green
        case "FAILURE", "ERROR": return .red
        case "PENDING", "EXPECTED": return .yellow
        default: return .gray
        }
    }

    private var mergeLabel: String {
        switch pr.mergeable {
        case "MERGEABLE": return "Mergeable"
        case "CONFLICTING": return "Conflicts"
        default: return "Merge unknown"
        }
    }

    private var mergeColor: Color {
        switch pr.mergeable {
        case "MERGEABLE": return .green
        case "CONFLICTING": return .red
        default: return .gray
        }
    }
}
