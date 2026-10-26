#!/bin/sh
# Node.js for the runtime image, from nodejs.org's release tarball.
#
# Not Debian's package: trixie ships Node 20, and the tools on this image need more -- ctxr-cli
# declares `node >=22.13`, agent-browser `node >=24`. The Hermes base brought its own Node; the
# runtime image has no base to borrow one from, so it pins one here.
#
# The hashes are pinned in this repository rather than read from the release's SHASUMS256.txt,
# for the reason install-skill-tools.sh gives for pandoc: a sums file fetched from the same
# place as the tarball proves only that the download was not corrupted in transit. A hash in
# this repository means changing what the build installs takes a reviewed commit.
#
# Regenerating both hashes when bumping NODE_VERSION -- both are required, because CI builds only
# linux/amd64 while a release builds both:
#
#   curl -fsSL "https://nodejs.org/dist/v$NODE_VERSION/SHASUMS256.txt" | grep -E 'linux-(x64|arm64)\.tar\.xz$'
#
# Inputs, all required, fed from Dockerfile ARGs:
#   NODE_VERSION        e.g. 24.22.1
#   NODE_SHA256_AMD64   sha256 of node-v$NODE_VERSION-linux-x64.tar.xz
#   NODE_SHA256_ARM64   sha256 of node-v$NODE_VERSION-linux-arm64.tar.xz
set -eu

fail() { echo "install-node: $*" >&2; exit 1; }

: "${NODE_VERSION:?NODE_VERSION is required}"
: "${NODE_SHA256_AMD64:?NODE_SHA256_AMD64 is required}"
: "${NODE_SHA256_ARM64:?NODE_SHA256_ARM64 is required}"

case "$(dpkg --print-architecture)" in
  amd64) arch=x64;   sha="$NODE_SHA256_AMD64" ;;
  arm64) arch=arm64; sha="$NODE_SHA256_ARM64" ;;
  *) fail "no Node build pinned for $(dpkg --print-architecture)" ;;
esac

tarball="node-v${NODE_VERSION}-linux-${arch}.tar.xz"
echo "install-node: installing Node ${NODE_VERSION} (${arch})"
curl -fsSL --retry 3 -o "/tmp/${tarball}" "https://nodejs.org/dist/v${NODE_VERSION}/${tarball}"
printf '%s  %s\n' "$sha" "/tmp/${tarball}" | sha256sum -c - >/dev/null \
  || fail "${tarball} does not match its pinned sha256"

# Into /usr/local, root-owned: the agent runs unprivileged and cannot replace the platform's
# Node. npm packages the agent installs go to NPM_CONFIG_PREFIX (~/.local) with THIS node, so they
# never write here either.
tar -xJf "/tmp/${tarball}" -C /usr/local --strip-components=1 \
  --exclude='*/CHANGELOG.md' --exclude='*/README.md' --exclude='*/LICENSE' --exclude='*/include' \
  --exclude='*/share/doc' --exclude='*/share/man'
rm -f "/tmp/${tarball}"

installed="$(node --version)"
[ "${installed}" = "v${NODE_VERSION}" ] || fail "node reports '${installed}' but NODE_VERSION is '${NODE_VERSION}'"
npm --version >/dev/null
echo "install-node: ok (node ${installed}, npm $(npm --version))"
