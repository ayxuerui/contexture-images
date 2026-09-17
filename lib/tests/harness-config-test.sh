#!/bin/sh
# Regression tests for the guards that keep a harness home's config backup safe.
#
# Three things are asserted here, and each one has already gone wrong somewhere:
#
#   1. The ALLOWLIST keeps what it claims and ignores what it claims -- in BOTH directions. The
#      277-line original this was generalized from grew by `auto: ignore ...` commits landing
#      after something had already been pushed; a both-ways matrix is what turns that into a
#      failing test instead of a postmortem.
#   2. The COMMIT GUARD refuses credential files, oversize blobs and gitlinks. A live repo today
#      carries a 95.6 MB blob against GitHub's 100 MB hard limit, and a mode-160000 gitlink with
#      no .gitmodules whose restore is therefore already broken.
#   3. The ARCHIVE VERIFIER refuses a `hermes backup` zip with no usable state.db. hermes' own
#      _safe_copy_db fails closed on a 10s lock deadline and the caller then just continues, so
#      a contended database is absent from an archive that still exits 0.
#
# Runs as root against repos owned by another uid: the exact shape of the production failure
# that has already broken the provisioner's refresh path twice. Needs root, git and python3;
# no network.
#
#   docker run --rm --user root -v "$PWD:/w" -w /w --entrypoint sh <image> \
#     lib/tests/harness-config-test.sh
set -u

SCRIPT_DIR=$(dirname "$0")
PUSH_SRC="$SCRIPT_DIR/../config-push.sh"
BACKUP_SRC="$SCRIPT_DIR/../../harnesses/hermes/harness-backup.sh"
ALLOWLIST="$SCRIPT_DIR/../../harnesses/hermes/hermes-config.gitignore"
# A private work area, not fixed /tmp paths. Leftovers from an earlier run once made the
# provisioner's test report another version's results -- the one failure mode a test must not
# have.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM
STORE_UID=10000

for f in "$PUSH_SRC" "$BACKUP_SRC" "$ALLOWLIST"; do
  [ -f "$f" ] || { echo "cannot find $f"; exit 1; }
done
command -v python3 >/dev/null 2>&1 || { echo "needs python3"; exit 1; }

# Extraction is by marker, so a refactor that drops one fails here loudly rather than silently
# sourcing an empty file and reporting green.
GUARD="$WORK/guard.sh"
VIS="$WORK/visibility.sh"
VERIFY="$WORK/verify.sh"
{ echo 'log() { echo "[harness-config-push] $*"; }'
  sed -n '/^# >>> commit-guard/,/^# <<< commit-guard/p' "$PUSH_SRC"; } > "$GUARD"
{ echo 'log() { echo "[harness-config-push] $*"; }'
  sed -n '/^# >>> visibility-gate/,/^# <<< visibility-gate/p' "$PUSH_SRC"; } > "$VIS"
sed -n '/^# >>> archive-verify/,/^# <<< archive-verify/p' "$BACKUP_SRC" > "$VERIFY"
grep -q '_max_mb'          "$GUARD"  || { echo "FAIL: commit-guard markers missing or moved";    exit 1; }
grep -q 'PUBLIC'           "$VIS"    || { echo "FAIL: visibility-gate markers missing or moved"; exit 1; }
grep -q 'SQLite format 3'  "$VERIFY" || { echo "FAIL: archive-verify markers missing or moved";  exit 1; }
. "$GUARD"
. "$VIS"
. "$VERIFY"

git config --global user.email harness-test@example.invalid
git config --global user.name "harness test"

PASS=0
FAIL=0
check() {
  if [ "$2" = "$3" ]; then echo "  PASS: $1"; PASS=$((PASS + 1))
  else echo "  FAIL: $1 (want '$3', got '$2')"; FAIL=$((FAIL + 1)); fi
}

# A repo owned by the runtime uid, as the live volume is. Every guard call below therefore runs
# root-against-foreign-uid, which is where "detected dubious ownership" bites.
mkrepo() {
  rm -rf "$WORK/repo"
  git init -q "$WORK/repo"
  chown -R "$STORE_UID:$STORE_UID" "$WORK/repo"
}
stage() { git -c safe.directory="$WORK/repo" -C "$WORK/repo" add -f "$@" >/dev/null 2>&1; }
guard() { harness_config_commit_guard "$WORK/repo" "${1:-95}" >/dev/null 2>&1; echo $?; }

