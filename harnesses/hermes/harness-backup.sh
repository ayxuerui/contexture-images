#!/bin/sh
# Snapshot a Hermes harness home to a restic destination, for disaster recovery.
#
# Shipped as `harness-backup`. Never run by this image -- a deployment schedules it.
#
# This is the RECOVERY copy: it carries everything, credentials included, encrypted at rest.
# `harness-config-push` is the other half and carries no secrets at all, so restoring from that
# alone yields a harness that cannot authenticate to anything. The two are not redundant.
#
# The payload is a `hermes backup` ZIP, not the live tree, and that is the single most important
# decision in this file. Hermes copies every *.db through sqlite3.backup() -- a consistent image
# even under a live writer -- and deliberately omits the .db-wal/.db-shm sidecars, because (its
# words) shipping the live WAL "would pair a fresh snapshot with stale sidecar state and produce
# a torn restore on the next open." state.db is ~1 GB here and is rewritten daily. A file-level
# restic run over the live tree would back up exactly that torn pair. It would also restore
# gateway_state.json and processes.json onto a foreign host, which `hermes import` refuses to do
# (NS-508 / NS-501: the gateway comes up stuck "starting" and never reconnects). Going through
# hermes' own archive format gets all of that for free.
#
# Dedup over a zip is degraded but not defeated: zip deflates per-file, so unchanged files yield
# identical byte runs and restic's rolling-hash chunker re-finds them at shifted offsets.
#
# Required:
#   HARNESS_BACKUP_DESTINATION     restic repository. Anything restic speaks, e.g.
#                                    rclone:gdrive:hermes-backup/pkm
#                                    s3:https://<account>.r2.cloudflarestorage.com/hermes
# Optional:
#   HERMES_DATA_DIR                harness home to back up          (default /opt/data)
#   HARNESS_BACKUP_PASSWORD_FILE   restic repo password             (default $HERMES_HOME/.restic-password)
#   HARNESS_BACKUP_KEEP            restic forget policy     (default "--keep-daily 7 --keep-weekly 8
#                                                                    --keep-monthly 6")
#   HARNESS_BACKUP_STAGING         where the zip is built           (default /tmp/harness-backup)
#   HARNESS_BACKUP_TAG             restic --tag                     (default harness-home)
#   HARNESS_BACKUP_MIN_FREE_MB     refuse to start below this much free space on the staging
#                                  filesystem                       (default 2048)
#   HARNESS_BACKUP_SKIP_VERIFY     1 to skip the archive assertion. Do not set this.
#   PUID / PGID                    runtime uid/gid                  (default 10000)
set -eu

HERMES_DATA="${HERMES_DATA_DIR:-/opt/data}"
STAGING="${HARNESS_BACKUP_STAGING:-/tmp/harness-backup}"
TAG="${HARNESS_BACKUP_TAG:-harness-home}"
KEEP="${HARNESS_BACKUP_KEEP:---keep-daily 7 --keep-weekly 8 --keep-monthly 6}"

log() { echo "[harness-backup] $*"; }

: "${HARNESS_BACKUP_DESTINATION:?HARNESS_BACKUP_DESTINATION is required}"

export HOME="$HERMES_DATA/home"
export RESTIC_REPOSITORY="$HARNESS_BACKUP_DESTINATION"
export RESTIC_PASSWORD_FILE="${HARNESS_BACKUP_PASSWORD_FILE:-$HERMES_DATA/.restic-password}"

for _t in hermes restic; do
  command -v "$_t" >/dev/null 2>&1 || { log "ERROR: $_t is not on PATH."; exit 1; }
done
[ -f "$RESTIC_PASSWORD_FILE" ] || {
  log "ERROR: no restic password at $RESTIC_PASSWORD_FILE."
  log "  Generate it OUTSIDE this volume and mount it in. If the only copy lives in the"
  log "  directory being backed up, losing the volume loses the key to its own backups."
  exit 1
}

# >>> archive-verify (lib/tests/harness-backup-test.sh extracts between these markers; keep
# them around exactly the assertion) >>>
# Assert the archive actually contains a usable state.db. THIS IS WHY THIS WRAPPER EXISTS.
#
# hermes' _safe_copy_db fails closed on a 10-second locked-source deadline, and the full-backup
# path handles that failure by appending to an `errors` list and `continue`-ing -- so a
# contended database is simply ABSENT from an otherwise complete-looking zip, and the command
# still exits 0. On a 1 GB state.db under a live gateway that is not hypothetical. Shipping such
# an archive would rebuild precisely the failure this whole change replaces: a green status over
# a backup that cannot restore.
#
# Checks the SQLite magic rather than mere presence, because issue #68474 produced a state.db of
# the right size filled with zeroes; hermes carries its own is_zeroed_sqlite_file() guard for it.
harness_backup_verify_archive() {   # $1 = zip path
  _py="$(command -v python3 || command -v python || echo '')"
  [ -n "$_py" ] || { echo "[harness-backup] ERROR: no python to verify the archive"; return 1; }
  "$_py" - "$1" <<'PYEOF'
import sys, zipfile
REQUIRED_DB = "state.db"
REQUIRED_ANY = ("config.yaml",)
try:
    zf = zipfile.ZipFile(sys.argv[1])
except Exception as exc:
    print(f"[harness-backup] ERROR: archive is not readable: {exc}")
    sys.exit(1)
names = set(zf.namelist())
missing = [n for n in REQUIRED_ANY if n not in names]
if REQUIRED_DB not in names:
    missing.append(REQUIRED_DB)
if missing:
    print("[harness-backup] ERROR: archive is missing " + ", ".join(sorted(missing)))
    print("[harness-backup]   A locked SQLite source makes `hermes backup` skip the file and")
    print("[harness-backup]   still exit 0. Re-run when the gateway is quieter, or stop it.")
    sys.exit(1)
info = zf.getinfo(REQUIRED_DB)
if info.file_size == 0:
    print("[harness-backup] ERROR: state.db in the archive is empty")
    sys.exit(1)
with zf.open(REQUIRED_DB) as fh:
    head = fh.read(100)
if not head.startswith(b"SQLite format 3\x00"):
    print("[harness-backup] ERROR: state.db is not a SQLite database (bad magic)")
    sys.exit(1)
if head == b"\x00" * len(head):
    print("[harness-backup] ERROR: state.db is zeroed (see hermes is_zeroed_sqlite_file)")
    sys.exit(1)
print(f"[harness-backup] archive OK: state.db {info.file_size} bytes, {len(names)} members")
PYEOF
}
# <<< archive-verify <<<

