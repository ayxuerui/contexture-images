#!/usr/bin/env python3
"""Install, update and supervise a runtime container's harnesses and tools.

Shipped as `runtime-install` in the contexture-runtime image (formerly `harness-install`). Everything
it installs goes into the agent's home, the way each publisher's own installer puts it, and the whole
home is backed up. See docs/design/harnesses-in-home.md.

    runtime-install                 at boot: install what is missing, render the programs
    runtime-install --update [NAME] run each one's update; restart the programs of what moved
    runtime-install --install-only  install what is missing; no hooks, no programs (workspace-init)
    runtime-install status          exit 0 only when everything is installed and every program serves
    runtime-install check           validate the variables against the recipes; install nothing
    runtime-install wait            block until everything selected is installed (the backup jobs)
    runtime-install hook NAME       run every installed recipe's NAME hook (store-updated, ...)
    runtime-install describe        JSON: each installed recipe's backup and config entries
    runtime-install allowlist PATH  render the config repository's allowlist from the recipes

Two kinds, chosen by two compose variables:

    HARNESSES         the agents: hermes, hermes-webui, claude, codex, agy
    TOOLS             what agents use: ctxr, cb, agent-browser
    HARNESS_SERVICES  the harnesses' programs to run (hermes-gateway, claude-remote, ...)

Each name is a recipe, lib/recipes/<name>/recipe.toml, declaring its `kind` and one way to install:

    npm = "<package>"   an npm package: `npm install -g` into NPM_CONFIG_PREFIX (~/.local), so its
                        binaries land in ~/.local/bin with everyone else's; updated to @latest
    an `install` script the publisher's own installer, run as the agent with its real HOME;
                        an `update` script, if the recipe has one, is its own update command
    self_updating = true  installed once by its own installer, which then keeps it current itself
                        (claude, codex, agy); never updated here, only its version recorded

No versions are kept or pinned here: each publisher's installer owns its layout. What is left is
what nothing else does -- installing on an empty home, the daily update for what does not update
itself, turning HARNESS_SERVICES into supervisor programs, and restarting a harness's programs
when its version moves.

Standard library only: this runs on Debian's python3, before anything is installed.
"""
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import string
import subprocess
import sys
import time
import tomllib


def home():
    return Path(os.environ.get('HOME', '/home/agent'))


RECIPES = Path(os.environ.get('RUNTIME_RECIPES', '/usr/local/share/contexture/recipes'))
RUN_DIR = Path(os.environ.get('RUNTIME_RUN_DIR', '/run/harness'))
PROGRAMS_CONF = RUN_DIR / 'programs.conf'
PROGRAMS_INDEX = RUN_DIR / 'programs.json'
# Every program is rendered into this one supervisor group. supervisord stops groups one after
# another but signals every process in a group in the same pass, so one group is what makes a
# shutdown parallel: three remote sessions each given harness-remote's 8 seconds to exit would
# otherwise take 24, past compose's default 10-second stop grace.
GROUP = 'runtime'
VERSION = re.compile(r'\d+\.\d+(?:\.\d+)?(?:[-+.][0-9A-Za-z.]+)?')
KINDS = ('harness', 'tool')
TRUE = {'1', 'true', 'yes', 'on'}
FALSE = {'0', 'false', 'no', 'off'}


class ConfigError(Exception):
    """A deployment mistake: wrong name, wrong kind, missing dependency. Fails the boot, loudly."""


def log(message):
    print('runtime-install: ' + message, flush=True)


def bin_dir():
    return Path(os.environ.get('RUNTIME_BIN', str(home() / '.local' / 'bin')))


def state_dir():
    return home() / '.local' / 'state' / 'contexture'


def status_file():
    # Fixed by the image (RUNTIME_STATUS_FILE), not derived from HOME: Docker runs the healthcheck
    # as root, whose HOME is /root, and `status` must read the agent's file all the same.
    configured = os.environ.get('RUNTIME_STATUS_FILE') or os.environ.get('HARNESS_STATUS_FILE')
    return Path(configured) if configured else state_dir() / 'runtime-status.json'


