# Harnesses live beside the home, not in the image

Status: proposed 2026-10-23. Phases 1 and 2 are built (2026-10-24): `runtime/`,
`lib/harness-install.py`, `lib/harnesses/`, the recipe-driven backup and config push, and
`harness-migrate-home`; tested in CI, not published or deployed. Phase 3, migrating the stores, is
not started.

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
chosen in compose, and upgrades without an image release.

| Layer | Contents | Lives in | Upgrades by |
|---|---|---|---|
| Platform | Debian, `tini`, supervisord, the boot entrypoint (`agent` user + UID remap), node, Debian's python3 and a platform venv on it (skill libs, `harness-remote`), Chromium's shared libraries, ctxr, gh, restic, rclone, pandoc, jq, every `ctxr-*`/`harness-*` script, and only the platform's own programs (`harness-update`, `store-update`) | the image | image release, as today (`watch-ctxr.yml`) |
| Harnesses | Hermes, the Hermes WebUI, claude, codex, agy, agent-browser, cb, anything added later | `harnesses` volume at `/opt/harnesses/<name>/` | `harness-install --update`, on a schedule |
| State | the agent's home: each harness's own state (`~/.hermes`, `~/.claude`, `~/.codex`, ...), credentials, sessions | `home` volume at `/home/agent` (see Home is the volume) | n/a |

The image tag stays the ctxr version, and merging a ctxr bump stays the rollout. That is the one
pin whose drift has repeatedly broken deployments, and `serve` and `store-update` run it.

### Home is the volume

Today the agent's home lives inside Hermes' state: the volume is `HERMES_HOME=/opt/data`, and
`HOME=/opt/data/home` is a directory in it. That is upstream's Docker layout, and it puts one
harness at the root of everyone's state. With Hermes one harness among several, it is inverted:
the volume **is** the agent's home, and every harness keeps its state where it does by default.

```
/home/agent/                         the `home` volume (today: `data`, at /opt/data)
  .hermes/                           Hermes' HERMES_HOME -- upstream's own non-Docker default
  .hermes-webui/                     WebUI state (today /opt/data/webui)
  .claude/  .claude.json  .codex/    as each harness defaults; a new one (gemini) adds its own
  .config/gh/  .config/circleback/   credentials, as today under home/
  .config/contexture/restic-password harness-backup's repository password
  .local/state/contexture/           harness-status.json, backup-status.json
```

Three things follow. Hermes lands on the layout its source installer creates (`~/.hermes`, code
elsewhere via `--dir`), so nothing about it is Docker-specific any more. The platform sets only
`HOME`; `HERMES_HOME=$HOME/.hermes` and `HERMES_WRITE_SAFE_ROOT=$HOME:/store:/tmp` are the Hermes
recipe's environment for its programs, not compose's. And `docker exec -u agent` with no `-e HOME`
lands where every harness reads.

The compose volume key becomes `home`, mounted at `/home/agent` in every service that mounts
`/opt/data` today. A store that maps the key to an existing volume renames the key and keeps the
name (`home: {name: pkm_pkm-data, external: true}`). **A store that does not map it -- pkm-leilei
today -- must add that mapping first** (`name: pkm-leilei_data`); otherwise Compose creates an empty
`pkm-leilei_home` and the agent boots with no logins.

### The harnesses volume

```
/opt/harnesses/
  bin/                  symlinks, LAST on PATH: hermes, claude, codex, agy, agent-browser, cb
  claude/
    2.1.308/            one directory per installed version, never moved after install
    2.1.287/            the version it replaced, kept for a rollback
    current -> 2.1.308  the one in use; an update or a rollback flips this link
  codex/  agy/  agent-browser/  cb/  hermes/  hermes-webui/   the same shape
  .installed.json       what harness-install put here: version, previous, platform facts, time
```

Versions are never moved because installers write absolute paths into them (claude's launcher is
an absolute symlink into its own version directory). An update installs the new version beside
the running one and flips `current` only after the new binary answers `--version`; a failure
leaves `current` alone. One previous version is kept, so a pin back to it is a link flip with
nothing downloaded.

`bin/` is last on PATH, after the platform: the volume is writable by the agent, and nothing in
it may shadow `ctxr`, `gh` or the platform python.

A separate volume rather than a directory in the home (`~/.local/share/harnesses`), because it is a **cache**:

- The home is what `harness-backup` snapshots. Inside it, hundreds of MB of architecture-bound
  binaries would ride along in every snapshot, several times a day, and be restored onto a host
  they may not match.
