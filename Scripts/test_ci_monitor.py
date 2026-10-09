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

def routing(labels=('self-hosted', 'Linux', 'glowscript-main-aggregate'), state='enabled'):
    return {'state': state, 'headSHA': 'current',
            'jobs': [{'workflow': 'test.yml', 'name': 'Vitest', 'runID': 1, 'labels': list(labels)}]}

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


    def test_main_aggregate_lane_reports_dedicated_runner_and_alerts_only_after_a_lasting_gap(self):
        dedicated = ('self-hosted', 'Linux', 'X64', 'glowscript-hostinger-slot-2', 'glowscript-main-aggregate')
        fallback = ('self-hosted', 'Linux', 'X64', 'glowscript-pool', 'glowscript-light', 'glowscript-main-aggregate')
        hosts = [host('hostinger', ['glowscript-hostinger-2-a', 'glowscript-hostinger-0-a'])]
        github = {'runners': [runner('glowscript-hostinger-2-a', labels=dedicated),
                              runner('glowscript-hostinger-0-a', labels=fallback, busy=True)], 'jobs': [],
                  'mainAggregateRouting': routing()}
        queue, alerts = collector.analyze(hosts, github, {}, now=0)
        self.assertEqual(queue['mainAggregate']['dedicated'], [{'name': 'glowscript-hostinger-2-a', 'status': 'online',
                                                                 'busy': False}])
        self.assertEqual(queue['mainAggregate']['fallbackOnline'], 1)
        self.assertEqual(queue['mainAggregate']['routingState'], 'enabled')
        self.assertIn('glowscript-main-aggregate', hosts[0]['pools'])
        self.assertEqual(alerts, [])
        state = {}
        gone = {'runners': [runner('glowscript-hostinger-0-a', labels=fallback, busy=True)], 'jobs': [],
                'mainAggregateRouting': routing()}
        _, alerts = collector.analyze([host('hostinger', [])], gone, state, now=1000)
        self.assertEqual(alerts, [])  # re-registering between jobs is not an outage
        _, alerts = collector.analyze([host('hostinger', [])], gone, state, now=1000 + collector.OFFLINE_ALERT_AFTER)
        self.assertEqual([a['key'] for a in alerts], ['lane:main-aggregate'])
        self.assertIn('1 qualified fallback runner', alerts[0]['message'])
        _, alerts = collector.analyze(hosts, github, state, now=2000 + collector.OFFLINE_ALERT_AFTER)
        self.assertEqual(alerts, [])
        self.assertNotIn('lane:main-aggregate', state['mismatchSince'])

    def test_main_aggregate_disabled_with_advertised_carriers_never_alerts(self):
        github = {'runners': [runner('fallback', labels=('self-hosted', 'Linux', 'glowscript-pool',
                                                        'glowscript-light', 'glowscript-main-aggregate'))],
                  'jobs': [], 'mainAggregateRouting': routing(('self-hosted', 'Linux', 'glowscript-light'), 'disabled')}
        state = {}
        collector.analyze([], github, state, now=1000)
        queue, alerts = collector.analyze([], github, state, now=2000)
        self.assertEqual(alerts, [])  # RED on the original collector: lane:main-aggregate
        self.assertEqual(queue['mainAggregate']['routingState'], 'disabled')
        self.assertIn('not enabled yet (fallback: 1 light', queue['mainAggregate']['message'])
        self.assertNotIn('lane:main-aggregate', state['mismatchSince'])

    def test_main_aggregate_enabled_with_no_carriers_alerts(self):
        github = {'runners': [], 'jobs': [], 'mainAggregateRouting': routing()}
        state = {}
        collector.analyze([], github, state, now=1000)
        _, alerts = collector.analyze([], github, state, now=1600)
        self.assertEqual([a['key'] for a in alerts], ['lane:main-aggregate'])
        self.assertIn('0 qualified fallback', alerts[0]['message'])

    def test_main_aggregate_full_labels_required_and_busy_runner_is_qualified(self):
        labels = ('self-hosted', 'Linux', 'X64', 'glowscript-main-aggregate')
        github = {'runners': [runner('wrong-os', labels=('self-hosted', 'macOS', 'X64', 'glowscript-main-aggregate'))],
                  'jobs': [], 'mainAggregateRouting': routing(labels)}
        state = {}
        collector.analyze([], github, state, now=1000)
        _, alerts = collector.analyze([], github, state, now=1600)
        self.assertEqual([a['key'] for a in alerts], ['lane:main-aggregate'])
        github['runners'].append(runner('qualified-busy', busy=True, labels=labels))
        _, alerts = collector.analyze([], github, state, now=1700)
        self.assertEqual(alerts, [])
        self.assertNotIn('lane:main-aggregate', state['mismatchSince'])

    def test_main_aggregate_unknown_resets_gap_even_with_stale_enabled_cache(self):
        github = {'runners': [], 'jobs': [], 'mainAggregateRouting': routing()}
        for error in (None, 'GitHub unavailable (OSError)'):
            state = {'mismatchSince': {'lane:main-aggregate': 100}}
            if error is None: github.pop('mainAggregateRouting', None)
            else: github['mainAggregateRouting'] = routing()
            queue, alerts = collector.analyze([], github, state, now=2000, github_error=error)
            self.assertEqual(alerts, [])
            self.assertEqual(queue['mainAggregate']['routingState'], 'unknown')
            self.assertIn('unknown', queue['mainAggregate']['message'])
            self.assertNotIn('lane:main-aggregate', state['mismatchSince'])
        github['mainAggregateRouting'] = routing()
        _, alerts = collector.analyze([], github, state, now=2100)
        self.assertEqual(alerts, [])  # recovery starts a new grace window

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

