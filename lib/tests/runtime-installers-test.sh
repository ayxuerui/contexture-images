#!/bin/sh
# Install every real recipe but Hermes' (runtime-hermes-test.py has those) into an empty home,
# against the publishers, and check each answers from ~/.local/bin. This is the test that catches
# a moved installer or a renamed package -- the failures the old image caught at build time.
#
# Needs the network. Then an --update must leave everything installed and runnable, and the
# self-updating harnesses must not have been touched by it.
#
#   sh lib/tests/runtime-installers-test.sh contexture-runtime:ci
set -eu

IMAGE="${1:-contexture-runtime:ci}"
NAME="runtime-installers-test-$$"
HARNESSES=claude,codex,agy
TOOLS=ctxr,cb,agent-browser
BINARIES="claude codex agy ctxr cb agent-browser"

cleanup() { docker volume rm -f "${NAME}-home" >/dev/null 2>&1 || true; }
trap cleanup EXIT

in_runtime() {
  docker run --rm -v "${NAME}-home:/home/agent" \
    -e HARNESSES="${HARNESSES}" -e TOOLS="${TOOLS}" -e HARNESS_SERVICES= "$@"
}

# No supervisor in a one-off container, so read the status file rather than `runtime-install
# status`, which also wants every program running.
check_status='import json, sys; h = json.load(open("/home/agent/.local/state/contexture/runtime-status.json"))["installed"]; bad = {n: e for n, e in h.items() if e["state"] != "ok"}; print("FAIL:", bad) if bad else None; sys.exit(1 if bad else 0)'

in_runtime "${IMAGE}" runtime-install
in_runtime -e BINARIES="${BINARIES}" -e CHECK="${check_status}" "${IMAGE}" sh -eu -c '
  for binary in ${BINARIES}; do
    path="$(command -v "${binary}")"
    case "${path}" in /home/agent/.local/bin/*) ;; *) echo "FAIL: ${binary} resolves to ${path:-nothing}"; exit 1 ;; esac
    printf "%s: %s\n" "${binary}" "$("${binary}" --version 2>&1 | head -1)"
  done
  # npm packages went to the user prefix, not the image.
  test -d /home/agent/.local/lib/node_modules/ctxr-cli || { echo "FAIL: ctxr not in ~/.local/lib/node_modules"; exit 1; }
  test -d /home/agent/.local/lib/node_modules/@circleback/cli || { echo "FAIL: cb not in ~/.local/lib/node_modules"; exit 1; }
  # The image ctxr is still there for serve, behind the home one.
  /usr/local/lib/contexture/bin/ctxr --version >/dev/null
  python3 -c "${CHECK}"
'
echo "PASS: every recipe installs from its publisher and answers --version from ~/.local/bin"

snapshot='for n in claude codex agy; do readlink -f "$(command -v $n)"; done'
before="$(in_runtime "${IMAGE}" sh -c "${snapshot}")"
in_runtime "${IMAGE}" runtime-install --update
after="$(in_runtime "${IMAGE}" sh -c "${snapshot}")"
in_runtime -e CHECK="${check_status}" "${IMAGE}" sh -c 'python3 -c "${CHECK}"'
[ "${before}" = "${after}" ] || { echo "FAIL: --update moved a self-updating harness:"; echo "${before}"; echo "${after}"; exit 1; }
echo "PASS: --update leaves everything runnable and the self-updating harnesses alone"
