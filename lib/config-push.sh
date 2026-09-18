#!/bin/sh
# Commit and push a harness home's CONFIG to a private git remote.
#
# Shipped as `harness-config-push`. Never run by this image -- a deployment schedules it.
#
# This repo tracks config so it can be DIFFED: what changed in SOUL.md last week, when a cron
# job's schedule moved, which skill was edited. It is NOT the disaster-recovery copy -- it holds
# no credentials by design, so restoring from it alone yields a harness that cannot authenticate
# to anything. `harness-backup` is the recovery path; these two are not redundant.
#
# It replaces an arrangement where the backup was performed by WAKING A LANGUAGE MODEL every six
# hours to type `git add -A && git commit && git push` from a skill. That worked 1,147 times --
# including through a prompt instructing it to `cd ~/.hermes`, a path that does not exist under
# HOME=$HERMES_HOME/home -- because the model silently corrected the instruction on every tick.
# It also reported success when the push had failed, since a model's summary is not an exit code.
#
# What is genuinely per-store is expressed as INPUT here, not as a forked script and not as a
# hand-grown .gitignore. The allowlist is an image artifact for the same reason this script is:
# the 277-line original it was generalized from grew one `auto: ignore ...` commit at a time,
# each one landing AFTER something had already been pushed.
#
# Required:
#   HARNESS_CONFIG_REPO            git remote for the config repo; MUST be private
# Optional:
#   HERMES_DATA_DIR                harness home to track            (default /opt/data)
#   HARNESS_CONFIG_BRANCH          branch to commit and push        (default main)
#   HARNESS_CONFIG_GITIGNORE_SRC   allowlist to render from
#                                  (default /usr/local/share/contexture/hermes-config.gitignore)
#   HARNESS_CONFIG_INCLUDE         extra allowlist entries, whitespace-separated. Each is
#                                  rendered as `!/<entry>`.  e.g. "platforms/ hooks/ plans/"
#   HARNESS_CONFIG_EXCLUDE         extra ignore patterns, whitespace-separated, verbatim.
#   HARNESS_CONFIG_MESSAGE         commit subject; " <ISO-8601>" is appended
#                                                  (default "auto: harness config")
#   HARNESS_CONFIG_MAX_BLOB_MB     refuse a staged blob larger than this   (default 95)
#   HARNESS_CONFIG_DRY_RUN         1 to run every guard and print the staged set, then stop
#                                  before `git commit`. Use this to adopt a live store.
#   HARNESS_CONFIG_ALLOW_UNVERIFIED_REMOTE
#                                  1 to push to a remote whose visibility `gh` cannot read
#                                  (self-hosted forge). Default 0 = refuse.
#   GIT_USER_NAME / GIT_USER_EMAIL commit identity, when the repo has none of its own. Normally
#                                  unnecessary: ctxr-provision already wrote ~/.gitconfig here.
#   PUID / PGID                    runtime uid/gid                  (default 10000)
#
# Deliberately NOT an input: GH_TOKEN. The long-running gateway never receives it and must not
# start doing so. `ctxr-provision` persists the credential to $HERMES_HOME/home/.config/gh and
# wires the git credential helper; this script exports HOME to that path and inherits both.
# Accepting GH_TOKEN would put a raw token in the environment of a command that runs on a timer
# for the life of the deployment -- exactly the exposure ctxr-provision goes out of its way to
# avoid by unsetting it before `gh auth login`.
set -eu

HERMES_DATA="${HERMES_DATA_DIR:-/opt/data}"
BRANCH="${HARNESS_CONFIG_BRANCH:-main}"
GITIGNORE_SRC="${HARNESS_CONFIG_GITIGNORE_SRC:-/usr/local/share/contexture/hermes-config.gitignore}"
MAX_BLOB_MB="${HARNESS_CONFIG_MAX_BLOB_MB:-95}"
PUID="${PUID:-10000}"
PGID="${PGID:-10000}"
MANAGED_MARKER="harness-config-push managed allowlist"

log() { echo "[harness-config-push] $*"; }

: "${HARNESS_CONFIG_REPO:?HARNESS_CONFIG_REPO is required}"

# The agent's own HOME, and where ctxr-provision put the gh credential and ~/.gitconfig. Both
# are needed: the credential to push, the gitconfig for the `gh auth git-credential` helper and
# the commit identity.
export HOME="$HERMES_DATA/home"

