import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('collector', Path(__file__).with_name('collect-ci-status.py'))
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)

class MonitorTests(unittest.TestCase):
    def probe(self, **changes):
        data = dict(service=True, docker=True, paused=False, onAC=True, runnerNames=[])
        data.update(changes)
        return data

    def test_draining_is_not_idle_or_stopped(self):
        self.assertEqual(collector.classify(self.probe(paused=True, runnerNames=['job'])), 'Draining')
        self.assertEqual(collector.classify(self.probe(paused=True)), 'Paused')

    def test_battery_admission(self):
        self.assertEqual(collector.classify(self.probe(onAC=False)), 'On battery')
        self.assertEqual(collector.classify(self.probe(onAC=False, runnerNames=['job'])), 'Draining on battery')

    def test_daemon_failure_is_not_ready(self):
        self.assertEqual(collector.classify(self.probe(service=False)), 'Stopped')
        self.assertEqual(collector.classify(self.probe(docker=False)), 'Docker unavailable')

    def test_empty_running_service_is_ready(self):
        self.assertEqual(collector.classify(self.probe()), 'Ready')

    def test_macbook_low_disk_pause_is_named(self):
        # GlowScript #2323: the supervisor closed admission below 30 GB free.
        low = {'state': 'low', 'free_bytes': 12_340_000_000, 'resume_bytes': 35 * 10**9}
        self.assertEqual(collector.classify(self.probe(disk=low)), 'Paused: low disk')
        self.assertEqual(collector.classify(self.probe(disk=low, runnerNames=['job'])), 'Draining: low disk')
        self.assertEqual(collector.classify(self.probe(disk={'state': 'unknown'})), 'Paused: disk unreadable')
        self.assertEqual(collector.classify(self.probe(disk=low, paused=True)), 'Paused: low disk')
        self.assertEqual(collector.classify(self.probe(disk=None)), 'Ready')

    def test_probe_reads_only_a_fresh_pause_from_disk_state(self):
        import json, pathlib, tempfile, time
        from unittest.mock import patch
        # The probe up to its own call of disk_pause(): imports, `state`, `command`, `disk_pause`.
        head = collector.PROBE.split('disk = disk_pause()')[0]
        with tempfile.TemporaryDirectory() as tmp, patch.object(pathlib.Path, 'home', return_value=pathlib.Path(tmp)):
            scope = {}
            exec(head, scope)
            (pathlib.Path(tmp) / 'glowscript-ci').mkdir()
            write = lambda **v: (pathlib.Path(tmp) / 'glowscript-ci' / 'disk-state.json').write_text(json.dumps(v))
            self.assertIsNone(scope['disk_pause']())
            write(state='low', checked=time.time(), free_bytes=1, resume_bytes=2, label='MacBook paused: low disk')
            self.assertEqual(scope['disk_pause']()['label'], 'MacBook paused: low disk')
            write(state='low', checked=time.time() - collector.DISK_STATE_FRESH - 5, free_bytes=1)
            self.assertIsNone(scope['disk_pause']())
            write(state='ok', checked=time.time(), free_bytes=50 * 10**9)
            self.assertIsNone(scope['disk_pause']())
            (pathlib.Path(tmp) / 'glowscript-ci' / 'disk-state.json').write_text('{')
            self.assertIsNone(scope['disk_pause']())

def host(hid, containers=(), state='Online', proxy=None):
    base = next(h for h in collector.HOSTS if h['id'] == hid)
    return dict(base, state=state, runnerNames=list(containers), memoryByName={}, proxy=proxy)

def runner(name, status='online', busy=False, labels=('self-hosted', 'Linux', 'ARM64', 'glowscript-studio')):
    return {'name': name, 'status': status, 'busy': busy, 'labels': list(labels)}

def job(labels=('self-hosted', 'Linux', 'ARM64', 'glowscript-studio'), status='queued', created=0, runner_name=''):
    return {'name': 'Lint gates', 'status': status, 'labels': list(labels), 'runner': runner_name, 'createdAt': created,
            'startedAt': None, 'url': None, 'branch': 'b', 'pr': 1, 'workflow': 'Tests'}

