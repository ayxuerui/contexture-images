#!/bin/sh
# Install every real recipe into an empty harnesses volume, against the publishers, and check
# each CLI answers from PATH. This is the test that catches a moved installer or a renamed
# package -- the failures the old image caught at build time, now caught here instead.
#
# Needs the network. Then a no-op --update must change nothing, and a pin back to the version
# already installed must be a flip with no download.
#
#   sh lib/tests/runtime-install-test.sh contexture-runtime:ci
set -eu

IMAGE="${1:-contexture-runtime:ci}"
NAME="runtime-install-test-$$"
HARNESSES=ctxr,claude,codex,agy,agent-browser,cb

cleanup() { docker volume rm -f "${NAME}-harnesses" "${NAME}-home" >/dev/null 2>&1 || true; }
trap cleanup EXIT

in_runtime() {
  docker run --rm -v "${NAME}-harnesses:/opt/harnesses" -v "${NAME}-home:/home/agent" \
    -e HARNESSES="${HARNESSES}" -e HARNESS_SERVICES= "$@"
}

in_runtime "${IMAGE}" harness-install
in_runtime "${IMAGE}" sh -eu -c '
  for binary in ctxr claude codex agy agent-browser cb; do
    path="$(command -v "${binary}")"
    case "${path}" in /opt/harnesses/bin/*) ;; *) echo "FAIL: ${binary} resolves to ${path:-nothing}"; exit 1 ;; esac
    printf "%s: %s\n" "${binary}" "$("${binary}" --version 2>&1 | head -1)"
  done
  # No supervisor in a one-off container, so read the harnesses from the status file rather
  # than `harness-install status`, which also wants every program running.
  python3 -c "import json, sys; h = json.load(open(\"/home/agent/.local/state/contexture/harness-status.json\"))[\"harnesses\"]; bad = [n for n, e in h.items() if e[\"state\"] != \"ok\"]; print(\"FAIL:\", bad) if bad else None; sys.exit(1 if bad else 0)"
'
echo "PASS: every recipe installs from its publisher and answers --version from PATH"

# Without the harnesses volume -- serve, the one-shots -- ctxr is the image's, at the image's version.
image_ctxr="$(docker run --rm --entrypoint sh "${IMAGE}" -c 'command -v ctxr; ctxr --version')"
case "${image_ctxr}" in /usr/local/lib/contexture/bin/ctxr*) ;; *) echo "FAIL: fallback ctxr is ${image_ctxr}"; exit 1 ;; esac
echo "PASS: without the harnesses volume ctxr falls back to the image's: $(echo "${image_ctxr}" | tail -1)"

before="$(in_runtime "${IMAGE}" sh -c 'for n in ctxr claude codex agy agent-browser cb; do readlink /opt/harnesses/$n/current; done')"
in_runtime "${IMAGE}" harness-install --update
after="$(in_runtime "${IMAGE}" sh -c 'for n in ctxr claude codex agy agent-browser cb; do readlink /opt/harnesses/$n/current; done')"
echo "versions: $(echo "${after}" | tr '\n' ' ')"
[ "${before}" = "${after}" ] || echo "NOTE: a publisher released during the test; --update moved to it"

codex="$(in_runtime "${IMAGE}" readlink /opt/harnesses/codex/current)"
out="$(in_runtime -e HARNESS_PINS="codex=${codex}" "${IMAGE}" harness-install)"
case "${out}" in *"codex: installing"*) echo "FAIL: pinning the installed version reinstalled it"; exit 1 ;; esac
echo "PASS: --update is safe to repeat, and a pin to an installed version downloads nothing"