# Every git call carries safe.directory for this one path. Not defensive -- `git -C /opt/data
# rev-parse HEAD` as root against a 10000-owned volume fails with "detected dubious ownership"
# today. The provisioner's refresh path has already been broken twice by exactly this, which is
# why it has its own CI job. Scoped per-invocation rather than written to ~/.gitconfig: the
# exception is true of this one path, and leaving it global would quietly extend it to every
# other repository root ever mounted here.
home_git() { git -c safe.directory="$HERMES_DATA" -C "$HERMES_DATA" "$@"; }

# >>> visibility-gate (lib/tests/harness-config-test.sh extracts between these markers; keep
# them around exactly the gate) >>>
# Refuses a public remote. The commit guard below defends against credential FILES; this
# defends against CONTENT -- chat transcripts, SOUL.md and config.yaml go up verbatim, and no
# path-matching guard can read what is inside them. Neither substitutes for the other.
assert_remote_private() {   # $1 = remote URL
  _vis="$(gh repo view "$1" --json visibility -q .visibility 2>&1)" || {
    if [ "${HARNESS_CONFIG_ALLOW_UNVERIFIED_REMOTE:-0}" = 1 ]; then
      log "WARNING: cannot read visibility of $1 - proceeding on HARNESS_CONFIG_ALLOW_UNVERIFIED_REMOTE"
      return 0
    fi
    log "REFUSED: cannot verify that $1 is private."
    log "  gh said: ${_vis}"
    log "  A self-hosted forge or local path is legitimate; set"
    log "  HARNESS_CONFIG_ALLOW_UNVERIFIED_REMOTE=1 to assert it yourself."
    return 1
  }
  case "$_vis" in
    PRIVATE|INTERNAL) return 0 ;;
    PUBLIC)
      log "REFUSED: $1 is PUBLIC."
      log "  This pushes chat transcripts, SOUL.md and config.yaml verbatim. There is no"
      log "  override for a confirmed-public remote, deliberately. Use a private repo."
      return 1 ;;
    *)
      log "REFUSED: unrecognised visibility '${_vis}' for $1 - failing closed."
      return 1 ;;
  esac
}
# <<< visibility-gate <<<

