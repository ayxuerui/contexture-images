# contexture-images

Container images that pair an agent harness runtime with the
[Contexture](https://github.com/ayxuerui/contexture) toolchain, so a deployment consumes a
published image instead of maintaining its own Dockerfile.

Published today:

| Image | Base | Contents |
|---|---|---|
| `ghcr.io/ayxuerui/contexture-hermes` | `nousresearch/hermes-agent` | Hermes agent + WebUI (in-process, supervised) + `gh` + `ctxr` + `codex`, `agent-browser`, `claude`, `agy` + `restic`, `rclone` |

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

Like `ctxr-provision`, these ship but never run — scheduling is a deployment choice. Absence of
the destination variable is the off switch, so an unconfigured store does nothing.

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