- `harness-config-push` is an allowlist, so it would ignore the directory either way.
- A volume can be dropped to force a clean reinstall without touching state:
  `docker compose down && docker volume rm <store>_harnesses && docker compose up -d`.

`harness-backup` runs harnesses' own snapshot commands (`hermes backup`), so its containers mount the volume read-only, as do the
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
`$HERMES_HOME/installs/<key>/` -- inside `~/.hermes`, in the home volume. `HERMES_RUNTIME_DIR` could move them,
but upstream documents it as a process-local development override and its launchers ignore it.

So `/opt/harnesses/hermes/` holds the code, and Hermes' runtime stays where upstream puts it. That
is fine for backups -- `hermes backup` already excludes `tools/` and `installs/`, and the Hermes
recipe excludes them from the file-level snapshot too -- and it is the layout upstream's installer
maintains. Fighting it would make every Hermes upgrade ours to debug.

**Hermes upgrades like the others, not by `hermes update`.** `hermes update` updates its checkout
in place and can only follow a channel; it cannot go to a named version. So a Hermes upgrade is
what every other harness's is: install.sh with `--commit v<version>` into a new version directory,
beside the running one, then a flip. That keeps pins, the `--version` smoke test before the flip,
and "a failed install never touches the running version". The installer runs Hermes' config
migration itself ("Configuration is up to date" is its last step). Each version is its own install
key to Hermes' package manager, so after an old version's directory is pruned the recipe's `gc`
hook runs `hermes pm gc` to drop that checkout's dependency environments. A cold install is about
two minutes on arm64 (Hermes 0.22.5: 1.1 GB of checkout and builds, 1.8 GB of runtime under
`~/.hermes`).

The WebUI runs Hermes in-process, and needs no environment of its own: started with the platform's
`python3` and `HERMES_WEBUI_AGENT_DIR` pointing at Hermes' checkout, it imports Hermes' bootstrap and
relaunches itself inside Hermes' managed runtime (checked with Hermes 0.22.5, WebUI 0.52.492). That
is also why its recipe says `restart_with = ["hermes"]`: a Hermes update restarts the WebUI.

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

### Choosing harnesses: three compose variables

Which harnesses a container has, which of their services run, and which are held back are
deployment choices, so they live where the rest of a deployment's choices do -- in compose:

```yaml
# harnesses/hermes/compose.yaml, the shared file every store includes from main
HARNESSES: ${HARNESSES:-hermes,hermes-webui,claude,codex,agy,agent-browser,cb}
HARNESS_SERVICES: ${HARNESS_SERVICES:-hermes-gateway,hermes-dashboard,hermes-webui,claude-remote,codex-remote,agy-remote}

# a store's own override, only when it differs
HARNESSES: hermes,hermes-webui,claude,codex,agy,agent-browser,cb,gemini
HARNESS_PINS: codex=0.162.1
```

- `HARNESSES` is what `harness-install` installs. A harness with no selected service is just a CLI
  on PATH.
- `HARNESS_SERVICES` is which programs run, by the names the recipes give them (see Services). It
  replaces today's three switches (`HERMES_DASHBOARD`, `HERMES_WEBUI_ENABLED`,
  `HARNESS_REMOTE_AGENTS`), and sits beside the ports, origins and passwords those services need
  anyway -- one decision in one file.
- `HARNESS_PINS` holds a tool at a version, the rollback for a bad release. Unpinned tools follow
  the channel their recipe defaults to (`stable` for Hermes, the WebUI and claude).

Defaults propagate. They are set in the shared compose file, which every store includes from
`main`, so adding a harness to the default reaches every store on merge, the same way a ctxr bump
does; a store overrides only what it wants different, and the history of that is its own repo's.

Changing any of the three is `docker compose up -d`, which recreates the container. That is a
deliberate, rare act -- adding a harness, turning a service on or off -- and it is not how
upgrades happen: the daily `harness-install --update` changes no variable and recreates nothing.

Each name maps to a recipe shipped in the image, `lib/harnesses/<name>/`: how to install and update
it, how to read the installed version, where its binary is, which harnesses it needs
(`hermes-webui` needs `hermes`), which services it can run, and what of its state is backed up and
tracked (see Backups follow the recipes). A name with no recipe, a service no selected harness
offers, or a pin for a harness not selected fails loudly at boot.

The harnesses volume is in neither backup.

### Installing and updating