class NotificationPersistenceTests(unittest.TestCase):
    def setUp(self):
        import contextlib, copy, io, tempfile
        from unittest.mock import patch
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.directory = Path(self.stack.enter_context(tempfile.TemporaryDirectory()))
        self.output = self.directory / 'Library/Application Support/Octowatch'
        self.stderr = io.StringIO()
        low_disk = host('macbook', state='Paused: low disk')
        low_disk['disk'] = {'state': 'low', 'free_bytes': 1, 'resume_bytes': 35 * 10**9}
        self.stack.enter_context(patch.object(collector.Path, 'home', return_value=self.directory))
        self.stack.enter_context(patch.object(collector, 'HOSTS', [low_disk]))
        self.stack.enter_context(patch.object(collector, 'collect', side_effect=copy.deepcopy))
        self.stack.enter_context(patch.object(collector, 'github_snapshot', return_value=(
            {'fetchedAt': 1000, 'runners': [], 'jobs': []}, None)))
        self.stack.enter_context(patch.object(collector.time, 'time', return_value=1000))
        self.stack.enter_context(patch.object(collector.sys, 'argv', ['collect-ci-status.py']))
        self.stack.enter_context(patch.object(collector.sys, 'stderr', self.stderr))
        self.notification = self.stack.enter_context(patch.object(collector.subprocess, 'run'))

    def assert_persisted_alert(self):
        import json
        state = json.loads((self.output / 'monitor-state.json').read_text())
        snapshot = json.loads((self.output / 'ci-status.json').read_text())
        self.assertEqual(state['announced'], ['disk:macbook'])
        self.assertEqual(state['mismatchSince']['disk:macbook'], 1000)
        self.assertEqual(snapshot['generatedAt'], 1000)
        self.assertEqual(snapshot['githubObservedAt'], 1000)
        self.assertEqual([item['key'] for item in snapshot['alerts']], ['disk:macbook'])
        return state, snapshot

    def test_notification_timeout_preserves_both_outputs_and_deduplicates(self):
        self.notification.side_effect = collector.subprocess.TimeoutExpired(
            ['private-command'], 5, output=b'private-output', stderr=b'private-error')
        collector.main()
        self.assert_persisted_alert()
        self.assertEqual(self.stderr.getvalue(), 'Notification unavailable (TimeoutExpired)\n')
        collector.main()
        self.assert_persisted_alert()
        self.notification.assert_called_once()

    def test_notification_startup_error_preserves_both_outputs(self):
        self.notification.side_effect = OSError('private-startup-detail')
        collector.main()
        self.assert_persisted_alert()
        self.assertEqual(self.stderr.getvalue(), 'Notification unavailable (OSError)\n')

    def test_notification_nonzero_return_keeps_existing_attempt_semantics(self):
        self.notification.return_value = collector.subprocess.CompletedProcess([], 1)
        collector.main()
        self.assert_persisted_alert()
        collector.main()
        self.notification.assert_called_once()
        self.assertEqual(self.stderr.getvalue(), '')

    def test_failed_notification_does_not_skip_other_alerts_and_rearms_after_clear(self):
        state = {}
        alerts = [{'key': 'first', 'message': 'First'}, {'key': 'second', 'message': 'Second'}]
        self.notification.side_effect = [OSError('private'), collector.subprocess.CompletedProcess([], 0),
                                         collector.subprocess.CompletedProcess([], 0)]
        collector.notify(alerts, state)
        self.assertEqual(self.notification.call_count, 2)
        self.assertEqual(state['announced'], ['first', 'second'])
        collector.notify(alerts, state)
        self.assertEqual(self.notification.call_count, 2)
        collector.notify([], state)
        collector.notify(alerts[:1], state)
        self.assertEqual(self.notification.call_count, 3)

    def test_analysis_errors_still_propagate(self):
        from unittest.mock import patch
        with patch.object(collector, 'analyze', side_effect=RuntimeError('analysis failed')):
            with self.assertRaisesRegex(RuntimeError, 'analysis failed'):
                collector.main()
        self.notification.assert_not_called()

    def test_persistence_errors_still_propagate_after_notification_failure(self):
        from unittest.mock import patch
        self.notification.side_effect = OSError('notification failed')
        with patch.object(collector, 'write_json', side_effect=OSError('persistence failed')):
            with self.assertRaisesRegex(OSError, 'persistence failed'):
                collector.main()

