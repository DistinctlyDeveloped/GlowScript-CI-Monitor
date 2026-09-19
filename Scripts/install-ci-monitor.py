#!/usr/bin/env python3
"""Install the read-only snapshot collector for the current macOS user."""
from pathlib import Path
import os
import plistlib
import shutil
import subprocess

home = Path.home()
root = home / 'Library/Application Support/Octowatch'
root.mkdir(parents=True, exist_ok=True, mode=0o700)
script = root / 'collect-ci-status.py'
shutil.copyfile(Path(__file__).with_name('collect-ci-status.py'), script)
script.chmod(0o700)
label = 'com.glowscript.octowatch-ci-status'
agent = home / 'Library/LaunchAgents' / (label + '.plist')
agent.parent.mkdir(parents=True, exist_ok=True)
value = {'Label': label, 'ProgramArguments': ['/usr/bin/python3', str(script)],
         'EnvironmentVariables': {'DEVELOPER_DIR': '/Library/Developer/CommandLineTools'},
         'RunAtLoad': True, 'StartInterval': 30, 'ProcessType': 'Background',
         'StandardOutPath': str(root / 'collector.log'), 'StandardErrorPath': str(root / 'collector-error.log')}
with agent.open('wb') as file: plistlib.dump(value, file)
agent.chmod(0o600)
subprocess.run(['/bin/launchctl', 'bootout', 'gui/%d/%s' % (os.getuid(), label)], capture_output=True)
subprocess.run(['/bin/launchctl', 'bootstrap', 'gui/%d' % os.getuid(), str(agent)], check=True)
print('Read-only CI snapshot collector installed; refreshes every 30 seconds at login.')
