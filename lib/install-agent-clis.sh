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
#   CLAUDE_VERSION         claude.ai/install.sh (see below -- not npm, but still an exact pin)
#   TOOLCHAIN_HOME         throwaway HOME for the curl|bash installers (see below)
set -eu

fail() { echo "install-agent-clis: $*" >&2; exit 1; }

: "${CODEX_VERSION:?CODEX_VERSION is required}"
: "${AGENT_BROWSER_VERSION:?AGENT_BROWSER_VERSION is required}"
: "${CLAUDE_VERSION:?CLAUDE_VERSION is required}"
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
# claude and agy don't ship on npm, but that's an installer-mechanics difference, not a reason
# either has to float:
#
#   claude  install.sh takes [stable|latest|VERSION] as $1 -- an exact version is a supported,
#           documented argument, not a workaround. Pinned here the same as codex/agent-browser,
#           watched the same way (watch-agent-clis.yml queries
#           https://downloads.claude.ai/claude-code-releases/stable, the same plain-text
#           version endpoint the bootstrap step of install.sh itself reads from, in place of
#           `npm view`).
#   agy     install.sh takes only -d/--dir and -h/--help. Genuinely unpinnable: no version
#           argument, and its manifest (queried by install.sh at
#           https://antigravity.google/cli/install.sh's $DOWNLOAD_BASE_URL/manifests/$platform.json)
#           serves only whatever build is current right now -- no history, and the download URL
#           it returns embeds an opaque per-build id that can't be reconstructed from a version
#           number. Re-pinned implicitly by the image tag once built, same as before; the smoke
#           test below ECHOes what landed since there is nothing to assert equality against.
#
# Installed against a throwaway HOME rather than the real one. At runtime HOME is a VOLUME
# (/opt/data on the Hermes base), which would put these binaries in mutable state instead of
# in the image; they would then survive a rebuild and drift invisibly. Symlinked into
# /usr/local/bin, which is already on PATH and root-owned -- the agent runs unprivileged and
# so cannot rewrite its own toolchain.
echo "install-agent-clis: installing claude ${CLAUDE_VERSION} and agy into ${TOOLCHAIN_HOME}"
mkdir -p "${TOOLCHAIN_HOME}"
HOME="${TOOLCHAIN_HOME}" sh -c 'curl -fsSL https://claude.ai/install.sh | bash -s "${CLAUDE_VERSION}"'
HOME="${TOOLCHAIN_HOME}" sh -c 'curl -fsSL https://antigravity.google/cli/install.sh | bash'
ln -sf "${TOOLCHAIN_HOME}/.local/bin/claude" /usr/local/bin/claude
ln -sf "${TOOLCHAIN_HOME}/.local/bin/agy" /usr/local/bin/agy
# `claude --version` prints "<version> (Claude Code)", so the version is the first field only --
# same as install-contexture-toolchain.sh's `ctxr --version` check, an exact pin gets an exact
# equality assertion: a claude that installed but landed on the wrong version still fails the
# BUILD here rather than a cron job at 03:00.
claude_version="$(claude --version | awk '{print $1}')"
[ "${claude_version}" = "${CLAUDE_VERSION}" ] \
  || fail "claude --version reported '${claude_version}', expected ${CLAUDE_VERSION}"

agy_version="$(agy --version 2>&1 | head -1)"
[ -n "${agy_version}" ] || fail "agy --version reported nothing"

echo "install-agent-clis: ok (codex ${CODEX_VERSION}, agent-browser ${AGENT_BROWSER_VERSION}, claude ${claude_version}, agy ${agy_version})"