class AnalysisTests(unittest.TestCase):
    def test_low_disk_alerts_at_once_with_the_label(self):
        hosts = [host('macbook', state='Paused: low disk')]
        hosts[0]['disk'] = {'state': 'low', 'free_bytes': 12_340_000_000, 'resume_bytes': 35 * 10**9,
                            'label': 'MacBook paused: low disk'}
        state = {}
        _, alerts = collector.analyze(hosts, {'runners': [], 'jobs': []}, state, now=1000)
        self.assertEqual([(a['key'], a['message']) for a in alerts],
                         [('disk:macbook', 'MacBook paused: low disk (12.3 GB free; admission reopens at 35 GB)')])
        recovered = [host('macbook', state='Ready')]
        _, alerts = collector.analyze(recovered, {'runners': [], 'jobs': []}, state, now=1100)
        self.assertEqual(alerts, [])
        self.assertNotIn('disk:macbook', state['mismatchSince'])

    def test_container_up_but_github_offline_alerts_only_after_ten_minutes(self):
        hosts = [host('macbook', ['glowscript-macbook-0-a'], proxy={'state': 'running', 'restarts': 0})]
        github = {'runners': [runner('glowscript-macbook-0-a', status='offline')], 'jobs': []}
        state = {}
        _, alerts = collector.analyze(hosts, github, state, now=1000)
        self.assertEqual(alerts, [])
        self.assertEqual(hosts[0]['lanes'][0]['github'], 'offline')
        self.assertTrue(hosts[0]['lanes'][0]['container'])
        _, alerts = collector.analyze([host('macbook', ['glowscript-macbook-0-a'], proxy={'state': 'running', 'restarts': 0})], github, state, now=1000 + 600)
        self.assertEqual([a['key'] for a in alerts], ['lane:glowscript-macbook-0-a'])
        self.assertIn('container up but', alerts[0]['message'])

    def test_fresh_container_awaiting_registration_is_starting_not_degraded(self):
        state = {}
        hosts = [host('studio', ['glowscript-studio-new'])]
        collector.analyze(hosts, {'runners': [], 'jobs': []}, state, now=1000)
        lane = hosts[0]['lanes'][0]
        self.assertEqual((lane['container'], lane['github'], lane['phase'], lane['mismatchSince']), (True, 'unregistered', 'starting', 1000))

    def test_torn_down_container_still_listed_by_github_is_stopping(self):
        github = {'runners': [runner('glowscript-simrig-old', busy=True)],
                  'jobs': [job(status='in_progress', runner_name='glowscript-simrig-old')]}
        hosts = [host('simrig', [])]
        collector.analyze(hosts, github, {}, now=1000)
        lane = hosts[0]['lanes'][0]
        self.assertFalse(lane['container'])
        self.assertEqual(lane['job']['name'], 'Lint gates')
        self.assertIsNone(lane['phase'])  # GitHub says online: no disagreement to age yet
        github['runners'][0]['status'] = 'offline'
        hosts = [host('simrig', [])]
        collector.analyze(hosts, github, {}, now=1000)
        self.assertEqual(hosts[0]['lanes'][0]['phase'], 'stopping')

    def test_mismatch_ages_across_persisted_runs_and_only_then_degrades(self):
        import json
        github = {'runners': [runner('glowscript-macbook-0-a', status='offline')], 'jobs': []}
        state = {}
        phases = []
        for now in (0, 30, 119, 120, 500):
            state = json.loads(json.dumps(state))  # monitor-state.json round trip between collector runs
            hosts = [host('macbook', ['glowscript-macbook-0-a'])]
            collector.analyze(hosts, github, state, now=now)
            phases.append((hosts[0]['lanes'][0]['phase'], hosts[0]['lanes'][0]['mismatchSince']))
        self.assertEqual(phases, [('starting', 0), ('starting', 0), ('starting', 0), ('degraded', 0), ('degraded', 0)])

    def test_age_comes_from_state_not_the_current_poll(self):
        github = {'runners': [runner('glowscript-macbook-0-a', status='offline')], 'jobs': []}
        hosts = [host('macbook', ['glowscript-macbook-0-a'])]
        collector.analyze(hosts, github, {}, now=10_000)
        self.assertEqual(hosts[0]['lanes'][0]['phase'], 'starting')
        self.assertEqual(collector.lane_phase(True, collector.TRANSITION_GRACE - 1), 'starting')
        self.assertEqual(collector.lane_phase(False, collector.TRANSITION_GRACE - 1), 'stopping')
        self.assertEqual(collector.lane_phase(True, collector.TRANSITION_GRACE), 'degraded')
        self.assertEqual(collector.lane_phase(False, collector.TRANSITION_GRACE), 'orphaned')
        self.assertGreater(collector.TRANSITION_GRACE, collector.GITHUB_INTERVAL + 30)

    def test_online_lane_and_unknown_github_have_no_phase(self):
        hosts = [host('studio', ['glowscript-studio-a'])]
        collector.analyze(hosts, {'runners': [runner('glowscript-studio-a')], 'jobs': []}, {}, now=0)
        self.assertEqual((hosts[0]['lanes'][0]['phase'], hosts[0]['lanes'][0]['mismatchSince']), (None, None))
        hosts = [host('studio', ['glowscript-studio-a'])]
        collector.analyze(hosts, None, {}, now=0)
        self.assertEqual((hosts[0]['lanes'][0]['github'], hosts[0]['lanes'][0]['phase']), ('unknown', None))

    def test_recovered_lane_clears_its_timer(self):
        state = {}
        collector.analyze([host('macbook', ['glowscript-macbook-0-a'])], {'runners': [runner('glowscript-macbook-0-a', status='offline')], 'jobs': []}, state, now=0)
        collector.analyze([host('macbook', ['glowscript-macbook-0-a'])], {'runners': [runner('glowscript-macbook-0-a')], 'jobs': []}, state, now=100)
        self.assertEqual(state['mismatchSince'], {})

    def test_proxy_restart_loop_alerts_immediately(self):
        state = {}
        collector.analyze([host('macbook', ['r'], proxy={'state': 'running', 'restarts': 700})], None, state, now=0)
        proxy = {'state': 'running', 'restarts': 702}
        _, alerts = collector.analyze([host('macbook', ['r'], proxy=proxy)], None, state, now=60)
        self.assertTrue(proxy['looping'])
        self.assertEqual([a['key'] for a in alerts], ['proxy:macbook'])
        _, alerts = collector.analyze([host('macbook', ['r'], proxy={'state': 'restarting', 'restarts': 702})], None, {}, now=0)
        self.assertEqual([a['key'] for a in alerts], ['proxy:macbook'])

    def test_queue_counts_all_self_hosted_jobs_and_waits(self):
        github = {'runners': [runner('glowscript-studio-a', busy=True)],
                  'jobs': [job(created=0), job(created=500), job(labels=('ubuntu-latest',), created=0),
                           job(status='in_progress', runner_name='glowscript-studio-a')]}
        hosts = [host('studio', ['glowscript-studio-a'])]
        queue, _ = collector.analyze(hosts, github, {}, now=1000)
        self.assertEqual((queue['queued'], queue['hosted'], queue['running']), (2, 1, 1))
        self.assertEqual((queue['oldestWaitSec'], queue['medianWaitSec']), (1000, 750))
        self.assertEqual(hosts[0]['lanes'][0]['job']['name'], 'Lint gates')

    def test_idle_eligible_and_unservable(self):
        simrig = ('self-hosted', 'Linux', 'X64', 'glowscript-simrig-canary', 'glowscript-simrig')
        github = {'runners': [runner('glowscript-simrig-a', labels=simrig), runner('glowscript-studio-a', busy=True)],
                  'jobs': [job(created=0), job(labels=('self-hosted', 'glowscript-nowhere'), created=0)]}
        hosts = [host('studio', ['glowscript-studio-a']), host('simrig', ['glowscript-simrig-a'])]
        queue, alerts = collector.analyze(hosts, github, {}, now=100)
        self.assertEqual([h['eligibleQueued'] for h in hosts], [1, 0])  # SimRig idle but can take none of it
        self.assertEqual((queue['idleRunners'], queue['idleEligible'], queue['unservable']), (1, 0, 1))
        self.assertEqual(queue['unservableLabels'], ['glowscript-nowhere'])


    def test_pools_drop_generic_and_slot_labels(self):
        labels = ('self-hosted', 'Linux', 'ARM64', 'glowscript-studio', 'glowscript-macbook-canary', 'glowscript-macbook-slot-0')
        hosts = [host('macbook', ['glowscript-macbook-0-a'])]
        collector.analyze(hosts, {'runners': [runner('glowscript-macbook-0-a', labels=labels)], 'jobs': []}, {}, now=0)
        self.assertEqual(hosts[0]['pools'], ['glowscript-macbook-canary', 'glowscript-studio'])

    def test_github_cache_reuses_recent_fetch_and_survives_errors(self):
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            calls = []
            def fetch():
                calls.append(1)
                return {'fetchedAt': 1000, 'runners': [], 'jobs': []}
            collector.github_snapshot(directory, fetch, now=1000)
            collector.github_snapshot(directory, fetch, now=1030)
            self.assertEqual(len(calls), 1)
            def broken(): raise OSError('offline')
            cached, error = collector.github_snapshot(directory, broken, now=2000)
            self.assertEqual(cached['fetchedAt'], 1000)
            self.assertIn('GitHub unavailable', error)

