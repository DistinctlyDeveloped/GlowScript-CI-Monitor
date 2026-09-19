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
                HStack(alignment: .top, spacing: 10) {
                    ForEach(snapshot.hosts) { host in hostCard(host, stale: snapshot.isStale(at: now) || viewModel.localStatusError != nil) }
                }
                if snapshot.isStale(at: now) || viewModel.localStatusError != nil {
                    Label("Host snapshot is stale. Current availability is unknown.", systemImage: "exclamationmark.clock")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else {
                Label("Host monitoring has not reported yet. GitHub job details are available below.", systemImage: "network")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 20) {
                metric("Running jobs", viewModel.trackedJobs.filter { $0.job.status == "in_progress" }.count)
                metric("Queued / waiting", viewModel.trackedJobs.filter { $0.job.isActive && $0.job.status != "in_progress" }.count)
                metric("Recent failures", viewModel.trackedJobs.filter { ["failure", "timed_out", "startup_failure"].contains($0.job.conclusion ?? "") }.count)
                Spacer()
                Text("Sampled job details\(viewModel.jobsError != nil || now.timeIntervalSince(viewModel.lastJobsRefresh ?? .distantPast) > 90 ? " · stale" : "")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(16)
    }

    private func metric(_ label: String, _ count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(viewModel.lastJobsRefresh == nil ? "—" : "\(count)").font(.title3.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func hostCard(_ host: CIHost, stale: Bool) -> some View {
        let jobs = viewModel.trackedJobs.filter { $0.job.status == "in_progress" && $0.job.location == host.name }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: host.id == "macbook" ? "laptopcomputer" : "desktopcomputer")
                Text(host.name).font(.subheadline.weight(.semibold))
                Spacer()
                Text(stale ? "Stale" : host.state).font(.caption.weight(.medium))
                    .foregroundStyle(stale || host.state == "Unreachable" || host.state == "Stopped" ? Color.orange : Color.secondary)
            }
            Text("\(stale || host.state == "Unreachable" ? "—" : String(host.runnerNames.count)) / \(host.expectedLanes) lanes present")
                .font(.callout.monospacedDigit())
            Text("Each: \(host.cpuPerLane) CPUs · \(host.memoryGiBPerLane) GiB limit")
                .font(.caption).foregroundStyle(.secondary)
            if !host.memoryUsage.isEmpty {
                Text("Memory: " + host.memoryUsage.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(jobs.first?.job.name ?? (host.runnerNames.isEmpty ? "No runner containers observed" : "Waiting for assignment details"))
                .font(.caption).lineLimit(1)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.08)))
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
