#!/bin/sh
# Command-line tools that agent SKILLS shell out to by bare name.
#
# Same category as the chromium-on-PATH line and the document-skill Python deps in the hermes
# Dockerfile, and here for the same reason: a skill names the tool in its own SKILL.md, the tool
# is not on the image, and the skill therefore cannot run at all. It is not a per-store problem
# and must not be solved per-store -- every Contexture store on this image carries the same
# bundled skills.
#
# The failure this fixes is worse than "missing", because the skills carry a fallback that looks
# like it handles the case. markdown-to-pdf-document says:
#
#     command -v pandoc || sudo apt-get install -y pandoc
#
# The agent in this image runs as a non-root UID with no sudo, so that line fails, and it fails
# at the moment someone is trying to render an outbound document -- a lawyer brief, an RFP, a
# board memo -- rather than at build time. Installing it here turns a live-session failure into
# a build-time one.
#
# pandoc: converts markdown to an HTML fragment for the PDF pipeline
#         (`pandoc -f gfm -t html body.md -o body.html`), which is then injected into a styled
#         template and printed by chromium. Only the BINARY is installed, not the tarball's
#         share/ tree: the official release binary embeds its own data files, and gfm->html with
#         an external template -- the only thing the skill asks of it -- is verified below
#         without share/ present.
#
# jq:     named by github-minimal-pat-operations and youtube-transcript-cloud-fallback for
#         shaping API JSON in a pipeline. `gh --jq` covers gh's own calls but nothing else, and
#         a skill written as `curl ... | jq ...` has no such fallback.
#
# Pinned release assets rather than distro packages, for the reasons install-backup-tools.sh
# sets out at length; they apply unchanged here. Debian 13 ships pandoc 3.1.11.1, four minor
# versions back.
#
# CHECKSUM ASYMMETRY, and it is deliberate rather than an oversight:
#
#   jq      publishes sha256sum.txt beside its assets, so it is verified the same way restic and
#           rclone are -- fetched from the release, matched, fails closed if the asset is absent
#           from the sums file.
#   pandoc  publishes NO checksum asset of any kind (checked against the 3.11 release: eleven
#           assets, not one sums or signature file). So its hashes are pinned EXPLICITLY, passed
#           in beside the version.
#
# The pandoc shape is the stronger of the two, which is worth stating because it looks like the
# weaker one. A sums file fetched from the same release as the binary proves only that the asset
# was not corrupted or swapped in transit -- if the release itself were replaced, the sums would
# be replaced with it. A hash pinned in this repository is independent of the release: changing
# what the build installs requires a commit here, reviewed, with the old value in the diff.
#
# Regenerating the pandoc hashes when bumping PANDOC_VERSION -- both are required, and the arch
# NOT being built is the one that will bite, since CI builds only linux/amd64 while release
# builds both:
#
#   v=3.11
#   for a in amd64 arm64; do
#     curl -fsSL "https://github.com/jgm/pandoc/releases/download/$v/pandoc-$v-linux-$a.tar.gz" \
#       | sha256sum | sed "s/-$/pandoc-$v-linux-$a.tar.gz/"
#   done
#
# Inputs, all required, fed from Dockerfile ARGs:
#   PANDOC_VERSION        pandoc release tag (pandoc does not prefix with v)
#   PANDOC_SHA256_AMD64   sha256 of pandoc-<ver>-linux-amd64.tar.gz
#   PANDOC_SHA256_ARM64   sha256 of pandoc-<ver>-linux-arm64.tar.gz
#   JQ_VERSION            jq release version, without the `jq-` tag prefix
set -eu

fail() { echo "install-skill-tools: $*" >&2; exit 1; }

: "${PANDOC_VERSION:?PANDOC_VERSION is required}"
: "${PANDOC_SHA256_AMD64:?PANDOC_SHA256_AMD64 is required}"
: "${PANDOC_SHA256_ARM64:?PANDOC_SHA256_ARM64 is required}"
: "${JQ_VERSION:?JQ_VERSION is required}"

command -v curl      >/dev/null 2>&1 || fail "needs curl on the base image"
command -v sha256sum >/dev/null 2>&1 || fail "needs sha256sum to verify the release assets"
command -v tar       >/dev/null 2>&1 || fail "needs tar to unpack the pandoc release"

