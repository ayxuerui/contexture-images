#!/usr/bin/env python3
"""Install, update and supervise the harnesses a runtime container is configured for.

Shipped as `harness-install` in the contexture-runtime image. It is the one writer of
/opt/harnesses, the harnesses volume, and the one renderer of the supervisor's program list.
See docs/design/harnesses-in-home.md for the design this implements.

    harness-install            at boot: install what is missing, render the programs
    harness-install --update   move each harness to the newest version its pin allows
    harness-install status     exit 0 only when every harness is installed and every program runs
    harness-install check      validate the three variables against the recipes; install nothing
    harness-install hook NAME  run every installed harness's NAME hook (store-updated, ...)
    harness-install describe   JSON: each installed harness's recipe, backup and config entries
    harness-install allowlist PATH   render the config repository's allowlist from the recipes

What a container has is three compose variables, never a file in the home:

    HARNESSES          harnesses to install, comma-separated (recipe names)
    HARNESS_SERVICES   programs to run, comma-separated (names the recipes give them)
    HARNESS_PINS       name=version pairs, comma-separated; a pin holds a harness at a version

Each name maps to a recipe, a directory under HARNESS_RECIPES holding `recipe.toml`, an `install`
script and a `latest` script. Every version installs into its own directory,
/opt/harnesses/<name>/<version>/, and `current` is a relative symlink to one of them. An update
installs beside the running version and flips the link only after the new binary answers
`--version`; the previous version stays on disk, so a pin back to it is a link flip with nothing
downloaded. Versions are never moved after install, because installers write absolute paths
(claude's launcher is an absolute symlink into its own version directory).

Standard library only: this runs on Debian's python3, before any harness exists.
"""
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import string
import subprocess
import sys
import time
import tomllib

ROOT = Path(os.environ.get('HARNESS_ROOT', '/opt/harnesses'))
RECIPES = Path(os.environ.get('HARNESS_RECIPES', '/usr/local/share/contexture/harnesses'))
RUN_DIR = Path(os.environ.get('HARNESS_RUN_DIR', '/run/harness'))
PROGRAMS_CONF = RUN_DIR / 'programs.conf'
PROGRAMS_INDEX = RUN_DIR / 'programs.json'
# Every program is rendered into this one supervisor group. supervisord stops groups one after
# another but signals every process in a group in the same pass, so one group is what makes a
# shutdown parallel: three remote sessions each given harness-remote's 8 seconds to exit would
# otherwise take 24, past compose's default 10-second stop grace.
GROUP = 'runtime'
STATE_FILE = ROOT / '.installed.json'
VERSION = re.compile(r'\d+\.\d+(?:\.\d+)?(?:[-+.][0-9A-Za-z.]+)?')
# A version becomes a directory name; nothing else may.
SAFE_VERSION = re.compile(r'^[0-9A-Za-z][0-9A-Za-z.+_-]*$')
TRUE = {'1', 'true', 'yes', 'on'}
FALSE = {'0', 'false', 'no', 'off'}


class ConfigError(Exception):
    """A deployment mistake: wrong name, missing dependency. Fails the boot, loudly."""


def log(message):
    print('harness-install: ' + message, flush=True)


def home():
    return Path(os.environ.get('HOME', '/home/agent'))


def status_file():
    return home() / '.local' / 'state' / 'contexture' / 'harness-status.json'


def names(variable):
    return [part.strip() for part in os.environ.get(variable, '').split(',') if part.strip()]


def pins():
    result = {}
    for entry in names('HARNESS_PINS'):
        name, separator, version = entry.partition('=')
        name, version = name.strip(), version.strip()
        if not separator or not name or not version:
            raise ConfigError(f'HARNESS_PINS entry {entry!r} is not name=version')
        if not SAFE_VERSION.match(version):
            raise ConfigError(f'HARNESS_PINS version {version!r} for {name} is not a version')
        result[name] = version
    return result


