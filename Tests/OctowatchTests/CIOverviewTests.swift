import Foundation
import Testing
@testable import Octowatch

struct CIOverviewTests {
    func decode(_ runner: String?, labels: [String], status: String = "queued") throws -> CIJob {
        var object: [String: Any] = ["id": 42, "name": "Tests", "status": status, "labels": labels,
            "steps": [["name": "Install", "status": "completed"], ["name": "Run tests", "status": "in_progress"]]]
        if let runner { object["runner_name"] = runner }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(CIJob.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test func queuedARMJobsDoNotClaimStudioAssignment() throws {
        let job = try decode(nil, labels: ["self-hosted", "Linux", "ARM64", "glowscript-studio"])
        #expect(job.location == "ARM64 pool")
        #expect(job.isActive)
    }

    @Test func actualRunnerOverridesSharedPoolLabel() throws {
        #expect(try decode("glowscript-macbook-0-abc123", labels: ["glowscript-studio"]).location == "MacBook")
        #expect(try decode("glowscript-studio-abc123", labels: ["glowscript-studio"]).location == "Studio")
        #expect(try decode("glowscript-simrig-abc123", labels: ["glowscript-simrig"]).location == "SimRig")
    }

    @Test func unassignedAndHostedRemainDistinct() throws {
        #expect(try decode(nil, labels: []).location == "Unassigned")
        #expect(try decode(nil, labels: ["ubuntu-latest"]).location == "GitHub-hosted")
        #expect(try decode(nil, labels: ["self-hosted"]).location == "Self-hosted")
    }

    @Test func currentStepAndCompletedState() throws {
        let job = try decode("worker", labels: [], status: "completed")
        #expect(!job.isActive)
        #expect(job.currentStep == "Run tests")
    }

    @Test func oldHostSnapshotsBecomeUnknown() {
        let snapshot = CIHostSnapshot(generatedAt: 1000, hosts: [])
        #expect(!snapshot.isStale(at: Date(timeIntervalSince1970: 1120)))
        #expect(snapshot.isStale(at: Date(timeIntervalSince1970: 1121)))
    }
}
