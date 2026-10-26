#!/usr/bin/env python3
"""Boot the runtime image for real -- tini, the entrypoint, supervisord -- with fake harnesses.

No network: the fake claude, codex and agy recipes keep the real recipes' services (so
harness-remote runs them exactly as it would the real CLIs) but install, into ~/.local/bin as their
publishers' installers do, a script that answers `--version` and otherwise prints who and where it
is, then sleeps ignoring SIGTERM, like a remote-control server that does not exit promptly. The
fake codex is given an `update` and is not self-updating, so the update path has one to move. That covers supervision without depending on
any publisher being up: privilege drop, HOME and cwd, one program restarting without the others,
an update restarting only its own harness's program, a bounded shutdown, PUID remapping, and a
configuration error stopping the container.

    python3 lib/tests/runtime-container-test.py contexture-runtime:ci
"""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

IMAGE = sys.argv[1] if len(sys.argv) > 1 else 'contexture-runtime:ci'
REPO = Path(__file__).resolve().parent.parent.parent
RUN = 'runtime-test-' + uuid.uuid4().hex[:8]

FAKE = '''#!/bin/sh
if [ "${1:-}" = --version ]; then cat "$HOME/.local/share/fake-$(basename "$0")/VERSION"; exit 0; fi
trap '' TERM
echo "ready $(basename "$0") uid=$(id -u) home=$HOME cwd=$(pwd)"
exec sleep 300
'''
INSTALL = '''#!/bin/sh
set -eu
mkdir -p "$HOME/.local/bin" "$HOME/.local/share/fake-{name}"
cat /test/latest > "$HOME/.local/share/fake-{name}/VERSION"
cp /test/fake "$HOME/.local/bin/{name}"
chmod +x "$HOME/.local/bin/{name}"
'''


def docker(*args, check=True):
    return subprocess.run(['docker', *args], check=check, capture_output=True, text=True)


def eventually(check, seconds=60, what='condition'):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if check():
            return
        time.sleep(0.5)
    raise AssertionError(what + ' did not become true')


def run(name, source, *extra, volumes=True):
    mounts = ['--mount', f'type=bind,src={source},dst=/test']
    if volumes:
        mounts += ['-v', f'{name}-home:/home/agent']
    return docker('run', '-d', '--name', name, '--network', 'none', *mounts,
                  '-e', 'RUNTIME_RECIPES=/test/recipes', '-e', 'CONTEXTURE_STORE_ROOT=/test/store',
                  '-e', 'HARNESSES=claude,codex,agy', '-e', 'TOOLS=', '-e', 'HARNESS_SERVICES=claude-remote,codex-remote,agy-remote',
                  *extra, IMAGE)


def agent(name, *command, check=True):
    return docker('exec', '-u', 'agent', name, *command, check=check)


def program_pid(name, program):
    return agent(name, 'supervisorctl', 'pid', 'runtime:' + program).stdout.strip()


def healthy(name):
    # As root, with no -u: that is how Docker runs a healthcheck, HOME=/root and all.
    return docker('exec', name, 'runtime-install', 'status', check=False).returncode == 0


def cleanup(name):
    docker('rm', '-f', name, check=False)
    docker('volume', 'rm', f'{name}-home', check=False)


