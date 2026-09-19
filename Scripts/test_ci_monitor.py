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

if __name__ == '__main__': unittest.main()
