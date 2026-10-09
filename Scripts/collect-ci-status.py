#!/usr/bin/env python3
"""Read-only snapshots for Robert's three CI hosts. No job control.

Run once or install with install-ci-monitor.py. SSH uses the user's existing
host-key-verified identities in batch mode. GitHub state comes from the user's
existing `gh` login, read-only (runners, active runs, their jobs). The app reads
only the resulting JSON.

"Online" is GitHub's view of a runner, not whether its container exists: a
container can be Up for hours while GitHub has the runner offline (e.g. the
proxy it egresses through is in a restart loop). Both are recorded per lane so a
mismatch is visible, with a `phase` that separates a lane registering or tearing
down (younger than TRANSITION_GRACE) from one that is genuinely degraded. The
first-seen time lives in monitor-state.json, so the age is real across runs.
"""
import base64
import calendar
import concurrent.futures
import fcntl
import json
import os
from pathlib import Path
import shlex
import statistics
import subprocess
import sys
import time
import zlib

REPO = 'DistinctlyDeveloped/GlowScript'
GH = '/opt/homebrew/bin/gh'
GITHUB_INTERVAL = 55          # seconds between GitHub refreshes (collector runs every 30s)
OFFLINE_ALERT_AFTER = 600     # container up / registered but GitHub offline this long -> alert
# Every job runs in a fresh ephemeral container that registers on start and deregisters on exit, so
# a container/GitHub disagreement younger than this is a lane starting or stopping, not a fault. The
# GitHub view is itself cached up to GITHUB_INTERVAL and polled every 30s, so the window must exceed both.
TRANSITION_GRACE = 120
UNREACHABLE_ALERT_AFTER = 600
IDLE_WHILE_QUEUED_AFTER = 300
UNSERVABLE_AFTER = 600
MAX_OLDEST = 5
# GlowScript #2300: the MacBook supervisor (#2299) rewrites vm-state.json every 15s while the VM is not
# running. A non-running state older than this means the supervisor stopped writing, so it reads as unknown.
VM_STATE_FRESH = 300
VM_LABELS = {'stopped': 'VM down', 'starting': 'VM starting', 'broken': 'VM broken', 'held': 'VM held', 'unknown': 'VM unknown'}
# The MacBook supervisor rewrites disk-state.json at least every 30s (GlowScript #2323); older means it stopped.
DISK_STATE_FRESH = 300
GENERIC_LABELS = {'self-hosted', 'Linux', 'X64', 'ARM64', 'macOS', 'Windows'}

HOSTS = [
    {'id': 'studio', 'name': 'Studio', 'expectedLanes': 2, 'cpuPerLane': 4, 'memoryGiBPerLane': 8},
    {'id': 'simrig', 'name': 'SimRig', 'expectedLanes': 2, 'cpuPerLane': 6, 'memoryGiBPerLane': 24},
    {'id': 'macbook', 'name': 'MacBook', 'expectedLanes': 3, 'cpuPerLane': 4, 'memoryGiBPerLane': 8},
    # Dedicated Hostinger VPS (GlowScript #2093): slots 0-1 (4 CPUs / 12 GiB) plus slot 2, the
    # 1-CPU / 2-GiB main-push aggregate lane (GlowScript #2347), under the glowscript-hostinger unit.
    {'id': 'hostinger', 'name': 'Hostinger', 'expectedLanes': 3, 'cpuPerLane': 4, 'memoryGiBPerLane': 12},
]
# GlowScript #2347: main's push-run required aggregates request this label. The dedicated runner
# (Hostinger slot 2) carries it outside glowscript-pool; the light slots carry it as the fallback.
MAIN_AGGREGATE = 'glowscript-main-aggregate'

