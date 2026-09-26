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

def host(hid, containers=(), state='Online', proxy=None):
    base = next(h for h in collector.HOSTS if h['id'] == hid)
    return dict(base, state=state, runnerNames=list(containers), memoryByName={}, proxy=proxy)

def runner(name, status='online', busy=False, labels=('self-hosted', 'Linux', 'ARM64', 'glowscript-studio')):
    return {'name': name, 'status': status, 'busy': busy, 'labels': list(labels)}

def job(labels=('self-hosted', 'Linux', 'ARM64', 'glowscript-studio'), status='queued', created=0, runner_name=''):
    return {'name': 'Lint gates', 'status': status, 'labels': list(labels), 'runner': runner_name, 'createdAt': created,
            'startedAt': None, 'url': None, 'branch': 'b', 'pr': 1, 'workflow': 'Tests'}

class AnalysisTests(unittest.TestCase):
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

if __name__ == '__main__': unittest.main()
