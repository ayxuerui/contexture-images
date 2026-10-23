# Harnesses live beside the home, not in the image

Status: proposed, 2026-10-23. Nothing here is implemented yet.

## Why

A new version of some harness lands almost every day, and today each one is an image release: a
watcher PR, a 45-minute CI matrix, a manual merge, then a recreate that ends every live session on
the host. In practice the pipeline stalls rather than flows. On 2026-10-23:

| PR | Tool | Image has | Upstream | Open since |
|---|---|---|---|---|
| #62 | claude | 2.1.287 | 2.1.308 | 10-14 |
| #63 | codex | 0.162.1 | 0.164.0 | 10-15 |
| #55 | agy | 1.3.3 | 1.4.6 | 10-13 |
| #59 | agent-browser | 0.39.0 | 0.39.2 | 10-13 |
| #72 | circleback | 1.1.0 | 1.1.1 | 10-21 |
| — | Hermes (base) | v2026.9.14 (= 0.21.3) | v0.22.5 | pinned 09-18, no watcher |

None of the five bot PRs has a CI run (a `GITHUB_TOKEN` PR starts no workflows). Meanwhile ctxr
bumps merge the day they open. The immutable image was meant to buy tested upgrades; for harnesses
it is buying no upgrades. Adding a harness costs the same release cycle, and with personal stores
for ~20 people the image becomes the union of everything anyone wants.

## What changes

The image stops being a Hermes image. It becomes the **contexture platform**: everything that must
match across containers, needs root, or is run by something other than the agent. Every
**harness** -- Hermes included -- is installed into one folder on its own volume, side by side,
from a manifest, and upgrades without an image release.

| Layer | Contents | Lives in | Upgrades by |
|---|---|---|---|
| Platform | Debian, s6-overlay, `hermes` user + UID remap, node, Debian's python3 and a platform venv on it (skill libs, `harness-remote`), Chromium's shared libraries, ctxr, gh, restic, rclone, pandoc, jq, every `ctxr-*`/`harness-*` script, s6 service definitions | the image | image release, as today (`watch-ctxr.yml`) |
| Harnesses | Hermes (+ WebUI), claude, codex, agy, agent-browser, cb, anything added later | `harnesses` volume at `/opt/harnesses/<name>/` | `harness-install --update`, on a schedule |
| State | `HERMES_HOME`, `HOME`, credentials, sessions, the manifest | `data` volume at `/opt/data`, as today | n/a |

The image tag stays the ctxr version, and merging a ctxr bump stays the rollout. That is the one
pin whose drift has repeatedly broken deployments, and `serve` and `store-update` run it.

### The harnesses volume

```
/opt/harnesses/
  bin/                  symlinks, first on PATH: hermes, claude, codex, agy, agent-browser, cb
  hermes/               git checkout (install.sh --dir)
  hermes-webui/         release source tree, run with Hermes' python
  claude/  codex/  agy/  agent-browser/  cb/
  .installed.json       what harness-install last put here: name, version, source, time
```

A separate volume rather than a directory under `/opt/data`, because it is a **cache**:

- `hermes backup` archives all of `HERMES_HOME`. It already skips its own `hermes-agent/`,
  `installs/`, `tools/`, `cache/`, venvs and `node_modules`, but a new `/opt/data/harnesses/` would
  ride along in every snapshot -- hundreds of MB of architecture-bound binaries, several times a
  day.
- `harness-config-push` is an allowlist, so it would ignore the directory either way.
- A volume can be dropped to force a clean reinstall without touching state:
  `docker compose down && docker volume rm <store>_harnesses && docker compose up -d`.

`harness-backup` calls `hermes backup`, so its containers mount the volume read-only, as do the
one-shot backup jobs. `serve` and `workspace-init` do not mount it.

It is owned by the runtime uid, so the agent can write it. That is accepted, not overlooked: the
agent can already persist anything it likes through `~/.claude/settings.json` hooks, `AGENTS.md` or
Hermes' `config.yaml`, all in the backed-up home. The line that matters is unchanged -- `serve`, the
only holder of the approval App key, runs ctxr from the image in its own container and mounts no
harnesses volume.