# Asset names use GOARCH-style labels, which is not what `uname -m` reports. Resolved once, and
# an unrecognised architecture fails loudly rather than silently fetching an amd64 binary onto
# something else.
case "$(uname -m)" in
  x86_64|amd64)  goarch=amd64; pandoc_want="$PANDOC_SHA256_AMD64" ;;
  aarch64|arm64) goarch=arm64; pandoc_want="$PANDOC_SHA256_ARM64" ;;
  *) fail "unsupported architecture $(uname -m)" ;;
esac

assert_sha256() {   # $1 = file on disk, $2 = expected hash, $3 = label for the message
  _got="$(sha256sum "$1" | awk '{print $1}')"
  [ "$2" = "${_got}" ] || fail "checksum mismatch for $3: expected $2, got ${_got}"
  echo "install-skill-tools: verified $3"
}

# --- pandoc -----------------------------------------------------------------------------------
echo "install-skill-tools: installing pandoc ${PANDOC_VERSION} (${goarch})"
pandoc_asset="pandoc-${PANDOC_VERSION}-linux-${goarch}.tar.gz"
curl -fsSL -o /tmp/pandoc.tar.gz \
  "https://github.com/jgm/pandoc/releases/download/${PANDOC_VERSION}/${pandoc_asset}"
assert_sha256 /tmp/pandoc.tar.gz "${pandoc_want}" "${pandoc_asset}"

# The member is named explicitly rather than globbed, so a changed archive layout fails HERE
# instead of extracting nothing and passing. --strip-components drops `pandoc-<ver>/bin/`.
tar -xzf /tmp/pandoc.tar.gz -C /usr/local/bin --strip-components=2 \
  "pandoc-${PANDOC_VERSION}/bin/pandoc"
chmod +x /usr/local/bin/pandoc
rm -f /tmp/pandoc.tar.gz

# --- jq ---------------------------------------------------------------------------------------
echo "install-skill-tools: installing jq ${JQ_VERSION} (${goarch})"
jq_asset="jq-linux-${goarch}"
jq_base="https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}"
curl -fsSL -o /tmp/jq "${jq_base}/${jq_asset}"
# Unlike pandoc, jq ships sums; fail closed when the asset is not listed, because "not mentioned"
# and "does not match" are the same amount of evidence.
jq_want="$(curl -fsSL "${jq_base}/sha256sum.txt" \
  | awk -v n="${jq_asset}" '$2 == n || $2 == "*" n { print $1; exit }')"
[ -n "${jq_want}" ] || fail "${jq_asset} is not listed in ${jq_base}/sha256sum.txt"
assert_sha256 /tmp/jq "${jq_want}" "${jq_asset}"
mv /tmp/jq /usr/local/bin/jq
chmod +x /usr/local/bin/jq

# --- smoke tests ------------------------------------------------------------------------------
# Asserting the REPORTED version equals the pin, not merely that the binary runs: a redirect or a
# cache that served the wrong asset would otherwise pass unnoticed.
installed_pandoc="$(pandoc --version | awk 'NR==1 {print $2}')"
[ "${installed_pandoc}" = "${PANDOC_VERSION}" ] \
  || fail "pandoc reports '${installed_pandoc}' but PANDOC_VERSION is '${PANDOC_VERSION}'"

installed_jq="$(jq --version | sed 's/^jq-//')"
[ "${installed_jq}" = "${JQ_VERSION}" ] \
  || fail "jq reports '${installed_jq}' but JQ_VERSION is '${JQ_VERSION}'"

# Exercise the conversion the PDF skill actually performs, rather than just --version. A gfm
# table is the specific case: it needs the gfm reader to be compiled in, and it is what breaks a
# document render if the binary were installed without its data files.
printf '# H\n\n| a | b |\n|---|---|\n| 1 | 2 |\n' > /tmp/skill-tools-check.md
pandoc -f gfm -t html /tmp/skill-tools-check.md -o /tmp/skill-tools-check.html
grep -q '<table>' /tmp/skill-tools-check.html \
  || fail "pandoc gfm->html produced no table; the gfm reader or its data files are missing"
rm -f /tmp/skill-tools-check.md /tmp/skill-tools-check.html

echo '{"a":1}' | jq -e '.a == 1' >/dev/null \
  || fail "jq cannot evaluate a basic filter"

echo "install-skill-tools: pandoc ${installed_pandoc}, jq ${installed_jq}"
