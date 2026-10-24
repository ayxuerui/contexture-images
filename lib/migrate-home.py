#!/usr/bin/env python3
"""Turn a Hermes-image volume into a runtime home, in place. Shipped as `harness-migrate-home`.

The Hermes image's volume is HERMES_HOME, with the agent's home as a directory inside it:

    /opt/data/              config.yaml, SOUL.md, state.db, sessions/, webui/, .git, ... + home/
    /opt/data/home/         .claude/, .codex/, .config/gh/, ...

The runtime image mounts the same volume as the agent's home, with Hermes at its default:

    /home/agent/            .claude/, .codex/, .config/gh/, ..., .git (the config repository)
    /home/agent/.hermes/    config.yaml, SOUL.md, state.db, sessions/, ...
    /home/agent/.hermes-webui/   what was webui/

    docker compose stop agents          # nothing may write the volume while it moves
    docker compose run --rm --entrypoint harness-migrate-home agents --agents-stopped
    docker compose run --rm --entrypoint harness-migrate-home agents --reverse   # to go back

Every move is a rename on one filesystem: a database moves with its WAL, nothing is copied, and
it takes seconds. The plan is written to a journal before the first move, every collision is
checked before anything moves, and --reverse replays the journal backwards. Absolute paths in a
fixed list of configuration files are rewritten, each original kept beside it; conversation
histories are left as written, because they record where things were.

The config repository's .git moves to the new root rather than into .hermes/: the home is the
repository now. The next harness-config-push renders the new allowlist and commits the moved
files, and git's rename detection keeps their history (`git log --follow`).
"""
import json
import os
from pathlib import Path
import sys
import time

OLD_ROOT, OLD_HOME = '/opt/data', '/opt/data/home'
NEW_HOME = '/home/agent'
MARKER = Path('.local/state/contexture/home-layout.json')

# Moved to the new root, not into .hermes/: they belong to the home now.
TO_ROOT = {'.git': '.git'}
# Moved somewhere other than .hermes/<same name>.
RENAMED = {'webui': '.hermes-webui', '.restic-password': '.config/contexture/restic-password'}
# Not carried over: regenerated, or meaningless under the new layout.
DROPPED = {'.gitignore', '.backup-status.json'}
KEEP_IN_PLACE = {'lost+found'}

# Configuration whose absolute paths are rewritten, as they are named AFTER the move.
REWRITE = ['.hermes/config.yaml', '.hermes/.env', '.hermes/cron/jobs.json', '.hermes/profiles/*/config.yaml',
           '.hermes/profiles/*/.env', '.claude.json', '.claude/settings.json', '.codex/config.toml', '.gitconfig']
SUBSTITUTIONS = [(OLD_HOME, NEW_HOME), (OLD_ROOT + '/webui', NEW_HOME + '/.hermes-webui'),
                 (OLD_ROOT, NEW_HOME + '/.hermes')]


def log(message):
    print('harness-migrate-home: ' + message, flush=True)