### Hermes is only partly in its folder

Upstream's source installer is the only supported install outside Docker (PyPI stopped at 0.19.0
and is listed as unsupported). Its `--dir` moves the **git checkout** only. Hermes' package manager
always keeps its pinned Python, the venv generations and its tools under `$HERMES_HOME/tools` and
`$HERMES_HOME/installs/<key>/` -- inside the `data` volume. `HERMES_RUNTIME_DIR` could move them,
but upstream documents it as a process-local development override and its launchers ignore it.

So `/opt/harnesses/hermes/` holds the code, and Hermes' runtime stays where upstream puts it. That
is fine for backups -- `hermes backup` already excludes `tools/` and `installs/` -- and it is the
only layout `hermes update` maintains. Fighting it would make every Hermes upgrade ours to debug.

Gateway supervision comes along unchanged. Hermes picks its service manager by probing for
`s6-svscan` as PID 1 and `/run/s6/basedir`, not for its own image, so in this image it registers
per-profile gateway slots under `/run/service` and restarts them on update exactly as it does
upstream. The slots need a user named `hermes`, `HERMES_HOME=/opt/data`, and `hermes` on the
container PATH -- all three hold here.

Optional Hermes features (messaging platforms, providers, search) are no longer prebuilt. The
Docker image bakes extras in because its venv is read-only; a source install prepares them on first
use (PM lazy installs) and `hermes update` carries every extra already present into the next
generation. A first use needs network, once.

Hermes also brings its own Python 3.14, node and Chromium, ignoring the image's. That is a second
toolchain, but a private one: nothing outside Hermes calls it, and `/opt/harnesses/bin` exposes
only `hermes`.

### The manifest

`/opt/data/harnesses.yaml`, seeded from the image's default on first boot and never overwritten
after:

```yaml
harnesses:
  hermes:        { channel: stable }
  hermes-webui:  { channel: stable }
  claude:        { channel: stable }
  codex:         {}
  agy:           {}
  agent-browser: {}
  cb:            {}
  # opencode:    {}            adding a harness is one line, then a restart
  # codex:       { version: 0.162.1 }   a pin holds a tool back
```

No version means "latest on its channel". A `version` holds it. Each name maps to an installer
recipe shipped in the image (`lib/harnesses/<name>.sh`: how to install, how to update, how to read
the installed version, where its binary is). A name with no recipe fails loudly at boot.

`harness-config-push` adds `harnesses.yaml` to its allowlist, so the config repo shows when a tool
was added or pinned. The volume itself is in neither backup.

### Installing and updating

`harness-install`, a platform script, is the single path that writes `/opt/harnesses`:

- **At boot**, an s6 oneshot `harness-install` runs before the Hermes gateway, dashboard, WebUI and
  `*-remote` services. It installs anything in the manifest that is missing, and reinstalls a tool
  whose recipe says the platform changed under it (node major for the npm tools). It does not
  upgrade. A failed install fails that harness's services, not the container.
- **On a schedule**, an s6 longrun `harness-update` inside the agents container runs
  `harness-install --update` daily at a quiet hour, via `harness-schedule`. It must be in-container,
  not a separate compose service like the backup schedulers: `hermes update` restarts the gateway
  through Hermes' own s6 backend, which only reaches the s6 it is running under. Per tool: update to the newest
  version the manifest allows, run its smoke test (`--version`), and on failure put the previous
  version back. One log line per tool, one status file (`/opt/data/.harness-status.json`, like
  `.backup-status.json`).
- **By hand**, `docker exec -u hermes <container> harness-install --update [name]`.

The harnesses' own auto-updaters are **turned off** (`DISABLE_AUTOUPDATER=1` for claude and the
equivalents for the others). Several writers on one folder means nobody can say what is installed or
honour a pin. One updater keeps `.installed.json` true.

Per-tool recipes:

