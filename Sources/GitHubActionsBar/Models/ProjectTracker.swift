import Foundation

// MARK: - Pull requests (GraphQL)

struct PullRequestGraphQLResponse: Decodable, Sendable {
    struct GraphQLError: Decodable, Sendable { let message: String }
    struct DataNode: Decodable, Sendable { let repository: RepositoryNode? }
    struct RepositoryNode: Decodable, Sendable { let pullRequests: Connection }
    struct Connection: Decodable, Sendable { let nodes: [TrackedPullRequest]; let pageInfo: PageInfo }
    struct PageInfo: Decodable, Sendable { let hasNextPage: Bool; let endCursor: String? }

    let data: DataNode?
    let errors: [GraphQLError]?
}

struct TrackedPullRequest: Decodable, Sendable, Identifiable {
    struct Author: Decodable, Sendable { let login: String }
    struct Commits: Decodable, Sendable { let nodes: [CommitNode] }
    struct CommitNode: Decodable, Sendable { let commit: Commit }
    struct Commit: Decodable, Sendable { let statusCheckRollup: Rollup? }
    struct Rollup: Decodable, Sendable { let state: String }
    struct IssueRefs: Decodable, Sendable { let nodes: [IssueRef] }
    struct IssueRef: Decodable, Sendable { let number: Int }

    let number: Int
    let title: String
    let isDraft: Bool
    let reviewDecision: String?
    let mergeable: String?
    let updatedAt: Date
    let url: URL
    let author: Author?
    let commits: Commits
    let closingIssuesReferences: IssueRefs

    var id: Int { number }
    var authorLogin: String { author?.login ?? "ghost" }
    var checkState: String? { commits.nodes.first?.commit.statusCheckRollup?.state }
    var closingIssueNumbers: [Int] { closingIssuesReferences.nodes.map(\.number) }
}

// MARK: - Issues (REST)

struct TrackedIssue: Decodable, Sendable, Identifiable {
    struct Label: Decodable, Sendable, Hashable {
        let name: String
        let color: String
    }
    struct User: Decodable, Sendable {
        let login: String
    }
    struct PullRequestMarker: Decodable, Sendable {
        let url: String?
    }

    let id: Int64
    let number: Int
    let title: String
    let htmlUrl: URL
    let updatedAt: Date
    let labels: [Label]
    let assignees: [User]
    let user: User?
    let comments: Int
    let pullRequest: PullRequestMarker?
}
