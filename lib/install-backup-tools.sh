#!/bin/sh
# Backup tooling a harness image makes available for snapshotting its own home.
#
# Separate from the other two installers on purpose, and harness-agnostic on purpose: any
# long-lived harness has state worth snapshotting, and restic is the part of that story with no
# harness-specific knowledge in it. What IS harness-specific -- what to put in the snapshot --
# lives in harnesses/<name>/, not here.
#
# rclone is here because it is restic's reach extender, not a second tool: restic speaks S3, B2,
# Azure, GCS, SFTP and REST natively, and everything ELSE -- Google Drive, Dropbox, OneDrive --
# through `rclone:remote:path`. A deployment that picks Drive needs both; one that picks an
# S3-compatible target needs only restic, and pays ~20 MB for the option.
#
# Pinned release assets rather than distro packages, deliberately. Debian 13 carries restic
# 0.18.0 (close) but rclone 1.60.1 (late 2022, fifteen releases behind) -- and rclone is exactly
# the component talking to Google Drive, whose API and OAuth handling have moved since. Pinning
# also preserves the property the whole image is built on: the smoke tests below assert the
# INSTALLED version equals the pin, so a moved or substituted asset fails the build rather than
# a backup job at 03:00. `apt-get install restic=<ver>` cannot offer that for long, because
# Debian drops superseded binaries from the mirror and the rebuild then fails.
#
# Extraction is done with python's stdlib rather than bzip2/unzip/dpkg. Neither bzip2 nor unzip
# is on these bases (checked), so the alternative was apt-get install + purge around a single
# decompression. Using python also leaves this script with no Debian dependency at all, which is
# more than install-contexture-toolchain.sh can say.
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
# `--version=1.75.1` and dies with "strconv.ParseBool". Observed -- it failed the build, which
# is where a collision like this should fail.
#
# Same shape as ctxr-provision's GH_TOKEN dance, and for the same underlying reason: a tool that
# reads a variable ambiently will read OURS if we happen to pick its name. The Dockerfile ARG
# keeps the obvious name; only this script's use of it is scoped.
restic_version="$RESTIC_VERSION"
rclone_version="$RCLONE_VERSION"
unset RESTIC_VERSION RCLONE_VERSION

command -v curl >/dev/null 2>&1 || fail "needs curl on the base image"
PY="$(command -v python3 || command -v python)" \
  || fail "needs python3 to unpack the release assets (bzip2/unzip are absent from these bases)"

# Both projects name assets by GOARCH, which is not what `uname -m` reports. Resolved once here
# rather than per-download so a new architecture is one case arm, and so an unrecognised one
# fails loudly instead of silently fetching an amd64 binary onto arm64.
case "$(uname -m)" in
  x86_64|amd64)  goarch=amd64 ;;
  aarch64|arm64) goarch=arm64 ;;
  *) fail "unsupported architecture $(uname -m)" ;;
esac

echo "install-backup-tools: installing restic ${restic_version} (${goarch})"
curl -fsSL -o /tmp/restic.bz2 \
  "https://github.com/restic/restic/releases/download/v${restic_version}/restic_${restic_version}_linux_${goarch}.bz2"
"$PY" -c 'import bz2,shutil,sys
with bz2.open(sys.argv[1],"rb") as s, open(sys.argv[2],"wb") as d: shutil.copyfileobj(s,d)' \
  /tmp/restic.bz2 /usr/local/bin/restic
chmod +x /usr/local/bin/restic
rm -f /tmp/restic.bz2

echo "install-backup-tools: installing rclone ${rclone_version} (${goarch})"
curl -fsSL -o /tmp/rclone.zip \
  "https://github.com/rclone/rclone/releases/download/v${rclone_version}/rclone-v${rclone_version}-linux-${goarch}.zip"
# The binary sits under a versioned directory inside the archive; named explicitly rather than
# globbed so a changed layout fails here instead of installing nothing and passing.
"$PY" -c 'import shutil,sys,zipfile
member = f"rclone-v{sys.argv[2]}-linux-{sys.argv[3]}/rclone"
with zipfile.ZipFile(sys.argv[1]) as z, open(sys.argv[4],"wb") as d:
    shutil.copyfileobj(z.open(member), d)' \
  /tmp/rclone.zip "$rclone_version" "$goarch" /usr/local/bin/rclone
chmod +x /usr/local/bin/rclone
rm -f /tmp/rclone.zip

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