def plan(volume):
    if not (volume / 'home').is_dir() or not ((volume / 'config.yaml').exists() or (volume / 'state.db').exists()):
        raise SystemExit(f'{volume} does not look like a Hermes-image volume (no home/ beside config.yaml or state.db)')
    moves, nested, dropped = [], [], []
    for entry in sorted(volume.iterdir()):
        name = entry.name
        if name == 'home' or name in KEEP_IN_PLACE:
            continue
        if name in DROPPED:
            dropped.append(name)
        elif name in TO_ROOT:
            moves.append((name, '.migrating-root/' + TO_ROOT[name]))
        elif name in RENAMED and '/' in RENAMED[name]:
            # Into a directory home/ may already have (.config): placed after home/ is promoted.
            moves.append((name, '.migrating-nested/' + name))
            nested.append(['.migrating-nested/' + name, RENAMED[name]])
        elif name in RENAMED:
            moves.append((name, '.migrating-root/' + RENAMED[name]))
        else:
            moves.append((name, '.migrating-root/.hermes/' + name))
    home_entries = sorted(p.name for p in (volume / 'home').iterdir())
    targets = {Path(target).parts[1] for _, target in moves if target.startswith('.migrating-root/')}
    collisions = sorted(set(home_entries) & (targets | {'home', '.migrating-root', '.migrating-nested'}))
    for _, target in nested:
        if (volume / 'home' / target).exists():
            collisions.append('home/' + target)
    if collisions:
        raise SystemExit('these names exist both in home/ and at the root, so one would overwrite the other: '
                         + ', '.join(collisions) + '. Move them aside by hand, then run again. Nothing was moved.')
    # Phase 1 moves the Hermes state into a staging directory; phase 2 promotes home/'s contents
    # to the root and the staging directory's contents beside them.
    steps = [[source, target] for source, target in moves]
    steps += [['home/' + name, name] for name in home_entries]
    steps += [['.migrating-root/' + name, name] for name in sorted(targets)]
    steps += nested
    return steps, dropped


def apply(volume, steps):
    for source, target in steps:
        (volume / target).parent.mkdir(parents=True, exist_ok=True)
        os.rename(volume / source, volume / target)


def rewrite(volume):
    changed = []
    for pattern in REWRITE:
        for path in sorted(volume.glob(pattern)):
            if not path.is_file() or path.is_symlink():
                continue
            try:
                text = path.read_text()
            except (OSError, UnicodeDecodeError):
                continue
            new = text
            for old, replacement in SUBSTITUTIONS:
                new = new.replace(old, replacement)
            if new != text:
                original = path.with_name(path.name + '.pre-migrate')
                original.write_text(text)
                os.chmod(original, path.stat().st_mode & 0o777)
                path.write_text(new)
                changed.append(str(path.relative_to(volume)))
    return changed