# Executed only by this collector on fixed, authorized hosts. Never provided by API data.
PROBE = r'''
import json, os, pathlib, subprocess, sys
host = sys.argv[1]
state = pathlib.Path.home() / 'glowscript-ci'
def command(args, timeout=8):
    r = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout
def vm_state():
    # Fails closed: anything but a well-formed file is 'unknown', which never classifies as healthy.
    import time
    try:
        value = json.loads((state / 'vm-state.json').read_text())
    except FileNotFoundError:
        return {'state': 'unknown', 'reason': 'missing'}
    except (OSError, ValueError):
        return {'state': 'unknown', 'reason': 'unreadable'}
    if not isinstance(value, dict) or value.get('state') not in ('running', 'stopped', 'starting', 'broken', 'held', 'unknown'):
        return {'state': 'unknown', 'reason': 'unrecognised'}
    # While running, the supervisor rewrites the file only on Docker activity, so its age means nothing.
    if value['state'] == 'running':
        return {'state': 'running'}
    checked = value.get('checked')
    if not isinstance(checked, (int, float)) or isinstance(checked, bool) or time.time() - checked > __VM_STATE_FRESH__:
        return {'state': 'unknown', 'reason': 'stale'}
    return {k: value[k] for k in ('state', 'since', 'checked', 'attempts', 'retry_at', 'action', 'markers') if k in value}
vm = vm_state() if host == 'macbook' else None
def disk_pause():
    # GlowScript #2323: the MacBook supervisor stops admitting below 30 GB free and says so here.
    try:
        import time
        value = json.loads((state / 'disk-state.json').read_text())
        if value.get('state') in ('low', 'unknown') and time.time() - value['checked'] <= __DISK_STATE_FRESH__:
            return {k: value.get(k) for k in ('state', 'free_bytes', 'resume_bytes', 'label', 'checked')}
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return None
disk = disk_pause() if host == 'macbook' else None
if host in ('simrig', 'hostinger'):
    docker = ['/usr/bin/docker']
    service = command(['systemctl', 'is-active', 'glowscript-' + host])[1].strip() == 'active'
else:
    docker = [str(state / 'docker')] if host == 'macbook' else ['/Applications/Docker.app/Contents/Resources/bin/docker']
    label = 'com.glowscript.macbook-ci' if host == 'macbook' else 'com.glowscript.ci-supervisor'
    code, status = command(['/bin/launchctl', 'print', 'gui/%d/%s' % (os.getuid(), label)])
    service = code == 0 and 'state = running' in status
code, output = command(docker + ['ps', '--filter', 'label=com.glowscript.ci=disposable', '--format', '{{.Names}}'])
if code != 0:
    print(json.dumps({'service': service, 'docker': False, 'paused': False, 'onAC': True, 'runnerNames': [], 'memoryUsage': [], 'memoryByName': {}, 'proxy': None, 'disk': disk, 'vm': vm}))
    sys.exit(0)
prefix = 'glowscript-' + host + '-'
names = [name for name in output.splitlines() if name.startswith(prefix)]
memory = {}
if names:
    try:
        code, stats = command(docker + ['stats', '--no-stream', '--format', '{{.Name}}\t{{.MemUsage}}'] + names, timeout=6)
        if code == 0:
            for line in stats.splitlines():
                name, _, usage = line.partition('\t')
                memory[name] = usage.split(' / ')[0]
    except subprocess.TimeoutExpired: pass
proxy = {'state': 'missing', 'restarts': 0}
code, inspect = command(docker + ['inspect', 'glowscript-ci-proxy', '--format', '{{.State.Status}} {{.RestartCount}}'])
if code == 0 and inspect.split():
    parts = inspect.split()
    proxy = {'state': parts[0], 'restarts': int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0}
on_ac = True
if host == 'macbook':
    code, power = command(['/usr/bin/pmset', '-g', 'batt'])
    on_ac = code == 0 and 'AC Power' in power
paused = (state / 'PAUSED').exists() if host != 'studio' else False
print(json.dumps({'service': service, 'docker': True, 'paused': paused, 'onAC': on_ac, 'runnerNames': names,
                  'memoryUsage': [memory.get(n, '') for n in names], 'memoryByName': memory, 'proxy': proxy,
                  'disk': disk, 'vm': vm}))
'''.replace('__DISK_STATE_FRESH__', str(DISK_STATE_FRESH)).replace('__VM_STATE_FRESH__', str(VM_STATE_FRESH))


