#!/usr/bin/env python3
"""Exercise real s6-overlay with fake agents, isolated networking and disposable state."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import uuid

IMAGE = sys.argv[1] if len(sys.argv) > 1 else 'contexture-hermes:ci'
NAME = 'remote-runtime-test-' + uuid.uuid4().hex[:8]


def docker(*args, check=True):
    return subprocess.run(['docker', *args], check=check, capture_output=True, text=True)


def eventually(check, seconds=30):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if check():
            return
        time.sleep(0.3)
    raise AssertionError('condition did not become true')


def status():
    return docker('exec', NAME, 'harness-remote', 'status', check=False)


def pids():
    code = ('import subprocess,json; '
            'names=("claude-remote","codex-remote","agy-remote","main-hermes"); '
            'print(json.dumps({n:int(subprocess.check_output(["/command/s6-svstat",'
            '"-o","pid","/run/service/"+n])) for n in names}))')
    return json.loads(docker('exec', NAME, 'python3', '-c', code).stdout)


with tempfile.TemporaryDirectory() as temporary:
    source = Path(temporary)
    source.chmod(0o755)
    (source / 'store').mkdir()
    (source / 'bin').mkdir()
    for name in ('claude', 'codex', 'agy'):
        script = source / 'bin' / name
        script.write_text('''#!/opt/hermes/.venv/bin/python
import os,signal,time
signal.signal(signal.SIGTERM,signal.SIG_IGN)
print('ready uid='+str(os.getuid())+' home='+os.environ['HOME']+' cwd='+os.getcwd(),flush=True)
time.sleep(300)
''')
        script.chmod(0o755)
    try:
        docker('run', '-d', '--name', NAME, '--network', 'none',
               '--mount', f'type=bind,src={source},dst=/test,readonly',
               '-e', 'PATH=/test/bin:/opt/hermes/.venv/bin:/opt/hermes/bin:/usr/local/bin:/usr/bin:/bin:/command',
               '-e', 'HARNESS_REMOTE_AGENTS=claude,codex,agy',
               '-e', 'HARNESS_REMOTE_HOME=/tmp', '-e', 'CONTEXTURE_STORE_ROOT=/test/store',
               '-e', 'CTXR_UPDATE_STORE_ENABLED=0', IMAGE, 'sleep', 'infinity')
        eventually(lambda: status().returncode == 0)
        eventually(lambda: docker('logs', NAME).stdout.count('ready uid=10000 home=/tmp cwd=/test/store') == 3)
        before = pids()
        code = ('from pathlib import Path; import os; '
                f'p={before["codex-remote"]}; '
                'c=Path(f"/proc/{p}/task/{p}/children").read_text().split(); '
                'os.kill(int(c[0]),9)')
        docker('exec', NAME, 'python3', '-c', code)
        eventually(lambda: status().returncode != 0)
        eventually(lambda: pids()['codex-remote'] != before['codex-remote'] and status().returncode == 0)
        after = pids()
        for name in ('claude-remote', 'agy-remote', 'main-hermes'):
            assert before[name] == after[name], (name, before, after)
        start = time.monotonic()
        docker('stop', '--timeout', '20', NAME)
        elapsed = time.monotonic() - start
        assert elapsed < 15, elapsed
        assert docker('inspect', '--format', '{{.State.ExitCode}}', NAME).stdout.strip() == '0'
        print('PASS: s6 integration, privilege drop, HOME/cwd, failure health, isolated restart, bounded shutdown')
        docker('rm', '-v', NAME)
        docker('run', '-d', '--name', NAME, '--network', 'none',
               '-e', 'CTXR_UPDATE_STORE_ENABLED=0', IMAGE, 'sleep', 'infinity')
        eventually(lambda: status().returncode == 0)
        assert status().stdout.count('disabled') == 3
        eventually(lambda: all(docker('exec', NAME, '/command/s6-svstat', '-o', 'wantedup',
                                      '/run/service/' + name + '-remote').stdout.strip() == 'false'
                               for name in ('claude', 'codex', 'agy')))
        print('PASS: disabled services stay down; existing image invocation remains usable')
    except Exception:
        print(docker('logs', NAME, check=False).stdout, file=sys.stderr)
        raise
    finally:
        docker('rm', '-f', '-v', NAME, check=False)
