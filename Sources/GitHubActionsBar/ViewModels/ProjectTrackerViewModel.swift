import Foundation
import Observation

@Observable
@MainActor
final class ProjectTrackerViewModel {
    static let owner = "DistinctlyDeveloped"
    static let repo = "GlowScript"
    static let refreshInterval: Duration = .seconds(90)

    var pullRequests: [TrackedPullRequest] = []
    var issues: [TrackedIssue] = []
    var isLoading = false
    var lastRefresh: Date?
    var pullRequestError: String?
    var issuesError: String?
    /// Set when the stored PAT lacked GraphQL scope and `gh auth token` was used instead.
    var usingGhCLIToken = false

    private let apiClient = GitHubAPIClient()
    private var pollingTask: Task<Void, Never>?
    private var ghToken: String?
    private var ghTokenLookupFailed = false

    enum TrackerError: LocalizedError {
        case noToken
        case storedTokenLacksAccess(APIError)

        var errorDescription: String? {
            switch self {
            case .noToken:
                return "No GitHub token available. Sign in or run `gh auth login`."
            case .storedTokenLacksAccess(let underlying):
                return "Stored token cannot read this repository (\(underlying.localizedDescription)) and `gh auth token` is unavailable."
            }
        }
    }

    func startPolling(tokenProvider: @escaping @MainActor () -> String?) {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(token: tokenProvider())
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func refresh(token: String?) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        async let prs: Void = loadPullRequests(storedToken: token)
        async let iss: Void = loadIssues(storedToken: token)
        _ = await (prs, iss)
        lastRefresh = Date()
    }

    private func loadPullRequests(storedToken: String?) async {
        do {
            pullRequests = try await withTokenFallback(storedToken: storedToken) { token in
                try await self.apiClient.fetchOpenPullRequests(owner: Self.owner, repo: Self.repo, token: token)
            }
            pullRequestError = nil
        } catch {
            pullRequestError = error.localizedDescription
        }
    }

    private func loadIssues(storedToken: String?) async {
        do {
            issues = try await withTokenFallback(storedToken: storedToken) { token in
                try await self.apiClient.fetchOpenIssues(owner: Self.owner, repo: Self.repo, token: token)
            }
            issuesError = nil
        } catch {
            issuesError = error.localizedDescription
        }
    }

    /// Runs `fetch` with the stored PAT first. If that token cannot see the resource, retries with
    /// the `gh` CLI token and remembers that choice so later polls skip the failing PAT.
    private func withTokenFallback<T>(storedToken: String?,
                                      fetch: (String) async throws -> T) async throws -> T {
        if usingGhCLIToken, let ghToken {
            return try await fetch(ghToken)
        }
        guard let storedToken else {
            guard let gh = resolveGhToken() else { throw TrackerError.noToken }
            usingGhCLIToken = true
            return try await fetch(gh)
        }
        do {
            return try await fetch(storedToken)
        } catch let error as APIError where error.isScopeError {
            guard let gh = resolveGhToken() else { throw TrackerError.storedTokenLacksAccess(error) }
            usingGhCLIToken = true
            return try await fetch(gh)
        }
    }

    /// Reads `gh auth token` once per session. The value is kept in memory only and never logged.
    private func resolveGhToken() -> String? {
        if let ghToken { return ghToken }
        if ghTokenLookupFailed { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gh", "auth", "token"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            ghTokenLookupFailed = true
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !value.isEmpty else {
            ghTokenLookupFailed = true
            return nil
        }
        ghToken = value
        return value
    }
}
