#!/bin/sh
# One-shot provisioning for a Contexture store in a container.
#
# Shipped as `ctxr-provision`. Every consuming deployment ran a near-identical copy of this as
# its own setup.sh; the two that existed agreed on eleven of thirteen steps and had already
# drifted apart on the other two -- one wired git hooks and the other did not, which is a
# silently weaker write gate, not a deliberate difference.
#
# What is genuinely per-store is expressed as INPUT here, not as a forked script. Anything a
# store cannot express through these variables belongs in its own one-shot service, not in a
# private copy of this file that drifts.
#
# Required:
#   REPO_URL GH_TOKEN GIT_USER_NAME GIT_USER_EMAIL
# Optional:
#   STORE_DIR                     store checkout       (default /store)
#   HERMES_DATA_DIR               agent data volume    (default /opt/data)
#   PUID / PGID                   runtime uid/gid      (default 10000)
#   CTXR_PROFILE                  taxonomy for a FRESH store only (default para)
#   HERMES_SKILLS_EXTERNAL_DIRS   JSON array for `hermes config set skills.external_dirs`
#   HERMES_SKILLS_DISABLED        JSON array for `hermes config set skills.disabled`
set -eu

STORE="${STORE_DIR:-/store}"
HERMES_DATA="${HERMES_DATA_DIR:-/opt/data}"
SENTINEL="$STORE/.contexture-initialized"
PUID="${PUID:-10000}"
PGID="${PGID:-10000}"

log() { echo "[ctxr-provision] $*"; }

# Two layers guard re-provisioning, and both matter. A deployment gates this behind something
# like compose `profiles:` so a plain `up` never calls it; the sentinel then keeps even a
# deliberate re-run from re-provisioning over live agent work -- which matters on platforms
# that have no `profiles` equivalent and re-run a release command on every deploy.
if [ -f "$SENTINEL" ]; then
  log "sentinel present ($SENTINEL) - store already provisioned, skipping."
  exit 0
fi

: "${REPO_URL:?REPO_URL is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GIT_USER_NAME:?GIT_USER_NAME is required}"
: "${GIT_USER_EMAIL:?GIT_USER_EMAIL is required}"

# The agent's own HOME, and the same path Hermes resolves `~` to for tool subprocesses
# ({HERMES_HOME}/home, hardcoded in its home_mode policy). Credentials written here are
# therefore found by the long-running gateway's subprocesses without GH_TOKEN ever being in
# their environment -- which is the point, since passing it through would expose the token to
# every shell command the agent runs.
export HOME="$HERMES_DATA/home"
mkdir -p "$HOME"

git config --global user.name "$GIT_USER_NAME"
git config --global user.email "$GIT_USER_EMAIL"

# `gh auth login --with-token` refuses to PERSIST a credential while GH_TOKEN is set in its own
# environment -- it uses the env var ambiently instead and stores nothing. That would defeat the
# purpose: the long-running gateway never receives GH_TOKEN, so it needs a stored credential.
# Capture, unset, then feed over stdin.
log "authenticating gh"
_gh_token="$GH_TOKEN"
unset GH_TOKEN
if ! printf '%s' "$_gh_token" | gh auth login --hostname github.com --with-token; then
  cat >&2 <<'EOF'
[ctxr-provision] ERROR: gh auth login rejected the token.

If the message was "missing required scope 'read:org'", the token is a CLASSIC PAT.
`gh auth login` validates classic tokens against a minimum scope set that includes
read:org - even though none of the operations a store performs (clone, push, pr
create/view/merge) need it. Two ways out:

  * Use a FINE-GRAINED PAT instead (recommended): repository access limited to the
    repos the agent touches, with Contents: read/write, Pull requests: read/write,
    Metadata: read-only. A fine-grained token reports no scopes header, so this
    check does not apply.

  * Or re-mint the classic token with read:org added.
EOF
  unset _gh_token
  exit 1
