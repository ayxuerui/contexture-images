#!/usr/bin/env python3
"""harness-install against fake recipes in a temporary directory: no image, no network.

Each fake harness's `latest` reads a file the test writes, and its `install` writes a shell script
that prints its version -- or fails, when the test says so. That is enough to exercise what can go
wrong silently: a boot that upgrades when it should not, an update that leaves a broken version
current, a rollback copy pruned away, a stale link on PATH, and a supervisor config that quietly
runs a service nobody selected.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parent.parent / 'harness-install.py'

INSTALL = '''#!/bin/sh
set -eu
[ ! -e "$HARNESS_FAKE_DIR/fail-{name}" ] || {{ echo "told to fail" >&2; exit 1; }}
mkdir -p "$HARNESS_PREFIX/bin"
reported="$HARNESS_VERSION"
[ ! -e "$HARNESS_FAKE_DIR/serves-{name}" ] || reported="$(cat "$HARNESS_FAKE_DIR/serves-{name}")"
printf '#!/bin/sh\\necho "{name} $reported"\\n' > "$HARNESS_PREFIX/bin/{binary}"
sed -i "s/\\$reported/$reported/" "$HARNESS_PREFIX/bin/{binary}"
chmod +x "$HARNESS_PREFIX/bin/{binary}"
echo "$HARNESS_VERSION" >> "$HARNESS_FAKE_DIR/installs-{name}"
'''
LATEST = '#!/bin/sh\ncat "$HARNESS_FAKE_DIR/latest-{name}"\n'


class HarnessInstall(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        base = Path(self.temporary.name)
        self.recipes, self.root, self.run_dir = base / 'recipes', base / 'harnesses', base / 'run'
        self.fake, self.home = base / 'fake', base / 'home'
        for path in (self.recipes, self.fake, self.home):
            path.mkdir()
        self.recipe('alpha', 'alpha', services={'alpha-remote': ['alpha', 'serve']})
        self.recipe('beta', 'beta')
        self.recipe('gamma', 'gamma', requires=['alpha'], services={'gamma-web': ['gamma', 'web', '--port', '50%']})
        self.recipe('loose', 'loose', pinnable=False)
        for name in ('alpha', 'beta', 'gamma', 'loose'):
            self.publish(name, '1.0.0')

    def tearDown(self):
        self.temporary.cleanup()

    def recipe(self, name, binary, requires=(), services=None, pinnable=True, extra='', hooks=()):
        directory = self.recipes / name
        directory.mkdir()
        lines = [f'binaries = ["{binary}"]', f'requires = {json.dumps(list(requires))}',
                 f'pinnable = {"true" if pinnable else "false"}', extra]
        for program, command in (services or {}).items():
            lines += [f'[services.{program}]', f'command = {json.dumps(command)}',
                      'environment = { WHERE = "${HOME}/x" }']
        (directory / 'recipe.toml').write_text('\n'.join(lines) + '\n')
        for script, body in (('install', INSTALL), ('latest', LATEST)):
            (directory / script).write_text(body.format(name=name, binary=binary))
            (directory / script).chmod(0o755)
        if not (self.fake / f'latest-{name}').exists():
            self.publish(name, '1.0.0')
        for hook in hooks:
            (directory / hook).write_text(f'#!/bin/sh\necho "{hook} $HARNESS_PREFIX $*" >> "$HARNESS_FAKE_DIR/hooks-{name}"\n')
            (directory / hook).chmod(0o755)

    def publish(self, name, version):
        (self.fake / f'latest-{name}').write_text(version + '\n')

    def run_tool(self, *args, expect=0, **variables):
        environment = dict(os.environ, HARNESS_ROOT=str(self.root), HARNESS_RECIPES=str(self.recipes),
                           HARNESS_RUN_DIR=str(self.run_dir), HARNESS_FAKE_DIR=str(self.fake),
                           HOME=str(self.home), HARNESSES='', HARNESS_SERVICES='', HARNESS_PINS='')
        environment.update(variables)
        result = subprocess.run([sys.executable, str(SCRIPT), *args], env=environment,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, expect, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def current(self, name):
        return os.readlink(self.root / name / 'current')

    def versions(self, name):
        return sorted(p.name for p in (self.root / name).iterdir() if p.is_dir() and not p.is_symlink())

    def installs(self, name):
        path = self.fake / f'installs-{name}'
        return path.read_text().split() if path.exists() else []

    def status(self):
        return json.loads((self.home / '.local/state/contexture/harness-status.json').read_text())

    # --- configuration ---------------------------------------------------------------------

    def test_configuration_mistakes_fail_the_boot(self):
        cases = [
            ({'HARNESSES': 'alpha,nope'}, 'nope, which has no recipe'),
            ({'HARNESSES': 'gamma'}, 'gamma needs alpha'),
            ({'HARNESSES': 'alpha', 'HARNESS_SERVICES': 'gamma-web'}, 'offered by gamma, which is not in HARNESSES'),
            ({'HARNESSES': 'alpha', 'HARNESS_PINS': 'beta=1.0.0'}, 'pins beta, which is not in HARNESSES'),
            ({'HARNESSES': 'alpha', 'HARNESS_PINS': 'alpha'}, 'is not name=version'),
            ({'HARNESSES': 'alpha', 'HARNESS_PINS': 'alpha=../x'}, 'is not a version'),
        ]
        for variables, message in cases:
            with self.subTest(variables=variables):
                self.assertIn(message, self.run_tool(expect=2, **variables))
        self.assertFalse((self.root / 'alpha').exists(), 'a configuration error must install nothing')

    def test_check_validates_without_installing(self):
        self.assertIn('configuration ok: 2 harnesses, 1 services',
                      self.run_tool('check', HARNESSES='alpha,beta', HARNESS_SERVICES='alpha-remote'))
        self.assertFalse((self.root / 'alpha').exists())

    # --- boot -----------------------------------------------------------------------------------

    def test_boot_installs_latest_once_and_does_not_upgrade(self):
        self.run_tool(HARNESSES='alpha,beta')
        self.assertEqual(self.current('alpha'), '1.0.0')
        self.assertEqual(os.readlink(self.root / 'bin' / 'alpha'), '../alpha/current/bin/alpha')
        self.publish('alpha', '2.0.0')
        self.run_tool(HARNESSES='alpha,beta')
        self.assertEqual(self.current('alpha'), '1.0.0', 'boot must not upgrade an installed harness')
        self.assertEqual(self.installs('alpha'), ['1.0.0'])

    def test_failed_install_does_not_stop_the_others(self):
        (self.fake / 'fail-beta').touch()
        out = self.run_tool(HARNESSES='alpha,beta')
        self.assertIn('beta: FAILED', out)
        self.assertEqual(self.current('alpha'), '1.0.0')
        self.assertFalse((self.root / 'beta' / '1.0.0').exists(), 'a failed install leaves no directory')
        self.assertEqual(self.status()['harnesses']['beta']['state'], 'failed')

    def test_dropping_a_harness_removes_its_link(self):
        self.run_tool(HARNESSES='alpha,beta')
        self.run_tool(HARNESSES='alpha')
        self.assertFalse((self.root / 'bin' / 'beta').is_symlink())
        self.assertTrue((self.root / 'bin' / 'alpha').is_symlink())

    # --- update and rollback ----------------------------------------------------------------------

    def test_update_moves_to_latest_and_keeps_one_previous(self):
        self.run_tool(HARNESSES='alpha')
        for version in ('2.0.0', '3.0.0'):
            self.publish('alpha', version)
            self.run_tool('--update', HARNESSES='alpha')
        self.assertEqual(self.current('alpha'), '3.0.0')
        self.assertEqual(self.versions('alpha'), ['2.0.0', '3.0.0'])
        self.run_tool(HARNESSES='alpha')
        self.assertEqual(self.versions('alpha'), ['2.0.0', '3.0.0'], 'a boot that changes nothing must keep the rollback copy')

    def test_failed_update_keeps_current(self):
        self.run_tool(HARNESSES='alpha')
        self.publish('alpha', '2.0.0')
        (self.fake / 'fail-alpha').touch()
        self.assertIn('alpha: FAILED', self.run_tool('--update', HARNESSES='alpha'))
        self.assertEqual(self.current('alpha'), '1.0.0')
        self.assertEqual(self.versions('alpha'), ['1.0.0'])

    def test_wrong_version_is_refused_for_a_pinnable_harness(self):
        self.run_tool(HARNESSES='alpha')
        self.publish('alpha', '2.0.0')
        (self.fake / 'serves-alpha').write_text('2.0.1')
        self.assertIn('reports 2.0.1, expected 2.0.0', self.run_tool('--update', HARNESSES='alpha'))
        self.assertEqual(self.current('alpha'), '1.0.0')

    def test_unpinnable_harness_warns_and_installs(self):
        (self.fake / 'serves-loose').write_text('1.0.5')
        out = self.run_tool(HARNESSES='loose')
        self.assertIn('cannot pin and gave 1.0.5', out)
        self.assertEqual(self.current('loose'), '1.0.0')
        self.assertEqual(self.status()['harnesses']['loose']['reported'], '1.0.5')

    def test_pin_back_to_previous_is_a_flip_with_no_download(self):
        self.run_tool(HARNESSES='alpha')
        self.publish('alpha', '2.0.0')
        self.run_tool('--update', HARNESSES='alpha')
        self.run_tool(HARNESSES='alpha', HARNESS_PINS='alpha=1.0.0')
        self.assertEqual(self.current('alpha'), '1.0.0')
        self.assertEqual(self.installs('alpha'), ['1.0.0', '2.0.0'], 'rolling back must not reinstall')
        self.publish('alpha', '3.0.0')
        self.run_tool('--update', HARNESSES='alpha', HARNESS_PINS='alpha=1.0.0')
        self.assertEqual(self.current('alpha'), '1.0.0', 'an update must respect the pin')

    def test_update_of_one_name_leaves_the_others(self):
        self.run_tool(HARNESSES='alpha,beta')
        self.publish('alpha', '2.0.0')
        self.publish('beta', '2.0.0')
        self.run_tool('--update', 'alpha', HARNESSES='alpha,beta')
        self.assertEqual((self.current('alpha'), self.current('beta')), ('2.0.0', '1.0.0'))

    # --- supervisor programs -----------------------------------------------------------------------

    def programs(self):
        return (self.run_dir / 'programs.conf').read_text()

    def test_render_selects_only_named_services(self):
        self.run_tool(HARNESSES='alpha,gamma', HARNESS_SERVICES='gamma-web')
        conf = self.programs()
        self.assertIn('[program:gamma-web]', conf)
        self.assertNotIn('[program:alpha-remote]', conf, 'an installed harness runs only the services named')
        self.assertIn('command=gamma web --port 50%%', conf, 'a literal % must be doubled for supervisord')
        self.assertIn(f'environment=WHERE="{self.home}/x"', conf)
        self.assertIn('[program:store-update]', conf)
        self.assertIn('[program:harness-update]', conf)
        self.assertIn('[group:runtime]\nprograms=store-update,harness-update,gamma-web', conf,
                      'one group, so a shutdown stops every program in parallel')

    def test_defaults_in_recipe_values(self):
        self.recipe('ported', 'ported', extra='''
[services.ported-web]
command = ["ported", "--port", "${PORTED_PORT:-9000}", "--host", "${PORTED_HOST:-}"]
probe = "http://127.0.0.1:${PORTED_PORT:-9000}/"
''')
        self.run_tool(HARNESSES='ported', HARNESS_SERVICES='ported-web')
        self.assertIn('command=ported --port 9000 --host \'\'', self.programs())
        self.run_tool(HARNESSES='ported', HARNESS_SERVICES='ported-web', PORTED_PORT='9100')
        self.assertIn('command=ported --port 9100', self.programs())
        index = json.loads((self.run_dir / 'programs.json').read_text())
        self.assertEqual(index['ported-web'], {'owner': 'ported', 'probe': 'http://127.0.0.1:9100/'})

    def test_daily_update_can_be_turned_off_but_store_update_always_runs(self):
        self.run_tool(HARNESSES='alpha', CTXR_UPDATE_STORE_ENABLED='0', HARNESS_UPDATE_INTERVAL='0')
        conf = self.programs()
        self.assertIn('command=runtime-store-update', conf, 'its hooks run even with the store update off')
        self.assertNotIn('harness-update', conf)

    # --- Hermes-shaped recipes --------------------------------------------------------------------

    def test_forward_only_refuses_a_pin_backwards(self):
        self.recipe('stateful', 'stateful', extra='forward_only = true')
        self.publish('stateful', '2.0.0')
        self.run_tool(HARNESSES='stateful')
        out = self.run_tool(HARNESSES='stateful', HARNESS_PINS='stateful=1.0.0')
        self.assertIn('cannot go back from 2.0.0 to 1.0.0', out)
        self.assertEqual(self.current('stateful'), '2.0.0')
        self.publish('stateful', '2.1.0')
        self.run_tool('--update', HARNESSES='stateful')
        self.assertEqual(self.current('stateful'), '2.1.0', 'forward is fine')

    def test_hooks(self):
        self.recipe('hooked', 'hooked', hooks=('boot', 'gc', 'store-updated'))
        self.run_tool(HARNESSES='hooked')
        for version in ('2.0.0', '3.0.0'):
            self.publish('hooked', version)
            self.run_tool('--update', HARNESSES='hooked')
        self.run_tool('hook', 'store-updated', HARNESSES='hooked')
        calls = (self.fake / 'hooks-hooked').read_text().splitlines()
        self.assertEqual(calls[0], f'boot {self.root}/hooked/1.0.0 ', 'boot runs with the current prefix')
        self.assertIn(f'gc {self.root}/hooked/3.0.0 ', calls, 'gc runs after a version is pruned')
        self.assertEqual(calls[-1], f'store-updated {self.root}/hooked/3.0.0 ')
        self.assertEqual(sum(1 for c in calls if c.startswith('gc')), 1, 'only the update that pruned runs gc')

    def test_describe_lists_installed_harnesses_with_backup_and_config(self):
        self.recipe('kept', 'kept', extra='''
[backup]
covers = [".kept"]
exclude = [".kept/cache/"]
[config]
root = ".kept"
rules = "!/notes/"
''')
        self.run_tool(HARNESSES='kept,beta')
        entries = {e['name']: e for e in json.loads(self.run_tool('describe', HARNESSES='kept,beta'))}
        self.assertEqual(entries['kept']['backup'], {'covers': ['.kept'], 'exclude': ['.kept/cache/']})
        self.assertEqual(entries['kept']['prefix'], f'{self.root}/kept/1.0.0')
        self.assertEqual(entries['beta']['config'], {})

    def test_allowlist_keeps_what_recipes_name_and_never_credentials(self):
        self.recipe('statey', 'statey', extra='''
[config]
root = ".statey"
rules = """
!/config.yaml
!/sessions/
!/web/
web/*
!web/sessions/
state.db
*.log
"""
''')
        self.run_tool(HARNESSES='statey')
        out = Path(self.temporary.name) / 'allowlist'
        self.run_tool('allowlist', str(out), HARNESSES='statey')
        text = out.read_text().replace('@HARNESS_CONFIG_EXTENSIONS@\n', '')
        repo = Path(self.temporary.name) / 'repo'
        repo.mkdir()
        subprocess.run(['git', 'init', '-q', str(repo)], check=True)
        (repo / '.gitignore').write_text(text)
        files = {'.statey/config.yaml': False, '.statey/sessions/a.json': False, '.statey/state.db': True,
                 '.statey/sessions/run.log': True, '.statey/web/sessions/x.json': False,
                 '.statey/web/other.json': True, '.statey/logs/x': True, '.statey/.env': True,
                 '.statey/sessions/auth.json': True, '.other/keep.txt': True, 'stray.txt': True,
                 '.config/gh/hosts.yml': True}
        for path in files:
            (repo / path).parent.mkdir(parents=True, exist_ok=True)
            (repo / path).write_text('x')
        for path, ignored in files.items():
            with self.subTest(path=path):
                result = subprocess.run(['git', '-C', str(repo), 'check-ignore', '-q', path])
                self.assertEqual(result.returncode == 0, ignored, f'{path} ignored={not ignored} expected {ignored}')

    def test_service_of_a_failed_harness_is_skipped_and_reported(self):
        (self.fake / 'fail-alpha').touch()
        self.run_tool(HARNESSES='alpha', HARNESS_SERVICES='alpha-remote')
        self.assertNotIn('[program:alpha-remote]', self.programs())
        self.assertEqual(self.status()['skipped_programs'], ['alpha-remote'])
        self.assertIn('alpha-remote: not started', self.run_tool('status', expect=1, HARNESSES='alpha'))


if __name__ == '__main__':
    unittest.main(verbosity=2)
