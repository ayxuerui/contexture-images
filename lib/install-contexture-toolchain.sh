#!/bin/sh
# Everything a Contexture store needs from a container, independent of harness.
#
# This is the ONLY file shared across harness images, and that is deliberate: each harness
# brings its own base image (nousresearch/hermes-agent for Hermes, whatever Codex or DeepSeek
# ship), so there is no common base to build FROM. What IS common is small -- `gh` and `ctxr`
# -- so it is a script every harness Dockerfile runs, not a layer they inherit.
#
# Run it from a single RUN so every install and its smoke test land in one layer: a broken or
# moved package then fails the BUILD, rather than failing at 03:00 in a cron job. That is the
# whole reason these images exist rather than an `npm i -g` at container start.
#
# Inputs, both required, fed from Dockerfile ARGs:
#   GH_VERSION    gh CLI release to install, e.g. 2.98.0
#   CTXR_VERSION  ctxr-cli version to install, e.g. 0.10.0
set -eu

fail() { echo "install-contexture-toolchain: $*" >&2; exit 1; }

: "${GH_VERSION:?GH_VERSION is required}"
: "${CTXR_VERSION:?CTXR_VERSION is required}"

# --- Base-image preconditions -------------------------------------------------------------
# Asserted here, loudly and by name, rather than left to fail obscurely 40 lines down. Both
# hold for the Hermes agent image; a future harness on Alpine or without Node will trip these
# immediately and know exactly which assumption it broke.
command -v apt-get >/dev/null 2>&1 || fail "needs a Debian/Ubuntu base (no apt-get); the gh install below is .deb-based"
command -v npm     >/dev/null 2>&1 || fail "needs Node/npm on the base image; ctxr-cli is an npm package"

# --- gh CLI -------------------------------------------------------------------------------
# Contexture's GitHub forge adapter shells out to `gh` (repo view / pr create / pr view /
# pr merge), so this is Contexture's requirement, not any harness's. Installed from a pinned
# .deb release asset rather than the cli.github.com apt repo, since that repo's setup needs
# gpg, which these base images don't ship.
echo "install-contexture-toolchain: installing gh ${GH_VERSION}"
apt-get update
apt-get install -y --no-install-recommends ca-certificates
ARCH="$(dpkg --print-architecture)"
curl -fsSL -o /tmp/gh.deb \
  "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${ARCH}.deb"
apt-get install -y /tmp/gh.deb
rm -f /tmp/gh.deb
apt-get clean
rm -rf /var/lib/apt/lists/*

# --- ctxr-cli -----------------------------------------------------------------------------
# The Contexture CLI the store is provisioned and reconciled with (`ctxr init`, `ctxr doctor`,
# session start/submit).
#
# CTXR_VERSION must track the store's contexture.yaml `schema_version`, and since 0.10.0 the
# gate is BOTH-directional (src/config/load.ts): a CLI older than the store is refused, and so
# is a CLI newer than it. There is no `ctxr migrate` to bridge the gap any more -- it was
# removed in 0.10.0 -- so a mismatch means every ctxr call fails outright, not degrades.
#
# That coupling is why the image tag IS this version. Do not let the two drift.
echo "install-contexture-toolchain: installing ctxr-cli ${CTXR_VERSION}"
npm install -g "ctxr-cli@${CTXR_VERSION}"
npm cache clean --force

# --- Smoke tests --------------------------------------------------------------------------
# `ctxr --version` exists as of 0.10.0 (src/run.ts, isGlobalVersionRequest) and prints the bare
# version on stdout. Asserting it EQUALS the requested version is what makes the image tag
# trustworthy -- the older `ctxr --help >/dev/null` check these images used to carry proved the
# binary ran, but said nothing about which version ran.
gh --version

installed_ctxr="$(ctxr --version)"
[ "${installed_ctxr}" = "${CTXR_VERSION}" ] \
  || fail "ctxr reports '${installed_ctxr}' but CTXR_VERSION is '${CTXR_VERSION}'"

echo "install-contexture-toolchain: ok (gh ${GH_VERSION}, ctxr ${installed_ctxr})"
