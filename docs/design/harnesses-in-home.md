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
| Platform | Debian, `tini`, supervisord, the boot entrypoint (`agent` user + UID remap), node, Debian's python3 and a platform venv on it (skill libs, `harness-remote`), Chromium's shared libraries, ctxr, gh, restic, rclone, pandoc, jq, every `ctxr-*`/`harness-*` script, and only the platform's own programs (`harness-update`, `store-update`) | the image | image release, as today (`watch-ctxr.yml`) |
| Harnesses | Hermes, the Hermes WebUI, claude, codex, agy, agent-browser, cb, anything added later | `harnesses` volume at `/opt/harnesses/<name>/` | `harness-install --update`, on a schedule |
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

Gateway supervision does not need Hermes' own. Hermes picks a service manager by probing for s6
(`s6-svscan` as PID 1), Windows, launchd or systemd; in this image it finds none and reports
`none`, which is a supported shape: `hermes gateway run --replace --external-supervisor` declares
that a wrapper owns the foreground gateway, and an in-chat restart, `hermes gateway restart` or
`hermes update` then exits it with status 75 for that wrapper to relaunch on the new code
(`reference/cli-commands.md`, "`--external-supervisor` is a restart-policy contract"). Here the
wrapper is supervisord; see Supervision.

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
  hermes:        { channel: stable, services: [gateway, dashboard] }
  hermes-webui:  { channel: stable, services: [webui] }
  claude:        { channel: stable, services: [remote] }
  codex:         { services: [remote] }
  agy:           { services: [remote] }
  agent-browser: {}
  cb:            {}
  # gemini:      {}                     adding a harness is one line, then a restart
  # codex:       { version: 0.162.1 }   a pin holds a tool back
