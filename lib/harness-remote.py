#!/opt/hermes/.venv/bin/python
"""Opt-in foreground remote harnesses under the image's existing s6 supervisor."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading

AGENTS = ('claude', 'codex', 'agy')
DEFAULT_ARGS = {
    'claude': ['--spawn', 'same-dir', '--permission-mode', 'plan'],
    'codex': ['--no-daemon', '-c', 'sandbox_mode="read-only"',
              '-c', 'approval_policy="on-request"'],
    # agy 1.3.3's internal OS-service entrypoint, not a public CLI contract.
    'agy': ['serve'],
}


def home():
    # Same default as the store-update service: the agent's tool-call home under HERMES_HOME.
    default = os.environ.get('HERMES_HOME', '/opt/data') + '/home'
    return os.environ.get('HARNESS_REMOTE_HOME', default)


def enabled():
    names = [name.strip() for name in os.environ.get('HARNESS_REMOTE_AGENTS', '').split(',')
             if name.strip()]
    unknown = set(names) - set(AGENTS)
    if unknown:
        raise ValueError('unknown remote harness: ' + ', '.join(sorted(unknown)))
    return set(names)


def command(name):
    # Blank means unset: a Compose file passes the variable through as an empty string.
    value = os.environ.get(f'HARNESS_REMOTE_{name.upper()}_ARGS', '').strip()
    args = json.loads(value) if value else DEFAULT_ARGS[name]
    if not isinstance(args, list) or not all(isinstance(arg, str) for arg in args):
        raise ValueError(f'{name} args must be a JSON array of strings')
    # Background launchers make supervision report a dead service as healthy.
    if name == 'codex' and ('--no-daemon' not in args or
                            any(arg in ('start', 'stop', 'pair') for arg in args)):
        raise ValueError('codex requires foreground --no-daemon without a daemon subcommand')
    if name == 'agy' and args != ['serve']:
        raise ValueError('agy requires foreground ["serve"]; OS-service management is unsupported')
    return [name, 'remote-control', *args]


def configuration():
    names = enabled()
    if names:
        root = os.environ.get('CONTEXTURE_STORE_ROOT', '')
        if not root or not Path(root).is_absolute() or not Path(root).is_dir():
            raise ValueError('CONTEXTURE_STORE_ROOT must be an existing absolute directory')
        directory = Path(home())
        if not directory.is_absolute() or not directory.is_dir():
            raise ValueError('HARNESS_REMOTE_HOME must be an existing absolute directory')
        for name in names:
            command(name)
    return names


def worker(name, argv):
    stopped = threading.Event()
    child = None

    def stop(_signum, _frame):
        stopped.set()
        if child is not None:
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        child = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 start_new_session=True)
    except OSError as error:
        print(f'[{name}] cannot start: {error}', flush=True)
        stopped.wait(10)
        return 1
    if stopped.is_set():
        stop(signal.SIGTERM, None)

    def output():
        for line in iter(child.stdout.readline, b''):
            sys.stdout.buffer.write(f'[{name}] '.encode() + line)
            sys.stdout.buffer.flush()

    reader = threading.Thread(target=output, daemon=True)
    reader.start()
    while child.poll() is None and not stopped.wait(0.2):
        pass
    if stopped.is_set():
        try:
            child.wait(timeout=8)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()
    # Clean up session descendants even when the server exits before its children.
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    reader.join(timeout=1)
    if not stopped.is_set():
        print(f'[{name}] exited {child.returncode}; retrying in 10 seconds', flush=True)
        stopped.wait(10)
    return child.returncode or 0


def status(names):
    healthy = True
    for name in AGENTS:
        if name not in names:
            print(f'{name}: disabled')
            continue
        result = subprocess.run(['/command/s6-svstat', '-o', 'up,pid',
                                 f'/run/service/{name}-remote'], capture_output=True, text=True)
        fields = result.stdout.split()
        running = False
        if not result.returncode and len(fields) == 2 and fields[0] == 'true':
            try:
                pid = fields[1]
                children = Path(f'/proc/{pid}/task/{pid}/children').read_text().split()
                running = any(Path(f'/proc/{child}/stat').read_text().split(') ', 1)[1][0]
                              not in ('Z', 'X') for child in children)
            except (OSError, IndexError):
                pass
        print(f'{name}: ' + ('running' if running else 'down or retrying'))
        healthy = healthy and running
    return 0 if healthy else 1


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else 'status'
    if action not in ('check-config', 'status', 'run', 'finish'):
        raise ValueError('usage: harness-remote [check-config|status|run NAME|finish NAME]')
    names = configuration()
    if action == 'check-config':
        return 0
    if action == 'status':
        return status(names)
    if len(sys.argv) != 3 or sys.argv[2] not in AGENTS:
        raise ValueError('run/finish requires claude, codex or agy')
    name = sys.argv[2]
    if action == 'finish':
        return 0 if name in names else 125
    if name not in names:
        return 0
    os.environ['HOME'] = home()
    os.chdir(os.environ['CONTEXTURE_STORE_ROOT'])
    return worker(name, command(name))


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError) as error:
        print(f'harness-remote: {error}', file=sys.stderr, flush=True)
        # Invalid configuration stays down rather than cycling forever; status fails.
        sys.exit(125 if len(sys.argv) > 1 and sys.argv[1] == 'finish' else 1)