`harness-install`, a platform script, is the single path that writes `/opt/harnesses`:

- **At boot**, the entrypoint runs `harness-install` before it starts the supervisor, so every
  harness is in place before any service runs. It installs anything in `HARNESSES` that is
  missing, reinstalls a tool whose recipe says the platform changed under it (node major for the
  npm tools), and writes the supervisor's program list (see Services). It does not upgrade. A
  failed install leaves that harness's programs out and is reported; it does not stop the boot.
- **On a schedule**, a supervised `harness-update` program inside the agents container runs
  `harness-install --update` daily at a quiet hour, via `harness-schedule`. It must be
  in-container, not a separate compose service like the backup schedulers: it restarts programs
  through supervisord's socket, and `hermes update` stops and restarts gateways by PID, both of
  which only reach the container they run in. Per tool: update to the newest version `HARNESS_PINS`
  allows, run its smoke test (`--version`), and on failure put the previous version back. One log
  line per tool, one status file (`~/.local/state/contexture/harness-status.json`, beside `backup-status.json`).
- **By hand**, `docker exec -u agent <container> harness-install --update [name]`.

The harnesses' own auto-updaters are **turned off** (`DISABLE_AUTOUPDATER=1` for claude and the
equivalents for the others). Several writers on one folder means nobody can say what is installed or
honour a pin. One updater keeps `.installed.json` true.

Per-tool recipes:

| Name | Install | Update |
|---|---|---|
| hermes | `hermes backup` of the current home first (two restore points kept, under `~/.local/state/contexture/hermes-pre-update/`), then install.sh `--dir <version>/src --commit v<version> --non-interactive --skip-computer-use`, with HOME pointed into the version directory so the launcher and rc edits stay there | the same, into a new version directory; then the flip restarts the gateway, the dashboard and (through `restart_with`) the WebUI |
| hermes-webui | the release's source tarball into `<version>/src`, and a `hermes-webui` launcher that runs `server.py` with the platform `python3` | the same |
| claude | its native installer with `HOME=/opt/harnesses/claude`, `.local/bin/claude` symlinked -- what `install-agent-clis.sh` already does into `/opt/toolchain`, and the agent already runs it with its real `HOME` | rerun the installer with the target version |
| codex, agent-browser, cb | `npm install -g --prefix /opt/harnesses/<name> <pkg>@<version>` with the image's node | same |
| agy | its installer into `agy/` (it takes no version: a pin is a cache key and an expectation, as today) | same |

### Services

A harness can bring long-running services, and every one of them is the same kind of thing:

| Harness | Service | Runs |
|---|---|---|
| hermes | `hermes-gateway` | `hermes gateway run --replace --external-supervisor`, serving every profile (below) |
| hermes | `dashboard` | `hermes dashboard --host ... --port ... --no-open` |
| hermes-webui | `webui` | the WebUI server, on Hermes' python, agent in-process |
| claude | `remote` | `claude remote-control` |
| codex | `remote` | `codex remote-control --no-daemon` |
| agy | `remote` | `agy remote-control serve` |

Today these are split across two mechanisms with a switch each: the
dashboard comes from the Hermes base image, `webui` and the three `*-remote` services are s6
directories baked into this image, each switched on by its own variable (`HERMES_DASHBOARD`,
`HERMES_WEBUI_ENABLED`, `HARNESS_REMOTE_AGENTS`), and `harness-remote` hard-codes the list of
remote harnesses. Adding one -- gemini, say -- is an image release, the cost this design exists to
remove.

After: a harness's recipe declares the services it can run -- name, command, directory, and the
probe that says it is serving -- and `HARNESS_SERVICES` picks which run. `harness-install`
renders one supervisord `[program:...]` per selected service (`hermes-dashboard`, `hermes-webui`,
`claude-remote`, ...; the recipe names it, and two recipes claiming one name is a boot error) into
the generated `/run/harness/supervisord.conf`. An unselected service simply has no program, which
replaces both the enable variables and s6's "exit 125 to stay down" `finish` scripts. After updating
a harness it restarts that harness's programs (`supervisorctl restart`) -- also how the dashboard
and WebUI get onto new code after `hermes update`, since Hermes' updater leaves both to their owner.
A changed `HARNESS_SERVICES` takes effect with the container's recreate, like any compose change.

The image then carries no harness's service at all: the baked `webui` and `*-remote` directories,
the three enable variables and the hard-coded list all go, replaced by one variable whose
history is the store's own compose override. The container healthcheck stops naming ports and
becomes `harness-install status`: every selected program is RUNNING and its recipe's probe answers.

