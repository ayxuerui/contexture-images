#!/usr/bin/env python3
"""The shared compose file: version parity, portability, and a store's include + override."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
REQUIRED = {'API_SERVER_KEY': 'k',
            'HERMES_WEBUI_ALLOWED_ORIGINS': 'https://store.example'}


def config(directory, *args, env=None):
    # A clean environment, so the runner's own variables cannot satisfy a required one.
    clean = {'PATH': os.environ['PATH'], 'HOME': os.environ.get('HOME', '/tmp'),
             **(env or {})}
    return subprocess.run(['docker', 'compose', *args, 'config', '--format', 'json'],
                          cwd=directory, env=clean, capture_output=True, text=True)


RUNTIME = ROOT / 'runtime' / 'compose.yaml'


class Runtime(unittest.TestCase):
    """runtime/compose.yaml, the deployment every store includes."""

    def render(self, *args, env=REQUIRED):
        result = config(RUNTIME.parent, '-f', RUNTIME.name, *args, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def everything(self):
        return self.render('--profile', 'init', '--profile', 'backup', '--profile', 'migrate')

    def test_version_matches_runtime_version(self):
        version = (ROOT / 'RUNTIME_VERSION').read_text().strip()
        pinned = re.findall(r'^x-image: &image ghcr\.io/ayxuerui/contexture-runtime:(\S+)$', RUNTIME.read_text(), re.M)
        self.assertEqual(pinned, [version])

    def test_every_service_pulls_the_version_tag(self):
        model = self.everything()
        version = (ROOT / 'RUNTIME_VERSION').read_text().strip()
        self.assertEqual({s['image'] for s in model['services'].values()},
                         {f'ghcr.io/ayxuerui/contexture-runtime:{version}'})
        self.assertEqual({s.get('pull_policy') for s in model['services'].values()}, {'always'})

    def test_portable(self):
        for name, service in self.everything()['services'].items():
            with self.subTest(service=name):
                self.assertNotIn('ports', service)
                self.assertNotIn('container_name', service)
                self.assertTrue(all(mount['type'] == 'volume' for mount in service.get('volumes', [])))

    def test_agents_keep_the_image_entrypoint_and_select_by_variable(self):
        agents = self.render()['services']['agents']
        self.assertIsNone(agents.get('entrypoint'))  # tini + the runtime entrypoint
        self.assertIsNone(agents.get('command'))
        env = agents['environment']
        self.assertEqual(env['HARNESSES'], 'hermes,hermes-webui,claude,codex,agy')
        self.assertEqual(env['TOOLS'], 'ctxr,cb,agent-browser')
        self.assertEqual(env['HARNESS_SERVICES'], 'hermes-gateway,hermes-dashboard,hermes-webui')
        self.assertEqual(env['RUNTIME_UPDATE_INTERVAL'], '86400')
        for retired in ('HERMES_DASHBOARD', 'HERMES_WEBUI_ENABLED', 'HARNESS_REMOTE_AGENTS', 'HERMES_HOME',
                        'HARNESS_PINS', 'HARNESS_UPDATE_INTERVAL'):
            self.assertNotIn(retired, env)
        mounts = {m['target']: m['source'] for m in agents['volumes']}
        self.assertEqual(mounts, {'/home/agent': 'home', '/store': 'store'}, 'everything installed lives in the home')

    def test_the_selection_reaches_the_backup_jobs(self):
        model = self.everything()
        agents = model['services']['agents']['environment']
        for name in ('harness-backup', 'harness-config-push', 'harness-backup-cron', 'harness-config-cron'):
            with self.subTest(service=name):
                service = model['services'][name]
                for variable in ('HARNESSES', 'TOOLS'):
                    self.assertEqual(service['environment'][variable], agents[variable])
                self.assertEqual({m['source'] for m in service['volumes']}, {'home'})
        self.assertEqual(model['services']['harness-backup']['entrypoint'], ['home-backup'])
        self.assertEqual(model['services']['harness-config-cron']['command'], ['home-config-push'])

    def test_the_old_backup_variable_names_still_work(self):
        env = dict(REQUIRED, HARNESS_BACKUP_DESTINATION='rclone:gdrive:old', HARNESS_CONFIG_REPO='git@x:old.git',
                   HOME_CONFIG_INCLUDE='.hermes/plugins/new/', HARNESS_CONFIG_INCLUDE='.hermes/plugins/old/',
                   HARNESS_BACKUP_INTERVAL='3600')
        model = self.render('--profile', 'backup', env=env)
        cron = model['services']['harness-backup-cron']['environment']
        self.assertEqual(cron['HOME_BACKUP_DESTINATION'], 'rclone:gdrive:old')
        self.assertEqual(cron['HARNESS_SCHEDULE_INTERVAL'], '3600')
        push = model['services']['harness-config-push']['environment']
        self.assertEqual(push['HOME_CONFIG_REPO'], 'git@x:old.git')
        self.assertEqual(push['HOME_CONFIG_INCLUDE'], '.hermes/plugins/new/', 'the new name wins')

    def test_serve_never_sees_the_home(self):
        model = self.render()
        serve = model['services']['serve']
        mounts = {m['target']: m['source'] for m in serve['volumes']}
        self.assertEqual(mounts, {'/home/agent': 'serve-home', '/store': 'store'},
                         'serve has a home of its own, never the agents\'')
        for name, service in self.everything()['services'].items():
            if name != 'serve':
                self.assertNotIn('serve-home', {m['source'] for m in service.get('volumes', [])}, name)
        self.assertIsNone(serve.get('entrypoint'), 'the runtime entrypoint installs its ctxr')
        env = serve['environment']
        self.assertEqual((env['HARNESSES'], env['TOOLS'], env['HARNESS_SERVICES']), ('', 'ctxr', 'ctxr-serve'))
        self.assertEqual(env['CTXR_UPDATE_STORE_ENABLED'], '0')
        agents = model['services']['agents']
        self.assertFalse(any('GITHUB_APP' in key for key in agents['environment']))
        self.assertNotIn('secrets', agents)

    def test_a_store_moves_by_renaming_the_volume_key(self):
        with tempfile.TemporaryDirectory() as temporary:
            store = Path(temporary)
            # The override in its own file: Compose before v5 refuses a service or volume declared
            # beside an `include` that also defines it ("conflicts with imported resource").
            (store / 'compose.yaml').write_text(f'''name: pkm-leilei
include:
  - {RUNTIME}
''')
            (store / 'compose.override.yaml').write_text('''services:
  agents:
    container_name: pkm-leilei-agents
volumes:
  home:
    name: pkm-leilei_data
    external: true
''')
            (store / '.env').write_text(''.join(f'{k}={v}\n' for k, v in REQUIRED.items()) +
                                        'HARNESS_SERVICES=hermes-gateway,hermes-webui,claude-remote\n')
            result = config(store)
            self.assertEqual(result.returncode, 0, result.stderr)
            model = json.loads(result.stdout)
        self.assertEqual(model['volumes']['home'], {'name': 'pkm-leilei_data', 'external': True})
        self.assertNotIn('harnesses', model['volumes'])
        self.assertEqual(model['services']['agents']['environment']['HARNESS_SERVICES'],
                         'hermes-gateway,hermes-webui,claude-remote')
        self.assertNotIn('data', model['volumes'])


if __name__ == '__main__':
    unittest.main()
