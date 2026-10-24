#!/bin/sh
# The runtime image's harness-config-push: the shared lib/config-push.sh, pointed at the home.
#
# In the Hermes image the config repository is HERMES_HOME and its allowlist is the fixed
# hermes-config.gitignore. Here the repository is the agent's home -- every harness's state is
# under it -- and the allowlist is rendered from the recipes of the harnesses in HARNESSES
# (`harness-install allowlist`), so a harness's state is tracked when, and only when, its recipe
# says what of it to keep. Everything config-push.sh guards -- a public remote, a staged
# credential, an oversized blob -- it still guards.
set -eu
# The allowlist comes from the installed harnesses' recipes. On a first boot the agents container
# is still installing when this runs; pushing then would untrack every harness's config.
harness-install wait
allowlist="$(mktemp)"
trap 'rm -f "${allowlist}"' EXIT
harness-install allowlist "${allowlist}"

# The skill bundle of the one recipe that names one (Hermes'), so shipped skills are told from
# authored ones. Absent, config-push.sh keeps all of skills/ and says so.
bundled="$(harness-install describe | python3 -c '
import json, sys
for entry in json.load(sys.stdin):
    path = entry.get("config", {}).get("bundled_skills")
    if path:
        print(entry["prefix"] + "/" + path + "\t" + entry["config"]["root"] + "/skills")
        break
')"

HERMES_DATA_DIR="${HOME}" \
HARNESS_CONFIG_HOME="${HOME}" \
HARNESS_CONFIG_GITIGNORE_SRC="${allowlist}" \
HARNESS_CONFIG_BUNDLED_SKILLS_DIR="$(printf '%s' "${bundled}" | cut -f1)" \
HARNESS_CONFIG_BUNDLED_SKILLS_PREFIX="$(printf '%s' "${bundled}" | cut -f2)" \
  exec /usr/local/lib/contexture/config-push.sh "$@"
