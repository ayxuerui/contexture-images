#!/bin/sh
# The runtime image's home-config-push (formerly harness-config-push): lib/config-push.sh, pointed
# at the home.
#
# The repository is the agent's home -- every harness's state is
# under it -- and the allowlist is rendered from the recipes in HARNESSES and TOOLS
# (`runtime-install allowlist`), so a recipe's state is tracked when, and only when, it
# says what of it to keep. Everything config-push.sh guards -- a public remote, a staged
# credential, an oversized blob -- it still guards.
set -eu
# The allowlist comes from the installed recipes. On a first boot the agents container is still
# installing when this runs; pushing then would untrack every harness's config.
runtime-install wait
allowlist="$(mktemp)"
trap 'rm -f "${allowlist}"' EXIT
runtime-install allowlist "${allowlist}"

# The skill bundle of the one recipe that names one (Hermes', home-relative), so shipped skills
# are told from authored ones. Absent, config-push.sh keeps all of skills/ and says so.
bundled="$(runtime-install describe | python3 -c '
import json, os, sys
for entry in json.load(sys.stdin):
    path = entry.get("config", {}).get("bundled_skills")
    if path:
        print(os.environ["HOME"] + "/" + path + "\t" + entry["config"]["root"] + "/skills")
        break
')"

# HOME_CONFIG_INCLUDE is already in the allowlist (runtime-install renders it knowing which
# directories are recipe roots); config-push.sh's own renderer would re-close those roots after it.
# The rest of config-push.sh's settings keep their HARNESS_CONFIG_* names; HOME_CONFIG_* is mapped.
for name in REPO BRANCH EXCLUDE MAX_BLOB_MB MESSAGE ALLOW_UNVERIFIED_REMOTE DRY_RUN; do
  eval "value=\${HOME_CONFIG_${name}:-}"
  [ -z "${value}" ] || export "HARNESS_CONFIG_${name}=${value}"
done
HARNESS_CONFIG_INCLUDE= \
HERMES_DATA_DIR="${HOME}" \
HARNESS_CONFIG_HOME="${HOME}" \
HARNESS_CONFIG_GITIGNORE_SRC="${allowlist}" \
HARNESS_CONFIG_BUNDLED_SKILLS_DIR="$(printf '%s' "${bundled}" | cut -f1)" \
HARNESS_CONFIG_BUNDLED_SKILLS_PREFIX="$(printf '%s' "${bundled}" | cut -f2)" \
  exec /usr/local/lib/contexture/config-push.sh "$@"