def forward(volume):
    marker = volume / MARKER
    if marker.exists():
        log(f'{volume} is already in the runtime layout ({marker}); nothing to do')
        return 0
    steps, dropped = plan(volume)
    journal = volume / '.migrate-home-journal.json'
    journal.write_text(json.dumps({'steps': steps, 'dropped': dropped}, indent=2))
    stash = volume / '.migrate-home-dropped'
    for name in dropped:
        stash.mkdir(exist_ok=True)
        os.rename(volume / name, stash / name)
    apply(volume, steps)
    for directory in ('home', '.migrating-root', '.migrating-nested'):
        if (volume / directory).exists():
            os.rmdir(volume / directory)
    install_method = volume / '.hermes' / '.install_method'
    if install_method.is_file() and install_method.read_text().strip() == 'docker':
        install_method.rename(install_method.with_name('.install_method.pre-migrate'))
    changed = rewrite(volume)
    marker.parent.mkdir(parents=True, exist_ok=True)
    os.rename(journal, volume / '.local/state/contexture/home-migration-journal.json')
    marker.write_text(json.dumps({'layout': 2, 'migrated_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                                  'rewritten': changed}, indent=2) + '\n')
    log(f'moved {len(steps)} entries; rewrote paths in: {", ".join(changed) or "nothing"}')
    log('next: start the runtime image; its first harness-config-push commits the moved files.')
    return 0


def reverse(volume):
    """Put the Hermes-image layout back, on a home that has been used since the migration.

    The runtime will have changed things under it: Hermes checkpoints and deletes a database's WAL,
    writes new state into ~/.hermes, and the agent creates files in its home. So a moved entry that
    is gone is skipped (it was deleted since), state written into ~/.hermes since goes back to the
    Hermes root with the rest, and anything new at the top of the home goes into home/."""
    marker = volume / MARKER
    journal_path = volume / '.local/state/contexture/home-migration-journal.json'
    if not marker.exists() or not journal_path.exists():
        raise SystemExit(f'{volume} has no migration to reverse')
    journal = json.loads(journal_path.read_text())
    steps = journal['steps']
    staging = {'home', '.migrating-root', '.migrating-nested', '.migrate-home-dropped', '.migrate-home-journal.json'}
    placed = {Path(target).parts[0] for _, target in steps if not target.startswith('.migrating')}
    data = json.loads(marker.read_text())

    for relative in data.get('rewritten', []):
        path = volume / relative
        original = path.with_name(path.name + '.pre-migrate')
        if original.exists():
            os.replace(original, path)
    install_method = volume / '.hermes' / '.install_method.pre-migrate'
    if install_method.exists():
        install_method.rename(install_method.with_name('.install_method'))
    marker.unlink()
    os.rename(journal_path, volume / '.migrate-home-journal.json')
    for directory in ('.local/state/contexture', '.local/state', '.local'):
        try:
            os.rmdir(volume / directory)  # only if the migration created them and they are empty
        except OSError:
            break
    # New at the top of the home since the migration (looked for after the rewritten files are put
    # back, so their .pre-migrate copies are not mistaken for new): the agent's, so into home/.
    newcomers = sorted(entry.name for entry in volume.iterdir()
                       if entry.name not in placed | staging | KEEP_IN_PLACE)
    for directory in ('home', '.migrating-root', '.migrating-nested'):
        (volume / directory).mkdir(exist_ok=True)

    for name in newcomers:
        os.rename(volume / name, volume / 'home' / name)
    skipped = []
    for source, target in reversed(steps):
        if not os.path.lexists(volume / target):
            skipped.append(target)
            continue
        (volume / source).parent.mkdir(parents=True, exist_ok=True)
        os.rename(volume / target, volume / source)
        # A nested target (.config/contexture/restic-password) leaves directories the migration
        # made inside one home/ already had; remove them while empty, before that one moves back.
        parent = (volume / target).parent
        while parent != volume:
            try:
                parent.rmdir()
            except OSError:
                break
            parent = parent.parent
    # Hermes state written since the migration is still in the staged .hermes: it is Hermes', and
    # the old layout keeps Hermes' state at the root.
    leftover = volume / '.migrating-root' / '.hermes'
    stranded = []
    if leftover.exists():
        for entry in sorted(leftover.iterdir()):
            if os.path.lexists(volume / entry.name):
                stranded.append(entry.name)
            else:
                os.rename(entry, volume / entry.name)
    for directory in ('.migrating-root/.hermes', '.migrating-root', '.migrating-nested'):
        try:
            os.rmdir(volume / directory)
        except OSError:
            pass
    stash = volume / '.migrate-home-dropped'
    for name in journal.get('dropped', []):
        if os.path.lexists(stash / name) and not os.path.lexists(volume / name):
            os.rename(stash / name, volume / name)
    try:
        os.rmdir(stash)
    except OSError:
        pass
    os.unlink(volume / '.migrate-home-journal.json')
    if skipped:
        log(f'{len(skipped)} moved entries were gone, deleted since the migration: {", ".join(skipped[:10])}')
    if newcomers:
        log(f'new since the migration, put in home/: {", ".join(newcomers)}')
    if stranded:
        log(f'WARNING: left in .migrating-root/.hermes, a name already back at the root: {", ".join(stranded)}')
    log(f'{volume} is back in the Hermes-image layout')
    return 0


if __name__ == '__main__':
    arguments = sys.argv[1:]
    volume = Path(os.environ.get('HARNESS_MIGRATE_VOLUME', NEW_HOME))
    if arguments == ['--reverse']:
        sys.exit(reverse(volume))
    if arguments == ['--agents-stopped']:
        sys.exit(forward(volume))
    sys.exit('usage: harness-migrate-home --agents-stopped | --reverse\n'
             '  Stop the agents first (docker compose stop agents): nothing may write the volume while it moves.')