def lock_file():
    return state_dir() / 'runtime-install.lock'


def names(variable):
    return [part.strip() for part in os.environ.get(variable, '').split(',') if part.strip()]


# --- Recipes ---------------------------------------------------------------------------------------

class Recipe:
    def __init__(self, directory):
        self.name = directory.name
        self.directory = directory
        with open(directory / 'recipe.toml', 'rb') as handle:
            data = tomllib.load(handle)
        self.kind = data.get('kind')
        if self.kind not in KINDS:
            raise ConfigError(f'recipe {self.name} must say kind = "harness" or "tool"')
        self.binaries = list(data.get('binaries', []))
        if not self.binaries:
            raise ConfigError(f'recipe {self.name} names no binaries')
        self.npm = data.get('npm')
        self.self_updating = bool(data.get('self_updating', False))
        if not self.npm and not self.hook('install'):
            raise ConfigError(f'recipe {self.name} has neither npm = "<package>" nor an install script')
        self.requires = list(data.get('requires', []))
        # Harnesses whose update must restart this one's programs too: the WebUI runs Hermes' code
        # in-process, so a Hermes update restarts it.
        self.restart_with = list(data.get('restart_with', []))
        # What home-backup and home-config-push do with this one's state.
        self.backup = dict(data.get('backup', {}))
        self.config = dict(data.get('config', {}))
        for key in ('snapshot', 'restore'):
            if key in self.backup and not self.hook(self.backup[key]):
                raise ConfigError(f'recipe {self.name}: backup.{key} names no executable script')
        self.services = {}
        for program, spec in data.get('services', {}).items():
            command = spec.get('command')
            if not isinstance(command, list) or not command or not all(isinstance(a, str) for a in command):
                raise ConfigError(f'recipe {self.name}: service {program} needs a command list')
            self.services[program] = {
                'command': command,
                'directory': spec.get('directory', '${HOME}'),
                'environment': dict(spec.get('environment', {})),
                # A URL that answers once the program is serving; any HTTP response counts.
                # supervisord's RUNNING means "up for startsecs", not "listening".
                'probe': spec.get('probe'),
            }

    def hook(self, name):
        path = self.directory / name
        return path if os.access(path, os.X_OK) else None


def load_recipes():
    if not RECIPES.is_dir():
        raise ConfigError(f'no recipes at {RECIPES}')
    recipes = {}
    for directory in sorted(RECIPES.iterdir()):
        if (directory / 'recipe.toml').is_file():
            recipes[directory.name] = Recipe(directory)
    programs = {}
    for recipe in recipes.values():
        for program in recipe.services:
            if program in programs or program in PLATFORM_PROGRAMS:
                raise ConfigError(f'program {program} is claimed twice ({programs.get(program, "platform")}, {recipe.name})')
            programs[program] = recipe.name
    return recipes


def configuration():
    """Read and check HARNESSES, TOOLS and HARNESS_SERVICES; every mistake is a ConfigError."""
    recipes = load_recipes()
    chosen = {'harness': names('HARNESSES'), 'tool': names('TOOLS')}
    selected = []
    for kind, variable in (('harness', 'HARNESSES'), ('tool', 'TOOLS')):
        for name in chosen[kind]:
            if name not in recipes:
                raise ConfigError(f'{variable} names {name}, which has no recipe (have: {", ".join(recipes)})')
            if recipes[name].kind != kind:
                other = 'TOOLS' if recipes[name].kind == 'tool' else 'HARNESSES'
                raise ConfigError(f'{name} is a {recipes[name].kind}: it belongs in {other}, not {variable}')
            if name not in selected:
                selected.append(name)
    for name in selected:
        for needed in recipes[name].requires:
            if needed not in selected:
                raise ConfigError(f'{name} needs {needed}, which is not selected')
    offered = {program: name for name in selected for program in recipes[name].services}
    services = names('HARNESS_SERVICES')
    for program in services:
        if program not in offered:
            owner = next((r.name for r in recipes.values() if program in r.services), None)
            hint = f' (offered by {owner}, which is not selected)' if owner else ''
            raise ConfigError(f'HARNESS_SERVICES names {program}, which no selected harness offers{hint}')
    return recipes, selected, services, offered


