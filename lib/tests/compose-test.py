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
SHA = '0123456789abcdef0123456789abcdef01234567'
REQUIRED = {'CONTEXTURE_IMAGES_REF': SHA, 'API_SERVER_KEY': 'k',
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
        pinned = re.findall(r'contexture-hermes:([^-\s]+)-\$\{CONTEXTURE_IMAGES_REF', BASE.read_text())
        self.assertEqual(pinned, [version])

    def test_one_ref_pins_every_image(self):
        model = self.render('--profile', 'init', '--profile', 'backup')
        version = (ROOT / 'CTXR_VERSION').read_text().strip()
        images = {service['image'] for service in model['services'].values()}
        self.assertEqual(images, {f'ghcr.io/ayxuerui/contexture-hermes:{version}-{SHA}'})
        self.assertEqual(len(model['services']), 7)

    def test_ref_is_required(self):
        env = dict(REQUIRED)
        del env['CONTEXTURE_IMAGES_REF']
        result = config(BASE.parent, '-f', BASE.name, env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('CONTEXTURE_IMAGES_REF', result.stderr)

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


if __name__ == '__main__':
    unittest.main()
