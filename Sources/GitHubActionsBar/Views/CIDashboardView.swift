import SwiftUI

struct CIDashboardView: View {
    @Bindable var viewModel: WorkflowViewModel
    @State private var runFilter = "All branches"
    @State private var jobFilter = "Active"

    private var filteredRuns: [WorkflowRun] {
        switch runFilter {
        case "Main": return viewModel.runs.filter { run in
            let branch = viewModel.repos.first { $0.fullName == run.repository?.fullName }?.defaultBranch ?? "main"
            return run.headBranch == branch
        }
        case "Pull requests": return viewModel.runs.filter { $0.event == "pull_request" || !($0.pullRequests ?? []).isEmpty }
        default: return viewModel.runs
        }
    }
    private var shownJobs: [TrackedCIJob] {
        viewModel.trackedJobs.filter { item in
            switch jobFilter {
            case "Failures": return ["failure", "timed_out", "startup_failure"].contains(item.job.conclusion ?? "")
            case "All": return true
            default: return item.job.isActive
            }
        }.sorted { ($0.job.startedAt ?? .distantPast) > ($1.job.startedAt ?? .distantPast) }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { clock in
            VStack(spacing: 0) {
                overview(now: clock.date)
                Divider()
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        sectionHeader("Workflows", count: filteredRuns.count)
                        Picker("Workflow filter", selection: $runFilter) {
                            ForEach(["All branches", "Main", "Pull requests"], id: \.self) { Text($0) }
                        }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 16).padding(.bottom, 10)
                        WorkflowRunListView(runs: filteredRuns, isLoading: viewModel.isLoading)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    VStack(alignment: .leading, spacing: 0) {
                        sectionHeader("Jobs", count: shownJobs.count)
                        Picker("Job filter", selection: $jobFilter) {
                            ForEach(["Active", "Failures", "All"], id: \.self) { Text($0) }
                        }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 16).padding(.bottom, 10)
                        Text(viewModel.jobsError ?? "Details from \(viewModel.detailedRunCount) recent runs · refreshed \(age(viewModel.lastJobsRefresh, now: clock.date))\(viewModel.jobsTruncated ? " · partial job list" : "")")
                            .font(.caption2).foregroundStyle(viewModel.jobsError == nil ? Color.secondary : Color.orange)
                            .padding(.horizontal, 16).padding(.bottom, 6)
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                if shownJobs.isEmpty {
                                    Text(viewModel.lastJobsRefresh == nil ? "Waiting for job details…" : "No matching jobs in this snapshot")
                                        .font(.callout).foregroundStyle(.secondary).padding(24)
                                }
                                ForEach(shownJobs) { item in
                                    jobRow(item, now: clock.date)
                                    Divider().padding(.horizontal, 16)
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).font(.headline)
            Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
        }.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
    }

