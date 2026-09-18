# contexture-images

Container images that pair an agent harness runtime with the
[Contexture](https://github.com/ayxuerui/contexture) toolchain, so a deployment consumes a
published image instead of maintaining its own Dockerfile.

Published today:

| Image | Base | Contents |
|---|---|---|
| `ghcr.io/ayxuerui/contexture-hermes` | `nousresearch/hermes-agent` | Hermes agent + WebUI (in-process, supervised) + `gh` + `ctxr` + `codex`, `agent-browser`, `claude`, `agy` + `restic`, `rclone` + `pandoc`, `jq` |

## Using it

```dockerfile
ARG CONTEXTURE_HERMES_TAG
FROM ghcr.io/ayxuerui/contexture-hermes:${CONTEXTURE_HERMES_TAG}

# …your own toolchain, your own provisioning script, your own write-safe roots
COPY setup.sh /usr/local/bin/setup.sh
RUN chmod +x /usr/local/bin/setup.sh
```

The image deliberately declares no `ENTRYPOINT`, `CMD`, `EXPOSE`, `HEALTHCHECK` or `VOLUME` —
those are deployment choices, and baking them in would silently override your compose file.

## Backing up the harness home

A Contexture store is version-controlled by definition. The harness home it runs against —
`$HERMES_HOME`, the agent's `config.yaml`, `SOUL.md`, `cron/jobs.json`, `user-skills/`, every
chat transcript and all of its credentials — is not. Two commands cover it, and they are not
redundant:

| | `harness-config-push` | `harness-backup` |
|---|---|---|
| Destination | a private git repo (`HARNESS_CONFIG_REPO`) | a restic repository (`HARNESS_BACKUP_DESTINATION`) |
| Purpose | track config, so it can be **diffed** | disaster recovery |
| Credentials | never — excluded by the allowlist and by a guard | yes, encrypted at rest |
| Restore | `git clone`, human-readable, no password | `restic restore` → `hermes import <zip>` |

Restoring from the git repo alone gives you a harness that cannot authenticate to anything.
A restic repository cannot tell you what changed in `SOUL.md` last week. Run both, or pick the
one whose failure you can live with.

Like `ctxr-provision`, these ship but never run. `harness-schedule` is the third command, and
what a deployment points a long-lived service at:

```sh
HARNESS_SCHEDULE_INTERVAL=86400 HARNESS_SCHEDULE_NOTIFY=telegram \
  harness-schedule harness-backup
```

Absence of the destination variable is the off switch, so an unconfigured store does nothing.

**Why a scheduler at all, rather than the harness's own cron or a host timer.** A harness's cron
dies with the harness: a gateway that wedges while still alive is never restarted, because
Docker restart policies act on process *exit* and not on healthcheck failure — so its scheduler
stops, and takes both the backups and the delivery channel that would have reported them
missing. A host timer survives that, but moves the schedule somewhere the compose file no longer
describes, and a container that shells back out to the host needs the docker socket mounted.
An ordinary container with its own restart policy has neither problem.

Three of its behaviours are load-bearing rather than incidental, and each is covered by
`lib/tests/schedule-test.sh`:

- **Runs at startup, then aligns to epoch slots.** `86400` lands on 00:00 UTC, `21600` on
  00/06/12/18 — stable times, no cron syntax. The startup run is the catch-up: a container
  restarted after the host was down runs immediately instead of waiting for the next slot,
  which is the one thing a systemd timer's `Persistent=true` would otherwise have given.
- **`sleep & wait $!`, never a bare `sleep`.** A bare sleep ignores its trap until it finishes —
  measured at 29s for a 30s sleep against 0s for this form. At a 24h interval every `compose
  down` would block for the whole grace period and then SIGKILL, and a SIGKILL partway through
  a restic run strands a lock the next run has to break.
- **A failing command never ends the loop.** Exiting would meet `restart: unless-stopped` and
  turn one bad run into a hot loop re-running the job continuously — a bill on a
  per-operation destination, a lockout on a rate-limited one.

**`harness-backup` archives through `hermes backup`, not the live tree**, and that is the
central decision. Hermes copies every `*.db` with `sqlite3.backup()` — a consistent image even
under a live writer — and deliberately omits the `.db-wal`/`.db-shm` sidecars, because pairing
a fresh main file with stale sidecar state produces a torn restore. A file-level snapshot of a
gigabyte-scale live `state.db` backs up exactly that torn pair. Going through hermes' own format
also means restoring with `hermes import`, which refuses to overwrite `gateway_state.json` and
`processes.json` — restore those onto a different host and the gateway comes up stuck
"starting".

The wrapper exists for one reason beyond glue: it **asserts the archive contains a usable
`state.db`**. Hermes' snapshot helper fails closed on a ten-second lock deadline, and the caller
then logs and continues — so a contended database is simply absent from an archive that still
exits 0. Without the assertion you get a green status over a backup that cannot restore, which
is the failure this whole thing replaces.

**The allowlist ships as an image artifact.** `harness-config-push` renders
`hermes-config.gitignore` into the home it tracks: ignore everything, then re-open only durable
state. A denylist loses every time a new root entry appears — and since `$HERMES_HOME` was once
`$HOME` for the in-process WebUI agent, "a new root entry" meant agent scratch, published before
anyone noticed. Extend it with `HARNESS_CONFIG_INCLUDE` / `HARNESS_CONFIG_EXCLUDE`; don't fork
it. A home whose `.gitignore` lacks the managed marker is left untouched, so adopting the
command changes no policy on day one.

Two guards, doing different jobs. The **commit guard** refuses staged credential *files*,
oversize blobs (a repo with a 100 MB blob can never be pushed again) and gitlinks with no
`.gitmodules` (they restore as empty directories and say nothing). The **visibility gate**
refuses a public remote, because transcripts and `SOUL.md` go up verbatim and no path-matching
guard can read what is inside them. Neither substitutes for the other, and neither remediates —
they refuse, leave the index alone, and fail the same way next run.

```sh
HARNESS_CONFIG_REPO=https://github.com/you/harness-config.git \
  HARNESS_CONFIG_DRY_RUN=1 harness-config-push    # what WOULD be committed

HARNESS_BACKUP_DESTINATION=rclone:gdrive:harness/pkm harness-backup
```

`restic` speaks S3, B2, Azure, GCS, SFTP and REST natively; `rclone` is shipped alongside so a
destination it doesn't speak — Google Drive, Dropbox, OneDrive — is reachable as
`rclone:remote:path`. Generate `rclone.conf` and the repository password outside the container:
OAuth cannot be completed in one, and a password whose only copy lives in the directory being
backed up is not a password.

It does ship `ctxr-provision`, but never runs it: clone, authenticate, verify, hand ownership to
the runtime uid. Point a one-shot service at it and gate that service yourself. What differs
between stores is passed in — see the script's header — rather than forked into a private copy.

## Pointing `harness-backup` at Google Drive

restic speaks S3, B2, Azure, GCS, SFTP and REST natively — if your destination is one of those,
set `HARNESS_BACKUP_DESTINATION` to the restic URL and skip this section. Google Drive is
reached through rclone instead, which is why `rclone` ships alongside `restic`.

**Make your own OAuth client.** rclone's built-in client ID is shared by every rclone user
globally and is rate-limited accordingly. In Google Cloud Console: new project → enable the
**Google Drive API** → configure the OAuth consent screen → Credentials → **Create OAuth client
ID → Desktop app**.

**Get a token, once, from a machine with a browser.** The container has none, and OAuth consent
cannot be automated:

```sh
RCLONE_DRIVE_SCOPE=drive.file rclone authorize "drive" "<client-id>" "<client-secret>"
```

That prints a JSON blob containing the refresh token.

**The scope prefix is not optional, and nothing prompts for it.** `rclone authorize` in its
id/secret form skips every config question and takes backend defaults, and rclone's drive
default is full `drive` — read and delete access to the user's entire Drive. Verified by reading
the `scope=` parameter off the OAuth redirect: bare gives
`.../auth/drive`, the line above gives `.../auth/drive.file`. Scope is fixed at consent time and
baked into the refresh token, so setting `scope` in config afterwards does NOT narrow an
existing token; it has to be re-consented and the old grant revoked at
myaccount.google.com/permissions.

Google shows a visibly narrower consent screen for `drive.file` — "only the specific files you
use with this app" rather than full Drive — which is the confirmation it worked.

`drive.file` means rclone sees only what it created. That is the right permission for a backup,
and it has one consequence worth planning for: **rclone cannot see a folder you made in the
Drive web UI.** Point the destination at a pre-existing folder and rclone will not find it, will
create a second one with the same name (Drive permits duplicates), and will back up into that.
Let rclone create the whole path, or pick a name it owns outright.

**Configure the remote from the environment, not a config file:**

```sh
RCLONE_CONFIG_GDRIVE_TYPE=drive
RCLONE_CONFIG_GDRIVE_CLIENT_ID=<id>.apps.googleusercontent.com
RCLONE_CONFIG_GDRIVE_CLIENT_SECRET=<secret>
RCLONE_CONFIG_GDRIVE_SCOPE=drive.file
RCLONE_CONFIG_GDRIVE_TOKEN={"access_token":"...","refresh_token":"...","expiry":"..."}

HARNESS_BACKUP_DESTINATION=rclone:gdrive:harness-backup/<store>
```

`RCLONE_CONFIG_<NAME>_<KEY>` defines a whole remote with no `rclone.conf` on disk at all. Note
it is `RCLONE_CONFIG_GDRIVE_*`, which names a remote — not `RCLONE_DRIVE_*`, which only sets
backend defaults and still needs a config file to name the remote.

**Environment rather than `rclone.conf` is deliberate.** A config file would live at
`$HERMES_HOME/home/.config/rclone/rclone.conf` — *inside the directory being backed up*. That is
a chicken-and-egg failure on the day you need it: reaching the backup requires credentials whose
only copy went down with the volume. The same reasoning applies to
`HARNESS_BACKUP_PASSWORD_FILE`; keep both wherever your deployment keeps its other secrets, and
a copy somewhere a dead machine cannot take with it.

The trade is that rclone cannot write a refreshed access token back to an env-defined remote, so
it re-derives one from the refresh token on every run and logs a NOTICE saying so. Google's
refresh tokens are durable, so this is noise rather than a problem — but if one is ever revoked,
you repeat the `rclone authorize` step.

**Scope these to the backup invocation, never to the gateway.** In a long-running container's
environment, the client secret and refresh token are readable by every shell command the agent
runs. That is the same argument that keeps `GH_TOKEN` off the gateway and gives it only to the
one-shot that runs `ctxr-provision`; a scheduled `harness-backup` should be gated the same way.

**One tuning knob worth setting for Drive.** Google throttles per-user API calls far harder than
object storage does, and restic's default 16 MiB pack size turns a ~2 GB archive into well over
a hundred uploads. `restic` reads this from its own environment, so no extra plumbing is needed:

```sh
RESTIC_PACK_SIZE=64        # MiB, restic's maximum is 128
```

Set it before the first snapshot — it applies to newly written packs only, so a repository that
started at the default keeps its existing packs. The cost is that a restore fetches in coarser
chunks than it strictly needs.

## The tag is the ctxr version

`contexture-hermes:0.10.0` contains `ctxr-cli@0.10.0`, and the build fails if that is not true.

This matters more than it looks. Since ctxr 0.10.0 the store schema gate is **both-directional**
— a CLI older *or* newer than a store's `contexture.yaml` `schema_version` is refused at config
load — and `ctxr migrate` was removed, so there is nothing to bridge a mismatch with. A drifted
pin doesn't degrade; every `ctxr` call fails outright, including the ones running from cron at
03:00. Putting the version in the tag makes the coupling visible at the point where a deployment
chooses it.

`CTXR_VERSION` at the repo root is the single source of truth, and the whole release flow hangs
off it:

1. `watch-ctxr.yml` polls npm hourly and opens a bump PR when a newer `ctxr-cli` exists.
2. CI builds that branch. The build asserts the installed `ctxr --version` equals the pin, so a
   green check means the new version actually installs and runs in the image.
3. **Merging the PR publishes.** `release.yml` triggers on a push to `main` touching
   `CTXR_VERSION` — merging is a user push, so it fires normally.
4. After every leg succeeds, a `v<version>` tag is created as a record of what shipped.

`:<version>` names the ctxr inside the image and moves when the image is rebuilt — a new tool
or a newer base republishes it. `:<version>-<sha>` is the immutable handle if you need one. The
build asserts the ctxr version either way, so the tag never lies about what it carries.

The tag is an output, not an input. It has to be: a tag pushed by a workflow using
`GITHUB_TOKEN` does not trigger other workflows, so tagging could never have been what causes a
publish. `workflow_dispatch` remains available to rebuild a version by hand.

Publishing is safe to automate because a published tag is **inert** — consumers pin an explicit
tag, and nothing reads `:latest`. A new image sits unused until someone bumps their own pin,
which is where the real judgement belongs (does this ctxr match my store's `schema_version`?).

## Layout

```
CTXR_VERSION                          the pin, single source of truth
lib/install-contexture-toolchain.sh   gh + ctxr: what CONTEXTURE needs
lib/install-agent-clis.sh             codex, agent-browser, claude, agy: what an AGENT needs
lib/install-backup-tools.sh           restic + rclone: what a BACKUP needs
lib/provision-store.sh                shipped as `ctxr-provision`: one-shot store setup
lib/config-push.sh                    shipped as `harness-config-push`: config to a git remote
lib/schedule.sh                       shipped as `harness-schedule`: run a command on an interval
lib/tests/                            marker-extracted guard tests; CI runs them before the build
harnesses/hermes/Dockerfile
harnesses/hermes/harness-backup.sh    shipped as `harness-backup`: whole home to restic
harnesses/hermes/hermes-config.gitignore   the allowlist seed the config repo is rendered from
harnesses/hermes/s6-rc.d/webui/       WebUI as an opt-in supervised s6 service
```

Adding a harness is adding a directory under `harnesses/` and a line in the two workflow
matrices. There is no shared *base image*, and that is not an oversight: each harness brings its
own base, so the only reusable piece is the small harness-agnostic layer that installs `gh` and
`ctxr`. Expect that to stay small — most of what a harness image contains is that harness's own
integration work.

Most harnesses need no image at all. A Contexture store is operable from Claude Code, Codex,
Cursor, Cline or Gemini CLI through the same files, with no container involved. Only a harness
you run as a long-lived service needs one.

## Building locally

Build context is the repo root, so `lib/` is reachable:

```sh
docker build -f harnesses/hermes/Dockerfile \
  --build-arg CTXR_VERSION="$(cat CTXR_VERSION)" \
  -t contexture-hermes:test .

docker run --rm contexture-hermes:test ctxr --version   # must match CTXR_VERSION
docker run --rm contexture-hermes:test gh --version
```

`CTXR_VERSION` has no default in the Dockerfile: a build that forgets it fails immediately
rather than quietly producing an image pinned to something stale.

## Licensing

MIT. The images are derived works of two MIT-licensed upstreams — see [NOTICE](NOTICE) for
attribution and the verification commands.