def classify(probe):
    if not probe['service']: return 'Stopped'
    vm = probe.get('vm')
    if vm and vm.get('state') != 'running': return VM_LABELS.get(vm.get('state'), VM_LABELS['unknown'])
    if not probe['docker']: return 'Docker unavailable'
    # Low disk first: it needs action, while PAUSED is a deliberate operator choice.
    if probe.get('disk'):
        reason = 'low disk' if probe['disk'].get('state') == 'low' else 'disk unreadable'
        return ('Draining: ' if probe['runnerNames'] else 'Paused: ') + reason
    if probe['paused']: return 'Draining' if probe['runnerNames'] else 'Paused'
    if not probe['onAC']: return 'Draining on battery' if probe['runnerNames'] else 'On battery'
    return 'Online' if probe['runnerNames'] else 'Ready'


def collect(host):
    result = dict(host, observedAt=time.time(), runnerNames=[], memoryUsage=[])
    try:
        if host['id'] == 'macbook':
            args = ['/usr/bin/python3', '-c', PROBE, 'macbook']
            data = subprocess.check_output(args, timeout=20, stderr=subprocess.DEVNULL)
        else:
            # 'bobs-mac-studio' resolves over Tailscale MagicDNS; the .local mDNS name only works on the same LAN.
            target = 'bobbuilder@bobs-mac-studio' if host['id'] == 'studio' else 'rober@100.121.29.119'
            # Compressed: SimRig's OpenSSH runs under cmd.exe, whose command line caps at 8,191 characters.
            payload = base64.b64encode(zlib.compress(PROBE.encode(), 9)).decode()
            python = "import base64,sys,zlib;sys.argv=['probe',%r];exec(zlib.decompress(base64.b64decode(%r)))" % (host['id'], payload)
            if host['id'] == 'studio':
                remote = '/usr/bin/env DEVELOPER_DIR=/Library/Developer/CommandLineTools /usr/bin/python3 -c ' + shlex.quote(python)
            elif host['id'] == 'hostinger':
                # The supervisor and its state run as root on the VPS (/root/glowscript-ci).
                target = 'root@82.180.163.60'
                remote = '/usr/bin/python3 -c ' + shlex.quote(python)
            else:
                # Listing running distros does not start one. Never wake a stopped CI VM just to monitor it.
                stopped = json.dumps({'service': False, 'docker': False, 'paused': False, 'onAC': True, 'runnerNames': [], 'memoryUsage': []})
                ps = "$names = @(& wsl.exe --list --running --quiet | ForEach-Object { ($_ -replace \"`0\", '').Trim() }); "
                ps += "if ($names -notcontains 'GlowScript-CI') { Write-Output '" + stopped + "'; exit 0 }; "
                ps += "& wsl.exe -d GlowScript-CI -u root --exec /usr/bin/python3 -c '" + python.replace("'", "''") + "'"
                remote = 'powershell.exe -NoProfile -EncodedCommand ' + base64.b64encode(ps.encode('utf-16le')).decode()
            args = ['/usr/bin/ssh', '-o', 'BatchMode=yes', '-o', 'ForwardAgent=no', '-o', 'ForwardX11=no', '-o', 'ClearAllForwardings=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=5', '-o', 'ConnectionAttempts=1', target, remote]
            data = subprocess.check_output(args, timeout=22, stderr=subprocess.DEVNULL)
        probe = json.loads(data)
        result.update(state=classify(probe), runnerNames=probe['runnerNames'], memoryUsage=probe['memoryUsage'],
                      memoryByName=probe.get('memoryByName', {}), proxy=probe.get('proxy'), disk=probe.get('disk'), vm=probe.get('vm'))
    except (subprocess.SubprocessError, OSError, ValueError, KeyError):
        result['state'] = 'Unreachable'
    return result


# ---------------------------------------------------------------- GitHub (read-only)

def gh_api(path):
    out = subprocess.check_output([GH, 'api', path], timeout=20, stderr=subprocess.DEVNULL,
                                  env={'HOME': str(Path.home()), 'PATH': '/usr/bin:/bin'})
    return json.loads(out)


