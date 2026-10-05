#!/bin/sh
# Agent CLIs a harness image makes available to the agent's shell.
#
# Separate from install-contexture-toolchain.sh on purpose. That script installs what
# CONTEXTURE needs (`gh`, because the forge adapter shells out to it; `ctxr` itself). This one
# installs what an AGENT needs -- other models and a browser driver it can call as tools. The
# two answer to different owners and change for different reasons, so they are not one file.
#
# Universal rather than per-store: a skill that reaches for `codex` or `claude` should find it
# on any store running this image, not only the one whose Dockerfile happened to install it.
# Upstream hermes issue #681 calls the equivalent gap in their WebUI container "architectural,
# not a bug" -- an agent whose shell lacks the tool cannot run the skill at all.
#
# Inputs, all required, fed from Dockerfile ARGs:
#   CODEX_VERSION          @openai/codex
#   AGENT_BROWSER_VERSION  agent-browser
#   CLAUDE_VERSION         exact claude build, passed to its installer
#   AGY_VERSION            the agy release this build expects (see below: recorded, not enforced)
#   TOOLCHAIN_HOME         throwaway HOME for the curl|bash installers (see below)
set -eu

fail() { echo "install-agent-clis: $*" >&2; exit 1; }

: "${CODEX_VERSION:?CODEX_VERSION is required}"
: "${AGENT_BROWSER_VERSION:?AGENT_BROWSER_VERSION is required}"
: "${CLAUDE_VERSION:?CLAUDE_VERSION is required}"
: "${AGY_VERSION:?AGY_VERSION is required}"
: "${TOOLCHAIN_HOME:?TOOLCHAIN_HOME is required}"

command -v npm >/dev/null 2>&1 || fail "needs Node/npm on the base image"

# --- npm-distributed --------------------------------------------------------------------
# Pinned, and smoke-tested in the same layer, so a moved or broken package fails the BUILD
# rather than a cron job at 03:00.
echo "install-agent-clis: installing codex ${CODEX_VERSION}, agent-browser ${AGENT_BROWSER_VERSION}"
npm install -g \
  "@openai/codex@${CODEX_VERSION}" \
  "agent-browser@${AGENT_BROWSER_VERSION}"
npm cache clean --force
codex --version
command -v agent-browser >/dev/null 2>&1 || fail "agent-browser did not land on PATH"

# --- curl|bash installers ---------------------------------------------------------------
# Neither claude nor agy ships on npm, so .github/workflows/watch-agent-clis.yml reads their own
# release endpoints instead, and opens a bump PR like it does for the two above. Upgrading is
# then the same for every tool in this image: merge the bump, pull the new image, recreate --
# which is the upgrade path upstream documents for this base, whose install tree is immutable at
# runtime by design.
#
#   claude  install.sh takes an exact VERSION as $1, so this is a real pin, asserted below. The
#           watcher tracks the `stable` channel, so the pin moves only as fast as stable does.
#   agy     install.sh takes no version at all -- it installs whatever its manifest serves. So
#           AGY_VERSION cannot pin; what it does is (a) give this layer a cache key that changes
#           when agy releases, so the installer actually re-runs instead of replaying a cached
#           layer, and (b) let the build SAY when what landed differs from what was expected.
#           That is a warning, not a failure: the only way to hit it is agy publishing between
#           the watcher's last check and this build, and failing there would turn every agy
#           release into a broken release build for whatever else was being shipped.
#
# Installed against a throwaway HOME rather than the real one. At runtime HOME is a VOLUME
# (/opt/data on the Hermes base), which would put these binaries in mutable state instead of
# in the image; they would then survive a rebuild and drift invisibly. Symlinked into
# /usr/local/bin, which is already on PATH and root-owned -- the agent runs unprivileged and
# so cannot rewrite its own toolchain.
echo "install-agent-clis: installing claude ${CLAUDE_VERSION} and agy into ${TOOLCHAIN_HOME}"
mkdir -p "${TOOLCHAIN_HOME}"
HOME="${TOOLCHAIN_HOME}" sh -c "curl -fsSL https://claude.ai/install.sh | bash -s '${CLAUDE_VERSION}'"
HOME="${TOOLCHAIN_HOME}" sh -c 'curl -fsSL https://antigravity.google/cli/install.sh | bash'
ln -sf "${TOOLCHAIN_HOME}/.local/bin/claude" /usr/local/bin/claude
ln -sf "${TOOLCHAIN_HOME}/.local/bin/agy" /usr/local/bin/agy

# `claude --version` prints "<version> (Claude Code)", so the version is the first field only --
# unlike `ctxr --version`, which prints the bare version and is compared whole in
# install-contexture-toolchain.sh.
claude_version="$(claude --version | awk '{print $1}')"
[ "${claude_version}" = "${CLAUDE_VERSION}" ] \
  || fail "claude reports '${claude_version}' but CLAUDE_VERSION is '${CLAUDE_VERSION}'"

agy_version="$(agy --version 2>&1 | head -1)"
[ -n "${agy_version}" ] || fail "agy --version reported nothing"
if [ "${agy_version}" != "${AGY_VERSION}" ]; then
  echo "install-agent-clis: WARNING: agy installed ${agy_version}, but AGY_VERSION is ${AGY_VERSION}." >&2
  echo "install-agent-clis: WARNING: agy cannot be pinned; the watcher will open a bump PR." >&2
fi

echo "install-agent-clis: ok (codex ${CODEX_VERSION}, agent-browser ${AGENT_BROWSER_VERSION}, claude ${claude_version}, agy ${agy_version})"