What a deployment still sets in compose is what is genuinely its own: ports, origins, passwords,
proxy trust (`HERMES_DASHBOARD_PORT`, `HERMES_WEBUI_ALLOWED_ORIGINS`, ...). Those are inputs to a
service, not the choice of whether it runs.

**One Hermes gateway serves every profile.** Since Hermes 0.22.5 the root profile's gateway
multiplexes all of them, and a gateway started for a single profile refuses to run (exit 78:
"Profile 'work' does not get a gateway of its own ... would double-bind its platforms"). Found by
the phase-2 test: on 0.22.4 a per-profile gateway still ran, on 0.22.5 it was refused, so this
design renders no per-profile programs at all. A profile created at runtime (`hermes profile
create`) is picked up by the running gateway, with no supervisor involved. The one thing left to
the supervisor: a gateway is stopped with `supervisorctl stop`, since `hermes gateway stop` from
inside would be relaunched.

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

Every program, and supervisord's own notices (FATAL, restarts), log to the container's stdout, so
`docker compose logs` stays the one place to read. supervisord adds no prefix; `harness-remote`
prefixes its harness's lines (`[claude] ...`), and the others name themselves. Programs restart on any exit (`autorestart=true`), which is what
`--external-supervisor`'s status 75 needs. supervisord's one sharp edge is that a program which
keeps dying inside `startsecs` goes FATAL and is never retried. That is used rather than fought:
`startsecs=5`, `startretries=3`, so a program that cannot start at all (a missing store, a bad
argument) is FATAL within seconds and `harness-install status` fails, while one that crashes after
running -- `harness-remote` waits 10 seconds before returning -- is simply restarted.
`stopasgroup`/`killasgroup` take a remote session's whole process group down with it, which
`harness-remote` already arranges.

The one-shot compose services (`workspace-init`, `serve`, the backup jobs) override the entrypoint
as they do today and never start the supervisor.

### The runtime user

