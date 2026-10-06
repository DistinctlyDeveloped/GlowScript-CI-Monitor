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
        #expect(try decode("glowscript-hostinger-1-abc123", labels: ["glowscript-pool"]).location == "Hostinger")
    }

    @Test func queuedHostingerJobsNameTheirLane() throws {
        #expect(try decode(nil, labels: ["self-hosted", "glowscript-hostinger"]).location == "Hostinger")
        #expect(try decode(nil, labels: ["self-hosted", "glowscript-hostinger-canary"]).location == "Hostinger canary")
    }

    @Test func hostingerLanesShowTheirSlot() throws {
        let s = try snapshot("""
        {"generatedAt": 1, "hosts": [{"id": "hostinger", "name": "Hostinger", "state": "Online", "expectedLanes": 2,
          "cpuPerLane": 4, "memoryGiBPerLane": 12, "observedAt": 1, "runnerNames": ["glowscript-hostinger-1-abcdef123456"],
          "memoryUsage": [], "proxy": {"state": "running", "restarts": 0},
          "lanes": [{"name": "glowscript-hostinger-1-abcdef123456", "container": true, "github": "online", "busy": true,
                     "memory": null, "job": null}]}],
         "queue": null, "alerts": []}
        """)
        #expect(s.hosts[0].lanes?.first?.shortName == "Slot 1")
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

    func snapshot(_ json: String) throws -> CIHostSnapshot {
        try JSONDecoder().decode(CIHostSnapshot.self, from: Data(json.utf8))
    }

    @Test func preLaneSnapshotsStillDecode() throws {
        let old = try snapshot("""
        {"generatedAt": 1, "hosts": [{"id": "macbook", "name": "MacBook", "state": "Online", "expectedLanes": 3,
          "cpuPerLane": 4, "memoryGiBPerLane": 8, "observedAt": 1, "runnerNames": ["a", "b"], "memoryUsage": []}]}
        """)
        #expect(old.queue == nil && old.activeAlerts.isEmpty)
        #expect(old.hosts[0].onlineLanes == 2)
        #expect(!old.hosts[0].isDegraded)
    }

    @Test func containerUpButGitHubOfflineIsDegradedNotOnline() throws {
        let s = try snapshot("""
        {"generatedAt": 1, "hosts": [{"id": "macbook", "name": "MacBook", "state": "Online", "expectedLanes": 3,
          "cpuPerLane": 4, "memoryGiBPerLane": 8, "observedAt": 1, "runnerNames": ["glowscript-macbook-0-a"], "memoryUsage": [],
          "proxy": {"state": "running", "restarts": 718, "looping": true},
          "lanes": [{"name": "glowscript-macbook-0-a", "container": true, "github": "offline", "busy": false, "memory": null, "job": null}]}],
         "queue": {"queued": 85, "hosted": 3, "running": 5, "oldestWaitSec": 8356, "medianWaitSec": 3343, "idleRunners": 1,
          "idleEligible": 0, "unservable": 0, "unservableLabels": [], "oldest": []},
         "alerts": [{"key": "proxy:macbook", "message": "MacBook: CI proxy is in a restart loop", "since": 1}]}
        """)
        let host = s.hosts[0]
        #expect(host.onlineLanes == 0)
        #expect(host.isDegraded)
        #expect(host.lanes?.first?.isMismatched == true)
        #expect(host.lanes?.first?.shortName == "Slot 0")
        #expect(s.queue?.queued == 85)
        #expect(s.activeAlerts.map(\.key) == ["proxy:macbook"])
    }

    func hostWithLane(_ lane: String) throws -> CIHost {
        try snapshot("""
        {"generatedAt": 1, "hosts": [{"id": "studio", "name": "Studio", "state": "Online", "expectedLanes": 2,
          "cpuPerLane": 4, "memoryGiBPerLane": 8, "observedAt": 1, "runnerNames": [], "memoryUsage": [],
          "proxy": {"state": "running", "restarts": 0, "looping": false}, "lanes": [\(lane)]}]}
        """).hosts[0]
    }

    @Test func youngMismatchIsTransitionalGreyNotDegraded() throws {
        let starting = try hostWithLane("""
        {"name": "glowscript-studio-new", "container": true, "github": "unregistered", "busy": false, "memory": null, "job": null,
         "phase": "starting", "mismatchSince": 0}
        """)
        #expect(starting.lanes?.first?.isTransitional == true)
        #expect(starting.lanes?.first?.isFaulted == false)
        #expect(!starting.isDegraded)
        let stopping = try hostWithLane("""
        {"name": "glowscript-studio-old", "container": false, "github": "offline", "busy": true, "memory": null,
         "job": {"name": "Lint gates", "branch": "b", "pr": 1, "startedAt": 0, "url": null, "workflow": "Tests"},
         "phase": "stopping", "mismatchSince": 0}
        """)
        #expect(stopping.lanes?.first?.isTransitional == true)
        #expect(!stopping.isDegraded)
    }

    @Test func agedMismatchDegradesOnlyWhenTheContainerIsUp() throws {
        let containerUp = try hostWithLane("""
        {"name": "glowscript-studio-a", "container": true, "github": "offline", "busy": false, "memory": null, "job": null,
         "phase": "degraded", "mismatchSince": 0}
        """)
        #expect(containerUp.isDegraded)
        #expect(containerUp.lanes?.first?.isTransitional == false)
        let orphaned = try hostWithLane("""
        {"name": "glowscript-studio-b", "container": false, "github": "offline", "busy": false, "memory": null, "job": null,
         "phase": "orphaned", "mismatchSince": 0}
        """)
        #expect(!orphaned.isDegraded)
        #expect(orphaned.lanes?.first?.isTransitional == false)
    }

    @Test func healthyProxyWithOnlineLanesIsNotDegraded() throws {
        let s = try snapshot("""
        {"generatedAt": 1, "hosts": [{"id": "studio", "name": "Studio", "state": "Online", "expectedLanes": 2,
          "cpuPerLane": 4, "memoryGiBPerLane": 8, "observedAt": 1, "runnerNames": [], "memoryUsage": [],
          "proxy": {"state": "running", "restarts": 0, "looping": false},
          "lanes": [{"name": "glowscript-studio-abcdef123", "container": false, "github": "unregistered", "busy": false, "memory": null, "job": null}]}]}
        """)
        // A just-finished JIT runner with no container is not a host fault.
        #expect(!s.hosts[0].isDegraded)
    }
}
