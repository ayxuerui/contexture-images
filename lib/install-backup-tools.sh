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
# Both projects publish SHA256SUMS beside the assets, and both are checked below. That is a
# weaker anchor than it looks -- the sums come from the same release as the binary, so it
# catches a corrupted or substituted ASSET but not a compromised release -- and it is still
# strictly more than HTTPS alone. restic also signs SHA256SUMS with GPG; verifying that would
# need a trusted key baked into the image, which is a key-management problem this script is the
# wrong place to solve.
#
# The official installers were considered and rejected. rclone's `curl https://rclone.org/
# install.sh | sudo bash` takes exactly one optional argument, `beta` -- it reads
# downloads.rclone.org/version.txt and always installs CURRENT, so the image's rclone would
# move on every rebuild with no record of what changed. restic publishes no install script at
# all; its `self-update` is a post-install updater that also goes to latest. install-agent-clis
# already carries two unpinned curl|bash installers and apologises for them in a comment,
# because claude and agy ship no versioned artifact. rclone and restic do, so taking the
# unpinned path here would trade away the version assertion for nothing -- and for a BACKUP
# tool, knowing which version wrote the repository is the whole point.
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

command -v curl      >/dev/null 2>&1 || fail "needs curl on the base image"
command -v sha256sum >/dev/null 2>&1 || fail "needs sha256sum to verify the release assets"

# Fetch SHA256SUMS from a release and assert one file against it. Fails closed on every branch:
# a sums file that does not list the asset is as fatal as a mismatch, because "not mentioned"
# and "does not match" are the same amount of evidence.
verify_sha256() {   # $1 = sums URL, $2 = file on disk, $3 = name as it appears in the sums file
  _want="$(curl -fsSL "$1" | awk -v n="$3" '$2 == n || $2 == "*" n { print $1; exit }')"
  [ -n "${_want}" ] || fail "$3 is not listed in $1"
  _got="$(sha256sum "$2" | awk '{print $1}')"
  [ "${_want}" = "${_got}" ] \
    || fail "checksum mismatch for $3: expected ${_want}, got ${_got}"
  echo "install-backup-tools: verified $3"
}
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
restic_asset="restic_${restic_version}_linux_${goarch}.bz2"
restic_base="https://github.com/restic/restic/releases/download/v${restic_version}"
curl -fsSL -o /tmp/restic.bz2 "${restic_base}/${restic_asset}"
verify_sha256 "${restic_base}/SHA256SUMS" /tmp/restic.bz2 "${restic_asset}"
"$PY" -c 'import bz2,shutil,sys
with bz2.open(sys.argv[1],"rb") as s, open(sys.argv[2],"wb") as d: shutil.copyfileobj(s,d)' \
  /tmp/restic.bz2 /usr/local/bin/restic
chmod +x /usr/local/bin/restic
rm -f /tmp/restic.bz2

echo "install-backup-tools: installing rclone ${rclone_version} (${goarch})"
rclone_asset="rclone-v${rclone_version}-linux-${goarch}.zip"
rclone_base="https://github.com/rclone/rclone/releases/download/v${rclone_version}"
curl -fsSL -o /tmp/rclone.zip "${rclone_base}/${rclone_asset}"
verify_sha256 "${rclone_base}/SHA256SUMS" /tmp/rclone.zip "${rclone_asset}"
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