# >>> commit-guard (extracted by lib/tests/harness-config-test.sh; keep the markers around
# exactly the guard) >>>
# Runs over the STAGED set, after `git add -A`, before `git commit`. Refuses; never remediates.
# An unattended job that ran `git rm --cached` on its own would eventually delete a session
# directory, and a bare glob there expands against the WORKING TREE rather than the index, which
# is its own trap. Refusing leaves the index untouched, so the next run fails identically --
# idempotent failure is the property you want from something on a timer.
harness_config_commit_guard() {   # $1 = repo dir, $2 = max blob MB
  _dir="$1"; _max_mb="$2"; _bad=0
  _g() { git -c safe.directory="$_dir" -C "$_dir" "$@"; }
  # Findings go to a temp file OUTSIDE the repo. Writing scratch into the very tree we just
  # ran `git add -A` over is how scratch ends up committed, which is the whole reason the
  # allowlist exists.
  _find="$(mktemp)"

  # -z, because a path containing a newline would otherwise be read as two paths. Any path git
  # would have to quote is refused outright below rather than parsed.
  _staged="$(_g diff --cached --name-only -z | tr '\0' '\n')"
  [ -n "$_staged" ] || { rm -f "$_find"; return 0; }

  printf '%s\n' "$_staged" | while IFS= read -r _p; do
    [ -n "$_p" ] || continue
    case "$_p" in
      *'"'*|*'\'*) echo "QUOTED|$_p" ;;
    esac
    _base="${_p##*/}"
    case "$_base" in
      .env|.env.*|auth.json|auth.lock|.git-credentials|.netrc|.npmrc|\
      google_token.json|google_client_secret.json|google_oauth_pending.json|\
      google_oauth_last_url.txt|hosts.yml|.credentials.json|oauth_creds.json|\
      google_accounts.json|antigravity-oauth-token|id_rsa|id_ed25519|*.pem|\
      rclone.conf|.restic-password|.restic-password.*|\
      .signing_key|.pbkdf2_key|*.key|*_key)
        case "$_base" in .env.example) ;; *) echo "SECRET|$_p" ;; esac ;;
    esac
    case "$_p" in
      mcp-tokens/*|*/mcp-tokens/*|profiles/*/.env|profiles/*/auth.json)
        echo "SECRET|$_p" ;;
    esac
  done > "$_find" 2>/dev/null || true

  # Oversize blobs. `git cat-file -s` on the staged object -- pure git, no stat portability
  # question, and it measures what would actually be PUSHED rather than what is on disk. This is
  # the only guard that prevents a repo becoming permanently unpushable: GitHub hard-rejects a
  # blob over 100 MB, and the repo this replaces already carries a 95.6 MB one.
  _limit=$(( _max_mb * 1024 * 1024 ))
  printf '%s\n' "$_staged" | while IFS= read -r _p; do
    [ -n "$_p" ] || continue
    _oid="$(_g rev-parse ":$_p" 2>/dev/null)" || continue
    _sz="$(_g cat-file -s "$_oid" 2>/dev/null)" || continue
    [ "$_sz" -gt "$_limit" ] && echo "OVERSIZE|$_p is $(( _sz / 1024 / 1024 )) MB (limit ${_max_mb} MB)"
  done >> "$_find" 2>/dev/null || true

  # Gitlinks with no .gitmodules. A committed submodule pointer with no mapping restores as an
  # EMPTY DIRECTORY and says nothing about it -- the repo this replaces has carried exactly that
  # (`BenchCAD-main`, mode 160000, no .gitmodules) for months, so its restore is already broken.
  if [ ! -f "${_dir}/.gitmodules" ]; then
    _g diff --cached --raw | awk '$2 == "160000" { print "GITLINK|" $NF }' \
      >> "$_find" 2>/dev/null || true
  fi

  if [ -s "$_find" ]; then
    log "REFUSED: the staged set is not safe to commit."
    while IFS='|' read -r _kind _detail; do
      case "$_kind" in
        SECRET)   log "  credential file staged : $_detail" ;;
        OVERSIZE) log "  blob too large         : $_detail" ;;
        GITLINK)  log "  gitlink, no .gitmodules: $_detail" ;;
        QUOTED)   log "  unparseable path       : $_detail" ;;
      esac
    done < "$_find"
    log ""
    log "  Nothing was committed and the index was left as-is, so this will fail the same way"
    log "  next run. To untrack a path, pipe from ls-files -- a bare glob expands against the"
    log "  working tree, not the index:"
    log "      git -C ${_dir} ls-files '<glob>' | xargs git -C ${_dir} rm --cached"
    _bad=1
  fi
  rm -f "$_find"
  return $_bad
}
# <<< commit-guard <<<

# Render the shipped allowlist, substituting the per-store block. Only when the file is ours:
# a store with a hand-grown .gitignore keeps it untouched, so adopting this script changes no
# policy on day one. The fork stays possible; it is just visible.
render_gitignore() {
  _dst="$HERMES_DATA/.gitignore"
  if [ -f "$_dst" ] && ! grep -q "$MANAGED_MARKER" "$_dst"; then
    log "WARNING: unmanaged .gitignore at $_dst - leaving it alone, shipped policy NOT applied."
    return 0
  fi
  [ -f "$GITIGNORE_SRC" ] || { log "ERROR: allowlist not found at $GITIGNORE_SRC"; return 1; }

  _ext=""
  for _e in ${HARNESS_CONFIG_INCLUDE:-}; do _ext="${_ext}!/${_e}
"; done
  for _e in ${HARNESS_CONFIG_EXCLUDE:-}; do _ext="${_ext}${_e}
"; done

  # awk rather than sed: the replacement is multi-line and the entries contain `/` and `!`.
  awk -v ext="$_ext" '
    $0 == "@HARNESS_CONFIG_EXTENSIONS@" { printf "%s", ext; next }
    { print }
  ' "$GITIGNORE_SRC" > "${_dst}.tmp"
  mv "${_dst}.tmp" "$_dst"
}

# --- run ---------------------------------------------------------------------------------
# The gate runs FIRST, before init/add/commit, so a refusal mutates nothing at all.
assert_remote_private "$HARNESS_CONFIG_REPO" || exit 1

# The gh credential is required only when the remote actually IS GitHub over https -- that is
# the only case where `gh auth setup-git`'s credential helper is what answers the push. An ssh
# remote, a self-hosted forge or a local path authenticates by some other means entirely, and
# demanding `gh auth status` there would refuse a perfectly working configuration.
case "$HARNESS_CONFIG_REPO" in
  https://github.com/*)
    command -v gh >/dev/null 2>&1 || { log "ERROR: gh is not installed."; exit 1; }
    if ! gh auth status >/dev/null 2>&1; then
      log "ERROR: gh has no stored credential under HOME=$HOME."
      log "  Run the store's provisioning one-shot first (entrypoint ctxr-provision), which is"
      log "  what persists it. This script takes no GH_TOKEN of its own, by design."
      exit 1
    fi
    ;;
esac

mkdir -p "$HERMES_DATA"
if [ -d "$HERMES_DATA/.git" ]; then
  _remote="$(home_git remote get-url origin 2>/dev/null || echo '')"
  if [ -n "$_remote" ] && [ "$_remote" != "$HARNESS_CONFIG_REPO" ]; then
    log "REFUSED: $HERMES_DATA already points at a different remote."
    log "  existing: $_remote"
    log "  wanted  : $HARNESS_CONFIG_REPO"
    log "  Repointing a config repo is a deliberate act; do it by hand."
    exit 1
  fi
  [ -n "$_remote" ] || home_git remote add origin "$HARNESS_CONFIG_REPO"
  _fresh=0
else
  log "initialising $HERMES_DATA as a config repo"
  home_git init -q -b "$BRANCH"
  home_git remote add origin "$HARNESS_CONFIG_REPO"
  _fresh=1
fi

render_gitignore

# A stale repo-local credential helper is a debugging trap, not a fault: pushes survive it
# because `gh auth setup-git` installs an ADDITIVE global helper that answers first. Warn only.
_helper="$(home_git config --get credential.helper 2>/dev/null || echo '')"
case "$_helper" in
  "store --file="*)
    _f="${_helper#store --file=}"
    [ -f "$_f" ] || log "WARNING: repo-local credential.helper points at $_f, which does not exist."
    ;;
esac

# Fetch and refuse to proceed on divergence. Never merge, never force: an unattended job that
# can rewrite remote history is a backup that can destroy itself.
if [ "$_fresh" -eq 0 ] && home_git fetch -q origin "$BRANCH" 2>/dev/null; then
  _behind="$(home_git rev-list --count "HEAD..origin/${BRANCH}" 2>/dev/null || echo 0)"
  if [ "${_behind:-0}" -gt 0 ]; then
    log "REFUSED: local is behind or diverged from origin/${BRANCH}."
    log "  Reconcile by hand; this script will not merge, rebase or force."
    exit 1
  fi
fi

# Identity, probed rather than assumed. Without it `git commit` dies with "unable to auto-detect
# email address (got 'root@<container-id>.(none)')", which names neither the cause nor the fix
# and is especially confusing here because HOME has been redirected to the volume -- a global
# gitconfig in the invoking user's real home is not the one this sees.
if ! home_git var GIT_AUTHOR_IDENT >/dev/null 2>&1; then
  if [ -n "${GIT_USER_NAME:-}" ] && [ -n "${GIT_USER_EMAIL:-}" ]; then
    home_git config user.name  "$GIT_USER_NAME"
    home_git config user.email "$GIT_USER_EMAIL"
  else
    log "ERROR: no git commit identity visible from HOME=$HOME."
    log "  ctxr-provision normally writes it to \$HERMES_HOME/home/.gitconfig. Either run that"
    log "  one-shot, or pass GIT_USER_NAME and GIT_USER_EMAIL to this command."
    exit 1
  fi
fi

home_git add -A

if home_git diff --cached --quiet 2>/dev/null; then
  log "no changes - nothing to commit."
  exit 0
fi

harness_config_commit_guard "$HERMES_DATA" "$MAX_BLOB_MB" || exit 1

if [ "${HARNESS_CONFIG_DRY_RUN:-0}" = 1 ]; then
  log "DRY RUN - would commit the following and stop:"
  home_git diff --cached --name-status | sed 's/^/    /'
  exit 0
fi

home_git commit -q -m "${HARNESS_CONFIG_MESSAGE:-auto: harness config} $(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [ "$_fresh" -eq 1 ]; then
  home_git push -q -u origin "$BRANCH"
else
  home_git push -q origin "$BRANCH"
fi
log "pushed $(home_git rev-parse --short HEAD) to ${HARNESS_CONFIG_REPO} (${BRANCH})"

# Scoped to what this script creates, NOT -R over the tree. ctxr-provision chowns everything
# because it runs once against a small checkout; this runs on a timer against a multi-gigabyte
# home with hundreds of thousands of inodes. The problem being prevented -- a root-owned object
# the agent cannot write on its next commit -- is a .git problem, so .git is what gets fixed.
if [ "$(id -u)" = 0 ]; then
  chown -R "${PUID}:${PGID}" "$HERMES_DATA/.git" 2>/dev/null || log "WARNING: chown .git failed."
  chown "${PUID}:${PGID}" "$HERMES_DATA/.gitignore" 2>/dev/null || true
fi