# Staging lives OUTSIDE $HERMES_DATA so the multi-gigabyte zip is never seen by the config
# layer's `git add -A`. Note this buys no disk headroom: hermes stages its DB snapshots next to
# the output zip on purpose (/tmp may be a small tmpfs elsewhere), and here /tmp and the volume
# are the same filesystem. Free space is a deployment problem, not a staging-path problem.
# Refuse before writing anything if the staging filesystem cannot take the archive. `hermes
# backup` streams a multi-gigabyte zip and stages its SQLite snapshots beside it, and on the
# deployment this was written for that filesystem also carries the live 1 GB state.db the
# gateway is writing to -- it was at 94% with 7.6 GB free the day this check was added. An
# ENOSPC underneath a running SQLite database is a worse outcome than a night without a backup,
# and a scheduled job hits this unattended, at 03:00, repeatedly.
#
# A fixed floor rather than a prediction: the archive size is not knowable until it is built,
# and a wrong guess that lets the run start is worse than a conservative number an operator can
# raise. Named in the error, both sides, so the fix is obvious.
_min_free_mb="${HARNESS_BACKUP_MIN_FREE_MB:-2048}"
_stage_parent="$(dirname "$STAGING")"
mkdir -p "$_stage_parent"
_free_mb="$(df -P -k "$_stage_parent" 2>/dev/null | awk 'NR==2 {print int($4/1024)}')"
if [ -z "$_free_mb" ]; then
  log "WARNING: cannot read free space on $_stage_parent - proceeding without the headroom check"
elif [ "$_free_mb" -lt "$_min_free_mb" ]; then
  log "REFUSED: only ${_free_mb} MB free on $_stage_parent, need ${_min_free_mb} MB."
  log "  The archive is staged here before upload. Free space, or lower"
  log "  HARNESS_BACKUP_MIN_FREE_MB if you know this run fits."
  exit 1
fi

rm -rf "$STAGING"
mkdir -p "$STAGING"

# Handed to the runtime uid BEFORE hermes runs, because `hermes` DROPS PRIVILEGES to the
# harness user (uid 10000 on this base) when invoked as root -- verified: the archive it writes
# comes out owned by hermes:hermes. A root-created staging directory is mode 0755 root:root, so
# the drop lands on a directory it cannot write and the run dies with EACCES on the .partial
# file, after having already walked the whole tree. Same family as the chown handover
# ctxr-provision performs, and the same reason: the process that does the work is not the
# process that created the directory.
if [ "$(id -u)" = 0 ]; then
  chown "${PUID:-10000}:${PGID:-10000}" "$STAGING" 2>/dev/null \
    || log "WARNING: could not chown $STAGING; hermes may fail to write there."
fi

ZIP="$STAGING/hermes-backup-$(date -u +%Y%m%dT%H%M%SZ).zip"

log "creating archive from $HERMES_DATA"
if ! HERMES_HOME="$HERMES_DATA" hermes backup -o "$ZIP"; then
  log "ERROR: hermes backup failed."
  rm -rf "$STAGING"
  exit 1
fi

if [ "${HARNESS_BACKUP_SKIP_VERIFY:-0}" = 1 ]; then
  log "WARNING: archive verification skipped (HARNESS_BACKUP_SKIP_VERIFY=1)."
elif ! harness_backup_verify_archive "$ZIP"; then
  rm -rf "$STAGING"
  exit 1
fi

# `restic cat config` is the cheapest "does this repo exist" probe that does not mutate.
if ! restic cat config >/dev/null 2>&1; then
  log "initialising restic repository at $HARNESS_BACKUP_DESTINATION"
  restic init
fi

log "backing up to $HARNESS_BACKUP_DESTINATION"
restic backup --tag "$TAG" "$STAGING"

# shellcheck disable=SC2086  # KEEP is a deliberate multi-flag word list
restic forget --tag "$TAG" --prune $KEEP

rm -rf "$STAGING"

# A status file the deployment healthcheck can assert freshness against. Written last, so it is
# only fresh when every step above succeeded -- the failure mode being designed out is a green
# status over a broken backup, so a status written early would defeat the point.
cat > "$HERMES_DATA/.backup-status.json" <<STATUS
{"ok": true, "at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)", "destination": "$HARNESS_BACKUP_DESTINATION", "tag": "$TAG"}
STATUS
if [ "$(id -u)" = 0 ]; then
  chown "${PUID:-10000}:${PGID:-10000}" "$HERMES_DATA/.backup-status.json" 2>/dev/null || true
fi
log "done."