class MainRoutingTests(unittest.TestCase):
    def fetch(self, labels=None, sha='current', missing=False, failed=False, event='push',
              missing_workflows=(), labels_by_workflow=None):
        from unittest.mock import patch
        def api(path):
            if path.endswith('/commits/main'): return {'sha': 'current'}
            if '/workflows/' in path:
                return {'workflow_runs': [{'id': 1 if 'test.yml/' in path else 2,
                                          'head_sha': sha, 'head_branch': 'main', 'event': event}]}
            if failed: raise OSError('offline')
            workflow = 'test.yml' if '/runs/1/' in path else 'typecheck.yml'
            if workflow in missing_workflows: return {'jobs': []}
            name = 'Vitest' if '/runs/1/' in path else 'TypeScript & Lint'
            job_labels = (labels_by_workflow or {}).get(workflow, labels or [])
            return {'jobs': [] if missing else [{'name': name, 'labels': job_labels}]}
        with patch.object(collector, 'gh_api', side_effect=api):
            return collector.fetch_main_aggregate_routing()

    def test_current_main_evaluated_labels_enable_lane(self):
        result = self.fetch(['self-hosted', 'Linux', 'glowscript-main-aggregate'])
        self.assertEqual(result['state'], 'enabled')
        self.assertEqual(result['headSHA'], 'current')
        self.assertEqual(len(result['jobs']), 2)

    def test_both_current_main_jobs_on_light_disable_lane(self):
        self.assertEqual(self.fetch(['self-hosted', 'Linux', 'glowscript-light'])['state'], 'disabled')

    def test_complete_mixed_labels_still_enable_when_one_job_uses_aggregate(self):
        result = self.fetch(labels_by_workflow={
            'test.yml': ['self-hosted', 'Linux', 'glowscript-main-aggregate'],
            'typecheck.yml': ['self-hosted', 'Linux', 'glowscript-light'],
        })
        self.assertEqual(result['state'], 'enabled')
        self.assertEqual(len(result['jobs']), 2)

    def test_partial_current_main_evidence_is_unknown(self):
        aggregate = ['self-hosted', 'Linux', 'glowscript-main-aggregate']
        for options in (
            {'missing_workflows': ('typecheck.yml',)},
            {'empty_typecheck_labels': True},
        ):
            with self.subTest(options=options):
                labels_by_workflow = {'test.yml': aggregate}
                if options.pop('empty_typecheck_labels', False):
                    labels_by_workflow['typecheck.yml'] = []
                result = self.fetch(labels_by_workflow=labels_by_workflow, **options)
                self.assertEqual(result['state'], 'unknown')
                self.assertEqual(len(result['jobs']), 1)
                github = {'runners': [runner('dedicated', labels=(
                    'self-hosted', 'Linux', 'X64', 'glowscript-main-aggregate'))],
                    'jobs': [], 'mainAggregateRouting': result}
                queue, alerts = collector.analyze([], github, {}, now=1000)
                self.assertEqual(queue['mainAggregate']['routingState'], 'unknown')
                self.assertIn('routing/capacity unknown', queue['mainAggregate']['message'])
                self.assertEqual(alerts, [])

    def test_stale_revision_missing_labels_or_wrong_event_are_unknown(self):
        for changes in ({'sha': 'previous'}, {'missing': True}, {'labels': []}, {'event': 'pull_request'}):
            self.assertEqual(self.fetch(**changes)['state'], 'unknown')

    def test_fetch_error_is_unknown(self):
        result = self.fetch(failed=True)
        self.assertEqual(result['state'], 'unknown')
        self.assertIn('OSError', result['reason'])