# --- Installed? ------------------------------------------------------------------------------------

def run_hook(recipe, name, *args, timeout=1800, quiet=False):
    """Run one of a recipe's scripts as the agent; a failure is logged, not raised."""
    path = recipe.hook(name)
    if not path:
        return True
    environment = dict(os.environ, RUNTIME_RECIPE_DIR=str(recipe.directory))
    result = subprocess.run([str(path), *args], env=environment, timeout=timeout,
                            capture_output=quiet, text=True)
    if result.returncode != 0 and not quiet:
        log(f'{recipe.name}: {name} exited {result.returncode}')
    return result.returncode == 0


def installed(recipe):
    """Every binary in ~/.local/bin and runnable, and the recipe's `check` hook, if any, passing.

    The hook is for an install that a binary alone does not prove: Hermes' launcher points at an
    interpreter under ~/.hermes/tools, gone from a home restored without it."""
    for binary in recipe.binaries:
        path = bin_dir() / binary
        if not (path.exists() and os.access(path, os.X_OK)):
            return False
    return run_hook(recipe, 'check', quiet=True) if recipe.hook('check') else True


def version_of(recipe):
    binary = bin_dir() / recipe.binaries[0]
    try:
        result = subprocess.run([str(binary), '--version'], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    match = VERSION.search(result.stdout + '\n' + result.stderr)
    return match.group(0) if result.returncode == 0 and match else None


def npm_global(package, version='latest'):
    """`npm install -g` as the agent: NPM_CONFIG_PREFIX (~/.local, set by the image) is writable."""
    result = subprocess.run(['npm', 'install', '-g', '--loglevel=error', f'{package}@{version}'],
                            capture_output=True, text=True, timeout=1800)
    if result.returncode != 0:
        raise RuntimeError(f'npm install -g {package}@{version} failed: {(result.stderr or result.stdout).strip()[-300:]}')


def install(recipe):
    log(f'{recipe.name}: installing')
    if recipe.hook('install'):
        if not run_hook(recipe, 'install'):
            raise RuntimeError('its install script failed')
    else:
        npm_global(recipe.npm)
    if not installed(recipe):
        raise RuntimeError(f'installed, but {", ".join(recipe.binaries)} not in {bin_dir()} or its check fails')


def update(recipe):
    """Run its own update: the recipe's `update` script, or npm's @latest for an npm package."""
    if recipe.hook('update'):
        if not run_hook(recipe, 'update'):
            raise RuntimeError('its update script failed')
    elif recipe.npm:
        npm_global(recipe.npm)


# --- Supervisor programs ---------------------------------------------------------------------------

# Programs the platform itself runs, beside whatever HARNESS_SERVICES selects.
PLATFORM_PROGRAMS = {
    # Once per container start, never restarted, never failing the boot. runtime/store-update.sh
    # reads CTXR_UPDATE_STORE_ENABLED for the store update itself, and runs the recipes'
    # store-updated hooks either way.
    'store-update': {'command': ['runtime-store-update'], 'oneshot': True, 'enabled': lambda: True},
    # The daily update, in this container because it restarts this container's programs.
    'runtime-update': {'command': ['runtime-schedule', 'runtime-install', '--update'], 'oneshot': False,
                       'environment': {'HARNESS_SCHEDULE_INTERVAL': '${RUNTIME_UPDATE_INTERVAL}',
                                       'HARNESS_SCHEDULE_NAME': 'runtime-update',
                                       'HARNESS_SCHEDULE_SKIP_FIRST': '1'},
                       'enabled': lambda: update_interval() not in ('', '0')},
}


def update_interval():
    return (os.environ.get('RUNTIME_UPDATE_INTERVAL') or os.environ.get('HARNESS_UPDATE_INTERVAL') or '86400').strip()


def expand(value, extra=None):
    environment = dict(os.environ)
    environment['RUNTIME_UPDATE_INTERVAL'] = update_interval()
    environment.setdefault('HOME', str(home()))
    environment.update(extra or {})
    # ${NAME:-default}, as a shell has it: the default when NAME is unset or empty.
    value = re.sub(r'\$\{(\w+):-([^}]*)\}', lambda m: environment.get(m.group(1)) or m.group(2), value)
    return string.Template(value).safe_substitute(environment)


def supervisor_value(value):
    if '\n' in value or '"' in value:
        raise ConfigError(f'value {value!r} cannot be written to the supervisor config')
    # supervisord interpolates %(...)s in every value; a literal % must be doubled.
    return value.replace('%', '%%')


def program_block(program, spec, oneshot, extra=None):
    command = shlex.join(expand(part, extra) for part in spec['command'])
    lines = [f'[program:{program}]',
             f'command={supervisor_value(command)}',
             f'directory={supervisor_value(expand(spec.get("directory", "${HOME}"), extra))}',
             'autostart=true',
             'stdout_logfile=/dev/stdout', 'stdout_logfile_maxbytes=0', 'redirect_stderr=true',
             'stopasgroup=true', 'killasgroup=true', 'stopwaitsecs=10']
    if oneshot:
        lines += ['autorestart=false', 'startsecs=0']
    else:
        # Restart on any exit: `hermes gateway run --external-supervisor` exits 75 on purpose and
        # expects to be relaunched. A program that cannot stay up for startsecs, three times in a
        # row, goes FATAL -- reported by `runtime-install status` rather than looping unseen.
        lines += ['autorestart=true', 'startsecs=5', 'startretries=3']
    environment = {key: expand(value, extra) for key, value in spec.get('environment', {}).items()}
    if environment:
        pairs = ','.join(f'{key}="{supervisor_value(value)}"' for key, value in sorted(environment.items()))
        lines.append('environment=' + pairs)
    return '\n'.join(lines) + '\n'


def render(recipes, services, offered, ready):
    blocks, rendered, skipped, owners = [], [], [], {}
    for program, spec in PLATFORM_PROGRAMS.items():
        if spec['enabled']():
            blocks.append(program_block(program, spec, spec['oneshot']))
            rendered.append(program)
    for program in services:
        owner = offered[program]
        if owner not in ready:
            skipped.append(program)
            continue
        spec = recipes[owner].services[program]
        extra = {'RUNTIME_RECIPE_DIR': str(recipes[owner].directory)}
        blocks.append(program_block(program, spec, False, extra))
        rendered.append(program)
        owners[program] = {'owner': owner, 'probe': expand(spec['probe'], extra) if spec.get('probe') else None}
    if rendered:
        blocks.append(f'[group:{GROUP}]\nprograms={",".join(rendered)}\n')
    RUN_DIR.mkdir(parents=True, exist_ok=True)
    temporary = PROGRAMS_CONF.with_suffix('.tmp')
    temporary.write_text('# Generated by runtime-install at boot. Do not edit: it is rewritten every start.\n\n'
                         + '\n'.join(blocks))
    os.replace(temporary, PROGRAMS_CONF)
    PROGRAMS_INDEX.write_text(json.dumps(owners, indent=2, sort_keys=True) + '\n')
    return rendered, skipped


def supervisorctl(*args):
    return subprocess.run(['supervisorctl', *args], capture_output=True, text=True, timeout=120)


def supervisor_running():
    return (RUN_DIR / 'supervisor.sock').exists() and supervisorctl('pid').returncode == 0


def read_owners():
    try:
        return json.loads(PROGRAMS_INDEX.read_text())
    except (OSError, ValueError):
        return {}


def read_rendered():
    try:
        return re.findall(r'^\[program:([^\]]+)\]', PROGRAMS_CONF.read_text(), re.M)
    except OSError:
        return []


# --- Commands ------------------------------------------------------------------------------------

def write_status(report):
    path = status_file()
    path.parent.mkdir(parents=True, exist_ok=True)
    report['time'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    os.replace(temporary, path)


def locked():
    lock_file().parent.mkdir(parents=True, exist_ok=True)
    handle = open(lock_file(), 'w')
    fcntl.flock(handle, fcntl.LOCK_EX)
    return handle


def previous_versions():
    try:
        return {name: entry.get('version') for name, entry in
                json.loads(status_file().read_text()).get('installed', {}).items()}
    except (OSError, ValueError):
        return {}


def converge(update_all, only=(), programs=True):
    recipes, selected, services, offered = configuration()
    with locked():
        before = previous_versions()
        report = {'installed': {}}
        moved = []
        for name in selected:
            recipe = recipes[name]
            try:
                if not installed(recipe):
                    install(recipe)
                elif update_all and (not only or name in only) and not recipe.self_updating:
                    update(recipe)
                version = version_of(recipe)
                if not installed(recipe):
                    raise RuntimeError('not runnable after its update')
                if before.get(name) and version and version != before[name]:
                    how = 'updated itself' if recipe.self_updating else 'updated'
                    log(f'{name}: {how} from {before[name]} to {version}')
                    moved.append(name)
                report['installed'][name] = {'state': 'ok', 'kind': recipe.kind, 'version': version}
            except Exception as error:  # one failing must not stop the others
                log(f'{name}: FAILED: {error}')
                report['installed'][name] = {'state': 'failed', 'kind': recipe.kind,
                                             'error': str(error)[:500], 'version': version_of(recipe)}
        ready = {name for name in selected if report['installed'][name]['state'] == 'ok'
                 or installed(recipes[name])}
        if update_all:
            if supervisor_running():
                owners = read_owners()
                for name in moved:
                    programs = sorted(p for p, entry in owners.items()
                                      if entry['owner'] == name or name in recipes[entry['owner']].restart_with)
                    if programs:
                        log(f'{name}: restarting {", ".join(programs)}')
                        supervisorctl('restart', *(f'{GROUP}:{p}' for p in programs))
            # After the restarts: what a new version needs done once it is in use -- ctxr's is the
            # store update, which a new ctxr may need before it will read the store.
            for name in moved:
                run_hook(recipes[name], 'updated')
            rendered, skipped = read_rendered(), []
        elif not programs:
            rendered, skipped = [], []
        else:
            for name in selected:
                if name in ready:
                    run_hook(recipes[name], 'boot')
            rendered, skipped = render(recipes, services, offered, ready)
            for program in skipped:
                log(f'{program}: not started, because {offered[program]} is not installed')
        report['programs'] = rendered
        report['skipped_programs'] = skipped
        write_status(report)
        return report


def status():
    healthy = True
    try:
        report = json.loads(status_file().read_text())
    except (OSError, ValueError):
        print('no status yet: runtime-install has not run')
        return 1
    for name, entry in sorted(report.get('installed', {}).items()):
        state = entry.get('state')
        print(f'{name}: {state} {entry.get("version") or ""}'.rstrip()
              + (f' ({entry["error"]})' if state == 'failed' else ''))
        healthy = healthy and state == 'ok'
    for program in report.get('skipped_programs', []):
        print(f'{program}: not started (not installed)')
        healthy = False
    states = {}
    if report.get('programs') and not supervisor_running():
        print('supervisor: not running')
        return 1
    if report.get('programs'):
        result = supervisorctl('status')
        for line in result.stdout.splitlines():
            fields = line.split()
            if len(fields) >= 2:
                states[fields[0].removeprefix(GROUP + ':')] = fields[1]
    probes = {program: entry.get('probe') for program, entry in read_owners().items()}
    for program in report.get('programs', []):
        state = states.get(program, 'UNKNOWN')
        oneshot = PLATFORM_PROGRAMS.get(program, {}).get('oneshot', False)
        good = state in (('RUNNING', 'STARTING', 'EXITED') if oneshot else ('RUNNING',))
        if good and probes.get(program) and not serving(probes[program]):
            state, good = 'RUNNING, not serving yet', False
        print(f'{program}: {state}')
        healthy = healthy and good
    return 0 if healthy else 1


def installed_recipes():
    recipes, selected, _, _ = configuration()
    return [recipes[name] for name in selected if installed(recipes[name])]


def wait():
    """Block until everything selected is installed and no install holds the lock.

    For the backup jobs, which run in their own containers and work from the installed recipes: on
    a store's first boot the agents container is still installing when the schedulers make their
    startup run, and a backup or config push then would see no Hermes -- snapshotting ~/.hermes file
    by file while its runtime downloads, and untracking its config. RUNTIME_WAIT_SECONDS (default
    1800) bounds it; past that it fails, naming what is missing."""
    seconds = os.environ.get('RUNTIME_WAIT_SECONDS') or os.environ.get('HARNESS_WAIT_SECONDS') or '1800'
    deadline = time.monotonic() + int(seconds)
    announced = False
    while True:
        recipes, selected, _, _ = configuration()
        missing = [name for name in selected if not installed(recipes[name])]
        busy = False
        try:
            with open(lock_file()) as handle:
                try:
                    fcntl.flock(handle, fcntl.LOCK_SH | fcntl.LOCK_NB)
                except BlockingIOError:
                    busy = True
        except FileNotFoundError:
            pass
        if not missing and not busy:
            return 0
        if time.monotonic() >= deadline:
            log('gave up waiting: ' + (f'not installed: {", ".join(missing)}' if missing else 'an install is still running'))
            return 1
        if not announced:
            log('waiting for ' + (f'{", ".join(missing)} to be installed' if missing else 'an install to finish'))
            announced = True
        time.sleep(10)


def describe():
    entries = []
    for recipe in installed_recipes():
        entries.append({'name': recipe.name, 'kind': recipe.kind, 'recipe_dir': str(recipe.directory),
                        'backup': recipe.backup, 'config': recipe.config})
    print(json.dumps(entries, indent=2))
    return 0


def allowlist_rules(root, rules):
    """Rewrite one recipe's gitignore rules, relative to its state directory, to the home.

    A rule naming a path (`/x`, `a/b`, `!/x`) is anchored, so it gets the root prepended. A bare
    name (`state.db`, `*.log`, `logs/`) matches at any depth and is left as it is."""
    lines = []
    for raw in rules.splitlines():
        line = raw.strip()
        if not line or line.startswith('#') or line.startswith('@'):
            lines.append(line)
            continue
        negate = line.startswith('!')
        body = line[1:] if negate else line
        anchored = body.startswith('/') or '/' in body.rstrip('/')
        if anchored:
            body = f'/{root}/{body.lstrip("/")}'
        lines.append(('!' if negate else '') + body)
    return lines


def allowlist(path):
    """The config repository's .gitignore source: an allowlist built from the recipes.

    Everything at the root is ignored, each recipe re-opens its own state directory and then says
    what in it is kept, the store's own keeps follow, and the credential denylist comes last so it
    always wins. home-config-push fills @HARNESS_CONFIG_EXTENSIONS@ and @HARNESS_CONFIG_BUNDLED_SKILLS@."""
    lines = ['# harness-config-push managed allowlist v2 -- rendered from the recipes by',
             '# `runtime-install allowlist`. DO NOT EDIT: per-store rules go in HOME_CONFIG_INCLUDE',
             '# and HOME_CONFIG_EXCLUDE.', '', '/*', '!/.gitignore', '!/README.md']
    for recipe in installed_recipes():
        root = recipe.config.get('root', '').strip('/')
        rules = recipe.config.get('rules', '')
        if not root:
            continue
        lines += ['', f'# --- {recipe.name} ({root}/) ---', f'!/{root}/', f'/{root}/*']
        lines += allowlist_rules(root, rules)
    lines += include_rules({recipe.config.get('root', '').strip('/') for recipe in installed_recipes()})
    lines += ['', '@HARNESS_CONFIG_EXTENSIONS@', '', '# --- never, whoever re-opened it ---']
    lines += [line.strip() for line in CREDENTIALS.strip().splitlines()]
    Path(path).write_text('\n'.join(lines) + '\n')
    return 0


def include_rules(roots):
    """A store's own keeps (HOME_CONFIG_INCLUDE), rendered here rather than by config-push.sh.

    Its renderer re-opens each ancestor of an included path and then closes the ancestor's contents
    again (`!/a/` then `a/*`), which is right when the ancestor was closed already. Under the home an
    ancestor can be a recipe's root (.hermes), and re-closing it after the recipe's block untracks
    everything the recipe kept: on pkm, one push of `.hermes/plugins/...` dropped SOUL.md,
    config.yaml and every session. So an ancestor that is a recipe's root is re-opened, not re-closed."""
    lines, seen = [], set()
    entries = (os.environ.get('HOME_CONFIG_INCLUDE') or os.environ.get('HARNESS_CONFIG_INCLUDE') or '').split()
    for entry in entries:
        parts = entry.strip('/').split('/')
        for depth in range(1, len(parts)):
            ancestor = '/'.join(parts[:depth])
            if ancestor in seen:
                continue
            seen.add(ancestor)
            lines.append(f'!/{ancestor}/')
            if ancestor not in roots:
                lines.append(f'/{ancestor}/*')
        lines.append(f'!/{entry.lstrip("/")}')
    return (['', '# --- this store\'s own (HOME_CONFIG_INCLUDE) ---'] + lines) if lines else []


# Basenames and paths that are credentials wherever they appear; last in the allowlist, so no
# recipe and no HOME_CONFIG_INCLUDE can re-open them.
CREDENTIALS = '''
.env
.env.*
!.env.example
auth.json
auth.lock
.git-credentials
.netrc
.npmrc
google_token.json
google_client_secret.json
google_oauth_pending.json
google_oauth_last_url.txt
mcp-tokens/
.credentials.json
oauth_creds.json
google_accounts.json
antigravity-oauth-token
hosts.yml
rclone.conf
/.config/rclone/
restic-password
.restic-password
.restic-password.*
*.pem
id_rsa
id_ed25519
*.key
*_key
.signing_key
.pbkdf2_key
/.ssh/
'''


class _NoRedirect(__import__('urllib.request').request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def serving(url):
    """True when anything answers HTTP at `url`: a 302 to /login or a 401 is serving."""
    import urllib.error
    import urllib.request
    try:
        urllib.request.build_opener(_NoRedirect).open(url, timeout=3)
    except urllib.error.HTTPError:
        return True
    except (urllib.error.URLError, OSError, ValueError):
        return False
    return True


def main(argv):
    if argv[:1] == ['status']:
        return status()
    if argv[:1] == ['check']:
        recipes, selected, services, _ = configuration()
        kinds = {kind: sum(1 for n in selected if recipes[n].kind == kind) for kind in KINDS}
        log(f'configuration ok: {kinds["harness"]} harnesses, {kinds["tool"]} tools, {len(services)} services')
        return 0
    if argv[:1] == ['hook'] and len(argv) == 2:
        ok = all([run_hook(recipe, argv[1]) for recipe in installed_recipes()])
        return 0 if ok else 1
    if argv[:1] == ['wait']:
        return wait()
    if argv[:1] == ['describe']:
        return describe()
    if argv[:1] == ['allowlist'] and len(argv) == 2:
        return allowlist(argv[1])
    if argv[:1] in ([], ['--boot']):
        converge(update_all=False)
        return 0
    if argv[:1] == ['--install-only']:
        report = converge(update_all=False, programs=False)
        return 0 if all(e['state'] == 'ok' for e in report['installed'].values()) else 1
    if argv[:1] == ['--update']:
        converge(update_all=True, only=tuple(argv[1:]))
        return 0
    print('usage: runtime-install [--boot | --update [NAME...] | --install-only | status | check | wait | hook NAME | describe | allowlist PATH]',
          file=sys.stderr)
    return 2


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv[1:]))
    except ConfigError as error:
        log(f'configuration error: {error}')
        sys.exit(2)
