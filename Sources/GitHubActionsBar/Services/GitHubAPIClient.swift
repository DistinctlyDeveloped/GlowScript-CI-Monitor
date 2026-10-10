import Foundation

actor GitHubAPIClient {
    private let session: URLSession
    private let baseURL = "https://api.github.com"
    private(set) var rateLimitRemaining: Int?
    private var etagCache: [URL: (etag: String, data: Data)] = [:]

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - User

    func fetchAuthenticatedUser(token: String) async throws -> GitHubUser {
        let request = makeRequest(path: "/user", token: token)
        return try await perform(request)
    }

    // MARK: - Repos

    func fetchUserRepos(token: String) async throws -> [Repository] {
        let request = makeRequest(
            path: "/user/repos",
            queryItems: [
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "sort", value: "pushed"),
            ],
            token: token
        )
        return try await perform(request)
    }

    // MARK: - Workflow Runs

    func fetchWorkflowRuns(owner: String, repo: String, branch: String?, token: String) async throws
        -> WorkflowRunsResponse
    {
        var queryItems = [
            URLQueryItem(name: "per_page", value: "50")
        ]
        if let branch {
            queryItems.append(URLQueryItem(name: "branch", value: branch))
        }
        let request = makeRequest(
            path: "/repos/\(owner)/\(repo)/actions/runs",
            queryItems: queryItems,
            token: token
        )
        return try await perform(request)
    }

    func fetchAllWorkflowRuns(repos: [(owner: String, repo: String, branch: String?)], token: String) async throws
        -> [WorkflowRun]
    {
        try await withThrowingTaskGroup(of: [WorkflowRun].self) { group in
            for (owner, repo, branch) in repos {
                group.addTask {
                    let response = try await self.fetchWorkflowRuns(
                        owner: owner, repo: repo, branch: branch, token: token)
                    return response.workflowRuns
                }
            }

            var allRuns: [WorkflowRun] = []
            for try await runs in group {
                allRuns.append(contentsOf: runs)
            }
            return allRuns.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    func fetchJobs(repository: String, runID: Int64, token: String) async throws -> CIJobsResponse {
        // Each run is independently bounded; the UI identifies this as sampled job detail.
        let request = makeRequest(path: "/repos/\(repository)/actions/runs/\(runID)/jobs",
            queryItems: [URLQueryItem(name: "per_page", value: "100"), URLQueryItem(name: "filter", value: "latest")], token: token)
        return try await perform(request)
    }

    // MARK: - Project tracker (PRs and issues)

    func fetchOpenPullRequests(owner: String, repo: String, token: String) async throws -> [TrackedPullRequest] {
        let query = """
        query($owner: String!, $repo: String!) {
          repository(owner: $owner, name: $repo) {
            pullRequests(states: OPEN, first: 100, orderBy: {field: UPDATED_AT, direction: DESC}) {
              nodes {
                number title isDraft reviewDecision mergeable updatedAt url
                author { login }
                commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
                closingIssuesReferences(first: 20) { nodes { number } }
              }
            }
          }
        }
        """
        var request = URLRequest(url: URL(string: baseURL + "/graphql")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query,
            "variables": ["owner": owner, "repo": repo],
        ])
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw APIError.httpError(http.statusCode)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(PullRequestGraphQLResponse.self, from: data)
        if let errors = envelope.errors, !errors.isEmpty, envelope.data?.repository == nil {
            throw APIError.graphQL(errors.map(\.message).joined(separator: "; "))
        }
        return envelope.data?.repository?.pullRequests.nodes ?? []
    }

    func fetchOpenIssues(owner: String, repo: String, token: String) async throws -> [TrackedIssue] {
        let request = makeRequest(
            path: "/repos/\(owner)/\(repo)/issues",
            queryItems: [
                URLQueryItem(name: "state", value: "open"),
                URLQueryItem(name: "per_page", value: "100"),
            ],
            token: token
        )
        let items: [TrackedIssue] = try await perform(request)
        return items.filter { $0.pullRequest == nil }
    }

    // MARK: - Helpers

    private func makeRequest(
        path: String, queryItems: [URLQueryItem] = [], token: String
    ) -> URLRequest {
        var components = URLComponents(string: baseURL + path)!
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    private func perform<T: Decodable & Sendable>(_ request: URLRequest) async throws -> T {
        var request = request
        request.cachePolicy = .reloadIgnoringLocalCacheData

        if let url = request.url, let cached = etagCache[url] {
            request.setValue(cached.etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await session.data(for: request)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601

        if let httpResponse = response as? HTTPURLResponse {
            if let remaining = httpResponse.value(forHTTPHeaderField: "X-RateLimit-Remaining") {
                rateLimitRemaining = Int(remaining)
            }

            if httpResponse.statusCode == 304, let url = request.url, let cached = etagCache[url] {
                return try decoder.decode(T.self, from: cached.data)
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                throw APIError.httpError(httpResponse.statusCode)
            }

            if let url = request.url,
                let etag = httpResponse.value(forHTTPHeaderField: "ETag")
            {
                if etagCache.count >= 128 { etagCache.removeAll() }
                etagCache[url] = (etag: etag, data: data)
            }
        }

        return try decoder.decode(T.self, from: data)
    }
}

enum APIError: LocalizedError {
    case httpError(Int)
    case graphQL(String)

    var errorDescription: String? {
        switch self {
        case .graphQL(let message):
            return "GitHub GraphQL error: \(message)"
        case .httpError(401):
            return "Invalid or expired token. Please sign in again."
        case .httpError(403):
            return "Rate limit exceeded or insufficient permissions."
        case .httpError(let code):
            return "GitHub API error (HTTP \(code))"
        }
    }

    var isAuthError: Bool {
        if case .httpError(401) = self { return true }
        return false
    }

    var isScopeError: Bool {
        switch self {
        case .httpError(401), .httpError(403): return true
        default: return false
        }
    }
}