# --- Recipes ---------------------------------------------------------------------------------

class Recipe:
    def __init__(self, directory):
        self.name = directory.name
        self.directory = directory
        with open(directory / 'recipe.toml', 'rb') as handle:
            data = tomllib.load(handle)
        self.binaries = list(data.get('binaries', []))
        if not self.binaries:
            raise ConfigError(f'recipe {self.name} names no binaries')
        self.requires = list(data.get('requires', []))
        # False for an installer that cannot be told a version (agy): what lands is what the
        # publisher serves, and a mismatch warns instead of failing.
        self.pinnable = bool(data.get('pinnable', True))
        self.rebuild_on = list(data.get('rebuild_on', []))
        # True when a newer version migrates state an older one cannot read (Hermes' state.db):
        # a pin to an older version is refused, because going back is a restore, not a flip.
        self.forward_only = bool(data.get('forward_only', False))
        # Harnesses whose update must restart this one's programs too: the WebUI runs Hermes'
        # code in-process, so a Hermes update restarts it.
        self.restart_with = list(data.get('restart_with', []))
        # What harness-backup and harness-config-push do with this harness's state.
        self.backup = dict(data.get('backup', {}))
        self.config = dict(data.get('config', {}))
        for key in ('snapshot', 'restore'):
            if key in self.backup:
                self.script(self.backup[key])
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

    def script(self, name):
        path = self.directory / name
        if not os.access(path, os.X_OK):
            raise ConfigError(f'recipe {self.name} has no executable {name}')
        return path

    def hook(self, name):
        path = self.directory / name
        return path if os.access(path, os.X_OK) else None


def version_key(version):
    return tuple(int(part) for part in re.findall(r'\d+', version)[:4])


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
    """Read and check the three variables; every mistake is a ConfigError."""
    recipes = load_recipes()
    selected = names('HARNESSES')
    for name in selected:
        if name not in recipes:
            raise ConfigError(f'HARNESSES names {name}, which has no recipe (have: {", ".join(recipes)})')
    for name in selected:
        for needed in recipes[name].requires:
            if needed not in selected:
                raise ConfigError(f'{name} needs {needed}, which is not in HARNESSES')
    pinned = pins()
    for name in pinned:
        if name not in selected:
            raise ConfigError(f'HARNESS_PINS pins {name}, which is not in HARNESSES')
    offered = {program: name for name in selected for program in recipes[name].services}
    services = names('HARNESS_SERVICES')
    for program in services:
        if program not in offered:
            owner = next((r.name for r in recipes.values() if program in r.services), None)
            hint = f' (offered by {owner}, which is not in HARNESSES)' if owner else ''
            raise ConfigError(f'HARNESS_SERVICES names {program}, which no selected harness offers{hint}')
    return recipes, selected, pinned, services, offered


# --- State on the harnesses volume ---------------------------------------------------------------

def read_state():
    try:
        return json.loads(STATE_FILE.read_text())
    except (OSError, ValueError):
        return {}


def write_state(state):
    temporary = STATE_FILE.with_suffix('.tmp')
    temporary.write_text(json.dumps(state, indent=2, sort_keys=True) + '\n')
    os.replace(temporary, STATE_FILE)


def current_version(name):
    link = ROOT / name / 'current'
    try:
        target = os.readlink(link)
    except OSError:
        return None
    return target if (ROOT / name / target).is_dir() else None


def platform_facts():
    facts = {}
    try:
        out = subprocess.run(['node', '--version'], capture_output=True, text=True, check=True).stdout
        facts['node-major'] = out.strip().lstrip('v').split('.')[0]
    except (OSError, subprocess.CalledProcessError):
        facts['node-major'] = None
    return facts


def needs_rebuild(recipe, record, facts):
    recorded = (record or {}).get('platform', {})
    return any(recorded.get(fact) != facts.get(fact) for fact in recipe.rebuild_on)


