#!/bin/sh
# gh, the GitHub CLI, into the image. Contexture's GitHub forge adapter shells out to `gh` (repo
# view / pr create / pr view / pr merge), and every harness and tool runs as the agent beside it,
# so it is the platform's, not any harness's. ctxr is not installed here: it is a tool, installed
# into a home (lib/recipes/ctxr).
#
# Installed from a pinned .deb release asset rather than the cli.github.com apt repo, since that
# repo's setup needs gpg, which the base image does not ship. Its smoke test runs in the same RUN,
# so a broken or moved release fails the build.
#
# Input, required, fed from a Dockerfile ARG:
#   GH_VERSION    gh CLI release to install, e.g. 2.98.0
set -eu

fail() { echo "install-gh: $*" >&2; exit 1; }

: "${GH_VERSION:?GH_VERSION is required}"
command -v apt-get >/dev/null 2>&1 || fail "needs a Debian/Ubuntu base (no apt-get); the gh install below is .deb-based"

echo "install-gh: installing gh ${GH_VERSION}"
apt-get update
apt-get install -y --no-install-recommends ca-certificates
ARCH="$(dpkg --print-architecture)"
curl -fsSL -o /tmp/gh.deb \
  "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${ARCH}.deb"
apt-get install -y /tmp/gh.deb
rm -f /tmp/gh.deb
apt-get clean
rm -rf /var/lib/apt/lists/*

gh --version
echo "install-gh: ok (gh ${GH_VERSION})"