echo "== the allowlist keeps what it claims =="
rm -rf "$WORK/al"; mkdir -p "$WORK/al"; git init -q "$WORK/al"
sed 's/^@HARNESS_CONFIG_EXTENSIONS@$//' "$ALLOWLIST" > "$WORK/al/.gitignore"
ign() { git -C "$WORK/al" check-ignore --no-index -q "$1" && echo ignored || echo kept; }
for p in config.yaml SOUL.md cron/jobs.json sessions/session_a.json webui/sessions/a.json \
         home/.claude/projects/p/a.jsonl home/.codex/sessions/2026/a.jsonl \
         user-skills/s/SKILL.md scripts/check_backup.py memories/m.md; do
  check "keeps $p" "$(ign "$p")" "kept"
done

echo "== the allowlist ignores what it claims =="
for p in .env auth.json .git-credentials google_token.json mcp-tokens/cb.json \
         home/.config/gh/hosts.yml home/.claude/.credentials.json home/.codex/auth.json \
         home/.gemini/oauth_creds.json home/.config/rclone/rclone.conf \
         .restic-password state.db state.db-wal checkpoints/a \
         state-snapshots/s/state.db lazy-packages/x.so skills/bundled/S.md \
         sessions/request_dump_1.json webui/sessions/_run_journal/a.jsonl \
         profiles/leilei/.env cron/executions.db logs/a.log node/x bin/y; do
  check "ignores $p" "$(ign "$p")" "ignored"
done

echo "== per-store extensions apply, and the secret tail still outranks them =="
rm -rf "$WORK/al2"; mkdir -p "$WORK/al2"; git init -q "$WORK/al2"
# The re-includes below are deliberately HOSTILE: a store that tried to un-ignore a credential
# must still fail. That is the property moving the secret block to the end of the file buys.
printf '!/platforms/\n!/hooks/\n!auth.json\n!home/.config/gh/hosts.yml\n' > "$WORK/ext"
python3 - "$ALLOWLIST" "$WORK/ext" "$WORK/al2/.gitignore" <<'PY'
import sys
src, ext, dst = sys.argv[1:4]
body = open(src).read().replace('@HARNESS_CONFIG_EXTENSIONS@', open(ext).read().rstrip('\n'))
open(dst, 'w').write(body)
PY
ign2() { git -C "$WORK/al2" check-ignore --no-index -q "$1" && echo ignored || echo kept; }
check "extension opens platforms/" "$(ign2 platforms/x.yaml)" "kept"
check "extension opens hooks/"     "$(ign2 hooks/h.sh)"       "kept"
check "hostile !auth.json loses"   "$(ign2 auth.json)"        "ignored"
check "hostile !hosts.yml loses"   "$(ign2 home/.config/gh/hosts.yml)" "ignored"

echo "== the commit guard passes legitimate content =="
mkrepo
printf 'x: 1\n' > "$WORK/repo/config.yaml"
mkdir -p "$WORK/repo/home/.claude/projects"; printf '{}\n' > "$WORK/repo/home/.claude/projects/a.jsonl"
printf 'K=\n' > "$WORK/repo/.env.example"
stage .
check "clean staged set exits 0" "$(guard)" "0"

echo "== the commit guard refuses credential files =="
for secret in .env auth.json .git-credentials google_token.json .restic-password; do
  mkrepo; printf 'x' > "$WORK/repo/$secret"; stage "$secret"
  check "refuses $secret" "$(guard)" "1"
done
mkrepo; mkdir -p "$WORK/repo/home/.config/gh"; printf 'x' > "$WORK/repo/home/.config/gh/hosts.yml"; stage .
check "refuses nested home/.config/gh/hosts.yml" "$(guard)" "1"
mkrepo; mkdir -p "$WORK/repo/mcp-tokens"; printf 'x' > "$WORK/repo/mcp-tokens/cb.json"; stage .
check "refuses mcp-tokens/" "$(guard)" "1"
mkrepo; mkdir -p "$WORK/repo/home/.config/rclone"; printf 'x' > "$WORK/repo/home/.config/rclone/rclone.conf"; stage .
check "refuses rclone.conf (holds a refresh token)" "$(guard)" "1"
mkrepo; mkdir -p "$WORK/repo/profiles/leilei"; printf 'x' > "$WORK/repo/profiles/leilei/auth.json"; stage .
check "refuses profiles/<name>/auth.json" "$(guard)" "1"