```

No version means "latest on its channel". A `version` holds it. `services` picks which of the
harness's services run in this container (see Services); a harness with none is just a CLI on PATH.

Each name maps to a recipe shipped in the image, `lib/harnesses/<name>/`: how to install and update
it, how to read the installed version, where its binary is, which harnesses it needs
(`hermes-webui` needs `hermes`), and which services it can run. A name with no recipe, or a service
its recipe does not offer, fails loudly at boot.

`harness-config-push` adds `harnesses.yaml` to its allowlist, so the config repo shows when a tool
was added or pinned. The volume itself is in neither backup.

### Installing and updating

`harness-install`, a platform script, is the single path that writes `/opt/harnesses`:

- **At boot**, the entrypoint runs `harness-install` before it starts the supervisor, so every
  harness is in place before any service runs. It installs anything in the manifest that is
  missing, reinstalls a tool whose recipe says the platform changed under it (node major for the
  npm tools), and writes the supervisor's program list (see Services). It does not upgrade. A
  failed install leaves that harness's programs out and is reported; it does not stop the boot.
- **On a schedule**, a supervised `harness-update` program inside the agents container runs
  `harness-install --update` daily at a quiet hour, via `harness-schedule`. It must be
  in-container, not a separate compose service like the backup schedulers: it restarts programs
  through supervisord's socket, and `hermes update` stops and restarts gateways by PID, both of
  which only reach the container they run in. Per tool: update to the newest version the manifest
  allows, run its smoke test (`--version`), and on failure put the previous version back. One log
  line per tool, one status file (`/opt/data/.harness-status.json`, like `.backup-status.json`).
- **By hand**, `docker exec -u agent <container> harness-install --update [name]`.

The harnesses' own auto-updaters are **turned off** (`DISABLE_AUTOUPDATER=1` for claude and the
equivalents for the others). Several writers on one folder means nobody can say what is installed or
honour a pin. One updater keeps `.installed.json` true.

Per-tool recipes:

| Name | Install | Update |
|---|---|---|
| hermes | `install.sh --dir /opt/harnesses/hermes --non-interactive --skip-computer-use`, `HERMES_HOME=/opt/data` | `hermes update --yes --backup` (see Rollback); the gateway exits 75 and supervisord relaunches it on the new code, but Hermes leaves the dashboard and WebUI running on old code by design, so `harness-install` restarts those two afterwards |
| hermes-webui | release tarball for the newest stable tag into `hermes-webui/`; `compileall` with Hermes' python | same, then restart its `webui` service |
| claude | its native installer with `HOME=/opt/harnesses/claude`, `.local/bin/claude` symlinked -- what `install-agent-clis.sh` already does into `/opt/toolchain`, and the agent already runs it with its real `HOME` | rerun the installer with the target version |
| codex, agent-browser, cb | `npm install -g --prefix /opt/harnesses/<name> <pkg>@<version>` with the image's node | same |
| agy | its installer into `agy/` (it takes no version: a pin is a cache key and an expectation, as today) | same |

### Services

A harness can bring long-running services, and every one of them is the same kind of thing:

| Harness | Service | Runs |
|---|---|---|
| hermes | `gateway` | `hermes gateway run --replace --external-supervisor`, one per profile (below) |
| hermes | `dashboard` | `hermes dashboard --host ... --port ... --no-open` |
| hermes-webui | `webui` | the WebUI server, on Hermes' python, agent in-process |
| claude | `remote` | `claude remote-control` |
| codex | `remote` | `codex remote-control --no-daemon` |
| agy | `remote` | `agy remote-control serve` |

Today these are split across two mechanisms and none of them is chosen by the manifest: the
dashboard comes from the Hermes base image, `webui` and the three `*-remote` services are s6
directories baked into this image, each switched on by its own variable (`HERMES_DASHBOARD`,
`HERMES_WEBUI_ENABLED`, `HARNESS_REMOTE_AGENTS`), and `harness-remote` hard-codes the list of
remote harnesses. Adding one -- gemini, say -- is an image release, the cost this design exists to
remove.

After: a harness's recipe declares the services it can run -- name, command, directory, and the
probe that says it is serving -- and the manifest's `services` picks which run. `harness-install`
renders one supervisord `[program:...]` per selected service (`hermes-dashboard`, `hermes-webui`,
`claude-remote`, ...; the recipe names it, and two recipes claiming one name is a boot error) into
the generated `/run/harness/supervisord.conf`. An unselected service simply has no program, which
replaces both the enable variables and s6's "exit 125 to stay down" `finish` scripts. After updating
a harness it restarts that harness's programs (`supervisorctl restart`) -- also how the dashboard
and WebUI get onto new code after `hermes update`, since Hermes' updater leaves both to their owner.
A manifest edit applies with `harness-install --services`, which re-renders and runs
`supervisorctl update`: changed programs restart, removed ones stop, others are untouched.

The image then carries no harness's service at all: the baked `webui` and `*-remote` directories,
the enable variables and the hard-coded list all go, and the manifest is in the config repo, so
switching a service on shows up in its history. The container healthcheck stops naming ports and
becomes `harness-install status`: every selected program is RUNNING and its recipe's probe answers.

What a deployment still sets in compose is what is genuinely its own: ports, origins, passwords,
proxy trust (`HERMES_DASHBOARD_PORT`, `HERMES_WEBUI_ALLOWED_ORIGINS`, ...). Those are inputs to a
service, not the choice of whether it runs.

**Hermes' `gateway` is one program per profile.** `harness-install` renders `hermes-gateway` for
the root profile and `hermes-gateway-<name>` for each directory under `$HERMES_HOME/profiles/` with
a `SOUL.md` -- the marker Hermes' own boot reconciliation uses. Every store runs the default profile
only today. A profile created at runtime (`hermes profile create`) gets its gateway on the next
`harness-install --services` or container start, not instantly; and a gateway is stopped with
`supervisorctl stop`, since `hermes gateway stop` from inside would be relaunched. Both are the
price of not running s6 (see Alternatives).

What each recipe keeps is the part that is a contract rather than a preference: the foreground
checks that `harness-remote` makes today (`codex` must have `--no-daemon`, `agy` must be `serve`, a
background launcher would make a dead service look healthy) move into the recipe. A harness whose
CLI has no foreground mode for a service cannot offer it. Whether gemini's CLI has a remote-control
mode is answered when its recipe is written. `harness-remote` itself stays as the generic wrapper
the remote programs run; its `status` reads `supervisorctl status` instead of `s6-svstat`.

### Supervision

One container, the same as today, with nothing in it running as root once it has booted:

1. **PID 1 is `tini`**, which forwards signals and reaps orphans -- remote sessions and Hermes'
   tools spawn grandchildren that outlive their parents.
2. **The entrypoint, as root,** applies `PUID`/`PGID` to the `agent` user (`usermod`/`groupmod`
   and targeted chowns, as upstream's `stage2-hook.sh` does), generates `API_SERVER_KEY` if absent,
   then drops to `agent` with `setpriv` for everything after.
3. **`harness-install`** installs and renders the program list (Installing and updating).
4. **`exec supervisord`**, as `agent`, with the generated config: one program per selected
   service plus the platform's own two, `harness-update` (long-running) and `store-update` (runs
   once at start, `autorestart=false`, never fails the boot -- the s6 `finish` exit 125 it replaces).

Every program logs to the container's stdout with a `[name]` prefix, so `docker compose logs`
stays the one place to read. Programs restart on any exit (`autorestart=true`), which is what
`--external-supervisor`'s status 75 needs. supervisord's one sharp edge is that a program which
keeps dying inside `startsecs` goes FATAL and is never retried; programs get a long `startretries`
and the healthcheck reports a FATAL program, so a crash loop is visible rather than silent.
`stopasgroup`/`killasgroup` take a remote session's whole process group down with it, which
`harness-remote` already arranges.

The one-shot compose services (`workspace-init`, `serve`, the backup jobs) override the entrypoint
as they do today and never start the supervisor.

### The runtime user

The image's one unprivileged user is **`agent`**, uid/gid 10000 by default (`PUID`/`PGID`), with
home `/opt/data/home`.

**Not `hermes`.** The name was required in exactly two places -- upstream's Docker scripts
(`main-wrapper.sh`, `stage2-hook.sh`) and Hermes' s6 backend, which writes `s6-setuidgid hermes`
into each gateway slot -- and this design keeps neither. Hermes' own code does not look the name up.
With Hermes one harness among several, `hermes` would be the last place the platform names it.
`agent` is what an operator reads where it is used, `docker exec -u agent pkm-agents ...`, and
matches the compose service. (`harness` reads oddly as a user; `ctxr` names one tool the user runs,
not who it is.)

Ownership does not move. Files on the volumes are owned by uid 10000, not by a name, and the
one-shot compose services already run as `${PUID:-10000}`. A leftover `docker exec -u hermes`
fails loudly (`unable to find user hermes`), never silently, and `-u 10000` works throughout.

The home directory changes on purpose. Upstream's `hermes` user has home `/opt/data`, which is why
the README has to say `docker exec -u hermes -e HOME=/opt/data/home` -- without the `-e`, `cb auth
login` writes its key under `/opt/data`, where the agent never looks. `agent`'s passwd home *is*
the agent's tool-call home, so a plain `docker exec -u agent` lands where the harnesses read, and
the `-e HOME=...` lines go. Hermes' own process then runs with `HOME=/opt/data/home` rather than
`/opt/data`; it takes its state from `HERMES_HOME`, and the phase-2 boot test confirms nothing of
Hermes' lands under `home/` that used to land at the root.

**Not root.** The case for it is real: no remap, no privilege drop, no permission bugs, and an agent
could `apt install` what it needs. Rejected:

- `/store` is shared with `serve` and the backup jobs, which run as uid 10000. Root-owned files in it
  break them -- already seen when a chowned store made `ctxr-provision` die on git's
  `safe.directory`. Root works only if every container is root, including `serve`, the holder of
  the approval App key.
- Root in the agents container can rewrite the platform under itself -- `ctxr`, `harness-install`,
  the entrypoint -- and `apt install` drift that the next image silently drops. The design keeps
  the agent out of both.
- The harnesses refuse or warn: Claude Code refuses `--dangerously-skip-permissions` as root,
  claude's installer refuses root without `CLAUDE_INSTALL_ALLOW_SUDO`, and Hermes warns that a root
  gateway leaves root-owned files in `HERMES_HOME`.
- Without rootless Docker or user namespaces, root in the container is root on the host.

A system package a harness needs is a reviewed platform image change, as before.

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
| s6-overlay, `/init`, `entrypoint-dispatch.sh` | `tini` + our entrypoint + supervisord (Debian packages); no s6 |
| `hermes` user (home `/opt/data`), `stage2-hook.sh` UID/GID remap and targeted chowns | the `agent` user (home `/opt/data/home`), remapped by our entrypoint as root before it drops privileges (see The runtime user) |
| First-boot seeding of `config.yaml`/`.env`, `API_SERVER_KEY` | `hermes update` and first `hermes` run seed config; `API_SERVER_KEY` generation moves to our entrypoint |
| `docker_config_migrate.py`, PM generation resolve, `skills_sync.py` at boot | done by `hermes update` instead, so no longer at every boot |
| `02-reconcile-profiles` (`hermes_cli.container_boot`), `015-supervise-perms` | gone: `harness-install` renders a gateway program per profile instead. Lost with it: a gateway an operator stopped stays stopped across a reboot (`desired_state`); here every selected gateway starts |
| `dashboard` s6 service, `main-hermes` placeholder | the `hermes` recipe's `dashboard` program; no placeholder needed |
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
pins (gh, restic, rclone, pandoc, jq) replaces nothing that exists today and is
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

**Keep s6-overlay.** Upstream's image runs it and the stores run it today without trouble. It is
the supervisor Hermes recognises: Hermes detects s6 as PID 1 and then does its own supervision --
`hermes profile create` registers a `gateway-<profile>` slot under `/run/service` at runtime,
`container_boot` brings each profile's gateway back in its last recorded state (an
operator-stopped gateway stays stopped), and `hermes gateway start/stop/restart` act through s6.
Under supervisord Hermes sees no service manager, so those become ours: a new profile's gateway
waits for `harness-install --services`, stop is `supervisorctl stop`, and a stopped gateway starts
again on reboot.

Rejected because none of that is used. Every store runs the default profile only -- pkm's second
profile, `leilei`, moved its Telegram bot to the pkm-leilei store on 2026-10-23 and was deleted --
and the ~20-person plan is separate stores, not profiles. What remains is general supervision, and
for that s6-overlay is the more expensive choice to own: four checksummed tarballs and their
conventions (`with-contenv`, `s6-setuidgid`, `finish` exit 125, `timeout-kill`, the s6-rc
bundle), against one Debian package and one generated file. Nor does s6 save a rewrite: the baked
`webui` and `*-remote` directories go under Services either way. And the combination this design
needs, a source install updated in place, is not what upstream exercises under s6 either -- their
image refuses `hermes update` -- whereas `--external-supervisor` is a documented contract.

It would flip if Hermes profiles become a feature stores rely on, or if the phase-2 boot test shows
supervisord mishandling status 75 or Hermes' process groups.

**Docker as the supervisor: one compose service per program.** Same image, shared volumes,
`restart: always`, a health check and log stream per service. Rejected because the manifest could
no longer choose services -- compose services are fixed in the store's compose file -- and an update
in one container would have to restart programs in others, which needs the Docker socket inside a
container the agent runs in.

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
- The platform owns supervision and the UID remap, which upstream used to own, and Hermes' own
  profile-gateway management (runtime registration, stay-stopped across reboots) is given up.
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
   `/opt/data/.harness-status.json` and every selected service's slot (`harness-install status`).

Rollback: compose back to `contexture-hermes:<last tag>`, `hermes import` the zip from step 1.

The user rename touches documentation, not ownership. In this repository: the README's four
`docker exec -u hermes` lines (and their `-e HOME=/opt/data/home`) and a comment in
`harness-backup.sh`; the s6 `run` files that also name it are deleted by this design. In the stores, as of
2026-10-24 -- prose and comments only, nothing that executes -- for each store's owner to update
with its migration:

| Store | File |
|---|---|
| pkm | `.docker/README.md` |
| pkm | `.agents/skills/agent-browser-routing/SKILL.md` |
| readyrun-brain | `.docker/README.md` |
| readyrun-brain | `.docker/docker-compose.yml` (a comment) |
| pkm-leilei | `.docker/README.md` |

## Phasing

1. **Platform image + `harness-install`, CLIs only.** Build `contexture-runtime` without Hermes,
   with the recipes for claude, codex, agy, agent-browser and cb, and boot-test it in CI with an
   empty harnesses volume. Not yet deployed.
2. **Hermes and the WebUI as harnesses.** Recipes, the entrypoint, the platform venv. CI boots a
   container, installs Hermes, starts the gateway under supervisord, runs `hermes update` and
   checks the gateway came back on the new code (status 75 relaunch), restarts the dashboard and
   WebUI, and runs `hermes backup` and `hermes import`. `lib/tests/harness-remote-container-test.py`
   moves from real s6-overlay to real supervisord: privilege drop, HOME and cwd, failure health,
   one program restarting without the others, and a FATAL program failing the healthcheck.
3. **Migrate** one store (pkm-leilei first, the smallest), then the rest. Retire
   `watch-agent-clis.yml` and stop building `contexture-hermes`.

## Questions settled before writing this

Each was open in the first draft; all were checked against Hermes at `e29c42a` (2026-10-23).

1. **SQLite.** Hermes' interpreter carries 3.53.1 built in, and nothing on the platform opens a
   live database, so no SQLite is shipped. See SQLite above.
2. **Gateway restarts without s6.** `hermes gateway run --external-supervisor` exits 75 on a
   restart or update for any supervisor to relaunch. `hermes update` does not restart the
   dashboard or WebUI under any supervisor; `harness-install` does. The update runs inside the
   agents container, which is why `harness-update` is a supervised program there.
3. **Profiles.** Not in use (every store runs the default profile since 2026-10-23); one gateway
   program per profile directory covers them if they return. See Alternatives, "Keep s6-overlay".
4. **claude's install location.** `HOME=<dir> install.sh <version>` plus a symlink, as
   `install-agent-clis.sh` already does in production.
5. **Hermes extras.** Prepared on first use and carried across updates; nothing to prebuild.

Still unknown, and only answerable by running it (phase 2's CI boot test): how long a cold Hermes
install takes on an empty volume, and whether `stage2-hook.sh`'s first-boot seeding has a step
`hermes update` does not repeat that our stores depend on, and whether anything in Hermes beyond the gateway --
the dashboard's gateway controls, `hermes doctor` -- misbehaves when it finds no service manager.
