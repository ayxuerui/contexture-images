#!/usr/bin/env python3
"""Snapshot the agent's whole home to restic, or restore it. The runtime image's harness-backup.

Shipped as `harness-backup` in contexture-runtime; the Hermes image keeps
harnesses/hermes/harness-backup.sh. This is the recovery copy -- credentials included, encrypted
at rest -- and harness-config-push is the other half, a history to diff with no secrets in it.

    harness-backup                     snapshot the home
    harness-backup restore [SNAPSHOT]  restore it (default: the latest), with the agents stopped

What goes in is everything in the home, because the home also holds what belongs to no harness
(`gh`'s credential, Circleback's, .gitconfig, .ssh). The harnesses shape it through their recipes
(`harness-install describe`):

    backup.snapshot  a recipe script that writes a consistent archive of its state into a
                     directory. Hermes' runs `hermes backup`, which copies databases with
                     sqlite3.backup(), so a live state.db is never copied torn.
    backup.covers    home-relative paths that snapshot accounts for, left out of the file pass
    backup.exclude   home-relative paths not worth keeping
    backup.restore   a recipe script that puts its archive back after `restic restore`

Environment, the same contract as harnesses/hermes/harness-backup.sh:
    HARNESS_BACKUP_DESTINATION     restic repository (required)
    HARNESS_BACKUP_PASSWORD_FILE   default ~/.config/contexture/restic-password
    HARNESS_BACKUP_KEEP            restic forget policy (default --keep-daily 7 --keep-weekly 8 --keep-monthly 6)
    HARNESS_BACKUP_STAGING         where snapshots are written first (default /tmp/harness-backup)
    HARNESS_BACKUP_TAG             restic --tag (default harness-home)
    HARNESS_BACKUP_MIN_FREE_MB     refuse below this much free space for staging (default 2048)
"""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import time

# Never worth a snapshot, whoever's they are: caches every tool regenerates.
ALWAYS_EXCLUDE = ['.cache/', '.npm/', '.local/share/Trash/']


def log(message):
    print('[harness-backup] ' + message, flush=True)


def fail(message):
    log('ERROR: ' + message)
    sys.exit(1)


def home():
    return Path(os.environ.get('HOME', '/home/agent'))


def describe():
    # The recipes say how each harness's state is backed up, and only installed harnesses are
    # described: on a first boot, wait for the agents container to finish installing.
    if subprocess.run(['harness-install', 'wait']).returncode != 0:
        fail('the selected harnesses are not installed; nothing was backed up')
    result = subprocess.run(['harness-install', 'describe'], capture_output=True, text=True)
    if result.returncode != 0:
        fail('harness-install describe failed: ' + (result.stderr or result.stdout).strip())
    return json.loads(result.stdout)


def recipe_env(entry):
    return dict(os.environ, HARNESS_PREFIX=entry['prefix'], HARNESS_RECIPE_DIR=entry['recipe_dir'])


def restic_env():
    destination = os.environ.get('HARNESS_BACKUP_DESTINATION', '').strip()
    if not destination:
        fail('HARNESS_BACKUP_DESTINATION is required')
    password = os.environ.get('HARNESS_BACKUP_PASSWORD_FILE') or str(home() / '.config/contexture/restic-password')
    if not Path(password).is_file():
        fail(f'no restic password at {password}. Generate it OUTSIDE this volume and mount it in: if '
             'the only copy lives in the home being backed up, losing the volume loses the key to its backups.')
    return dict(os.environ, RESTIC_REPOSITORY=destination, RESTIC_PASSWORD_FILE=password)


def restic(environment, *args, check=True):
    return subprocess.run(['restic', *args], env=environment, check=check)


