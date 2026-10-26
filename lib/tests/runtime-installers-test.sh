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

cleanup() {
  docker rm -f "${NAME}-serve" >/dev/null 2>&1 || true
  docker volume rm -f "${NAME}-home" "${NAME}-serve-home" "${NAME}-provision-home" "${NAME}-store" >/dev/null 2>&1 || true
}
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
  # The image carries no ctxr: the one on PATH is in the home.
  [ ! -e /usr/local/bin/ctxr ] || { echo "FAIL: the image ships a ctxr"; exit 1; }
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

# workspace-init on an empty home: runtime-provision installs ctxr as the agent, then hands over to
# ctxr-provision. With no REPO_URL, ctxr-provision stops at once, naming what is missing -- far
# enough to show ctxr reached the home first.
out="$(docker run --rm -v "${NAME}-provision-home:/home/agent" --entrypoint runtime-provision "${IMAGE}" 2>&1 || true)"
docker run --rm -v "${NAME}-provision-home:/home/agent" --entrypoint sh "${IMAGE}" -c \
  'test "$(stat -c %u /home/agent/.local/bin/ctxr)" = 10000 && /home/agent/.local/bin/ctxr --version' \
  || { echo "FAIL: runtime-provision did not install ctxr into the home as the agent"; echo "${out}"; exit 1; }
echo "PASS: workspace-init installs ctxr into the home before provisioning"

# serve on its own home: the runtime entrypoint installs ctxr into it and supervises `ctxr serve`.
docker run --rm -v "${NAME}-store:/store" --entrypoint sh "${IMAGE}" -c \
  'chown 10000:10000 /store && setpriv --reuid=10000 --regid=10000 --clear-groups env HOME=/tmp sh -c \
     "git config --global user.email t@example.com && git config --global user.name t && \
      npx -y ctxr-cli init --profile para --root /store >/dev/null"'
docker run -d --name "${NAME}-serve" -v "${NAME}-serve-home:/home/agent" -v "${NAME}-store:/store" \
  -e HARNESSES= -e TOOLS=ctxr -e HARNESS_SERVICES=ctxr-serve -e CONTEXTURE_STORE_ROOT=/store \
  -e CTXR_UPDATE_STORE_ENABLED=0 "${IMAGE}" >/dev/null
for _ in $(seq 1 60); do
  docker exec "${NAME}-serve" runtime-install status >/dev/null 2>&1 && break
  sleep 5
done
docker exec "${NAME}-serve" runtime-install status \
  || { echo "FAIL: serve did not come up"; docker logs "${NAME}-serve" 2>&1 | tail -40; exit 1; }
echo "PASS: serve installs ctxr into its own home and serves"