# --- Installing one version -----------------------------------------------------------------------

def reported_version(recipe, prefix):
    binary = prefix / 'bin' / recipe.binaries[0]
    result = subprocess.run([str(binary), '--version'], capture_output=True, text=True, timeout=60)
    match = VERSION.search(result.stdout + '\n' + result.stderr)
    if result.returncode != 0 or not match:
        raise RuntimeError(f'{binary} --version failed: {(result.stdout + result.stderr).strip()[:200]}')
    return match.group(0)


def valid(recipe, prefix):
    """An intact install: every binary present, and the recipe's `check` hook, if any, passes.

    The hook is for a harness whose install is not all in its version directory -- Hermes keeps its
    runtime in the home -- so a version can be on disk and still not runnable."""
    if not prefix.is_dir() or not all(os.access(prefix / 'bin' / b, os.X_OK) for b in recipe.binaries):
        return False
    check = recipe.hook('check')
    if not check:
        return True
    result = subprocess.run([str(check), str(prefix)], env=dict(os.environ, HARNESS_PREFIX=str(prefix)),
                            capture_output=True, text=True, timeout=120)
    if result.returncode != 0:
        log(f'{recipe.name}: {prefix.name} is on disk but fails its check; reinstalling it')
    return result.returncode == 0


def latest(recipe):
    result = subprocess.run([str(recipe.script('latest'))], capture_output=True, text=True, timeout=120)
    version = result.stdout.strip()
    if result.returncode != 0 or not SAFE_VERSION.match(version):
        raise RuntimeError(f'could not read the latest {recipe.name}: {(result.stderr or result.stdout).strip()[:200]}')
    return version


def install(recipe, version):
    """Install `version` into its own directory and smoke-test it. Never touches `current`."""
    prefix = ROOT / recipe.name / version
    if prefix.exists():
        shutil.rmtree(prefix)
    prefix.mkdir(parents=True)
    environment = dict(os.environ, HARNESS_PREFIX=str(prefix), HARNESS_VERSION=version)
    log(f'{recipe.name}: installing {version}')
    result = subprocess.run([str(recipe.script('install'))], env=environment, timeout=1800)
    try:
        if result.returncode != 0:
            raise RuntimeError(f'install exited {result.returncode}')
        if not valid(recipe, prefix):
            raise RuntimeError(f'install left no {", ".join("bin/" + b for b in recipe.binaries)}')
        reported = reported_version(recipe, prefix)
    except Exception:
        shutil.rmtree(prefix, ignore_errors=True)
        raise
    if reported != version:
        if recipe.pinnable:
            shutil.rmtree(prefix, ignore_errors=True)
            raise RuntimeError(f'installed {recipe.name} reports {reported}, expected {version}')
        log(f'{recipe.name}: WARNING: asked for {version}, its installer cannot pin and gave {reported}')
    return reported


def flip(name, version, earlier=None):
    """Point `current` at `version` atomically; keep the version it replaced, prune the rest.

    `earlier` is the previous version on record, kept when `current` does not move -- otherwise
    a boot that changed nothing would delete the one copy a pin can roll back to."""
    directory = ROOT / name
    previous = current_version(name)
    temporary = directory / '.current.tmp'
    if temporary.is_symlink() or temporary.exists():
        temporary.unlink()
    os.symlink(version, temporary)
    os.replace(temporary, directory / 'current')
    kept = previous if previous and previous != version else earlier
    keep = {version, kept, 'current'}
    pruned = []
    for entry in directory.iterdir():
        if entry.name not in keep and not entry.name.startswith('.') and entry.is_dir() and not entry.is_symlink():
            shutil.rmtree(entry, ignore_errors=True)
            pruned.append(entry.name)
    return previous, kept, pruned


