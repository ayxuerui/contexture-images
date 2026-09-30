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
#   TOOLCHAIN_HOME         throwaway HOME for the curl|bash installers (see below)
set -eu

fail() { echo "install-agent-clis: $*" >&2; exit 1; }

: "${CODEX_VERSION:?CODEX_VERSION is required}"
: "${AGENT_BROWSER_VERSION:?AGENT_BROWSER_VERSION is required}"
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
# Neither claude nor agy ships on npm, so neither can be pinned the way the two above are.
# They are NOT the same case beyond that, despite this comment previously claiming they were:
#
#   claude  install.sh takes [stable|latest|VERSION] as $1. Asked for `stable` -- a floating
#           CHANNEL, not a version pin. A numeric pin here would need its own watcher to stay
#           current (cf. .github/workflows/watch-ctxr.yml, which exists for exactly that reason
#           for ctxr-cli), and there is no such watcher for claude; an unwatched number would
#           rot silently, which is worse than a named channel. `stable` also happens to be what
#           `claude install` defaults to with no argument, so naming it changes nothing today
#           and keeps an upstream default change from moving this image without a diff.
#   agy     install.sh takes only -d/--dir and -h/--help. Genuinely unpinnable; it is whatever
#           the installer serves on build day.
#
# Both are therefore re-pinned implicitly by the image tag once built. Since neither version is
# knowable from this file, the smoke tests below ECHO what landed: the build log is the only
# record of which claude and agy a given tag carries.
#
# Installed against a throwaway HOME rather than the real one. At runtime HOME is a VOLUME
# (/opt/data on the Hermes base), which would put these binaries in mutable state instead of
# in the image; they would then survive a rebuild and drift invisibly. Symlinked into
# /usr/local/bin, which is already on PATH and root-owned, so what the image ships is always
# what the tag says. That makes these a baseline rather than the only copy: the agent upgrades
# or adds a tool in its own prefix, /opt/data/home/.local/bin, which sits ahead of this one on
# PATH -- see harnesses/hermes/profile.d/10-hermes-path.sh. An override there is visible by
# being in a named directory, rather than drifting inside the image's own tree.
echo "install-agent-clis: installing claude and agy into ${TOOLCHAIN_HOME}"
mkdir -p "${TOOLCHAIN_HOME}"
HOME="${TOOLCHAIN_HOME}" sh -c 'curl -fsSL https://claude.ai/install.sh | bash -s stable'
HOME="${TOOLCHAIN_HOME}" sh -c 'curl -fsSL https://antigravity.google/cli/install.sh | bash'
ln -sf "${TOOLCHAIN_HOME}/.local/bin/claude" /usr/local/bin/claude
ln -sf "${TOOLCHAIN_HOME}/.local/bin/agy" /usr/local/bin/agy
# `claude --version` prints "<version> (Claude Code)", so the version is the first field only --
# unlike `ctxr --version`, which prints the bare version and is compared whole in
# install-contexture-toolchain.sh. A floating channel admits no equality assertion, so assert
# SHAPE: a claude that installed but cannot report a version still fails the BUILD here rather
# than a cron job at 03:00, which is the property every other install in this file has.
claude_version="$(claude --version | awk '{print $1}')"
case "${claude_version}" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) fail "claude --version reported '${claude_version}', which is not a version" ;;
esac

agy_version="$(agy --version 2>&1 | head -1)"
[ -n "${agy_version}" ] || fail "agy --version reported nothing"

echo "install-agent-clis: ok (codex ${CODEX_VERSION}, agent-browser ${AGENT_BROWSER_VERSION}, claude ${claude_version}, agy ${agy_version})"