class HostingerLaneTests(unittest.TestCase):
    def test_hosts_match_the_fleet_slot_layout(self):
        layout = {h['id']: (h['expectedLanes'], h['cpuPerLane'], h['memoryGiBPerLane']) for h in collector.HOSTS}
        self.assertEqual(layout['hostinger'], (3, 4, 12))  # slot 2: main-aggregate lane (#2347)
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

class MacBookVmTests(unittest.TestCase):
    """GlowScript #2300: the MacBook supervisor's ~/glowscript-ci/vm-state.json (contract from #2299)."""

    def run_probe(self, vm_state=None, raw=None, docker_ok=False, now=None):
        """Runs the real PROBE as the collector does, with HOME pointed at a temporary directory
        and a stub docker. Read-only: it never touches the real VM or supervisor."""
        import json, os, subprocess, tempfile, time
        with tempfile.TemporaryDirectory() as home:
            state = Path(home) / 'glowscript-ci'
            state.mkdir()
            docker = state / 'docker'
            docker.write_text('#!/bin/sh\nexit %d\n' % (0 if docker_ok else 1))
            docker.chmod(0o700)
            if vm_state is not None:
                raw = json.dumps(vm_state)
            if raw is not None:
                (state / 'vm-state.json').write_text(raw)
            env = dict(os.environ, HOME=home)
            out = subprocess.check_output(['/usr/bin/python3', '-c', collector.PROBE, 'macbook'], env=env, timeout=30)
            return json.loads(out)

    def fresh(self, current, **fields):
        import time
        return dict({'state': current, 'since': int(time.time()) - 900, 'checked': int(time.time()),
                     'attempts': 2, 'retry_at': None}, **fields)

    def classify(self, probe):
        return collector.classify(dict(probe, service=True))

    def test_running_vm_keeps_todays_classification(self):
        probe = self.run_probe(self.fresh('running'), docker_ok=True)
        self.assertEqual(probe['vm']['state'], 'running')
        self.assertIn(self.classify(probe), ('Ready', 'On battery'))
        # The supervisor only rewrites the file on Docker activity while running, so an old
        # `checked` on a running VM is normal (observed 14h on 2026-10-07) and is not unknown.
        old = dict(self.fresh('running'), checked=1)
        self.assertEqual(self.run_probe(old, docker_ok=True)['vm']['state'], 'running')

    def test_stopped_vm_reads_as_macbook_vm_down(self):
        probe = self.run_probe(self.fresh('stopped', retry_at=None))
        self.assertEqual(probe['vm']['state'], 'stopped')
        self.assertFalse(probe['docker'])
        self.assertEqual(self.classify(probe), 'VM down')

    def test_held_and_broken_and_starting_name_themselves(self):
        held = self.run_probe(self.fresh('held', markers=['PAUSED']))
        self.assertEqual((self.classify(held), held['vm']['markers']), ('VM held', ['PAUSED']))
        broken = self.run_probe(self.fresh('broken', action='inspect lima, then colima stop/start by hand'))
        self.assertEqual(self.classify(broken), 'VM broken')
        self.assertIn('colima stop', broken['vm']['action'])
        self.assertEqual(self.classify(self.run_probe(self.fresh('starting'))), 'VM starting')

    def test_missing_corrupt_stale_or_unrecognised_file_fails_closed_to_unknown(self):
        cases = {
            'missing': dict(),
            'corrupt': dict(raw='{"state": "runn'),
            'not an object': dict(raw='["running"]'),
            'unrecognised state': dict(vm_state=self.fresh('healthy')),
            'stale stopped': dict(vm_state=dict(self.fresh('stopped'), checked=1)),
            'non-numeric checked': dict(vm_state=dict(self.fresh('stopped'), checked='now')),
        }
        for name, kwargs in cases.items():
            for docker_ok in (True, False):
                with self.subTest(name, docker_ok=docker_ok):
                    probe = self.run_probe(docker_ok=docker_ok, **kwargs)
                    self.assertEqual(probe['vm']['state'], 'unknown')
                    label = self.classify(probe)
                    self.assertEqual(label, 'VM unknown')
                    self.assertNotIn(label, ('Online', 'Ready'))

    def test_other_hosts_are_not_affected(self):
        probe = {'service': True, 'docker': True, 'paused': False, 'onAC': True, 'runnerNames': []}
        self.assertEqual(collector.classify(probe), 'Ready')
        self.assertEqual(collector.classify(dict(probe, vm=None)), 'Ready')

    def test_vm_down_replaces_stale_runner_rows_with_one_host_alert(self):
        offline = [runner('glowscript-macbook-%d-old' % slot, status='offline') for slot in range(3)]
        github = {'runners': offline, 'jobs': []}
        state = {'mismatchSince': {'lane:glowscript-macbook-0-old': 0}}
        down = {'state': 'stopped', 'since': 0, 'checked': 5000}
        for now in (0, 5000):
            hosts = [host('macbook', state='VM down')]
            hosts[0]['vm'] = down
            _, alerts = collector.analyze(hosts, github, state, now=now)
        self.assertEqual(hosts[0]['lanes'], [])
        self.assertEqual([a['key'] for a in alerts], ['host:macbook'])
        self.assertEqual(alerts[0]['message'], 'MacBook VM down for 83m')
        self.assertNotIn('lane:glowscript-macbook-0-old', state['mismatchSince'])

    def test_broken_alert_carries_the_supervisors_action(self):
        hosts = [host('macbook', state='VM broken')]
        hosts[0]['vm'] = {'state': 'broken', 'action': 'run colima stop/start by hand'}
        state = {}
        collector.analyze(hosts, None, state, now=0)
        _, alerts = collector.analyze(hosts, None, state, now=collector.UNREACHABLE_ALERT_AFTER)
        self.assertEqual(alerts[0]['message'], 'MacBook VM broken for 10m: run colima stop/start by hand')

    def test_unknown_vm_keeps_lanes_but_is_never_healthy(self):
        github = {'runners': [runner('glowscript-macbook-0-a')], 'jobs': []}
        hosts = [host('macbook', ['glowscript-macbook-0-a'], state='VM unknown')]
        hosts[0]['vm'] = {'state': 'unknown', 'reason': 'missing'}
        state = {}
        collector.analyze(hosts, github, state, now=0)
        self.assertEqual(len(hosts[0]['lanes']), 1)
        _, alerts = collector.analyze(hosts, github, state, now=collector.UNREACHABLE_ALERT_AFTER)
        self.assertEqual(alerts[0]['message'], 'MacBook VM unknown for 10m (vm-state.json missing)')

if __name__ == '__main__': unittest.main()