def link_binaries(recipes, selected):
    bin_dir = ROOT / 'bin'
    bin_dir.mkdir(exist_ok=True)
    wanted = {}
    for name in selected:
        if current_version(name):
            for binary in recipes[name].binaries:
                wanted[binary] = Path('..') / name / 'current' / 'bin' / binary
    for entry in bin_dir.iterdir():
        if entry.name not in wanted or not entry.is_symlink() or Path(os.readlink(entry)) != wanted[entry.name]:
            entry.unlink()
    for binary, target in wanted.items():
        link = bin_dir / binary
        if not link.is_symlink():
            os.symlink(target, link)


def run_hook(recipe, name, *args):
    """Run a recipe's optional hook with the current version's prefix; a failure is logged."""
    path = recipe.hook(name)
    if not path:
        return True
    current = current_version(recipe.name)
    environment = dict(os.environ, HARNESS_RECIPE_DIR=str(recipe.directory),
                       HARNESS_PREFIX=str(ROOT / recipe.name / current) if current else '')
    result = subprocess.run([str(path), *args], env=environment, timeout=1800)
    if result.returncode != 0:
        log(f'{recipe.name}: {name} hook exited {result.returncode}')
    return result.returncode == 0


def bring_to(recipe, target, state, facts):
    """Make `target` current, installing it unless an intact copy is already on disk."""
    name = recipe.name
    record = state.get(name)
    current = current_version(name)
    if recipe.forward_only and current and version_key(target) < version_key(current):
        raise RuntimeError(f'{name} cannot go back from {current} to {target}: a newer version has '
                           f'migrated its state. Going back is a restore (see the recipe), not a pin')
    prefix = ROOT / name / target
    rebuild = needs_rebuild(recipe, record, facts) and target == current_version(name)
    if rebuild or not valid(recipe, prefix):
        if rebuild:
            log(f'{name}: the platform changed under {target} ({", ".join(recipe.rebuild_on)}); reinstalling')
        reported = install(recipe, target)
    else:
        reported = (record or {}).get('reported', target) if target == current_version(name) else target
    moved_from, kept, pruned = flip(name, target, (record or {}).get('previous'))
    if pruned:
        log(f'{name}: removed {", ".join(pruned)}')
        run_hook(recipe, 'gc')
    state[name] = {'version': target, 'reported': reported, 'previous': kept,
                   'platform': {fact: facts.get(fact) for fact in recipe.rebuild_on},
                   'installed_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}
    return moved_from != target


# --- Supervisor programs ----------------------------------------------------------------------------

# Programs the platform itself runs, beside whatever HARNESS_SERVICES selects.
PLATFORM_PROGRAMS = {
    # Once per container start, never restarted, never failing the boot: what the s6 store-update
    # service did with `finish` exiting 125. Always rendered: runtime/store-update.sh reads
    # CTXR_UPDATE_STORE_ENABLED for the store update itself, and runs the harnesses'
    # store-updated hooks either way, as the s6 service ran the Circleback install either way.
    'store-update': {'command': ['runtime-store-update'], 'oneshot': True, 'enabled': lambda: True},
    # The daily update, in this container because it restarts this container's programs.
    'harness-update': {'command': ['harness-schedule', 'harness-install', '--update'], 'oneshot': False,
                       'environment': {'HARNESS_SCHEDULE_INTERVAL': '${HARNESS_UPDATE_INTERVAL}',
                                       'HARNESS_SCHEDULE_NAME': 'harness-update',
                                       'HARNESS_SCHEDULE_SKIP_FIRST': '1'},
                       'enabled': lambda: os.environ.get('HARNESS_UPDATE_INTERVAL', '86400').strip() not in ('', '0')},
}


def expand(value, extra=None):
    environment = dict(os.environ)
    environment.setdefault('HARNESS_UPDATE_INTERVAL', '86400')
    environment.setdefault('HOME', str(home()))
    environment['HARNESS_ROOT'] = str(ROOT)
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
        # row, goes FATAL -- reported by `harness-install status` rather than looping unseen.
        lines += ['autorestart=true', 'startsecs=5', 'startretries=3']
    environment = {key: expand(value, extra) for key, value in spec.get('environment', {}).items()}
    if environment:
        pairs = ','.join(f'{key}="{supervisor_value(value)}"' for key, value in sorted(environment.items()))
        lines.append('environment=' + pairs)
    return '\n'.join(lines) + '\n'


def render(recipes, services, offered, installed):
    blocks, rendered, skipped, owners = [], [], [], {}
    for program, spec in PLATFORM_PROGRAMS.items():
        if spec['enabled']():
            blocks.append(program_block(program, spec, spec['oneshot']))
            rendered.append(program)
    for program in services:
        owner = offered[program]
        if owner not in installed:
            skipped.append(program)
            continue
        spec = recipes[owner].services[program]
        extra = {'HARNESS_RECIPE_DIR': str(recipes[owner].directory)}
        blocks.append(program_block(program, spec, False, extra))
        rendered.append(program)
        owners[program] = {'owner': owner, 'probe': expand(spec['probe'], extra) if spec.get('probe') else None}
    if rendered:
        blocks.append(f'[group:{GROUP}]\nprograms={",".join(rendered)}\n')
    RUN_DIR.mkdir(parents=True, exist_ok=True)
    temporary = PROGRAMS_CONF.with_suffix('.tmp')
    temporary.write_text('# Generated by harness-install at boot. Do not edit: it is rewritten every start.\n\n'
                         + '\n'.join(blocks))
    os.replace(temporary, PROGRAMS_CONF)
    PROGRAMS_INDEX.write_text(json.dumps(owners, indent=2, sort_keys=True) + '\n')
    return rendered, skipped


def supervisorctl(*args):
    return subprocess.run(['supervisorctl', *args], capture_output=True, text=True, timeout=120)


def supervisor_running():
    return (RUN_DIR / 'supervisor.sock').exists() and supervisorctl('pid').returncode == 0


# --- Commands -------------------------------------------------------------------------------------

def write_status(report):
    path = status_file()
    path.parent.mkdir(parents=True, exist_ok=True)
    report['time'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    os.replace(temporary, path)


def locked():
    ROOT.mkdir(parents=True, exist_ok=True)
    handle = open(ROOT / '.lock', 'w')
    fcntl.flock(handle, fcntl.LOCK_EX)
    return handle


def converge(update, only=()):
    recipes, selected, pinned, services, offered = configuration()
    with locked():
        state, facts = read_state(), platform_facts()
        report = {'harnesses': {}}
        changed = []
        for name in selected:
            if only and name not in only:
                if current_version(name):
                    report['harnesses'][name] = {'state': 'ok', 'version': current_version(name)}
                continue
            recipe = recipes[name]
            try:
                if name in pinned:
                    target = pinned[name]
                elif update or not current_version(name):
                    target = latest(recipe)
                else:
                    target = current_version(name)
                if bring_to(recipe, target, state, facts):
                    changed.append(name)
                    log(f'{name}: now {target}')
                report['harnesses'][name] = {'state': 'ok', 'version': target,
                                             'reported': state[name].get('reported', target)}
            except Exception as error:  # one harness failing must not stop the others
                log(f'{name}: FAILED: {error}')
                current = current_version(name)
                report['harnesses'][name] = {'state': 'failed', 'error': str(error)[:500],
                                             'version': current}
            write_state(state)
        link_binaries(recipes, selected)
        installed = {name for name in selected if current_version(name)}
        if update:
            if supervisor_running():
                owners = read_owners()
                for name in changed:
                    programs = sorted(p for p, entry in owners.items()
                                      if entry['owner'] == name or name in recipes[entry['owner']].restart_with)
                    if programs:
                        log(f'{name}: restarting {", ".join(programs)}')
                        supervisorctl('restart', *(f'{GROUP}:{p}' for p in programs))
            rendered, skipped = read_rendered(), []
        else:
            for name in selected:
                if name in installed:
                    run_hook(recipes[name], 'boot')
            rendered, skipped = render(recipes, services, offered, installed)
            for program in skipped:
                log(f'{program}: not started, because {offered[program]} is not installed')
        report['programs'] = rendered
        report['skipped_programs'] = skipped
        write_status(report)
        return report


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


def status():
    healthy = True
    try:
        report = json.loads(status_file().read_text())
    except (OSError, ValueError):
        print('no status yet: harness-install has not run')
        return 1
    for name, entry in sorted(report.get('harnesses', {}).items()):
        state = entry.get('state')
        print(f'{name}: {state} {entry.get("version") or ""}'.rstrip()
              + (f' ({entry["error"]})' if state == 'failed' else ''))
        healthy = healthy and state == 'ok'
    for program in report.get('skipped_programs', []):
        print(f'{program}: not started (its harness is not installed)')
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
    recipes, selected, _, _, _ = configuration()
    return [recipes[name] for name in selected if current_version(name)]


def describe():
    entries = []
    for recipe in installed_recipes():
        entries.append({'name': recipe.name, 'recipe_dir': str(recipe.directory),
                        'prefix': str(ROOT / recipe.name / current_version(recipe.name)),
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

    Same contract as harnesses/hermes/hermes-config.gitignore, which this replaces in the runtime
    image: everything at the root is ignored, each harness re-opens its own state directory and
    then says what in it is kept, and the credential denylist comes last so it always wins.
    harness-config-push fills @HARNESS_CONFIG_EXTENSIONS@ and @HARNESS_CONFIG_BUNDLED_SKILLS@."""
    lines = ['# harness-config-push managed allowlist v2 -- rendered from the harness recipes by',
             '# `harness-install allowlist`. DO NOT EDIT: per-store rules go in HARNESS_CONFIG_INCLUDE',
             '# and HARNESS_CONFIG_EXCLUDE.', '', '/*', '!/.gitignore', '!/README.md']
    for recipe in installed_recipes():
        root = recipe.config.get('root', '').strip('/')
        rules = recipe.config.get('rules', '')
        if not root:
            continue
        lines += ['', f'# --- {recipe.name} ({root}/) ---', f'!/{root}/', f'/{root}/*']
        lines += allowlist_rules(root, rules)
    lines += ['', '@HARNESS_CONFIG_EXTENSIONS@', '', '# --- never, whoever re-opened it ---']
    lines += [line.strip() for line in CREDENTIALS.strip().splitlines()]
    Path(path).write_text('\n'.join(lines) + '\n')
    return 0


# Basenames and paths that are credentials wherever they appear; last in the allowlist, so no
# recipe and no HARNESS_CONFIG_INCLUDE can re-open them. The same set as hermes-config.gitignore,
# with home/ dropped now that the home is the repository root.
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
    if argv[:1] == ['hook'] and len(argv) == 2:
        ok = all([run_hook(recipe, argv[1]) for recipe in installed_recipes()])
        return 0 if ok else 1
    if argv[:1] == ['describe']:
        return describe()
    if argv[:1] == ['allowlist'] and len(argv) == 2:
        return allowlist(argv[1])
    if argv[:1] == ['status']:
        return status()
    if argv[:1] == ['check']:
        _, selected, pinned, services, _ = configuration()
        log(f'configuration ok: {len(selected)} harnesses, {len(services)} services, {len(pinned)} pins')
        return 0
    if argv[:1] in ([], ['--boot']):
        converge(update=False)
        return 0
    if argv[:1] == ['--update']:
        converge(update=True, only=tuple(argv[1:]))
        return 0
    print('usage: harness-install [--boot | --update [NAME...] | status | check | hook NAME | describe | allowlist PATH]',
          file=sys.stderr)
    return 2


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv[1:]))
    except ConfigError as error:
        log(f'configuration error: {error}')
        sys.exit(2)