    private func overview(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("Local CI", systemImage: "server.rack").font(.headline)
                Spacer()
                Text("GitHub updated \(age(viewModel.lastRefresh, now: now))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let snapshot = viewModel.localSnapshot {
                let stale = snapshot.isStale(at: now) || viewModel.localStatusError != nil
                if !stale && !snapshot.activeAlerts.isEmpty { alertBanner(snapshot.activeAlerts, now: now) }
                HStack(alignment: .top, spacing: 10) {
                    ForEach(snapshot.hosts) { host in hostCard(host, stale: stale, now: now) }
                }
                if stale {
                    Label("Host snapshot is stale. Current availability is unknown.", systemImage: "exclamationmark.clock")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let error = snapshot.githubError {
                    Label("\(error). Runner status and queue may be out of date.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let queue = snapshot.queue, !stale { queueStrip(queue, observedAt: snapshot.githubObservedAt, now: now) }
                else { sampledMetrics(now: now) }
            } else {
                Label("Host monitoring has not reported yet. GitHub job details are available below.", systemImage: "network")
                    .font(.callout).foregroundStyle(.secondary)
                sampledMetrics(now: now)
            }
        }.padding(16)
    }

    private func alertBanner(_ alerts: [CIAlert], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(alerts) { alert in
                Label(alert.message, systemImage: "exclamationmark.octagon.fill")
                    .font(.callout.weight(.medium)).foregroundStyle(.red)
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Whole-queue numbers from the collector: every waiting self-hosted job, not a sample.
    private func queueStrip(_ queue: CIQueue, observedAt: Double?, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 20) {
                metric("Running", queue.running)
                metric("Queued", queue.queued, warn: queue.queued > 0 && queue.medianWaitSec > 900)
                duration("Oldest wait", queue.oldestWaitSec, warn: queue.oldestWaitSec > 1800)
                duration("Median wait", queue.medianWaitSec, warn: queue.medianWaitSec > 900)
                metric("Idle runners", queue.idleRunners)
                Spacer()
                Text("All active runs\(observedAt.map { " · \(age(Date(timeIntervalSince1970: $0), now: now))" } ?? "")\(queue.hosted > 0 ? " · +\(queue.hosted) GitHub-hosted" : "")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if queue.idleEligible > 0 {
                Label("\(queue.idleEligible) idle runner(s) could take queued work", systemImage: "hourglass")
                    .font(.caption).foregroundStyle(.orange)
            }
            if queue.unservable > 0 {
                Label("\(queue.unservable) queued job(s) need \(queue.unservableLabels.joined(separator: ", ")); no online runner has them",
                      systemImage: "nosign").font(.caption).foregroundStyle(.orange)
            }
            if !queue.oldest.isEmpty {
                Text("Waiting longest: " + queue.oldest.prefix(3).map { job in
                    "\(job.name) (\(job.pr.map { "#\($0)" } ?? job.branch ?? "?"), \(minutes(job.waitSec)))"
                }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func sampledMetrics(now: Date) -> some View {
        HStack(spacing: 20) {
            metric("Running jobs", viewModel.trackedJobs.filter { $0.job.status == "in_progress" }.count)
            metric("Queued / waiting", viewModel.trackedJobs.filter { $0.job.isActive && $0.job.status != "in_progress" }.count)
            metric("Recent failures", viewModel.trackedJobs.filter { ["failure", "timed_out", "startup_failure"].contains($0.job.conclusion ?? "") }.count)
            Spacer()
            Text("Sampled from \(viewModel.detailedRunCount) recent runs\(viewModel.jobsError != nil || now.timeIntervalSince(viewModel.lastJobsRefresh ?? .distantPast) > 90 ? " · stale" : "")")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func metric(_ label: String, _ count: Int, warn: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("\(count)").font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(warn ? Color.orange : Color.primary)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func duration(_ label: String, _ seconds: Int, warn: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(minutes(seconds)).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(warn ? Color.orange : Color.primary)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func minutes(_ seconds: Int) -> String {
        seconds >= 3600 ? "\(seconds / 3600)h \((seconds % 3600) / 60)m" : "\(seconds / 60)m"
    }

    private func hostCard(_ host: CIHost, stale: Bool, now: Date) -> some View {
        let unreachable = stale || host.state == "Unreachable"
        let label = stale ? "Stale" : (host.isDegraded ? "Degraded" : host.state)
        let alarming = stale || host.isDegraded || ["Unreachable", "Stopped", "Docker unavailable"].contains(host.state)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: host.id == "macbook" ? "laptopcomputer" : "desktopcomputer")
                Text(host.name).font(.subheadline.weight(.semibold))
                Spacer()
                Text(label).font(.caption.weight(.medium))
                    .foregroundStyle(host.isDegraded && !stale ? Color.red : (alarming ? Color.orange : Color.secondary))
            }
            Text("\(unreachable ? "—" : String(host.onlineLanes)) / \(host.expectedLanes) lanes online\(host.lanes == nil ? " (containers)" : "")")
                .font(.callout.monospacedDigit())
            if let proxy = host.proxy, !unreachable {
                Text(proxy.isHealthy ? "Proxy running" : "Proxy \(proxy.looping == true ? "restart loop" : proxy.state) · \(proxy.restarts) restarts")
                    .font(.caption).foregroundStyle(proxy.isHealthy ? Color.secondary : Color.red)
            }
            if let lanes = host.lanes, !unreachable {
                ForEach(lanes) { lane in laneRow(lane, now: now) }
            } else {
                Text(host.runnerNames.isEmpty ? "No runner containers observed" : "Lane detail not reported yet")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let eligible = host.eligibleQueued, let queued = viewModel.localSnapshot?.queue?.queued, queued > 0, !unreachable {
                Text(eligible == 0 ? "Can take none of the \(queued) queued jobs" : "Can take \(eligible) of \(queued) queued jobs")
                    .font(.caption).foregroundStyle(eligible == 0 ? Color.orange : Color.secondary)
            }
            if let pools = host.pools, !pools.isEmpty {
                Text("Serves: " + pools.joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            Text("Each: \(host.cpuPerLane) CPUs · \(host.memoryGiBPerLane) GiB limit")
                .font(.caption2).foregroundStyle(.tertiary)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(host.isDegraded && !stale ? Color.red.opacity(0.5) : Color.primary.opacity(0.08)))
    }

    private func laneRow(_ lane: CILane, now: Date) -> some View {
        let status: (String, Color) = {
            if lane.isMismatched && lane.container { return ("container up · GitHub \(lane.github)", .red) }
            if lane.isMismatched { return ("GitHub \(lane.github)", .orange) }
            if lane.github == "unknown" { return ("GitHub status unknown", .secondary) }
            return (lane.busy ? "busy" : "idle", lane.busy ? .green : .secondary)
        }()
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(status.1).frame(width: 7, height: 7)
            Text(lane.shortName).font(.caption.monospacedDigit().weight(.medium))
            if let job = lane.job {
                Text("\(job.name)\(job.pr.map { " · #\($0)" } ?? "")").font(.caption).lineLimit(1)
                Spacer(minLength: 4)
                if let start = job.startedAt {
                    Text("\(max(0, Int(now.timeIntervalSince1970 - start) / 60))m").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            } else {
                Text(status.0).font(.caption).foregroundStyle(status.1 == .secondary ? Color.secondary : status.1)
                Spacer(minLength: 4)
            }
            if let memory = lane.memory, !memory.isEmpty {
                Text(memory).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }.help(lane.name)
    }

    private func jobRow(_ item: TrackedCIJob, now: Date) -> some View {
        Button {
            if let url = URL(string: item.job.htmlUrl ?? item.run.htmlUrl), url.scheme == "https", url.host == "github.com" {
                NSWorkspace.shared.open(url)
            }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: item.job.status == "completed" ? (item.job.conclusion == "success" ? "checkmark.circle" : "minus.circle") : "clock")
                        .foregroundStyle(item.job.conclusion == "failure" ? Color.red : Color.secondary)
                    Text(item.job.name).font(.callout.weight(.medium)).lineLimit(1)
                    Spacer()
                    Text(item.job.location).font(.caption.weight(.medium))
                }
                Text([item.run.repository?.fullName, item.run.headBranch, item.run.headSha.map { String($0.prefix(7)) }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack {
                    Text(item.job.currentStep ?? item.job.conclusion ?? item.job.status.replacingOccurrences(of: "_", with: " "))
                        .lineLimit(1)
                    Spacer()
                    if item.job.status == "in_progress", let start = item.job.startedAt {
                        Text("\(max(0, Int(now.timeIntervalSince(start) / 60)))m elapsed").monospacedDigit()
                    }
                }.font(.caption2).foregroundStyle(.secondary)
            }.padding(.horizontal, 16).padding(.vertical, 10).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func age(_ date: Date?, now: Date) -> String {
        guard let date else { return "never" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        return seconds < 60 ? "\(seconds)s ago" : "\(seconds / 60)m ago"
    }
}
