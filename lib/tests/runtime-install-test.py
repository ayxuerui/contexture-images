#!/usr/bin/env python3
"""runtime-install against fake recipes in a temporary directory: no image, no network.

Each fake recipe installs a shell script into the fake home's ~/.local/bin that prints the version
the test published -- the way a publisher's installer would -- or fails, when the test says so.
npm recipes go through a fake `npm` on PATH that does the same. That is enough to exercise what
can go wrong silently: a boot that updates when it should not, a self-updating harness updated
behind its back, a version that moved without its programs restarting, a harness in TOOLS, and a
supervisor config that quietly runs a service nobody selected.
"""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parent.parent / 'runtime-install.py'

# Writes ~/.local/bin/<binary>, printing the published version; logs each call.
WRITE_BINARY = '''#!/bin/sh
set -eu
[ ! -e "$FAKE_DIR/fail-{name}" ] || {{ echo "told to fail" >&2; exit 1; }}
mkdir -p "$HOME/.local/bin"
version="$(cat "$FAKE_DIR/latest-{name}")"
printf '#!/bin/sh\\necho "{name} %s"\\n' "$version" > "$HOME/.local/bin/{binary}"
chmod +x "$HOME/.local/bin/{binary}"
echo "$(basename "$0") $version" >> "$FAKE_DIR/calls-{name}"
'''

# A fake npm: `npm install -g <package>@<version>` as its installer would, from the published file.
NPM = '''#!/bin/sh
set -eu
[ "$1 $2" = "install -g" ] || exit 64
spec="$4"; package="${{spec%@*}}"
name="$(cat "$FAKE_DIR/npm-$(echo "$package" | tr / _)")"
[ ! -e "$FAKE_DIR/fail-$name" ] || {{ echo "npm told to fail" >&2; exit 1; }}
mkdir -p "$HOME/.local/bin"
version="$(cat "$FAKE_DIR/latest-$name")"
printf '#!/bin/sh\\necho "%s %s"\\n' "$name" "$version" > "$HOME/.local/bin/$name"
chmod +x "$HOME/.local/bin/$name"
echo "npm $spec $version" >> "$FAKE_DIR/calls-$name"
'''


