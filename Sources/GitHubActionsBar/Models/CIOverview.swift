import Foundation

struct CIHostSnapshot: Codable, Sendable {
    let generatedAt: Double
    let hosts: [CIHost]
    var queue: CIQueue? = nil
    var alerts: [CIAlert]? = nil
    var githubObservedAt: Double? = nil
    var githubError: String? = nil
    func isStale(at date: Date) -> Bool { date.timeIntervalSince1970 - generatedAt > 120 }
    var activeAlerts: [CIAlert] { alerts ?? [] }
}

/// Every self-hosted job waiting across all active runs (not a sample), from the collector.
struct CIQueue: Codable, Sendable {
    let queued: Int
    let hosted: Int
    let running: Int
    let oldestWaitSec: Int
    let medianWaitSec: Int
    let idleRunners: Int
    let idleEligible: Int
    let unservable: Int
    let unservableLabels: [String]
    let oldest: [CIQueuedJob]
}

struct CIQueuedJob: Codable, Sendable, Identifiable {
    let name: String
    let workflow: String?
    let branch: String?
    let pr: Int?
    let waitSec: Int
    let url: String?
    var id: String { "\(url ?? "")|\(name)|\(branch ?? "")" }
}

struct CIAlert: Codable, Sendable, Identifiable {
    let key: String
    let message: String
    let since: Double
    var id: String { key }
}

struct CIProxy: Codable, Sendable {
    let state: String
    let restarts: Int
    var looping: Bool? = nil
    var isHealthy: Bool { state == "running" && looping != true }
}

/// One runner slot: whether its container exists on the host and what GitHub thinks of it.
struct CILane: Codable, Sendable, Identifiable {
    let name: String
    let container: Bool
    let github: String
    let busy: Bool
    let memory: String?
    let job: CILaneJob?
    var id: String { name }
    /// Container up but GitHub cannot hand it work (or the reverse) -- the failure a container-only check hides.
    var isMismatched: Bool { github != "online" && github != "unknown" }
    var shortName: String {
        let parts = name.split(separator: "-")
        if name.hasPrefix("glowscript-macbook-"), parts.count > 2 { return "Slot \(parts[2])" }
        return String(parts.last?.prefix(6) ?? "")
    }
}

struct CILaneJob: Codable, Sendable {
    let name: String
    let branch: String?
    let pr: Int?
    let startedAt: Double?
    let url: String?
    let workflow: String?
}

struct CIHost: Codable, Sendable, Identifiable {
    let id: String
    let name: String
    let state: String
    let expectedLanes: Int
    let cpuPerLane: Int
    let memoryGiBPerLane: Int
    let observedAt: Double
    let runnerNames: [String]
    let memoryUsage: [String]
    var lanes: [CILane]? = nil
    var pools: [String]? = nil
    var proxy: CIProxy? = nil

    /// Lanes GitHub reports online. Falls back to container count for pre-lane snapshots.
    var onlineLanes: Int { lanes.map { $0.filter { $0.github == "online" }.count } ?? runnerNames.count }
    var isDegraded: Bool { (proxy.map { !$0.isHealthy } ?? false) || (lanes ?? []).contains { $0.isMismatched && $0.container } }
    /// How many of the currently queued self-hosted jobs this host's online runners could take.
    var eligibleQueued: Int? = nil
}

struct CIJobsResponse: Decodable, Sendable {
    let totalCount: Int
    let jobs: [CIJob]
}

struct CIJob: Decodable, Sendable, Identifiable {
    let id: Int64
    let name: String
    let status: String
    let conclusion: String?
    let runnerName: String?
    let labels: [String]?
    let startedAt: Date?
    let completedAt: Date?
    let htmlUrl: String?
    let steps: [CIJobStep]?

    var isActive: Bool { status != "completed" }
    var location: String {
        let runner = runnerName ?? ""
        if runner.hasPrefix("glowscript-macbook-") { return "MacBook" }
        if runner.hasPrefix("glowscript-simrig-") { return "SimRig" }
        if runner.hasPrefix("glowscript-studio-") { return "Studio" }
        if labels?.contains("glowscript-simrig") == true { return "SimRig" }
        if labels?.contains("glowscript-studio") == true { return "ARM64 pool" }
        if labels?.contains("self-hosted") == true { return "Self-hosted" }
        if !runner.isEmpty || labels?.contains(where: { $0.hasPrefix("ubuntu-") || $0.hasPrefix("macos-") || $0.hasPrefix("windows-") }) == true { return "GitHub-hosted" }
        return "Unassigned"
    }
    var currentStep: String? { steps?.first { $0.status == "in_progress" }?.name }
}

struct CIJobStep: Decodable, Sendable {
    let name: String
    let status: String
}

struct TrackedCIJob: Identifiable, Sendable {
    let job: CIJob
    let run: WorkflowRun
    var id: Int64 { job.id }
}