def staging():
    path = Path(os.environ.get('HARNESS_BACKUP_STAGING', '/tmp/harness-backup'))
    minimum = int(os.environ.get('HARNESS_BACKUP_MIN_FREE_MB', '2048'))
    path.parent.mkdir(parents=True, exist_ok=True)
    free = shutil.disk_usage(path.parent).free // (1024 * 1024)
    if free < minimum:
        fail(f'only {free} MB free on {path.parent}, need {minimum} MB to stage snapshots. Free space, or '
             'lower HARNESS_BACKUP_MIN_FREE_MB if you know this run fits.')
    shutil.rmtree(path, ignore_errors=True)
    path.mkdir(parents=True)
    return path


def backup():
    environment = restic_env()
    entries = describe()
    stage = staging()
    excludes = list(ALWAYS_EXCLUDE)
    try:
        for entry in entries:
            spec = entry.get('backup', {})
            excludes += spec.get('exclude', [])
            if 'snapshot' in spec:
                target = stage / entry['name']
                log(f'{entry["name"]}: writing its snapshot')
                script = Path(entry['recipe_dir']) / spec['snapshot']
                if subprocess.run([str(script), str(target)], env=recipe_env(entry)).returncode != 0:
                    fail(f'{entry["name"]}: its snapshot failed; nothing was backed up')
                excludes += spec.get('covers', [])
        exclude_file = stage / '.exclude'
        # restic matches an exclude pattern against the absolute path; anchor each to the home.
        exclude_file.write_text(''.join(f'{home()}/{p.strip("/")}\n' for p in excludes))
        if restic(environment, 'cat', 'config', check=False).returncode != 0:
            log(f'initialising restic repository at {environment["RESTIC_REPOSITORY"]}')
            restic(environment, 'init')
        tag = os.environ.get('HARNESS_BACKUP_TAG', 'harness-home')
        log(f'backing up {home()} to {environment["RESTIC_REPOSITORY"]}')
        restic(environment, 'backup', '--tag', tag, '--exclude-file', str(exclude_file), str(home()), str(stage))
        keep = shlex.split(os.environ.get('HARNESS_BACKUP_KEEP', '--keep-daily 7 --keep-weekly 8 --keep-monthly 6'))
        restic(environment, 'forget', '--tag', tag, '--prune', *keep)
    finally:
        shutil.rmtree(stage, ignore_errors=True)
    status = home() / '.local/state/contexture/backup-status.json'
    status.parent.mkdir(parents=True, exist_ok=True)
    status.write_text(json.dumps({'ok': True, 'at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                                  'destination': environment['RESTIC_REPOSITORY'], 'tag': tag}) + '\n')
    log('done.')


def restore(snapshot='latest'):
    """Put the home back from a snapshot, then let each harness restore its own archive.

    restic restores to absolute paths, so the home lands where it was and the staging directory
    lands at its old path under /. Each recipe's restore script then reads its archive from there.
    Run it with the agents stopped: Hermes' import writes into its live databases."""
    environment = restic_env()
    stage = Path(os.environ.get('HARNESS_BACKUP_STAGING', '/tmp/harness-backup'))
    shutil.rmtree(stage, ignore_errors=True)
    log(f'restoring {snapshot} into {home()}')
    restic(environment, 'restore', snapshot, '--target', '/', '--include', str(home()), '--include', str(stage))
    for entry in describe():
        spec = entry.get('backup', {})
        if 'restore' in spec:
            log(f'{entry["name"]}: restoring its snapshot')
            script = Path(entry['recipe_dir']) / spec['restore']
            if subprocess.run([str(script), str(stage / entry['name'])], env=recipe_env(entry)).returncode != 0:
                fail(f'{entry["name"]}: its restore failed')
    shutil.rmtree(stage, ignore_errors=True)
    log('restored.')


if __name__ == '__main__':
    arguments = sys.argv[1:]
    if not arguments:
        backup()
    elif arguments[0] == 'restore' and len(arguments) <= 2:
        restore(*arguments[1:])
    else:
        sys.exit('usage: harness-backup [restore [SNAPSHOT]]')
