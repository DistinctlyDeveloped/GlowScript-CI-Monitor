import SwiftUI

struct PullRequestsView: View {
    @Bindable var tracker: ProjectTrackerViewModel

    var body: some View {
        VStack(spacing: 0) {
            if tracker.usingGhCLIToken {
                TrackerNotice(message: "Stored token lacks GraphQL scope. Using the token from `gh auth token` for pull requests.")
            }
            if let error = tracker.pullRequestError {
                TrackerNotice(message: error, tint: .orange)
            }
            if tracker.pullRequests.isEmpty {
                ContentUnavailableView(
                    tracker.isLoading && tracker.lastRefresh == nil ? "Loading pull requests…" : "No open pull requests",
                    systemImage: "arrow.triangle.pull")
            } else {
                List(tracker.pullRequests) { pr in
                    PullRequestRow(pr: pr)
                        .contentShape(Rectangle())
                        .onTapGesture { openInBrowser(pr.url) }
                }
                .listStyle(.inset)
            }
        }
        .navigationSubtitle("\(tracker.pullRequests.count) open in \(ProjectTrackerViewModel.owner)/\(ProjectTrackerViewModel.repo)")
    }
}

struct PullRequestRow: View {
    let pr: TrackedPullRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("#\(pr.number)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(pr.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text(pr.updatedAt, style: .relative)
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
                Badge(text: reviewLabel, color: reviewColor)
                Badge(text: checksLabel, color: checksColor)
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
        case nil: return "No checks"
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