fi
unset _gh_token
gh auth setup-git

if [ -d "$STORE/.git" ]; then
  log "existing checkout at $STORE"
  if [ -n "$(git -C "$STORE" status --porcelain)" ]; then
    log "store is dirty - skipping pull so in-flight agent work is never clobbered."
  else
    log "pulling (fast-forward only)"
    git -C "$STORE" pull --ff-only
  fi
else
  log "cloning $REPO_URL into $STORE"
  git clone "$REPO_URL" "$STORE"
fi

# Decided from the store's state, not from a per-deployment flag. `ctxr init` against an
# established store takes an idempotent-reconcile path over contexture-owned files, which
# produces a diff in the container's clone that nobody asked for and shows up as dirty state on
# the very first session. Against a genuinely fresh checkout it is the thing that makes the
# store a store. Absence of contexture.yaml is exactly that distinction.
if [ -f "$STORE/contexture.yaml" ]; then
  log "contexture.yaml present - established store, verifying rather than reconciling"
else
  log "no contexture.yaml - fresh store, running ctxr init --profile ${CTXR_PROFILE:-para}"
  ctxr init --profile "${CTXR_PROFILE:-para}" --root "$STORE"
fi

# `ctxr doctor`'s write-lifecycle check self-heals core.hooksPath, but only once the hooks
# directory is present. Setting it here is what keeps the pre-push guard (refuses a direct push
# to the default branch) active inside the container from the first session.
if [ -d "$STORE/.githooks" ]; then
  git -C "$STORE" config core.hooksPath .githooks
  log "core.hooksPath set to .githooks"
fi

# Optional Hermes wiring. Without external_dirs pointing at the store's skills, Hermes resolves
# skills only from its own bundle and reaches for the nearest match -- a store whose skills it
# cannot see does not degrade gracefully, it follows someone else's instructions.
if [ -n "${HERMES_SKILLS_EXTERNAL_DIRS:-}" ]; then
  log "hermes config set skills.external_dirs"
  hermes config set skills.external_dirs "$HERMES_SKILLS_EXTERNAL_DIRS"
fi
if [ -n "${HERMES_SKILLS_DISABLED:-}" ]; then
  log "hermes config set skills.disabled"
  hermes config set skills.disabled "$HERMES_SKILLS_DISABLED"
fi

# Both trees, not just the store. This script runs as root, so everything it created under
# $HOME is root-owned -- including the gh credential at 0600, which the agent then cannot even
# READ. That breaks `ctxr session start` and every `gh pr create` the submit path makes.
chown -R "${PUID}:${PGID}" "$STORE" 2>/dev/null || log "WARNING: chown $STORE failed."
chown -R "${PUID}:${PGID}" "$HOME"  2>/dev/null || log "WARNING: chown $HOME failed."

# Verification runs LAST, and as the runtime uid rather than as root. Both matter. Before the
# chown the tree is root-owned and git refuses it for anyone else ("dubious ownership"), so a
# doctor run here reports a failure that is an artifact of provisioning rather than a fact about
# the store -- observed, and it emits a WARNING that sends an operator looking for a problem that
# does not exist. Run as ${PUID} after the handover, it verifies the store under exactly the
# conditions the agent will meet.
log "verifying as ${PUID}:${PGID}"
if command -v setpriv >/dev/null 2>&1; then
  setpriv --reuid="${PUID}" --regid="${PGID}" --clear-groups \
    env HOME="$HOME" ctxr doctor --root "$STORE" \
    || log "WARNING: ctxr doctor reported issues - inspect before relying on this store."
else
  log "setpriv unavailable - running doctor as root; a dubious-ownership failure here is expected"
  ctxr doctor --root "$STORE" || log "WARNING: ctxr doctor reported issues."
fi

touch "$SENTINEL"
chown "${PUID}:${PGID}" "$SENTINEL" 2>/dev/null || true
log "provisioning complete."