| Name | Install | Update |
|---|---|---|
| hermes | `install.sh --dir /opt/harnesses/hermes --non-interactive --skip-computer-use`, `HERMES_HOME=/opt/data` | `hermes update --yes --backup` (see Rollback); it restarts its own gateway slots through s6, but leaves the dashboard and WebUI running on old code by design, so `harness-install` restarts those two afterwards |
| hermes-webui | release tarball for the newest stable tag into `hermes-webui/`; `compileall` with Hermes' python | same, then restart the `webui` service |
| claude | its native installer with `HOME=/opt/harnesses/claude`, `.local/bin/claude` symlinked -- what `install-agent-clis.sh` already does into `/opt/toolchain`, and the agent already runs it with its real `HOME` | rerun the installer with the target version |
| codex, agent-browser, cb | `npm install -g --prefix /opt/harnesses/<name> <pkg>@<version>` with the image's node | same |
| agy | its installer into `agy/` (it takes no version: a pin is a cache key and an expectation, as today) | same |

### Rollback

- **claude, codex, agy, agent-browser, cb:** pin `version` in the manifest and run
  `harness-install --update <name>`. Seconds, no image.
- **Hermes cannot be pinned backwards.** Once a newer release has written `state.db`, older
  releases refuse to open it. So every scheduled Hermes update runs `hermes update --backup`, which
  takes a full `hermes backup` zip first, and the way back is `hermes import` of that zip followed
  by a pin. `hermes update` itself rolls back a checkout that fails its syntax check.

This follows the repository's "trial by release" habit: reversible changes ship and are reversed,
rather than gated. Hermes is the one harness whose reversal is a restore, which is why its update
always carries a backup.

### What the platform has to take over from the Hermes base

Today these come free with `FROM nousresearch/hermes-agent`. Each becomes ours:

| Today, from the base | After |
|---|---|
| s6-overlay, `/init`, `entrypoint-dispatch.sh` | installed by the image (s6-overlay v3, checksum-pinned) |
| `hermes` user, `stage2-hook.sh` UID/GID remap and targeted chowns | our `cont-init.d/01-runtime-user` |
| First-boot seeding of `config.yaml`/`.env`, `API_SERVER_KEY` | `hermes update` and first `hermes` run seed config; `API_SERVER_KEY` generation moves to our cont-init |
| `docker_config_migrate.py`, PM generation resolve, `skills_sync.py` at boot | done by `hermes update` instead, so no longer at every boot |
| `02-reconcile-profiles` (`hermes_cli.container_boot`) | our cont-init calls the same module with Hermes' python. It is not image-specific: it reads `HERMES_HOME` and `S6_PROFILE_GATEWAY_SCANDIR` (default `/run/service`), and the gateway slots it writes run `hermes gateway run --replace` by PATH as user `hermes` |
| `dashboard` s6 service | ours, same `run` |
| SQLite 3.53.4 compiled in, ahead of Debian trixie's 3.46.1 | not needed (see SQLite below) |
| `/opt/hermes/.venv` for WebUI, `harness-remote` and the document-skill libraries | split: WebUI runs on Hermes' python; `harness-remote` and pypdf/docx/openpyxl/pptx/bs4/reportlab go in a platform venv at `/opt/contexture/venv`, on PATH, so a Hermes update cannot remove them |
| `/opt/hermes/skills` (used by `harness-config-push` to tell shipped skills from authored) | `HARNESS_CONFIG_BUNDLED_SKILLS_DIR=/opt/harnesses/hermes/skills` |
| `profile.d/10-hermes-path.sh` | rewritten: `/opt/harnesses/bin:/opt/contexture/venv/bin:...` |
| Chromium on PATH via the Playwright glob | `agent-browser`'s and Hermes' own browsers; the image keeps only the shared libraries they need |

`HERMES_WRITE_SAFE_ROOT=/opt/data:/store:/tmp` and the `HOME=/opt/data/home` /
`HERMES_HOME=/opt/data` split are unchanged.

### SQLite

