#!/usr/bin/env python3
"""The Hermes recipe's snapshot script against a fake `hermes`: which exits it accepts.

`hermes backup` exits 1 when it kept an archive but could not add some files (one it may not
read, one deleted mid-run). That archive is accepted when it holds a real config.yaml and
state.db; one missing state.db is not, whatever the exit; and any other exit fails.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parent.parent / 'recipes' / 'hermes' / 'snapshot'

FAKE = '''#!/usr/bin/env python3
import os, sys, zipfile
out = sys.argv[sys.argv.index('-o') + 1]
code = int(os.environ['FAKE_EXIT'])
if os.environ.get('FAKE_ARCHIVE') != 'none':
    with zipfile.ZipFile(out, 'w') as zf:
        zf.writestr('config.yaml', 'x: 1\\n')
        if os.environ.get('FAKE_ARCHIVE') != 'no-db':
            zf.writestr('state.db', b'SQLite format 3\\x00' + b'\\x01' * 100)
if code == 1:
    print("  config.yaml.bak: [Errno 13] Permission denied: '/home/agent/.hermes/config.yaml.bak'")
sys.exit(code)
'''


class Snapshot(unittest.TestCase):
    def run_snapshot(self, exit_code, archive='good'):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            (base / 'bin').mkdir()
            (base / 'bin' / 'hermes').write_text(FAKE)
            (base / 'bin' / 'hermes').chmod(0o755)
            (base / 'home' / '.hermes').mkdir(parents=True)
            (base / 'home' / '.hermes' / 'state.db').write_text('live')
            env = dict(os.environ, HOME=str(base / 'home'), PATH=f'{base / "bin"}:{os.environ["PATH"]}',
                       FAKE_EXIT=str(exit_code), FAKE_ARCHIVE=archive)
            return subprocess.run([sys.executable, str(SCRIPT), str(base / 'out')], env=env,
                                  capture_output=True, text=True)

    def test_complete_archive(self):
        self.assertEqual(self.run_snapshot(0).returncode, 0)

    def test_incomplete_but_sound_archive_is_accepted_and_says_so(self):
        result = self.run_snapshot(1)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('archive incomplete, 1 file(s) not added', result.stdout)
        self.assertIn('Permission denied', result.stdout)

    def test_incomplete_archive_without_state_db_fails(self):
        result = self.run_snapshot(1, archive='no-db')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('missing state.db', result.stdout + result.stderr)

    def test_other_exits_fail(self):
        self.assertNotEqual(self.run_snapshot(2).returncode, 0)
        self.assertNotEqual(self.run_snapshot(1, archive='none').returncode, 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
