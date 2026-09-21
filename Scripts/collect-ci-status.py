#!/usr/bin/env python3
"""Read-only snapshots for Robert's three CI hosts. No GitHub tokens or job control.

Run once or install with install-ci-monitor.py. SSH uses the user's existing
host-key-verified identities in batch mode. The app reads only the resulting JSON.
"""
import base64
import concurrent.futures
import fcntl
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import time

HOSTS = [
    {'id': 'studio', 'name': 'Studio', 'expectedLanes': 2, 'cpuPerLane': 4, 'memoryGiBPerLane': 8},
    {'id': 'simrig', 'name': 'SimRig', 'expectedLanes': 1, 'cpuPerLane': 4, 'memoryGiBPerLane': 16},
    {'id': 'macbook', 'name': 'MacBook', 'expectedLanes': 3, 'cpuPerLane': 4, 'memoryGiBPerLane': 8},
]

# Executed only by this collector on fixed, authorized hosts. Never provided by API data.
PROBE = r'''
import json, os, pathlib, subprocess, sys
host = sys.argv[1]
state = pathlib.Path.home() / 'glowscript-ci'
def command(args, timeout=8):
    r = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout
if host == 'simrig':
    docker = ['/usr/bin/docker']
    service = command(['systemctl', 'is-active', 'glowscript-simrig'])[1].strip() == 'active'
else:
    docker = [str(state / 'docker')] if host == 'macbook' else ['/Applications/Docker.app/Contents/Resources/bin/docker']
    label = 'com.glowscript.macbook-ci' if host == 'macbook' else 'com.glowscript.ci-supervisor'
    code, status = command(['/bin/launchctl', 'print', 'gui/%d/%s' % (os.getuid(), label)])
    service = code == 0 and 'state = running' in status
code, output = command(docker + ['ps', '--filter', 'label=com.glowscript.ci=disposable', '--format', '{{.Names}}'])
if code != 0:
    print(json.dumps({'service': service, 'docker': False, 'paused': False, 'onAC': True, 'runnerNames': [], 'memoryUsage': []}))
    sys.exit(0)
prefix = 'glowscript-' + host + '-'
names = [name for name in output.splitlines() if name.startswith(prefix)]
usage = []
if names:
    try:
        code, stats = command(docker + ['stats', '--no-stream', '--format', '{{.MemUsage}}'] + names, timeout=6)
        if code == 0: usage = [line.split(' / ')[0] for line in stats.splitlines()][:2]
    except subprocess.TimeoutExpired: pass
on_ac = True
if host == 'macbook':
    code, power = command(['/usr/bin/pmset', '-g', 'batt'])
    on_ac = code == 0 and 'AC Power' in power
paused = (state / 'PAUSED').exists() if host != 'studio' else False
print(json.dumps({'service': service, 'docker': True, 'paused': paused, 'onAC': on_ac, 'runnerNames': names, 'memoryUsage': usage}))
'''


def classify(probe):
    if not probe['service']: return 'Stopped'
    if not probe['docker']: return 'Docker unavailable'
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
            payload = base64.b64encode(PROBE.encode()).decode()
            python = "import base64,sys;sys.argv=['probe',%r];exec(base64.b64decode(%r))" % (host['id'], payload)
            if host['id'] == 'studio':
                remote = '/usr/bin/env DEVELOPER_DIR=/Library/Developer/CommandLineTools /usr/bin/python3 -c ' + shlex.quote(python)
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
        result.update(state=classify(probe), runnerNames=probe['runnerNames'], memoryUsage=probe['memoryUsage'])
    except (subprocess.SubprocessError, OSError, ValueError, KeyError):
        result['state'] = 'Unreachable'
    return result


def main():
    directory = Path.home() / 'Library/Application Support/Octowatch'
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (directory / 'collector.lock').open('w') as lock:
        try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: return
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
            hosts = list(pool.map(collect, HOSTS))
        snapshot = {'generatedAt': time.time(), 'hosts': hosts}
        target = directory / 'ci-status.json'
        temporary = directory / ('ci-status.%d.tmp' % os.getpid())
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as output:
            json.dump(snapshot, output, indent=2)
            output.write('\n')
        os.replace(temporary, target)
        if '--print' in sys.argv: print(json.dumps(snapshot, indent=2))


if __name__ == '__main__': main()
