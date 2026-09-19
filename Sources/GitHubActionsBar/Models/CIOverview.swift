import Foundation

struct CIHostSnapshot: Codable, Sendable {
    let generatedAt: Double
    let hosts: [CIHost]
    func isStale(at date: Date) -> Bool { date.timeIntervalSince1970 - generatedAt > 120 }
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
