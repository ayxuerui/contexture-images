#!/usr/bin/env python3
"""Hermes and its WebUI on the runtime image, for real: install, supervise, update, back up.

Needs the network: it installs Hermes with upstream's own installer into the home, one release
behind the latest (the install hook's test-only HERMES_INSTALL_COMMIT), then lets `hermes update`
take it to the latest. What it proves is the part of the design that only running Hermes can:

  - a fresh home boots to a gateway, dashboard and WebUI under supervisord, as `agent`, with
    Hermes' checkout in ~/.local/share/hermes-agent and the WebUI's in ~/.local/share/hermes-webui
  - `hermes gateway restart` exits 75 and supervisord relaunches it (--external-supervisor)
  - with a second profile, the one gateway still serves (Hermes 0.22.5+ multiplexes profiles)
  - --update runs `hermes update` and restarts the gateway, dashboard and WebUI onto the new code
  - home-backup takes ~/.hermes' databases through `hermes backup` and the rest as files, and
    restore brings the home back
  - a checkout whose runtime is missing (a damaged home) is reinstalled at boot
  - home-config-push would track the recipes' files and none of the credentials

    python3 lib/tests/runtime-hermes-test.py contexture-runtime:ci
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import uuid

IMAGE = sys.argv[1] if len(sys.argv) > 1 else 'contexture-runtime:ci'
NAME = 'runtime-hermes-test-' + uuid.uuid4().hex[:8]
SERVICES = 'hermes-gateway,hermes-dashboard,hermes-webui'


def docker(*args, check=True, timeout=1800):
    return subprocess.run(['docker', *args], check=check, capture_output=True, text=True, timeout=timeout)


def agent(*command, check=True, env=()):
    flags = [part for pair in env for part in ('-e', pair)]
    return docker('exec', '-u', 'agent', *flags, NAME, *command, check=check)


def sh(script, **kwargs):
    return agent('sh', '-ec', script, **kwargs).stdout


def eventually(check, seconds=900, what='condition'):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if check():
            return
        time.sleep(3)
    raise AssertionError(what + ' did not become true')


def healthy():
    return agent('runtime-install', 'status', check=False).returncode == 0


def pid(program):
    return agent('supervisorctl', 'pid', 'runtime:' + program).stdout.strip()


def github(path):
    out = subprocess.run(['curl', '-fsSL', 'https://api.github.com/repos/NousResearch/hermes-agent/' + path],
                         capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def releases():
    return [r['tag_name'].lstrip('v') for r in github('releases?per_page=10') if not r['prerelease'] and not r['draft']]


def start(*env):
    flags = [part for pair in env for part in ('-e', pair)]
    docker('run', '-d', '--name', NAME, '-v', f'{NAME}-home:/home/agent',
           '--mount', f'type=bind,src={store},dst=/store', '-e', 'CONTEXTURE_STORE_ROOT=/store',
           '-e', 'HARNESSES=hermes,hermes-webui', '-e', 'TOOLS=', '-e', f'HARNESS_SERVICES={SERVICES}',
           '-e', 'HERMES_WEBUI_HOST=127.0.0.1', '-e', 'HERMES_WEBUI_PORT=8787', '-e', 'CTXR_UPDATE_STORE_ENABLED=0',
           *flags, IMAGE)


latest, older = releases()[:2]
older_commit = github(f'commits/v{older}')['sha']
with tempfile.TemporaryDirectory() as temporary:
    store = Path(temporary)
    store.chmod(0o777)
    try:
        # --- fresh boot, one release behind -------------------------------------------------------
        start(f'HERMES_INSTALL_COMMIT={older_commit}')
        eventually(healthy, what=f'Hermes {older} installed and serving')
        assert older in agent('hermes', '--version').stdout
        assert sh('readlink -f "$(command -v hermes)"').startswith('/home/agent/.local/share/hermes-agent/')
        assert sh('test -f ~/.local/share/hermes-webui/server.py && echo ok').strip() == 'ok'
        # RUNNING means up for supervisord's 5 seconds, not yet listening: the dashboard can take longer.
        serving = lambda port: agent('curl', '-s', '-o', '/dev/null', '-w', '%{http_code}',
                                     f'http://127.0.0.1:{port}/', check=False).stdout not in ('', '000')
        for port in (8642, 9119, 8787):
            eventually(lambda: serving(port), seconds=180, what=f'something serving on {port}')
        assert docker('exec', NAME, 'ps', '-o', 'user=', '-C', 'supervisord').stdout.split()[:1] == ['agent']
        print(f'PASS: a fresh home boots Hermes {older}, its gateway, dashboard and WebUI, as agent, from the home')

        before = pid('hermes-gateway')
        agent('hermes', 'gateway', 'restart', '--yes')
        eventually(lambda: pid('hermes-gateway') not in ('0', before), seconds=120, what='gateway relaunched')
        assert 'exit status 75' in docker('logs', NAME).stdout
        print('PASS: `hermes gateway restart` exits 75 and supervisord relaunches the gateway')

        agent('hermes', 'profile', 'create', 'work')
        docker('restart', NAME)
        eventually(healthy, seconds=600, what='healthy after restart')
        programs = agent('supervisorctl', 'status', check=False).stdout  # exits 3: store-update is EXITED
        assert programs.count('hermes-gateway') == 1, programs
        print('PASS: a second profile adds no gateway program; the one gateway stays healthy')

        # --- update ---------------------------------------------------------------------------
        pids = {p: pid(p) for p in ('hermes-gateway', 'hermes-dashboard', 'hermes-webui')}
        out = agent('runtime-install', '--update', 'hermes').stdout
        assert latest in agent('hermes', '--version').stdout, out
        assert f'hermes: updated from {older} to {latest}' in out, out
        eventually(healthy, seconds=300, what='healthy after update')
        for program, old in pids.items():
            assert pid(program) not in ('0', old), f'{program} was not restarted onto {latest}'
        print(f'PASS: --update runs `hermes update` {older} -> {latest}; gateway, dashboard and WebUI restarted')

        # --- backup and restore ------------------------------------------------------------------
        sh('''
mkdir -p ~/.config/contexture ~/.claude/projects/p
echo pw > ~/.config/contexture/restic-password
echo '{"m":1}' > ~/.claude/projects/p/x.jsonl
echo 'original soul' > ~/.hermes/SOUL.md
HOME_BACKUP_DESTINATION=/tmp/restic HOME_BACKUP_MIN_FREE_MB=100 home-backup
''')
        listing = sh('RESTIC_REPOSITORY=/tmp/restic RESTIC_PASSWORD_FILE=~/.config/contexture/restic-password restic ls latest')
        assert '/tmp/harness-backup/hermes/hermes.zip' in listing
        assert '/home/agent/.claude/projects/p/x.jsonl' in listing
        assert '/home/agent/.hermes/state.db' not in listing, 'state.db must go in through hermes backup, not as a file'
        assert '/home/agent/.hermes/config.yaml' in listing, 'the rest of ~/.hermes goes in as files'
        assert '/home/agent/.local/share/hermes-agent/run_agent.py' in listing, 'the installed harness is backed up'
        agent('supervisorctl', 'stop', 'runtime:hermes-gateway', 'runtime:hermes-dashboard', 'runtime:hermes-webui')
        sh('rm -rf ~/.claude; echo damaged > ~/.hermes/SOUL.md; HARNESS_BACKUP_DESTINATION=/tmp/restic home-backup restore')
        assert sh('cat ~/.claude/projects/p/x.jsonl').strip() == '{"m":1}'
        assert sh('cat ~/.hermes/SOUL.md').strip() == 'original soul'
        agent('supervisorctl', 'start', 'runtime:hermes-gateway', 'runtime:hermes-dashboard', 'runtime:hermes-webui')
        eventually(healthy, seconds=300, what='healthy after restore')
        print('PASS: home-backup takes Hermes\' databases through `hermes backup`, and restore brings the home back')

        # --- a home without Hermes' runtime --------------------------------------------------------
        # A home damaged or copied without Hermes' runtime: the checkout is there, its interpreter is
        # not. The recipe's check must catch it and reinstall, not start a half-installed Hermes.
        docker('stop', '-t', '30', NAME)
        docker('run', '--rm', '--entrypoint', 'sh', '-v', f'{NAME}-home:/home/agent', IMAGE,
               '-c', 'rm -rf /home/agent/.hermes/tools /home/agent/.hermes/installs')
        docker('start', NAME)
        eventually(healthy, seconds=900, what='healthy after Hermes\' runtime was removed')
        assert 'hermes: installing' in docker('logs', NAME).stdout
        print('PASS: a checkout whose runtime is gone is reinstalled at boot, and serves')

        # --- config repository ---------------------------------------------------------------------
        staged = sh('''
echo token > ~/.codex-auth-probe; mkdir -p ~/.codex && echo t > ~/.codex/auth.json
git init -q --bare /tmp/config.git
git config --global user.email ci@example.com; git config --global user.name ci
HOME_CONFIG_REPO=/tmp/config.git HOME_CONFIG_ALLOW_UNVERIFIED_REMOTE=1 HOME_CONFIG_DRY_RUN=1 home-config-push
''')
        files = [line.split('\t', 1)[1] for line in staged.splitlines() if line.strip().startswith('A\t')]
        for wanted in ('.hermes/SOUL.md', '.hermes/config.yaml'):
            assert wanted in files, (wanted, files)
        # claude is not in this container's HARNESSES, so its history is not tracked: a harness's
        # state is tracked only when a selected harness's recipe names it.
        assert '.claude/projects/p/x.jsonl' not in files, files
        for secret in ('.hermes/.env', '.codex/auth.json', '.config/contexture/restic-password', '.hermes/state.db'):
            assert secret not in files, (secret, files)
        assert not any(f.startswith('.hermes/skills/') for f in files), 'bundled skills must not be tracked'
        print('PASS: home-config-push would track the selected recipes\' files and no credentials')
    except Exception:
        out = docker('logs', NAME, check=False)
        print(f'--- logs\n{out.stdout[-20000:]}{out.stderr[-5000:]}', file=sys.stderr)
        raise
    finally:
        docker('rm', '-f', NAME, check=False)
        docker('volume', 'rm', f'{NAME}-home', check=False)
