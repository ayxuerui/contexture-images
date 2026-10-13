#!/usr/bin/env python3
"""Configuration and shutdown regressions without provider credentials or network."""
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / 'harness-remote.py'
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('remote', SOURCE)
remote = importlib.util.module_from_spec(spec)
spec.loader.exec_module(remote)


class Configuration(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        env = {'CONTEXTURE_STORE_ROOT': self.temp.name, 'HARNESS_REMOTE_HOME': self.temp.name}
        self.env = patch.dict(os.environ, env, clear=True)
        self.env.start()
        self.addCleanup(self.env.stop)

    def test_disabled_without_store(self):
        os.environ.clear()
        self.assertEqual(remote.configuration(), set())
        self.assertEqual(remote.status(set()), 0)

    def test_unknown_harness_fails(self):
        os.environ['HARNESS_REMOTE_AGENTS'] = 'codex,typo'
        with self.assertRaisesRegex(ValueError, 'unknown remote harness'):
            remote.configuration()

    def test_missing_store_fails(self):
        os.environ['HARNESS_REMOTE_AGENTS'] = 'codex'
        os.environ['CONTEXTURE_STORE_ROOT'] = '/nonexistent-remote-test-store'
        with self.assertRaisesRegex(ValueError, 'CONTEXTURE_STORE_ROOT'):
            remote.configuration()

    def test_foreground_contract(self):
        for name, value in [('codex', '["start"]'), ('agy', '["start"]'),
                            ('claude', '"shell string"')]:
            with self.subTest(name=name):
                with patch.dict(os.environ, {f'HARNESS_REMOTE_{name.upper()}_ARGS': value}):
                    with self.assertRaises(ValueError):
                        remote.command(name)

    def test_args_preserve_literal_values(self):
        os.environ['HARNESS_REMOTE_CLAUDE_ARGS'] = '["--name", "literal $(touch bad)"]'
        self.assertEqual(remote.command('claude')[-1], 'literal $(touch bad)')
        self.assertIn('--permission-mode', remote.DEFAULT_ARGS['claude'])
        self.assertIn('sandbox_mode="read-only"', remote.DEFAULT_ARGS['codex'])

    def test_home_follows_hermes_home(self):
        del os.environ['HARNESS_REMOTE_HOME']
        self.assertEqual(remote.home(), '/opt/data/home')
        os.environ['HERMES_HOME'] = '/srv/hermes'
        self.assertEqual(remote.home(), '/srv/hermes/home')
        os.environ['HARNESS_REMOTE_HOME'] = self.temp.name
        self.assertEqual(remote.home(), self.temp.name)

    def test_enabled_selection(self):
        os.environ['HARNESS_REMOTE_AGENTS'] = ' claude, codex,agy,claude '
        self.assertEqual(remote.configuration(), {'claude', 'codex', 'agy'})


class Shutdown(unittest.TestCase):
    def test_stop_cleans_child_that_ignores_term(self):
        # The same worker used by s6 must stop before the container grace period,
        # even when the foreground server refuses TERM.
        code = ('import importlib.util,sys; '
                's=importlib.util.spec_from_file_location("r",sys.argv[1]); '
                'r=importlib.util.module_from_spec(s); s.loader.exec_module(r); '
                'sys.exit(r.worker("fake",[sys.executable,"-u","-c",'
                '"import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); '
                'print(\\\"ready\\\",flush=True); time.sleep(300)"]))')
        process = subprocess.Popen([sys.executable, '-u', '-c', code, str(SOURCE)],
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.addCleanup(lambda: process.poll() is None and process.kill())
        self.assertEqual(process.stdout.readline().decode().strip(), '[fake] ready')
        start = time.monotonic()
        process.send_signal(signal.SIGTERM)
        process.wait(timeout=12)
        self.assertLess(time.monotonic() - start, 11)
        self.assertEqual(process.returncode, 247)  # worker reports child SIGKILL (-9).
        process.stdout.close()


if __name__ == '__main__':
    unittest.main()