def parse_time(value):
    if not value: return None
    return calendar.timegm(time.strptime(value, '%Y-%m-%dT%H:%M:%SZ'))


def fetch_main_aggregate_routing():
    """Use evaluated main-push job labels, never labels advertised by runners.

    A previous revision's run cannot establish current routing. Missing/skipped
    jobs remain unknown until Actions exposes their evaluated runs-on labels.
    """
    evidence = []
    try:
        sha = gh_api('repos/%s/commits/main' % REPO)['sha']
        for workflow, name in (('test.yml', 'Vitest'), ('typecheck.yml', 'TypeScript & Lint')):
            runs = gh_api('repos/%s/actions/workflows/%s/runs?branch=main&event=push&per_page=1'
                          % (REPO, workflow))['workflow_runs']
            if not runs or runs[0]['head_sha'] != sha:
                continue
            run = runs[0]
            if run.get('event') != 'push' or run.get('head_branch') != 'main':
                continue
            jobs = gh_api('repos/%s/actions/runs/%d/jobs?per_page=100&filter=latest'
                          % (REPO, run['id']))['jobs']
            matches = [j for j in jobs if j['name'] == name]
            if len(matches) == 1 and matches[0].get('labels'):
                evidence.append({'workflow': workflow, 'name': name, 'runID': run['id'],
                                 'labels': matches[0]['labels']})
        complete = len(evidence) == 2
        enabled = complete and any(MAIN_AGGREGATE in j['labels'] for j in evidence)
        return {'state': 'enabled' if enabled else 'disabled' if complete else 'unknown',
                'headSHA': sha, 'jobs': evidence}
    except (subprocess.SubprocessError, OSError, ValueError, KeyError) as error:
        # A partial fetch is not evidence of disabled routing or healthy capacity.
        return {'state': 'unknown', 'jobs': [], 'reason': 'Routing unavailable (%s)' % type(error).__name__}


def fetch_github():
    runners = gh_api('repos/%s/actions/runners?per_page=100' % REPO)['runners']
    runs = {}
    for status in ('queued', 'in_progress', 'pending', 'waiting'):
        for run in gh_api('repos/%s/actions/runs?status=%s&per_page=100' % (REPO, status))['workflow_runs']:
            runs[run['id']] = run
    jobs = []
    for run in runs.values():
        for job in gh_api('repos/%s/actions/runs/%d/jobs?per_page=100&filter=latest' % (REPO, run['id']))['jobs']:
            if job['status'] == 'completed': continue
            prs = run.get('pull_requests') or []
            jobs.append({'name': job['name'], 'status': job['status'], 'labels': job.get('labels') or [],
                         'runner': job.get('runner_name') or '', 'createdAt': parse_time(job.get('created_at')),
                         'startedAt': parse_time(job.get('started_at')), 'url': job.get('html_url'),
                         'branch': run.get('head_branch'), 'pr': prs[0]['number'] if prs else None,
                         'workflow': run.get('name')})
    return {'fetchedAt': time.time(),
            'runners': [{'name': r['name'], 'status': r['status'], 'busy': r['busy'],
                         'labels': [l['name'] for l in r['labels']]} for r in runners],
            'jobs': jobs, 'mainAggregateRouting': fetch_main_aggregate_routing()}


def github_snapshot(directory, fetch=fetch_github, now=None):
    """Cached so the 30s collector hits GitHub at most once a minute."""
    now = now or time.time()
    cache = directory / 'github-cache.json'
    try:
        cached = json.loads(cache.read_text())
        if now - cached['fetchedAt'] < GITHUB_INTERVAL: return cached, None
    except (OSError, ValueError, KeyError):
        cached = None
    try:
        fresh = fetch()
        write_json(cache, fresh)
        return fresh, None
    except (subprocess.SubprocessError, OSError, ValueError, KeyError) as error:
        return cached, 'GitHub unavailable (%s)' % type(error).__name__


# ---------------------------------------------------------------- analysis