Debian trixie's `libsqlite3` is 3.46.1, inside the WAL-reset corruption range (3.7.0 to 3.51.2,
https://sqlite.org/wal.html#walresetbug). Upstream's image compiles 3.53.4 for that reason, and
`state.db` is ~1 GB on pkm. Checked on 2026-10-23: Hermes' source install runs on the
python-build-standalone build its lock pins (`cpython-3.14.9+20261021`), and that interpreter has
**SQLite 3.53.1 compiled in** as a built-in module, with FTS5 -- it never loads a system
`libsqlite3`. Hermes and the WebUI are covered by their own interpreter.

So the image ships no SQLite of its own. Nothing on the platform side opens the live `state.db`:
`harness-backup` inspects the copy inside the `hermes backup` zip, which no writer touches, and
`harness-remote` and the skill libraries do not use SQLite. The platform venv stays on Debian's
python3.

Two guards keep it that way. CI asserts `sqlite3.sqlite_version >= 3.51.3` on Hermes' interpreter
after installing it, because that is where the guarantee now lives and a future lock could change
it. And the image does not install Debian's `sqlite3` CLI, so an agent poking at `state.db` from its
shell reaches for Hermes' own tools rather than the vulnerable library. If something on the
platform ever needs to open a live Hermes database, it runs under Hermes' python, not Debian's.

### Image name and layout

`contexture-hermes` stops being honest once Hermes is not in it. The image becomes
`ghcr.io/ayxuerui/contexture-runtime:<ctxr version>`, and `harnesses/hermes/` becomes `image/`, with
recipes under `lib/harnesses/`. The old name keeps its last tag for rollback; it is not rebuilt.

`watch-agent-clis.yml` is retired. `watch-ctxr.yml` stays. A low-frequency watcher for the platform
pins (s6-overlay, gh, restic, rclone, pandoc, jq) replaces nothing that exists today and is
optional.

## Alternatives considered

**Keep everything in the image; make the pipeline flow.** Give the watchers a token that triggers
CI, batch tool bumps into one daily PR, auto-merge on green. This keeps the property that every
container runs a CI-tested set of binaries, which is the strongest thing the current design has,
and it is a much smaller change. Rejected because it removes the clicks but not the cost: still a
45-minute build and a recreate that ends sessions every day, still an image release to try a new
harness, still one union image for every person. It is the right answer if per-person harness
choice never materialises.

**Keep Hermes as the base; move only the CLIs.** Cheapest version of this design, and it keeps
upstream's one supported deployment shape (their s6, their UID remap, their SQLite, their tested
venv). Rejected because Hermes is a harness like the others -- and the stalest one -- and would stay
the only one whose upgrade needs an image, while every store keeps carrying Hermes whether it wants
it or not. It remains the fallback if the platform work below proves fragile.

**No s6: another supervisor.** The gateway, dashboard and WebUI can share one container under any
process supervisor -- supervisord, or `tini` and a short script -- or run as separate compose
services from this image with Docker's `restart: always` as the supervisor. Hermes supports this
explicitly: `hermes gateway run --external-supervisor` makes in-chat restarts and `hermes update`
exit the gateway with status 75 and expect the supervisor to relaunch it on the new code. The UID
remap is not s6's either; any root entrypoint can do it before dropping privileges. So
`hermes update` works without s6, and the dashboard and WebUI need restarting by us under either
supervisor.

What only s6 gives is Hermes' runtime gateway registration: `hermes profile create` adds a
supervised slot under `/run/service`, and `container_boot` brings each profile's gateway back in its
last recorded state (an operator-stopped gateway stays stopped). Under another supervisor every
profile's gateway is a line of supervisor config, and adding a profile means editing it and
restarting. Kept s6 because that is the one capability with no substitute, and because the rest of
its cost is already paid: this repository already writes s6 service directories (`webui`,
`store-update`, `*-remote`) and tests them under real s6-overlay
(`lib/tests/harness-remote-container-test.py`). Switching supervisors would rewrite those for no
gain. The new cost of owning s6 is installing s6-overlay (four checksummed tarballs) and the
UID-remap cont-init, which another supervisor needs too. It would flip if Hermes stopped being
used, or if the s6-overlay install proves to be more upkeep than that.

