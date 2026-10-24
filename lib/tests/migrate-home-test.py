#!/usr/bin/env python3
"""harness-migrate-home against a fixture in the Hermes-image layout: forward, reverse, refusals.

The migration renames live state, so the test that matters is that --reverse gives back exactly
what was there -- every file, byte for byte and mode for mode -- and that a collision stops it
before the first move rather than halfway.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parent.parent / 'migrate-home.py'

FIXTURE = {
    'config.yaml': 'terminal:\n  cwd: /store\nskills:\n  dir: /opt/data/skills\n',
    '.env': 'API_SERVER_KEY=0123456789abcdef0123\n',
    'SOUL.md': 'soul\n',
    'state.db': 'SQLite format 3\0db',
    'state.db-wal': 'wal',
    'sessions/s1.json': '{"cwd": "/opt/data/home"}',
    'cron/jobs.json': '{"script": "/opt/data/scripts/run.sh"}',
    'profiles/work/config.yaml': 'x: /opt/data/profiles/work\n',
    'profiles/work/SOUL.md': 'work\n',
    'webui/sessions/a.json': '{}',
    '.install_method': 'docker\n',
    '.restic-password': 'secret\n',
    '.backup-status.json': '{}',
    '.gitignore': '# old allowlist\n',
    '.git/HEAD': 'ref: refs/heads/main\n',
    'home/.claude/settings.json': '{"hooks": "/opt/data/home/bin/hook"}',
    'home/.claude/projects/p/1.jsonl': '{"path": "/opt/data/home"}',
    'home/.claude.json': '{"home": "/opt/data/home"}',
    'home/.codex/config.toml': 'home = "/opt/data/home/.codex"\n',
    'home/.config/gh/hosts.yml': 'github.com: {}\n',
    'home/.gitconfig': '[safe]\n  directory = /opt/data\n',
}


def tree(root):
    """Every path under root with its content and mode -- what reverse must give back."""
    result = {}
    for path in sorted(root.rglob('*')):
        relative = str(path.relative_to(root))
        mode = path.stat().st_mode & 0o777
        result[relative] = (path.read_bytes() if path.is_file() else None, mode)
    return result


class MigrateHome(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.volume = Path(self.temporary.name) / 'volume'
        for relative, content in FIXTURE.items():
            path = self.volume / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        (self.volume / '.env').chmod(0o600)
        (self.volume / 'home/.config/gh/hosts.yml').chmod(0o600)

    def tearDown(self):
        self.temporary.cleanup()

    def migrate(self, *args, expect=0):
        result = subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True,
                                env=dict(os.environ, HARNESS_MIGRATE_VOLUME=str(self.volume)))
        self.assertEqual(result.returncode, expect, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def read(self, relative):
        return (self.volume / relative).read_text()

    def test_forward_gives_the_runtime_layout(self):
        self.migrate('--agents-stopped')
        v = self.volume
        self.assertFalse((v / 'home').exists())
        for relative in ('.hermes/config.yaml', '.hermes/state.db', '.hermes/state.db-wal', '.hermes/SOUL.md',
                         '.hermes/sessions/s1.json', '.hermes/profiles/work/SOUL.md', '.hermes-webui/sessions/a.json',
                         '.claude/projects/p/1.jsonl', '.config/gh/hosts.yml', '.git/HEAD',
                         '.config/contexture/restic-password'):
            self.assertTrue((v / relative).is_file(), relative)
        for gone in ('.gitignore', '.backup-status.json', '.hermes/.install_method', '.hermes/.git', 'webui'):
            self.assertFalse((v / gone).exists(), gone)
        self.assertEqual((v / '.hermes/.env').stat().st_mode & 0o777, 0o600, 'modes survive the move')
        self.assertEqual(self.read('.hermes/config.yaml'), 'terminal:\n  cwd: /store\nskills:\n  dir: /home/agent/.hermes/skills\n')
        self.assertEqual(self.read('.claude/settings.json'), '{"hooks": "/home/agent/bin/hook"}')
        self.assertEqual(self.read('.gitconfig'), '[safe]\n  directory = /home/agent/.hermes\n')
        self.assertEqual(self.read('.hermes/cron/jobs.json'), '{"script": "/home/agent/.hermes/scripts/run.sh"}')
        self.assertEqual(self.read('.hermes/profiles/work/config.yaml'), 'x: /home/agent/.hermes/profiles/work\n')
        self.assertEqual(self.read('.claude/projects/p/1.jsonl'), '{"path": "/opt/data/home"}', 'histories untouched')
        self.assertEqual(self.read('.claude/settings.json.pre-migrate'), FIXTURE['home/.claude/settings.json'])
        marker = json.loads(self.read('.local/state/contexture/home-layout.json'))
        self.assertEqual(marker['layout'], 2)
        self.assertIn('.hermes/config.yaml', marker['rewritten'])

    def test_reverse_gives_back_exactly_what_was_there(self):
        before = tree(self.volume)
        self.migrate('--agents-stopped')
        self.migrate('--reverse')
        self.assertEqual(tree(self.volume), before)

    def test_reverse_after_the_runtime_has_used_the_home(self):
        before = tree(self.volume)
        self.migrate('--agents-stopped')
        v = self.volume
        (v / '.hermes/state.db-wal').unlink()                    # Hermes checkpointed it away
        (v / '.hermes/installs/key').mkdir(parents=True)        # Hermes' runtime, since
        (v / '.hermes/installs/key/facts.json').write_text('{}')
        (v / '.ssh').mkdir()                                     # the agent, in its home
        (v / '.ssh/known_hosts').write_text('github.com ...')
        (v / '.local/state/contexture/harness-status.json').write_text('{}')
        out = self.migrate('--reverse')
        self.assertIn('deleted since the migration: .migrating-root/.hermes/state.db-wal', out)
        after = tree(v)
        for gone in ('.migrating-root', '.migrating-nested', '.migrate-home-dropped', '.hermes', '.ssh'):
            self.assertNotIn(gone, after, gone)
        self.assertEqual(after['installs/key/facts.json'][0], b'{}', 'new Hermes state goes to the Hermes root')
        self.assertEqual(after['home/.ssh/known_hosts'][0], b'github.com ...', 'new home entries go into home/')
        unchanged = {k: v for k, v in before.items() if k != 'state.db-wal'}
        for path, value in unchanged.items():
            self.assertEqual(after.get(path), value, path)

    def test_running_twice_is_a_no_op(self):
        self.migrate('--agents-stopped')
        after = tree(self.volume)
        self.assertIn('already in the runtime layout', self.migrate('--agents-stopped'))
        self.assertEqual(tree(self.volume), after)

    def test_collision_refuses_before_anything_moves(self):
        (self.volume / 'home/.hermes').mkdir()
        before = tree(self.volume)
        self.assertIn('.hermes', self.migrate('--agents-stopped', expect=1))
        self.assertEqual(tree(self.volume), before)

    def test_nested_collision_refuses_too(self):
        (self.volume / 'home/.config/contexture').mkdir()
        (self.volume / 'home/.config/contexture/restic-password').write_text('other')
        before = tree(self.volume)
        self.assertIn('home/.config/contexture/restic-password', self.migrate('--agents-stopped', expect=1))
        self.assertEqual(tree(self.volume), before)

    def test_refuses_without_the_acknowledgement_and_on_a_foreign_volume(self):
        self.assertIn('Stop the agents first', self.migrate(expect=1))
        (self.volume / 'config.yaml').unlink()
        (self.volume / 'state.db').unlink()
        self.assertIn('does not look like a Hermes-image volume', self.migrate('--agents-stopped', expect=1))


if __name__ == '__main__':
    unittest.main(verbosity=2)