class RuntimeInstall(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        base = Path(self.temporary.name)
        self.recipes, self.run_dir = base / 'recipes', base / 'run'
        self.fake, self.home, self.path = base / 'fake', base / 'home', base / 'path'
        for path in (self.recipes, self.fake, self.home, self.path):
            path.mkdir()
        (self.path / 'npm').write_text(NPM.format())
        (self.path / 'npm').chmod(0o755)
        self.recipe('alpha', services={'alpha-remote': ['alpha', 'serve']})
        self.recipe('beta')
        self.recipe('gamma', requires=['alpha'], services={'gamma-web': ['gamma', 'web', '--port', '50%']})
        self.recipe('selfy', self_updating=True, services={'selfy-remote': ['selfy', 'remote']})
        self.recipe('tooly', kind='tool', npm='@acme/tooly')

    def tearDown(self):
        self.temporary.cleanup()

    def recipe(self, name, kind='harness', binary=None, requires=(), services=None, npm=None,
               self_updating=False, extra='', hooks=(), update=True):
        binary = binary or name
        directory = self.recipes / name
        directory.mkdir()
        lines = [f'kind = "{kind}"', f'binaries = ["{binary}"]', f'requires = {json.dumps(list(requires))}']
        if npm:
            lines.append(f'npm = "{npm}"')
            (self.fake / ('npm-' + npm.replace('/', '_'))).write_text(name)
        if self_updating:
            lines.append('self_updating = true')
        lines.append(extra)
        for program, command in (services or {}).items():
            lines += [f'[services.{program}]', f'command = {json.dumps(command)}',
                      'environment = { WHERE = "${HOME}/x" }']
        (directory / 'recipe.toml').write_text('\n'.join(lines) + '\n')
        scripts = [] if npm else ['install'] + (['update'] if update and not self_updating else [])
        for script in scripts:
            (directory / script).write_text(WRITE_BINARY.format(name=name, binary=binary))
            (directory / script).chmod(0o755)
        for hook in hooks:
            (directory / hook).write_text(f'#!/bin/sh\necho "{hook} $RUNTIME_RECIPE_DIR $*" >> "$FAKE_DIR/hooks-{name}"\n')
            (directory / hook).chmod(0o755)
        self.publish(name, '1.0.0')

    def publish(self, name, version):
        (self.fake / f'latest-{name}').write_text(version + '\n')

    def run_tool(self, *args, expect=0, **variables):
        environment = dict(os.environ, RUNTIME_RECIPES=str(self.recipes), RUNTIME_RUN_DIR=str(self.run_dir),
                           FAKE_DIR=str(self.fake), HOME=str(self.home), HARNESSES='', TOOLS='',
                           HARNESS_SERVICES='', PATH=f'{self.path}:{os.environ["PATH"]}')
        for name in ('RUNTIME_STATUS_FILE', 'HARNESS_STATUS_FILE', 'RUNTIME_BIN', 'HOME_CONFIG_INCLUDE',
                     'HARNESS_CONFIG_INCLUDE', 'RUNTIME_UPDATE_INTERVAL', 'HARNESS_UPDATE_INTERVAL'):
            environment.pop(name, None)
        environment.update(variables)
        result = subprocess.run([sys.executable, str(SCRIPT), *args], env=environment,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, expect, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def calls(self, name):
        path = self.fake / f'calls-{name}'
        return path.read_text().splitlines() if path.exists() else []

    def status(self):
        return json.loads((self.home / '.local/state/contexture/runtime-status.json').read_text())

    def programs(self):
        return (self.run_dir / 'programs.conf').read_text()

    # --- configuration ---------------------------------------------------------------------

    def test_configuration_mistakes_fail_the_boot(self):
        cases = [
            ({'HARNESSES': 'alpha,nope'}, 'HARNESSES names nope, which has no recipe'),
            ({'HARNESSES': 'gamma'}, 'gamma needs alpha'),
            ({'HARNESSES': 'alpha', 'HARNESS_SERVICES': 'gamma-web'}, 'offered by gamma, which is not selected'),
            ({'HARNESSES': 'tooly'}, 'tooly is a tool: it belongs in TOOLS, not HARNESSES'),
            ({'TOOLS': 'alpha'}, 'alpha is a harness: it belongs in HARNESSES, not TOOLS'),
        ]
        for variables, message in cases:
            with self.subTest(variables=variables):
                self.assertIn(message, self.run_tool(expect=2, **variables))
        self.assertFalse((self.home / '.local/bin').exists(), 'a configuration error must install nothing')

    def test_a_recipe_must_say_its_kind(self):
        (self.recipes / 'beta' / 'recipe.toml').write_text('binaries = ["beta"]\n')
        self.assertIn('recipe beta must say kind', self.run_tool('check', expect=2))

    def test_check_validates_without_installing(self):
        self.assertIn('configuration ok: 2 harnesses, 1 tools, 1 services',
                      self.run_tool('check', HARNESSES='alpha,beta', TOOLS='tooly', HARNESS_SERVICES='alpha-remote'))
        self.assertFalse((self.home / '.local/bin').exists())

    # --- boot ---------------------------------------------------------------------------------

    def test_boot_installs_what_is_missing_into_the_home_and_nothing_else(self):
        self.run_tool(HARNESSES='alpha,selfy', TOOLS='tooly')
        for name in ('alpha', 'selfy', 'tooly'):
            self.assertTrue((self.home / '.local/bin' / name).exists(), name)
        self.assertEqual(self.calls('alpha'), ['install 1.0.0'])
        self.assertEqual(self.calls('tooly'), ['npm @acme/tooly@latest 1.0.0'], 'an npm tool goes through npm -g')
        self.publish('alpha', '2.0.0')
        self.run_tool(HARNESSES='alpha,selfy', TOOLS='tooly')
        self.assertEqual(self.calls('alpha'), ['install 1.0.0'], 'a boot never updates what is installed')
        installed = self.status()['installed']
        self.assertEqual(installed['alpha'], {'state': 'ok', 'kind': 'harness', 'version': '1.0.0'})
        self.assertEqual(installed['tooly']['kind'], 'tool')

    def test_install_only_installs_and_renders_nothing(self):
        self.recipe('booted', hooks=('boot',))
        self.run_tool('--install-only', HARNESSES='booted', TOOLS='tooly')
        self.assertTrue((self.home / '.local/bin/booted').exists())
        self.assertTrue((self.home / '.local/bin/tooly').exists())
        self.assertFalse((self.run_dir / 'programs.conf').exists(), 'workspace-init runs no supervisor')
        self.assertFalse((self.fake / 'hooks-booted').exists(), 'no boot hooks either')
        (self.fake / 'fail-beta').touch()
        self.run_tool('--install-only', HARNESSES='beta', expect=1)

    def test_failed_install_does_not_stop_the_others(self):
        (self.fake / 'fail-alpha').touch()
        self.run_tool(HARNESSES='alpha,beta')
        self.assertEqual(self.status()['installed']['alpha']['state'], 'failed')
        self.assertEqual(self.status()['installed']['beta']['state'], 'ok')
        self.assertIn('alpha: failed', self.run_tool('status', expect=1))

    def test_a_failing_check_reinstalls(self):
        self.recipe('split', extra='')
        (self.recipes / 'split' / 'check').write_text('#!/bin/sh\n[ -e "$FAKE_DIR/whole-split" ]\n')
        (self.recipes / 'split' / 'check').chmod(0o755)
        (self.fake / 'whole-split').touch()
        self.run_tool(HARNESSES='split')
        (self.fake / 'whole-split').unlink()
        # The installer leaves it whole again only when the check passes afterwards.
        (self.recipes / 'split' / 'install').write_text(WRITE_BINARY.format(name='split', binary='split')
                                                        + 'touch "$FAKE_DIR/whole-split"\n')
        self.run_tool(HARNESSES='split')
        self.assertEqual(self.calls('split'), ['install 1.0.0', 'install 1.0.0'],
                         'a binary on PATH is not enough when the check fails')

    # --- update ---------------------------------------------------------------------------------

    def test_update_runs_each_ones_own_update_and_never_a_self_updating_one(self):
        self.run_tool(HARNESSES='alpha,selfy', TOOLS='tooly')
        for name in ('alpha', 'selfy', 'tooly'):
            self.publish(name, '2.0.0')
        out = self.run_tool('--update', HARNESSES='alpha,selfy', TOOLS='tooly')
        self.assertEqual(self.calls('alpha'), ['install 1.0.0', 'update 2.0.0'])
        self.assertEqual(self.calls('tooly')[-1], 'npm @acme/tooly@latest 2.0.0')
        self.assertEqual(self.calls('selfy'), ['install 1.0.0'], 'a self-updating harness is never updated here')
        self.assertIn('alpha: updated from 1.0.0 to 2.0.0', out)
        self.assertEqual(self.status()['installed']['alpha']['version'], '2.0.0')

    def test_a_self_update_is_noticed_and_its_hook_runs(self):
        self.recipe('noticed', self_updating=True, hooks=('updated',))
        self.run_tool(HARNESSES='noticed')
        # It updated itself between two runs: its installer rewrote the binary.
        self.publish('noticed', '1.1.0')
        subprocess.run([str(self.recipes / 'noticed' / 'install')], check=True,
                       env=dict(os.environ, HOME=str(self.home), FAKE_DIR=str(self.fake)))
        out = self.run_tool('--update', HARNESSES='noticed')
        self.assertIn('noticed: updated itself from 1.0.0 to 1.1.0', out)
        self.assertEqual((self.fake / 'hooks-noticed').read_text().splitlines(),
                         [f'updated {self.recipes / "noticed"} '])

    def test_failed_update_keeps_what_was_installed(self):
        self.run_tool(HARNESSES='alpha')
        (self.fake / 'fail-alpha').touch()
        self.publish('alpha', '2.0.0')
        out = self.run_tool('--update', HARNESSES='alpha', expect=1)
        self.assertIn('FAILED: alpha', out, 'exits non-zero so the scheduler sends the failure out')
        entry = self.status()['installed']['alpha']
        self.assertEqual((entry['state'], entry['version']), ('failed', '1.0.0'))

    def test_a_full_disk_holds_updates_and_fails_the_healthcheck(self):
        self.run_tool(HARNESSES='alpha')
        self.publish('alpha', '2.0.0')
        full = {'RUNTIME_MIN_FREE_MB': str(10 ** 12)}
        out = self.run_tool('--update', HARNESSES='alpha', expect=1, **full)
        self.assertIn('not updating: only', out)
        self.assertEqual(self.calls('alpha'), ['install 1.0.0'], 'no update runs on a full disk')
        self.assertIn('disk: only', self.run_tool('status', expect=1, HARNESSES='alpha', **full))
        self.run_tool('--update', HARNESSES='alpha')
        self.assertEqual(self.calls('alpha')[-1], 'update 2.0.0', 'with room again, the update runs')

    def test_the_daily_update_reports_to_the_notify_target(self):
        self.run_tool(HARNESSES='alpha', HARNESS_NOTIFY_TARGET='telegram')
        self.assertIn('HARNESS_SCHEDULE_NOTIFY="telegram"', self.programs())

    def test_update_of_one_name_leaves_the_others(self):
        self.run_tool(HARNESSES='alpha,beta')
        self.publish('alpha', '2.0.0')
        self.publish('beta', '2.0.0')
        self.run_tool('--update', 'beta', HARNESSES='alpha,beta')
        self.assertEqual(self.calls('alpha'), ['install 1.0.0'])
        self.assertEqual(self.calls('beta'), ['install 1.0.0', 'update 2.0.0'])

    def test_hooks(self):
        self.recipe('hooked', hooks=('boot', 'updated', 'store-updated'))
        self.run_tool(HARNESSES='hooked')
        self.run_tool('--update', HARNESSES='hooked')
        self.publish('hooked', '2.0.0')
        self.run_tool('--update', HARNESSES='hooked')
        self.run_tool('hook', 'store-updated', HARNESSES='hooked')
        directory = self.recipes / 'hooked'
        self.assertEqual((self.fake / 'hooks-hooked').read_text().splitlines(),
                         [f'boot {directory} ', f'updated {directory} ', f'store-updated {directory} '],
                         '`updated` runs only when the version moved')

    # --- programs --------------------------------------------------------------------------------

    def test_render_selects_only_named_services(self):
        self.run_tool(HARNESSES='alpha,gamma', HARNESS_SERVICES='gamma-web')
        conf = self.programs()
        self.assertIn('[program:gamma-web]', conf)
        self.assertNotIn('[program:alpha-remote]', conf, 'an installed harness runs only the services named')
        self.assertIn('command=gamma web --port 50%%', conf, 'a literal % must be doubled for supervisord')
        self.assertIn(f'environment=WHERE="{self.home}/x"', conf)
        self.assertIn('[program:store-update]', conf)
        self.assertIn('[program:runtime-update]', conf)
        self.assertIn('[group:runtime]\nprograms=store-update,runtime-update,gamma-web', conf,
                      'one group, so a shutdown stops every program in parallel')

    def test_defaults_in_recipe_values(self):
        self.recipe('ported', extra='''
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

    def test_an_include_under_a_recipe_root_keeps_what_the_recipe_kept(self):
        # pkm, 2026-10-25: HARNESS_CONFIG_INCLUDE (now HOME_CONFIG_INCLUDE)=.hermes/plugins/... re-closed .hermes/ after the
        # Hermes recipe's block and one push untracked SOUL.md, config.yaml and every session.
        self.recipe('statey', extra='''
[config]
root = ".statey"
rules = """
!/config.yaml
!/plugins/
plugins/*
"""
''')
        self.run_tool(HARNESSES='statey')
        out = Path(self.temporary.name) / 'allowlist'
        self.run_tool('allowlist', str(out), HARNESSES='statey',
                      HOME_CONFIG_INCLUDE='.statey/plugins/mine/ .other/ext/manifest.json')
        repo = Path(self.temporary.name) / 'repo'
        repo.mkdir()
        subprocess.run(['git', 'init', '-q', str(repo)], check=True)
        (repo / '.gitignore').write_text(out.read_text().replace('@HARNESS_CONFIG_EXTENSIONS@\n', ''))
        files = {'.statey/config.yaml': False, '.statey/plugins/mine/plugin.py': False,
                 '.statey/plugins/theirs/plugin.py': True, '.other/ext/manifest.json': False,
                 '.other/ext/other.json': True, '.statey/plugins/mine/.env': True}
        for path in files:
            (repo / path).parent.mkdir(parents=True, exist_ok=True)
            (repo / path).write_text('x')
        for path, ignored in files.items():
            with self.subTest(path=path):
                result = subprocess.run(['git', '-C', str(repo), 'check-ignore', '-q', path])
                self.assertEqual(result.returncode == 0, ignored, f'{path}: expected ignored={ignored}')

    def test_allowlist_keeps_what_recipes_name_and_never_credentials(self):
        self.recipe('statey', extra='''
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

    def test_daily_update_can_be_turned_off_but_store_update_always_runs(self):
        self.run_tool(HARNESSES='alpha', CTXR_UPDATE_STORE_ENABLED='0', RUNTIME_UPDATE_INTERVAL='0')
        conf = self.programs()
        self.assertIn('command=runtime-store-update', conf, 'its hooks run even with the store update off')
        self.assertNotIn('runtime-update', conf)
        self.run_tool(HARNESSES='alpha', HARNESS_UPDATE_INTERVAL='0')
        self.assertNotIn('runtime-update', self.programs(), 'the old variable name is still read')

    def test_service_of_a_failed_harness_is_skipped_and_reported(self):
        (self.fake / 'fail-alpha').touch()
        self.run_tool(HARNESSES='alpha', HARNESS_SERVICES='alpha-remote')
        self.assertNotIn('[program:alpha-remote]', self.programs())
        self.assertEqual(self.status()['skipped_programs'], ['alpha-remote'])
        self.assertIn('alpha-remote: not started', self.run_tool('status', expect=1, HARNESSES='alpha'))

    # --- the backup jobs' view ------------------------------------------------------------------

    def test_wait_until_the_selection_is_installed(self):
        self.assertIn('gave up waiting: not installed: alpha',
                      self.run_tool('wait', expect=1, HARNESSES='alpha', RUNTIME_WAIT_SECONDS='0'))
        self.run_tool(HARNESSES='alpha')
        self.run_tool('wait', HARNESSES='alpha', RUNTIME_WAIT_SECONDS='0')
        with open(self.home / '.local/state/contexture/runtime-install.lock', 'w') as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            self.assertIn('an install is still running',
                          self.run_tool('wait', expect=1, HARNESSES='alpha', HARNESS_WAIT_SECONDS='0'))

    def test_describe_lists_installed_recipes_with_backup_and_config(self):
        self.recipe('kept', extra='''
[backup]
exclude = [".kept/**/*.db"]
[config]
root = ".kept"
rules = "!/notes/"
''')
        self.run_tool(HARNESSES='kept,beta', TOOLS='tooly')
        entries = {e['name']: e for e in json.loads(self.run_tool('describe', HARNESSES='kept,beta,alpha', TOOLS='tooly'))}
        self.assertNotIn('alpha', entries, 'only what is installed')
        self.assertEqual(entries['kept']['backup'], {'exclude': ['.kept/**/*.db']})
        self.assertEqual(entries['kept']['recipe_dir'], str(self.recipes / 'kept'))
        self.assertEqual(entries['tooly']['kind'], 'tool')
        self.assertEqual(entries['beta']['config'], {})


if __name__ == '__main__':
    unittest.main(verbosity=2)