class HostingerLaneTests(unittest.TestCase):
    def test_hosts_match_the_fleet_slot_layout(self):
        layout = {h['id']: (h['expectedLanes'], h['cpuPerLane'], h['memoryGiBPerLane']) for h in collector.HOSTS}
        self.assertEqual(layout['hostinger'], (2, 4, 12))
        self.assertEqual(layout['simrig'], (2, 6, 24))

    def test_hostinger_probe_runs_as_root_over_pinned_ssh_and_reads_its_systemd_unit(self):
        from unittest.mock import patch
        import json
        probe = {'service': True, 'docker': True, 'paused': False, 'onAC': True,
                 'runnerNames': ['glowscript-hostinger-1-abcdef123456'], 'memoryUsage': ['1GiB'], 'memoryByName': {}, 'proxy': None}
        hostinger = next(h for h in collector.HOSTS if h['id'] == 'hostinger')
        with patch.object(collector.subprocess, 'check_output', return_value=json.dumps(probe).encode()) as run:
            result = collector.collect(hostinger)
        args = run.call_args.args[0]
        self.assertEqual(args[0], '/usr/bin/ssh')
        self.assertIn('StrictHostKeyChecking=yes', args)
        self.assertIn('BatchMode=yes', args)
        self.assertEqual(args[-2], 'root@82.180.163.60')
        self.assertTrue(args[-1].startswith('/usr/bin/python3 -c '))
        self.assertNotIn('powershell', args[-1])
        self.assertEqual(result['state'], 'Online')
        self.assertIn("'glowscript-' + host", collector.PROBE)
        self.assertIn("host in ('simrig', 'hostinger')", collector.PROBE)

    def test_simrig_probe_stays_under_the_cmd_exe_command_line_cap(self):
        from unittest.mock import patch
        import base64, json
        probe = {'service': True, 'docker': True, 'paused': False, 'onAC': True, 'runnerNames': [], 'memoryUsage': []}
        simrig = next(h for h in collector.HOSTS if h['id'] == 'simrig')
        with patch.object(collector.subprocess, 'check_output', return_value=json.dumps(probe).encode()) as run:
            collector.collect(simrig)
        remote = run.call_args.args[0][-1]
        self.assertTrue(remote.startswith('powershell.exe -NoProfile -EncodedCommand '))
        self.assertLess(len(remote), 8191)
        self.assertIn('zlib.decompress', base64.b64decode(remote.split(' ')[-1]).decode('utf-16le'))

    def test_hostinger_runners_are_attributed_to_their_host(self):
        self.assertEqual(collector.host_of('glowscript-hostinger-0-abcdef123456'), 'hostinger')

if __name__ == '__main__': unittest.main()