with tempfile.TemporaryDirectory() as temporary:
    source = Path(temporary)
    source.chmod(0o777)
    (source / 'store').mkdir()
    (source / 'store').chmod(0o777)
    (source / 'fake').write_text(FAKE)
    (source / 'latest').write_text('1.0.0\n')
    (source / 'latest').chmod(0o666)
    for name in ('claude', 'codex', 'agy'):
        directory = source / 'recipes' / name
        directory.mkdir(parents=True)
        recipe = (REPO / 'lib' / 'recipes' / name / 'recipe.toml').read_text()
        scripts = ['install']
        if name == 'codex':
            recipe = recipe.replace('self_updating = true\n', '')
            scripts.append('update')
        (directory / 'recipe.toml').write_text(recipe)
        for script in scripts:
            (directory / script).write_text(INSTALL.format(name=name))
            (directory / script).chmod(0o755)
    names = [RUN, RUN + '-remap', RUN + '-bad']
    try:
        # --- supervision -------------------------------------------------------------------
        run(RUN, source)
        eventually(lambda: healthy(RUN), what='runtime-install status')
        logs = lambda: docker('logs', RUN).stdout
        for name in ('claude', 'codex', 'agy'):
            eventually(lambda: f'ready {name} uid=10000 home=/home/agent cwd=/test/store' in logs(),
                       what=f'{name} running as agent in the store')
        top = docker('exec', RUN, 'ps', '-o', 'user=,comm=', '-C', 'supervisord').stdout.split()
        assert top[:1] == ['agent'], ('supervisord must run as agent', top)
        assert docker('exec', RUN, 'ps', '-o', 'user=', '-p', '1').stdout.strip() == 'root'  # only tini
        print('PASS: boot installs, supervisord runs as agent, programs get HOME and the store cwd')

        before = {p: program_pid(RUN, p) for p in ('claude-remote', 'codex-remote', 'agy-remote')}
        docker('exec', RUN, 'pkill', '-KILL', '-f', 'harness-remote run codex')
        eventually(lambda: program_pid(RUN, 'codex-remote') not in ('0', before['codex-remote']),
                   what='codex-remote restarted')
        eventually(lambda: healthy(RUN), what='healthy after restart')
        for program in ('claude-remote', 'agy-remote'):
            assert program_pid(RUN, program) == before[program], (program, 'restarted with codex')
        print('PASS: one program restarts without the others')

        (source / 'latest').write_text('2.0.0\n')
        pids = {p: program_pid(RUN, p) for p in ('claude-remote', 'codex-remote', 'agy-remote')}
        agent(RUN, 'runtime-install', '--update')
        assert agent(RUN, 'codex', '--version').stdout.strip() == '2.0.0', 'PATH reaches the new version'
        assert agent(RUN, 'claude', '--version').stdout.strip() == '1.0.0', 'a self-updating harness was updated'
        eventually(lambda: program_pid(RUN, 'codex-remote') not in ('0', pids['codex-remote']),
                   what='codex-remote restarted by the update')
        assert program_pid(RUN, 'claude-remote') == pids['claude-remote'], 'update restarted claude-remote'
        assert json.loads(agent(RUN, 'cat', '/home/agent/.local/state/contexture/runtime-status.json').stdout
                          )['installed']['codex']['version'] == '2.0.0'
        print('PASS: --update moves what does not update itself and restarts only its program')

        start = time.monotonic()
        docker('stop', '--timeout', '30', RUN)
        elapsed = time.monotonic() - start
        assert elapsed < 15, f'stop took {elapsed:.1f}s: programs stopping one after another again?'
        code = docker('inspect', '--format', '{{.State.ExitCode}}', RUN).stdout.strip()
        assert code == '0', f'exit code {code}'
        docker('start', RUN)
        (source / 'latest').write_text('3.0.0\n')
        eventually(lambda: healthy(RUN), what='healthy after a restart')
        assert agent(RUN, 'codex', '--version').stdout.strip() == '2.0.0', 'boot must not move codex'
        print(f'PASS: bounded shutdown ({elapsed:.1f}s, exit 0); a restart keeps what is installed')

        # --- PUID remap ----------------------------------------------------------------------
        remap = RUN + '-remap'
        run(remap, source, '-e', 'PUID=10001', '-e', 'PGID=10001')
        eventually(lambda: healthy(remap), what='remapped container healthy')
        eventually(lambda: 'uid=10001 home=/home/agent' in docker('logs', remap).stdout, what='programs as 10001')
        owner = docker('exec', remap, 'stat', '-c', '%u', '/home/agent', '/home/agent/.local/bin/claude').stdout.split()
        assert owner == ['10001', '10001'], owner
        print('PASS: PUID/PGID remap the agent and its home')

        # --- configuration error ---------------------------------------------------------------
        bad = RUN + '-bad'
        run(bad, source, '-e', 'HARNESSES=claude,nope', volumes=False)
        eventually(lambda: docker('inspect', '--format', '{{.State.Running}}', bad).stdout.strip() == 'false',
                   what='a misconfigured container stopping')
        assert docker('inspect', '--format', '{{.State.ExitCode}}', bad).stdout.strip() == '2'
        assert 'nope, which has no recipe' in docker('logs', bad).stdout + docker('logs', bad).stderr
        print('PASS: a configuration error stops the container with exit 2')
    except Exception:
        for name in names:
            out = docker('logs', name, check=False)
            print(f'--- logs {name}\n{out.stdout}{out.stderr}', file=sys.stderr)
        raise
    finally:
        for name in names:
            cleanup(name)