echo "== the commit guard refuses oversize blobs =="
mkrepo; head -c 2000000 /dev/zero | tr '\0' 'a' > "$WORK/repo/big.json"; stage big.json
check "refuses a blob over the limit" "$(guard 1)" "1"
mkrepo; head -c 400000 /dev/zero | tr '\0' 'a' > "$WORK/repo/ok.json"; stage ok.json
check "passes a blob under the limit" "$(guard 1)" "0"

echo "== the commit guard refuses a gitlink with no .gitmodules =="
mkrepo
git init -q "$WORK/inner"; (cd "$WORK/inner" && printf 'a' > a && git add a && git commit -qm a)
git -c safe.directory="$WORK/repo" -C "$WORK/repo" -c protocol.file.allow=always \
  submodule add -q "$WORK/inner" sub >/dev/null 2>&1 || cp -r "$WORK/inner" "$WORK/repo/sub"
rm -f "$WORK/repo/.gitmodules"
git -c safe.directory="$WORK/repo" -C "$WORK/repo" add -f sub >/dev/null 2>&1
check "refuses a bare gitlink" "$(guard)" "1"

echo "== the visibility gate =="
mkdir -p "$WORK/bin"; PATH="$WORK/bin:$PATH"; export PATH
ghstub() { printf '#!/bin/sh\n%s\n' "$1" > "$WORK/bin/gh"; chmod +x "$WORK/bin/gh"; }
vis() { assert_remote_private https://github.com/o/r.git >/dev/null 2>&1; echo $?; }
ghstub 'echo PRIVATE';  check "PRIVATE passes"  "$(vis)" "0"
ghstub 'echo INTERNAL'; check "INTERNAL passes" "$(vis)" "0"
ghstub 'echo PUBLIC';   check "PUBLIC refused"  "$(vis)" "1"
ghstub 'echo weird';    check "unknown visibility fails closed" "$(vis)" "1"
ghstub 'exit 1';        check "unreadable fails closed by default" "$(vis)" "1"
HARNESS_CONFIG_ALLOW_UNVERIFIED_REMOTE=1
export HARNESS_CONFIG_ALLOW_UNVERIFIED_REMOTE
check "unreadable passes with the override" "$(vis)" "0"
unset HARNESS_CONFIG_ALLOW_UNVERIFIED_REMOTE
ghstub 'echo PUBLIC'
HARNESS_CONFIG_ALLOW_UNVERIFIED_REMOTE=1
export HARNESS_CONFIG_ALLOW_UNVERIFIED_REMOTE
check "PUBLIC is refused even WITH the override" "$(vis)" "1"
unset HARNESS_CONFIG_ALLOW_UNVERIFIED_REMOTE

echo "== the archive verifier =="
python3 - "$WORK" <<'PY'
import os, sqlite3, sys, zipfile
w = sys.argv[1]
db = os.path.join(w, "real.db")
c = sqlite3.connect(db); c.execute("create table t(x)"); c.commit(); c.close()
good = open(db, "rb").read()
def mk(name, members):
    with zipfile.ZipFile(os.path.join(w, name), "w") as z:
        for n, d in members.items(): z.writestr(n, d)
mk("good.zip",   {"state.db": good,           "config.yaml": b"a: 1"})
mk("nodb.zip",   {"config.yaml": b"a: 1",     "sessions/x.json": b"{}"})
mk("empty.zip",  {"state.db": b"",            "config.yaml": b"a: 1"})
mk("zeroed.zip", {"state.db": b"\x00" * 4096, "config.yaml": b"a: 1"})
mk("nocfg.zip",  {"state.db": good})
mk("notdb.zip",  {"state.db": b"x" * 200,     "config.yaml": b"a: 1"})
PY
av() { harness_backup_verify_archive "$WORK/$1" >/dev/null 2>&1; echo $?; }
check "a complete archive passes"        "$(av good.zip)"   "0"
check "missing state.db refused"         "$(av nodb.zip)"   "1"
check "empty state.db refused"           "$(av empty.zip)"  "1"
check "zeroed state.db refused"          "$(av zeroed.zip)" "1"
check "missing config.yaml refused"      "$(av nocfg.zip)"  "1"
check "state.db with bad magic refused"  "$(av notdb.zip)"  "1"
check "unreadable archive refused"       "$(av absent.zip)" "1"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