def host_of(runner_name):
    for host in HOSTS:
        if runner_name.startswith('glowscript-%s-' % host['id']): return host['id']
    return None


def can_run(runner_labels, job_labels):
    return set(job_labels) <= set(runner_labels)


def is_hosted(labels):
    return 'self-hosted' not in labels


def lane_phase(container, mismatch_age):
    """How to read a lane whose container and GitHub registration disagree.

    'starting': container up, GitHub has not registered it yet (or not online yet).
    'stopping': container gone, GitHub still lists the runner (and maybe its job).
    After TRANSITION_GRACE it is no longer a handover:
    'degraded': container up but GitHub still cannot hand it work -- a host fault.
    'orphaned': no container, GitHub keeps a stale offline registration. Not a host fault; GitHub
                expires these on its own schedule, which can take hours.
    The age must come from a first-seen time persisted across collector runs; one poll proves nothing.
    """
    if mismatch_age < TRANSITION_GRACE: return 'starting' if container else 'stopping'
    return 'degraded' if container else 'orphaned'


def analyze(hosts, github, state, now, github_error=None):
    """Adds lanes/pools per host, a queue summary and alerts. Mutates `state` (persisted between runs)."""
    runners = {r['name']: r for r in (github or {}).get('runners', [])}
    jobs = (github or {}).get('jobs', [])
    running = {j['runner']: j for j in jobs if j['status'] == 'in_progress' and j['runner']}
    seen_since = state.setdefault('mismatchSince', {})
    live_keys = set()
    alerts = []

    def alert(key, message, since):
        live_keys.add(key)
        alerts.append({'key': key, 'message': message, 'since': since})

    for host in hosts:
        containers = host.get('runnerNames', [])
        memory = host.get('memoryByName', {})
        names = list(containers) + sorted(n for n in runners if host_of(n) == host['id'] and n not in containers)
        vm = host.get('vm') or {}
        if vm.get('state') not in (None, 'running', 'unknown'):
            # The VM is down: GitHub's rows for it are stale registrations, not lanes. One host alert below.
            names = []
        lanes = []
        for name in names:
            runner = runners.get(name)
            github_state = 'unknown' if github is None else ('unregistered' if runner is None else runner['status'])
            job = running.get(name)
            lane = {'name': name, 'container': name in containers, 'github': github_state,
                    'busy': bool(runner and runner['busy']), 'memory': memory.get(name),
                    'job': None if not job else {k: job[k] for k in ('name', 'branch', 'pr', 'startedAt', 'url', 'workflow')},
                    'phase': None, 'mismatchSince': None}
            lanes.append(lane)
            mismatch = github is not None and github_state != 'online'
            if mismatch:
                key = 'lane:%s' % name
                since = seen_since.setdefault(key, now)
                lane['mismatchSince'] = since
                lane['phase'] = lane_phase(name in containers, now - since)
                if now - since >= OFFLINE_ALERT_AFTER:
                    where = 'container up but ' if name in containers else ''
                    alert(key, '%s: %s%s is %s on GitHub for %dm' % (host['name'], where, name, github_state, (now - since) // 60), since)
                else:
                    live_keys.add(key)
        host['lanes'] = lanes
        pools = set()
        for name in names:
            if name in runners: pools |= set(runners[name]['labels'])
        host['pools'] = sorted(l for l in pools - GENERIC_LABELS if '-slot-' not in l)

        proxy = host.get('proxy')
        if proxy:
            previous = state.setdefault('proxyRestarts', {}).get(host['id'])
            looping = proxy['state'] == 'restarting' or (previous is not None and proxy['restarts'] > previous)
            proxy['looping'] = looping
            state['proxyRestarts'][host['id']] = proxy['restarts']
            if looping or (proxy['state'] != 'running' and containers):
                key = 'proxy:%s' % host['id']
                since = seen_since.setdefault(key, now)
                alert(key, '%s: CI proxy is %s (%d restarts); its runners cannot reach GitHub'
                      % (host['name'], 'in a restart loop' if looping else proxy['state'], proxy['restarts']), since)

        disk = host.get('disk')
        if disk:
            # No delay: admission is already closed, and a full Mac disk stops the VM (GlowScript #2323).
            key = 'disk:%s' % host['id']
            since = seen_since.setdefault(key, now)
            if disk.get('state') == 'low' and isinstance(disk.get('free_bytes'), int):
                detail = ' (%.1f GB free; admission reopens at %d GB)' % (
                    disk['free_bytes'] / 1e9, (disk.get('resume_bytes') or 0) // 10**9)
            else:
                detail = ''
            alert(key, '%s%s' % (disk.get('label') or '%s paused: low disk' % host['name'], detail), since)

        if host['state'] in ('Unreachable', 'Stopped', 'Docker unavailable') or host['state'] in VM_LABELS.values():
            key = 'host:%s' % host['id']
            since = seen_since.setdefault(key, now)
            if now - since >= UNREACHABLE_ALERT_AFTER:
                minutes = (now - since) // 60
                if host['state'] in VM_LABELS.values():
                    detail = vm.get('action') and ': %s' % vm['action'] or (
                        vm.get('reason') and ' (vm-state.json %s)' % vm['reason'] or '')
                    alert(key, '%s %s for %dm%s' % (host['name'], host['state'], minutes, detail), since)
                else:
                    alert(key, '%s is %s for %dm' % (host['name'], host['state'].lower(), minutes), since)
            else:
                live_keys.add(key)

    queue = None
    if github is not None:
        queued = [j for j in jobs if j['status'] != 'in_progress']
        self_hosted = [j for j in queued if not is_hosted(j['labels'])]
        waits = sorted(now - j['createdAt'] for j in self_hosted if j['createdAt'] is not None)
        online = [r for r in runners.values() if r['status'] == 'online']
        idle = [r for r in online if not r['busy']]
        idle_eligible = [r for r in idle if any(can_run(r['labels'], j['labels']) for j in self_hosted)]
        unservable = [j for j in self_hosted if not any(can_run(r['labels'], j['labels']) for r in online)]
        oldest = sorted(self_hosted, key=lambda j: now if j['createdAt'] is None else j['createdAt'])[:MAX_OLDEST]
        queue = {'queued': len(self_hosted), 'hosted': len(queued) - len(self_hosted),
                 'running': len(running), 'oldestWaitSec': int(waits[-1]) if waits else 0,
                 'medianWaitSec': int(statistics.median(waits)) if waits else 0,
                 'idleRunners': len(idle), 'idleEligible': len(idle_eligible),
                 'unservable': len(unservable),
                 'unservableLabels': sorted({l for j in unservable for l in j['labels']} - GENERIC_LABELS),
                 'oldest': [{'name': j['name'], 'workflow': j['workflow'], 'branch': j['branch'], 'pr': j['pr'],
                             'waitSec': 0 if j['createdAt'] is None else int(now - j['createdAt']), 'url': j['url']} for j in oldest]}
        carriers = [r for r in runners.values() if MAIN_AGGREGATE in r['labels']]
        dedicated = [r for r in carriers if 'glowscript-pool' not in r['labels']]
        routing = (github.get('mainAggregateRouting') or {'state': 'unknown', 'jobs': []})
        if github_error:
            routing = {'state': 'unknown', 'jobs': [], 'reason': github_error}
        requests = [j['labels'] for j in routing.get('jobs', []) if MAIN_AGGREGATE in j['labels']]
        fallback_online = sum(1 for r in runners.values() if 'glowscript-light' in r['labels'] and r['status'] == 'online')
        qualified = all(any(r['status'] == 'online' and can_run(r['labels'], labels)
                            for r in dedicated) for labels in requests)
        routing_state = routing['state']
        if routing_state == 'disabled':
            message = 'Main-aggregate: dedicated lane not enabled yet (fallback: %d light runner(s))' % fallback_online
        elif routing_state == 'enabled' and requests:
            message = 'Main-aggregate: dedicated lane enabled; %s' % ('qualified dedicated runner online' if qualified else 'no qualified dedicated runner online')
        else:
            routing_state = 'unknown'
            message = 'Main-aggregate: routing/capacity unknown; %s' % routing.get('reason', 'awaiting current main aggregate job labels')
        queue['mainAggregate'] = {
            'dedicated': [{'name': r['name'], 'status': r['status'], 'busy': r['busy']} for r in dedicated],
            'fallbackOnline': fallback_online, 'routingState': routing_state,
            'message': message, 'routingEvidence': routing}
        if routing_state == 'enabled' and requests and not qualified:
            # The slot re-registers after every job; only a lasting gap means main's aggregates
            # are back to queueing behind PR light jobs.
            key = 'lane:main-aggregate'
            since = seen_since.setdefault(key, now)
            if now - since >= OFFLINE_ALERT_AFTER:
                fallback_qualified = sum(1 for r in carriers if 'glowscript-pool' in r['labels'] and r['status'] == 'online'
                                         and all(can_run(r['labels'], labels) for labels in requests))
                alert(key, 'Main-aggregate lane: no qualified dedicated runner online for %dm; %d qualified fallback runner(s) online'
                      % ((now - since) // 60, fallback_qualified), since)
            else:
                live_keys.add(key)
        for host in hosts:
            mine = [r for r in online if host_of(r['name']) == host['id']]
            host['eligibleQueued'] = sum(1 for j in self_hosted if any(can_run(r['labels'], j['labels']) for r in mine))
        if idle_eligible and waits:
            key = 'queue:idle'
            since = seen_since.setdefault(key, now)
            if now - since >= IDLE_WHILE_QUEUED_AFTER:
                alert(key, '%d runner(s) idle while %d job(s) they could run are queued' % (len(idle_eligible), len(self_hosted)), since)
            else:
                live_keys.add(key)
        if unservable:
            key = 'queue:unservable'
            since = seen_since.setdefault(key, now)
            if now - since >= UNSERVABLE_AFTER:
                alert(key, '%d queued job(s) need %s; no online runner has those labels'
                      % (len(unservable), ', '.join(queue['unservableLabels']) or 'labels'), since)
            else:
                live_keys.add(key)

    for key in list(seen_since):
        if key not in live_keys: del seen_since[key]
    return queue, alerts


def notify(alerts, state):
    """Attempt a macOS notification once per newly raised alert, even if delivery fails."""
    announced = set(state.get('announced', []))
    for item in alerts:
        if item['key'] in announced: continue
        script = 'display notification %s with title "GlowScript CI"' % json.dumps(item['message'])
        try:
            subprocess.run(['/usr/bin/osascript', '-e', script], timeout=5, capture_output=True)
        except (subprocess.SubprocessError, OSError) as error:
            # Notification delivery must not prevent snapshot/state persistence. Do not log payloads.
            print('Notification unavailable (%s)' % type(error).__name__, file=sys.stderr)
    state['announced'] = sorted(a['key'] for a in alerts)


def write_json(path, value):
    temporary = path.with_name('%s.%d.tmp' % (path.name, os.getpid()))
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as output:
        json.dump(value, output, indent=2)
        output.write('\n')
    os.replace(temporary, path)


def main():
    directory = Path.home() / 'Library/Application Support/Octowatch'
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (directory / 'collector.lock').open('w') as lock:
        try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: return
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
            hosts = list(pool.map(collect, HOSTS))
        github, github_error = github_snapshot(directory)
        state_path = directory / 'monitor-state.json'
        try: state = json.loads(state_path.read_text())
        except (OSError, ValueError): state = {}
        now = time.time()
        queue, alerts = analyze(hosts, github, state, now, github_error=github_error)
        for host in hosts: host.pop('memoryByName', None)
        if '--no-notify' not in sys.argv: notify(alerts, state)
        write_json(state_path, state)
        snapshot = {'generatedAt': now, 'hosts': hosts, 'queue': queue, 'alerts': alerts,
                    'githubObservedAt': github['fetchedAt'] if github else None, 'githubError': github_error}
        write_json(directory / 'ci-status.json', snapshot)
        if '--print' in sys.argv: print(json.dumps(snapshot, indent=2))


if __name__ == '__main__': main()