**Let each harness self-update in place.** Least code. Rejected because a pin cannot be honoured
and nothing can report what is installed; `harness-install` keeps one writer.

**Let `ctxr update` install harnesses.** Rejected outright. contexture core is harness-neutral and
never references these images; making ctxr a harness package manager breaks both.

**Put the harness folder under `/opt/data`.** One volume fewer. Rejected because `hermes backup`
would archive it into every snapshot, and a reinstall could no longer be a volume drop.

**Use the container as a full VM (apt as the agent, sudo).** Rejected: root for the agent, and
drift between whatever was apt-installed and the next image. If a harness ever needs system
packages, that is a platform image change, reviewed.

## Costs accepted

- Two containers can run different harness versions. With ~20 people that can mean "works for me"
  reports. The answer, if it bites, is pinning in the shared default manifest -- a one-line PR with
  no build.
- A bad upstream release reaches stores the morning after it ships, without a CI gate. The smoke
  test and per-tool rollback bound it; Hermes' bound is a restore.
- The platform owns s6 and the UID remap, which upstream used to own.
- First boot on an empty harnesses volume downloads every harness (Hermes' installer alone fetches
  Python, node and Chromium). It needs network, and takes minutes.

## Migration of a live store

pkm, pkm-leilei and readyrun-brain run on this host. Per store, one at a time, with live sessions
counted first:

1. `harness-backup` (the restic snapshot) and a `hermes backup` zip kept aside. The new Hermes will
   be ≥ 0.22.x and write `state.db`; the old image cannot open it afterwards, so this zip is the
   rollback.
2. Delete `/opt/data/.install_method` if it reads `docker`; `hermes update` refuses to run on a
   Docker-stamped home inside a container.
3. Merge the compose change (new image name, `harnesses` volume, new services). Stores include the
   compose file from `main`, so the merge is the rollout -- as for a ctxr bump, wait for the
   release before `up`.
4. `docker compose up -d`; `harness-install` populates the volume. Check
   `/opt/data/.harness-status.json`, the gateway, WebUI and each `*-remote`.

Rollback: compose back to `contexture-hermes:<last tag>`, `hermes import` the zip from step 1.

## Phasing

1. **Platform image + `harness-install`, CLIs only.** Build `contexture-runtime` without Hermes,
   with the recipes for claude, codex, agy, agent-browser and cb, and boot-test it in CI with an
   empty harnesses volume. Not yet deployed.
2. **Hermes and the WebUI as harnesses.** Recipes, cont-init replacements, the platform venv. CI boots a container, installs Hermes, starts the gateway, runs `hermes backup`
   and `hermes import`.
3. **Migrate** one store (pkm-leilei first, the smallest), then the rest. Retire
   `watch-agent-clis.yml` and stop building `contexture-hermes`.

## Questions settled before writing this

Each was open in the first draft; all were checked against Hermes at `e29c42a` (2026-10-23).

1. **SQLite.** Hermes' interpreter carries 3.53.1 built in, and nothing on the platform opens a
   live database, so no SQLite is shipped. See SQLite above.
2. **Gateway restarts under s6.** Hermes' s6 backend is generic (PID-1 probe), so `hermes update`
   restarts its slots itself (and under another supervisor, `--external-supervisor` would do the
   same). It does not restart the dashboard or WebUI under any supervisor; `harness-install` does. The only constraint is that the update runs inside the agents
   container, which is why `harness-update` is an s6 service there.
3. **Profile reconciliation.** `hermes_cli.container_boot` reads `HERMES_HOME` and the scandir from
   the environment and is called from our cont-init unchanged.
4. **claude's install location.** `HOME=<dir> install.sh <version>` plus a symlink, as
   `install-agent-clis.sh` already does in production.
5. **Hermes extras.** Prepared on first use and carried across updates; nothing to prebuild.

Still unknown, and only answerable by running it (phase 2's CI boot test): how long a cold Hermes
install takes on an empty volume, and whether `stage2-hook.sh`'s first-boot seeding has a step
`hermes update` does not repeat that our stores depend on.
