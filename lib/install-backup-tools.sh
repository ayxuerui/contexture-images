#!/bin/sh
# Backup tooling a harness image makes available for snapshotting its own home.
#
# Separate from the other two installers on purpose, and harness-agnostic on purpose: any
# long-lived harness has state worth snapshotting, and restic is the part of that story with no
# harness-specific knowledge in it. What IS harness-specific -- what to put in the snapshot --
# lives in harnesses/<name>/, not here.
#
# Both are single static binaries published as release assets, so there is no apt repo to add
# and no gpg to need (the bases lack it -- see install-contexture-toolchain.sh). Pinned and
# smoke-tested in the same layer, so a moved or broken release fails the BUILD rather than a
# backup job at 03:00.
#
# rclone is here because it is restic's reach extender, not a second tool: restic speaks S3,
# B2, Azure, GCS, SFTP and REST natively, and everything ELSE -- Google Drive, Dropbox, OneDrive
# -- through `rclone:remote:path`. A deployment that picks Drive needs both; one that picks an
# S3-compatible target needs only restic, and pays ~20 MB for the option.
#
# Inputs, all required, fed from Dockerfile ARGs:
#   RESTIC_VERSION   restic release tag, without the leading v
#   RCLONE_VERSION   rclone release tag, without the leading v
set -eu

fail() { echo "install-backup-tools: $*" >&2; exit 1; }

: "${RESTIC_VERSION:?RESTIC_VERSION is required}"
: "${RCLONE_VERSION:?RCLONE_VERSION is required}"

# Captured and then UNSET, because rclone maps its entire RCLONE_* environment namespace onto
# its own CLI flags: with RCLONE_VERSION still exported, `rclone version` is parsed as
# `--version=1.75.1` and dies with "strconv.ParseBool: parsing \"1.75.1\"". Observed -- it
# failed the build, which is where a collision like this should fail.
#
# Same shape as ctxr-provision's GH_TOKEN dance, and for the same underlying reason: a tool that
# reads a variable ambiently will read OURS if we happen to pick its name. The Dockerfile ARG
# keeps the obvious name; only this script's use of it is scoped.
restic_version="$RESTIC_VERSION"
rclone_version="$RCLONE_VERSION"
unset RESTIC_VERSION RCLONE_VERSION

command -v apt-get >/dev/null 2>&1 || fail "needs a Debian/Ubuntu base (no apt-get); rclone installs from .deb"
command -v curl    >/dev/null 2>&1 || fail "needs curl on the base image"
command -v dpkg    >/dev/null 2>&1 || fail "needs dpkg to resolve the Debian architecture name"

# Both projects name assets by GOARCH, which is not what `uname -m` reports. Resolved once here
# rather than per-download so a new architecture is one case arm, and so an unrecognised one
# fails loudly instead of silently fetching an amd64 binary onto arm64. (GOARCH and dpkg's
# architecture names agree on amd64/arm64, which is why one variable serves both installs.)
case "$(uname -m)" in
  x86_64|amd64)  goarch=amd64 ;;
  aarch64|arm64) goarch=arm64 ;;
  *) fail "unsupported architecture $(uname -m)" ;;
esac

# The two projects ship different formats, so they install differently. restic publishes ONLY
# a bare .bz2 binary; rclone publishes a .deb. Neither `bzip2` nor `unzip` is on these bases
# (checked -- both are absent from nousresearch/hermes-agent), so bzip2 is pulled in for the
# one decompression and removed again, while rclone takes the .deb path `gh` already uses.
apt-get update
apt-get install -y --no-install-recommends ca-certificates bzip2

echo "install-backup-tools: installing restic ${restic_version} (${goarch})"
curl -fsSL -o /tmp/restic.bz2 \
  "https://github.com/restic/restic/releases/download/v${restic_version}/restic_${restic_version}_linux_${goarch}.bz2"
bunzip2 -c /tmp/restic.bz2 > /usr/local/bin/restic
chmod +x /usr/local/bin/restic
rm -f /tmp/restic.bz2

echo "install-backup-tools: installing rclone ${rclone_version} (${goarch})"
curl -fsSL -o /tmp/rclone.deb \
  "https://github.com/rclone/rclone/releases/download/v${rclone_version}/rclone-v${rclone_version}-linux-${goarch}.deb"
apt-get install -y /tmp/rclone.deb
rm -f /tmp/rclone.deb

# bzip2 was needed for exactly one command and is not a runtime dependency of either tool.
apt-get purge -y bzip2
apt-get autoremove -y
apt-get clean
rm -rf /var/lib/apt/lists/*

# Smoke tests. Asserting the REPORTED version equals the pin, not merely that the binary runs:
# a redirect or a stale cache that served the wrong asset would otherwise pass unnoticed and
# only surface when a restore needed a format the pinned version could read.
installed_restic="$(restic version | awk '{print $2}')"
[ "${installed_restic}" = "${restic_version}" ] \
  || fail "restic reports '${installed_restic}' but RESTIC_VERSION is '${restic_version}'"

installed_rclone="$(rclone version | awk 'NR==1 {sub(/^v/,"",$2); print $2}')"
[ "${installed_rclone}" = "${rclone_version}" ] \
  || fail "rclone reports '${installed_rclone}' but RCLONE_VERSION is '${rclone_version}'"

echo "install-backup-tools: restic ${installed_restic}, rclone ${installed_rclone}"