The image's one unprivileged user is **`agent`**, uid/gid 10000 by default (`PUID`/`PGID`), with
home `/home/agent` -- the home volume.

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
login` writes its key under `/opt/data`, where the agent never looks. `agent`'s passwd home is the
home volume, and every harness's state is under it, so a plain `docker exec -u agent` lands where
the harnesses read and the `-e HOME=...` lines go.

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

- **claude, codex, agy, agent-browser, cb:** add `<name>=<version>` to the store's `HARNESS_PINS`
  and `docker compose up -d`. If that version is the one kept on disk, it is a link flip with no
  download; otherwise it installs it. A minute, no image. agy is the exception among these: its
  publisher serves only the latest build, so it can go back only to the version kept on disk, and
  it updates itself inside its version directory between our updates.
- **Hermes cannot be pinned backwards.** Once a newer release has written `state.db`, older
  releases refuse to open it. Its recipe is `forward_only`: a pin to an older version is refused
  (the running version keeps running, and `harness-install status` fails, naming the refusal).
  Every Hermes install over an existing home takes a full `hermes backup` first, with the version
  being replaced, and a failed backup stops the install. The way back is `hermes import` of that
  zip, then a pin.

This follows the repository's "trial by release" habit: reversible changes ship and are reversed,
rather than gated. Hermes is the one harness whose reversal is a restore, which is why its update
always carries a backup.

### What the platform has to take over from the Hermes base

Today these come free with `FROM nousresearch/hermes-agent`. Each becomes ours:

| Today, from the base | After |
|---|---|
| s6-overlay, `/init`, `entrypoint-dispatch.sh` | `tini` + our entrypoint + supervisord (Debian packages); no s6 |
| `hermes` user (home `/opt/data`), `stage2-hook.sh` UID/GID remap and targeted chowns | the `agent` user (home `/home/agent`), remapped by our entrypoint as root before it drops privileges (see The runtime user) |
| First-boot seeding of `config.yaml`/`.env`, `API_SERVER_KEY` | the installer seeds config ("config prepared"); the Hermes recipe's `boot` hook generates `API_SERVER_KEY` in `~/.hermes/.env` when neither it nor the environment has one, and removes a `docker` install stamp |
| `docker_config_migrate.py`, PM generation resolve, `skills_sync.py` at boot | done by the installer at each version's install, so no longer at every boot |
| the s6 `store-update` service running `ctxr-install-circleback-script` | `runtime-store-update`: the store update, then every installed harness's `store-updated` hook; Hermes' runs the Circleback install |
| `02-reconcile-profiles` (`hermes_cli.container_boot`), `015-supervise-perms` | gone: one multiplexing gateway serves every profile (Hermes 0.22.5+). Lost with it: a gateway an operator stopped stays stopped across a reboot (`desired_state`); here a selected gateway always starts |
| `dashboard` s6 service, `main-hermes` placeholder | the `hermes` recipe's `dashboard` program; no placeholder needed |
| SQLite 3.53.4 compiled in, ahead of Debian trixie's 3.46.1 | not needed (see SQLite below) |
| `/opt/hermes/.venv` for WebUI, `harness-remote` and the document-skill libraries | split: WebUI runs on Hermes' python; `harness-remote` and pypdf/docx/openpyxl/pptx/bs4/reportlab go in a platform venv at `/opt/contexture/venv`, on PATH, so a Hermes update cannot remove them |
| `/opt/hermes/skills` (used by `harness-config-push` to tell shipped skills from authored) | `HARNESS_CONFIG_BUNDLED_SKILLS_DIR=/opt/harnesses/hermes/skills` |
| `profile.d/10-hermes-path.sh` | `runtime/profile.d/10-runtime-path.sh`: `/opt/contexture/venv/bin:...:/opt/harnesses/bin`, platform first |
| Chromium on PATH via the Playwright glob | `agent-browser`'s and Hermes' own browsers; the image keeps only the shared libraries they need |

`HERMES_WRITE_SAFE_ROOT` keeps its meaning -- the agent's own state, the store, and `/tmp` -- as
`$HOME:/store:/tmp`, set by the Hermes recipe. The `HOME`/`HERMES_HOME` nesting is inverted; see
Home is the volume.

### Backups follow the recipes

`harness-backup` and `harness-config-push` both know Hermes by name today: one archives through
`hermes backup`, the other's 277-line-descended allowlist names `SOUL.md`, `sessions/`,
`home/.claude/projects/` and the rest. Both become generic over the home, and each recipe says
what of its state they handle:

| Recipe declares | Used by | Hermes' entry |
|---|---|---|
| `backup.snapshot`: a command writing a consistent archive of its state, and `backup.restore` | `harness-backup` | `hermes backup -o <file>` / `hermes import <file>` |
| `backup.exclude`: paths not worth snapshotting | `harness-backup` | `.hermes/{installs,tools,cache}/` |
| `config`: paths to track for diffing, relative to home | `harness-config-push` | `.hermes/{config.yaml,SOUL.md,memories/,cron/jobs.json,user-skills/,scripts/,sessions/}` |

Other entries, from today's allowlist: `hermes-webui` tracks `.hermes-webui/sessions/*.json`,
`claude` tracks `.claude/projects/*/*.jsonl`, `codex` tracks `.codex/sessions/`. None of them
needs a snapshot command; plain files are consistent enough. A harness that keeps a live SQLite
database declares a snapshot command, as Hermes does.

**`harness-backup`** snapshots the whole home to restic -- it stays the recovery copy, credentials
included, and the default is everything, because home also holds what belongs to no harness (`gh`,
Circleback, `.gitconfig`, `.ssh`). For each installed harness with `backup.snapshot` it writes that
archive to staging and leaves the harness's own directory out of the file-level pass, so a live
database is never copied torn; then one restic run takes the staging archives plus the rest of the
home, minus every recipe's `backup.exclude`. Restore is `restic restore`, then each restored
archive's `backup.restore`. The `hermes backup` reasoning in today's script -- `sqlite3.backup()`,
no WAL sidecars, no foreign `gateway_state.json` -- is unchanged; it just moves into Hermes' recipe.

**`harness-config-push`** renders its allowlist from the `config` entries of the harnesses in
`HARNESSES`, and still takes `HARNESS_CONFIG_INCLUDE`/`EXCLUDE` for a store's own additions.
It stays an allowlist: a new harness's state is invisible until its recipe names it. The
bundled-skill test (`HARNESS_CONFIG_BUNDLED_SKILLS_DIR`) becomes part of Hermes' `config` entry
(`bundled_skills = "src/skills"`, inside its version directory).

A recipe's `config.rules` are gitignore lines relative to its `root` -- Hermes' are today's
hermes-config.gitignore rules, moved under `.hermes/` -- so the order of keeps and denies, which the
allowlist depends on, survives. `harness-install allowlist` prefixes each recipe's anchored rules
with its root (a bare name like `state.db` matches at any depth and is left alone), re-opens each
root, and puts the credential denylist last so nothing re-opens it. `runtime/config-push.sh` hands
the result to the unchanged `lib/config-push.sh`, which gained two variables:
`HARNESS_CONFIG_HOME` (gh's HOME, which is the repository itself now) and
`HARNESS_CONFIG_BUNDLED_SKILLS_PREFIX`.

The config repository's paths change with the home (`config.yaml` becomes `.hermes/config.yaml`,
`home/.claude/...` becomes `.claude/...`). The migration moves `.git` to the new root and the files
with the home; the next harness-config-push commits the result, and git's rename detection keeps
each file's history (`git log --follow`). No separate `git mv` commit is needed.

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
`container_boot` brings the gateway back in its last recorded state (an operator-stopped gateway
stays stopped), and `hermes gateway start/stop/restart` act through s6. Under supervisord Hermes
sees no service manager, so stop is `supervisorctl stop`, and a stopped gateway starts again on
reboot. (Runtime registration of per-profile gateway slots was s6's other unique feature; Hermes
0.22.5 retired per-profile gateways in favour of one multiplexing gateway, so it no longer counts.)

Rejected because what is left is small. Every store runs the default profile only -- pkm's second
profile, `leilei`, moved its Telegram bot to the pkm-leilei store on 2026-10-23 and was deleted --
and the ~20-person plan is separate stores, not profiles. What remains is general supervision, and
for that s6-overlay is the more expensive choice to own: four checksummed tarballs and their
conventions (`with-contenv`, `s6-setuidgid`, `finish` exit 125, `timeout-kill`, the s6-rc
bundle), against one Debian package and one generated file. Nor does s6 save a rewrite: the baked
`webui` and `*-remote` directories go under Services either way. And the combination this design
needs, a source install updated in place, is not what upstream exercises under s6 either -- their
image refuses `hermes update` -- whereas `--external-supervisor` is a documented contract.

It would flip if a stopped gateway staying stopped across restarts became something operators
rely on. The phase-2 test showed supervisord handling status 75 as designed: `hermes gateway
restart` reports "relaunched by its supervisor".

**Docker as the supervisor: one compose service per program.** Same image, shared volumes,
`restart: always`, a health check and log stream per service. Rejected because choosing a service
would mean writing a compose service per program -- with its own volumes, environment and health
check -- in place of one name in `HARNESS_SERVICES`, and an update in one container would have to
restart programs in others, which needs the Docker socket inside a container the agent runs in.

**A manifest in the home** (`~/.config/contexture/harnesses.yaml`, seeded on first boot). Its case:
it changes without recreating the container (`harness-install --services` re-renders and reloads
the supervisor), the agent or the person can edit it without host access, and the config repo
records it. Rejected because a seeded file never receives a new default -- a harness added to the
image's default would never reach an existing store -- because a service switched on there still
needs its ports and passwords in compose, splitting one decision across two files, and because
"the agent can turn on its own remote-control service" is the capability the runtime user section
keeps out of reach. The recreate it avoids happens only when the set of harnesses or services
changes, a few times a year. It would flip if people without host access must choose their own
harnesses, or if service changes become frequent enough that recreates hurt.

**Let each harness self-update in place.** Least code. Rejected because a pin cannot be honoured
and nothing can report what is installed; `harness-install` keeps one writer.

**Let `ctxr update` install harnesses.** Rejected outright. contexture core is harness-neutral and
never references these images; making ctxr a harness package manager breaks both.

**Put the harness folder in the home.** One volume fewer. Rejected because `harness-backup` would
snapshot it every time, and a reinstall could no longer be a volume drop.

**Keep Hermes' layout for the home** (`HOME` inside `HERMES_HOME`). No volume migration at all,
which is the strongest reason to keep it: the move below is the riskiest step of this design.
Rejected because it is the one place the platform would still be shaped around Hermes, every
other harness's state would keep living inside Hermes', and `docker exec` would keep needing
`-e HOME`.

**Use the container as a full VM (apt as the agent, sudo).** Rejected: root for the agent, and
drift between whatever was apt-installed and the next image. If a harness ever needs system
packages, that is a platform image change, reviewed.

## Costs accepted

- Two containers can run different harness versions. With ~20 people that can mean "works for me"
  reports. The answer, if it bites, is a `HARNESS_PINS` default in the shared compose file -- a one-line
  PR with no build.
- A bad upstream release reaches stores the morning after it ships, without a CI gate. The smoke
  test and per-tool rollback bound it; Hermes' bound is a restore.
- The platform owns supervision and the UID remap, which upstream used to own, and a gateway an
  operator stopped no longer stays stopped across a restart.
- Every store's state is moved in place once (`harness-migrate-home`). It is renames on one
  filesystem with the agents stopped, reversible, and rehearsed on a copy first, but it is the
  riskiest step here, and paths inside conversation histories keep pointing at the old layout.
- First boot on an empty harnesses volume downloads every harness (Hermes' installer alone fetches
  Python, node and Chromium). It needs network, and takes minutes.

## Migration of a live store

pkm, pkm-leilei and readyrun-brain run on this host. Per store, one at a time, with live sessions
counted first:

1. `docker compose stop agents`, so nothing writes the volume. Take `harness-backup` (the restic
   snapshot) and a `hermes backup` zip kept aside, both with the OLD image. The new Hermes will be
   ≥ 0.22.x and write `state.db`; the old image cannot open it afterwards, so this zip is the
   rollback. It is the only restore point: the recipe's own pre-upgrade backup needs a working
   current version, and on a migrated home there is none yet.
2. **Move the home into place**, with `harness-migrate-home`, a one-shot on the new image that
   mounts the volume and refuses to run twice (a layout marker in `.local/state/contexture/`):
   - every root entry except `home/` moves into `.hermes/`; then `home/`'s contents, dotfiles
     included, move to the root. Both are renames on one filesystem, so a database moves with its
     WAL and nothing is copied. A name that would collide (a stray `home/.hermes`, say) stops it
     before anything moves, with the list.
   - absolute paths in configuration are rewritten, `/opt/data/home` to `/home/agent` first, then
     `/opt/data` to `/home/agent/.hermes`: Hermes' `config.yaml`, `.env`, profile files and
     `cron/jobs.json`, `.claude.json` and `.claude/settings.json`, `.codex/config.toml`,
     `.gitconfig`. It prints every file it changed and keeps each original beside it. Conversation
     histories (`sessions/`, `*.jsonl`, `state.db`) are left as written: they record where things
     were.
   - `.hermes/.install_method` is deleted if it reads `docker`; `hermes update` refuses to run on a
     Docker-stamped home inside a container.
   - `harness-migrate-home --reverse` puts the old layout back, for the rollback below. It works
     on a home that has been used since: an entry the runtime deleted (Hermes checkpoints a WAL
     away) is skipped, state Hermes wrote since goes back to the Hermes root, and anything new at
     the top of the home goes into `home/`. The first rehearsal found it aborting on exactly that.
3. The store's compose change: its include moves from `harnesses/hermes/compose.yaml` to
   `runtime/compose.yaml`, the volume key `data` becomes `home` keeping its `name:` (and gaining one
   where the store had none -- pkm-leilei's is `pkm-leilei_data`), and `HARNESS_REMOTE_AGENTS`
   becomes entries in `HARNESS_SERVICES`. Stores still on the old include are untouched, so stores
   move one at a time.
4. `docker compose up -d`; `harness-install` populates the harnesses volume. Check
   `~/.local/state/contexture/harness-status.json`, `hermes doctor`, and every selected program
   (`harness-install status`).

Step 2 is rehearsed first on a copy of pkm-leilei's volume, never on the live one: copy the volumes
(mounted read-only), migrate the copy, install with network but no services, boot the services
with **no network** (the copy's `.env` holds the live Telegram token; a second poller on one bot
would fight the live gateway), check, stop, `--reverse`, and compare with an untouched copy.

What the rehearsals found, all fixed before the live move:

- `--reverse` aborted on a used home (above).
- A Hermes install is split: the checkout in the harnesses volume, its runtime in `~/.hermes/tools`
  and `~/.hermes/installs`, which `hermes backup` omits. A home restored from backup, or a kept
  harnesses volume over a replaced home, has a checkout whose launcher's interpreter is missing,
  and every program launches into a Hermes trying to rebuild itself. The recipe's `check` hook now
  catches that and `harness-install` reinstalls the version at boot.
- On its first start, Hermes 0.22.5 opening pkm-leilei's 0.21.3-era `state.db` failed once ("no
  such savepoint: fts_align_empty", the gateway exits 1); supervisord's restart opened it cleanly
  and `integrity_check` is ok. Expected once per store, on the first boot after the move.

Rollback: `harness-migrate-home --reverse`, compose back to `contexture-hermes:<last tag>`, then
`hermes import` the zip from step 1 (the new Hermes may already have written `state.db`).

The user rename touches documentation, not ownership. In this repository: the README's four
`docker exec -u hermes` lines (and their `-e HOME=/opt/data/home`), the `/opt/data` paths the
README and scripts name (`config-push.sh`, `provision-store.sh`, `install-circleback-script.sh`,
`harness-remote.py`, the compose file), and a comment in
`harness-backup.sh`; the s6 `run` files that also name it are deleted by this design. In the stores, as of
2026-10-24, for each store's owner to update with its migration -- the user name in prose and
comments only, plus each store's own `/opt/data` paths (pkm's compose comment on
`/opt/data/config.yaml`, readyrun-brain's on `/opt/data/home`) and the volume key:

| Store | File |
|---|---|
| pkm | `.docker/README.md` |
| pkm | `.agents/skills/agent-browser-routing/SKILL.md` |
| readyrun-brain | `.docker/README.md` |
| readyrun-brain | `.docker/docker-compose.yml` (a comment) |
| pkm-leilei | `.docker/README.md` |

## Phasing

1. **Platform image + `harness-install`, CLIs only.** *Built.* Build `contexture-runtime` without Hermes,
   with the recipes for claude, codex, agy, agent-browser and cb, and boot-test it in CI with an
   empty harnesses volume. Not yet deployed. Tests: `lib/tests/harness-install-test.py` (fake
   recipes, no image), `lib/tests/runtime-container-test.py` (the image with fake harnesses, no
   network: supervision, privilege drop, update restarts, a parallel shutdown, PUID remap, a
   configuration error) and `lib/tests/runtime-install-test.sh` (every real recipe from its
   publisher).
2. **Hermes and the WebUI as harnesses.** *Built.* The `hermes` and `hermes-webui` recipes, the
   recipe-driven `harness-backup` (`lib/runtime-backup.py`) and `harness-config-push`
   (`runtime/config-push.sh`), `harness-migrate-home` (`lib/migrate-home.py`), and
   `runtime-store-update`. Tests: `lib/tests/runtime-hermes-test.py` (Hermes from upstream, one
   release behind the latest: boot, exit-75 relaunch, a second profile under the one gateway, the update with its
   backup and restarts, the forward-only refusal, backup and restore, what the config repository
   would track) and `lib/tests/migrate-home-test.py` (forward, a byte-for-byte reverse, refusals).
   The supervision test in `runtime-container-test.py` already covers what
   `harness-remote-container-test.py` covered under s6.
3. **Migrate** one store (pkm-leilei first, the smallest, after rehearsing `harness-migrate-home`
   on a copy of its volume), then the rest. Retire
   `watch-agent-clis.yml` and stop building `contexture-hermes`.

## Questions settled before writing this

Each was open in the first draft; all were checked against Hermes at `e29c42a` (2026-10-23).

1. **SQLite.** Hermes' interpreter carries 3.53.1 built in, and nothing on the platform opens a
   live database, so no SQLite is shipped. See SQLite above.
2. **Gateway restarts without s6.** `hermes gateway run --external-supervisor` exits 75 on a
   restart or update for any supervisor to relaunch. `hermes update` does not restart the
   dashboard or WebUI under any supervisor; `harness-install` does. The update runs inside the
   agents container, which is why `harness-update` is a supervised program there.
3. **Profiles.** Not in use (every store runs the default profile since 2026-10-23), and since
   Hermes 0.22.5 one gateway serves every profile anyway. See "One Hermes gateway serves every
   profile".
4. **claude's install location.** `HOME=<dir> install.sh <version>` plus a symlink, as
   `install-agent-clis.sh` already does in production.
5. **Hermes extras.** Prepared on first use and carried across updates; nothing to prebuild.

Answered by running it (2026-10-24): a cold Hermes install is about two minutes; the installer
seeds config and runs the migration, so only `API_SERVER_KEY` and the Docker install stamp needed a
boot hook; and with no service manager Hermes recognises the external supervisor itself
("Restarting externally-supervised gateway ... relaunched by its supervisor"). Two things a source
install needed that the old image hid: `libatomic1` (Hermes' pinned Node will not start without it)
and Chromium's shared libraries, both now in the platform image. Still to see on a live store: the
dashboard's own gateway controls, and `hermes doctor`, with no service manager.
