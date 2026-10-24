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
BASE = ROOT / 'harnesses' / 'hermes' / 'compose.yaml'
REQUIRED = {'API_SERVER_KEY': 'k',
            'HERMES_WEBUI_ALLOWED_ORIGINS': 'https://store.example'}


def config(directory, *args, env=None):
    # A clean environment, so the runner's own variables cannot satisfy a required one.
    clean = {'PATH': os.environ['PATH'], 'HOME': os.environ.get('HOME', '/tmp'),
             **(env or {})}
    return subprocess.run(['docker', 'compose', *args, 'config', '--format', 'json'],
                          cwd=directory, env=clean, capture_output=True, text=True)


class Base(unittest.TestCase):
    def render(self, *args, env=REQUIRED):
        result = config(BASE.parent, '-f', BASE.name, *args, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_version_matches_ctxr_version(self):
        version = (ROOT / 'CTXR_VERSION').read_text().strip()
        pinned = re.findall(r'^x-image: &image ghcr\.io/ayxuerui/contexture-hermes:(\S+)$', BASE.read_text(), re.M)
        self.assertEqual(pinned, [version])

    def test_every_service_pulls_the_version_tag(self):
        # The tag is rebuilt in place, so a cached build must never outlive a newer compose file.
        model = self.render('--profile', 'init', '--profile', 'backup')
        version = (ROOT / 'CTXR_VERSION').read_text().strip()
        self.assertEqual({s['image'] for s in model['services'].values()},
                         {f'ghcr.io/ayxuerui/contexture-hermes:{version}'})
        self.assertEqual({s.get('pull_policy') for s in model['services'].values()}, {'always'})
        self.assertEqual(len(model['services']), 7)

    def test_portable(self):
        for name, service in self.render('--profile', 'init', '--profile', 'backup')['services'].items():
            with self.subTest(service=name):
                self.assertNotIn('ports', service)
                self.assertNotIn('container_name', service)
                self.assertTrue(all(mount['type'] == 'volume' for mount in service.get('volumes', [])))

    def test_optional_settings_stay_off(self):
        agents = self.render()['services']['agents']
        self.assertEqual(agents['environment']['HARNESS_REMOTE_AGENTS'], '')
        self.assertIsNone(agents.get('entrypoint'))  # s6 must stay PID 1


    def test_approval_credential_is_off_by_default_and_never_reaches_agents(self):
        model = self.render()
        env = model['services']['serve']['environment']
        # Blank ID and blank key path together: ctxr refuses a key without an ID.
        self.assertEqual(env['CONTEXTURE_GITHUB_APP_ID'], '')
        self.assertEqual(env['CONTEXTURE_GITHUB_APP_PRIVATE_KEY_FILE'], '')
        agents = model['services']['agents']
        self.assertFalse(any('GITHUB_APP' in key for key in agents['environment']))
        self.assertNotIn('secrets', agents)
        self.assertEqual(model['secrets']['github-app-key']['file'], '/dev/null')

    def test_approval_credential_when_configured(self):
        env = {**REQUIRED, 'CONTEXTURE_GITHUB_APP_ID': '5354981',
               'CONTEXTURE_GITHUB_APP_PRIVATE_KEY_PATH': str(BASE)}
        model = self.render(env=env)
        serve = model['services']['serve']
        self.assertEqual(serve['environment']['CONTEXTURE_GITHUB_APP_PRIVATE_KEY_FILE'], '/run/secrets/github-app-key')
        self.assertEqual([s['target'] for s in serve['secrets']], ['/run/secrets/github-app-key'])
        self.assertNotIn('secrets', model['services']['agents'])

    def test_serve_lands_so_there_is_no_separate_runner(self):
        model = self.render('--profile', 'approvals', '--profile', 'init', '--profile', 'backup')
        self.assertNotIn('land-cron', model['services'])
        serve = model['services']['serve']
        store = [v for v in serve['volumes'] if v['source'] == 'store']
        self.assertEqual(len(store), 1)
        self.assertFalse(store[0].get('read_only', False))  # landing writes the store


class Store(unittest.TestCase):
    """A store includes the base and overrides only what is its own."""

    def test_include_and_override(self):
        with tempfile.TemporaryDirectory() as temporary:
            store = Path(temporary)
            (store / 'compose.yaml').write_text(f'''name: pkm
include:
  - {BASE}
''')
            (store / 'compose.override.yaml').write_text('''services:
  agents:
    container_name: pkm-hermes
    ports:
      - "127.0.0.1:8642:8642"
    environment:
      API_SERVER_CORS_ORIGINS: chrome-extension://example
volumes:
  data:
    name: pkm_pkm-data
    external: true
''')
            (store / '.env').write_text(''.join(f'{k}={v}\n' for k, v in REQUIRED.items()) +
                                        'HARNESS_REMOTE_AGENTS=claude\nCTXR_SERVE_PORT=8790\n')
            result = config(store)
            self.assertEqual(result.returncode, 0, result.stderr)
            model = json.loads(result.stdout)
        agents = model['services']['agents']
        self.assertEqual(agents['container_name'], 'pkm-hermes')
        self.assertEqual(agents['environment']['API_SERVER_CORS_ORIGINS'], 'chrome-extension://example')
        # The base's own settings survive the merge, and the store's .env reaches into the base.
        self.assertEqual(agents['environment']['API_SERVER_PORT'], '8642')
        self.assertEqual(agents['environment']['HARNESS_REMOTE_AGENTS'], 'claude')
        self.assertIn('8790', model['services']['serve']['command'])
        self.assertEqual(model['volumes']['data'], {'name': 'pkm_pkm-data', 'external': True})
        self.assertEqual(model['volumes']['store']['name'], 'pkm_store')


RUNTIME = ROOT / 'runtime' / 'compose.yaml'


class Runtime(unittest.TestCase):
    """runtime/compose.yaml, the successor stores move to one at a time."""

    def render(self, *args, env=REQUIRED):
        result = config(RUNTIME.parent, '-f', RUNTIME.name, *args, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def everything(self):
        return self.render('--profile', 'init', '--profile', 'backup', '--profile', 'migrate')

    def test_version_matches_ctxr_version(self):
        version = (ROOT / 'CTXR_VERSION').read_text().strip()
        pinned = re.findall(r'^x-image: &image ghcr\.io/ayxuerui/contexture-runtime:(\S+)$', RUNTIME.read_text(), re.M)
        self.assertEqual(pinned, [version])

    def test_every_service_pulls_the_version_tag(self):
        model = self.everything()
        version = (ROOT / 'CTXR_VERSION').read_text().strip()
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
        self.assertEqual(env['HARNESSES'], 'hermes,hermes-webui,claude,codex,agy,agent-browser,cb')
        self.assertEqual(env['HARNESS_SERVICES'], 'hermes-gateway,hermes-dashboard,hermes-webui')
        self.assertEqual(env['HARNESS_PINS'], '')
        for retired in ('HERMES_DASHBOARD', 'HERMES_WEBUI_ENABLED', 'HARNESS_REMOTE_AGENTS', 'HERMES_HOME'):
            self.assertNotIn(retired, env)
        mounts = {m['target']: m['source'] for m in agents['volumes']}
        self.assertEqual(mounts, {'/home/agent': 'home', '/opt/harnesses': 'harnesses', '/store': 'store'})

    def test_the_selection_reaches_the_backup_jobs(self):
        model = self.everything()
        for name in ('harness-backup', 'harness-config-push', 'harness-backup-cron', 'harness-config-cron'):
            with self.subTest(service=name):
                service = model['services'][name]
                self.assertEqual(service['environment']['HARNESSES'], model['services']['agents']['environment']['HARNESSES'])
                harnesses = [m for m in service['volumes'] if m['source'] == 'harnesses']
                self.assertEqual(len(harnesses), 1)
                self.assertTrue(harnesses[0].get('read_only'), 'the backup jobs never install')

    def test_serve_never_sees_the_home_or_the_harnesses(self):
        model = self.render()
        sources = {m['source'] for m in model['services']['serve']['volumes']}
        self.assertEqual(sources, {'store'})
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
        self.assertEqual(model['volumes']['harnesses']['name'], 'pkm-leilei_harnesses')
        self.assertEqual(model['services']['agents']['environment']['HARNESS_SERVICES'],
                         'hermes-gateway,hermes-webui,claude-remote')
        self.assertNotIn('data', model['volumes'])


if __name__ == '__main__':
    unittest.main()
