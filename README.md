# contexture-images

Container images that pair an agent harness runtime with the
[Contexture](https://github.com/ayxuerui/contexture) toolchain, so a deployment consumes a
published image instead of maintaining its own Dockerfile.

Published today:

| Image | Base | Contents |
|---|---|---|
| `ghcr.io/ayxuerui/contexture-hermes` | `nousresearch/hermes-agent` | Hermes agent + WebUI (in-process, supervised) + `gh` + `ctxr` |

## Using it

```dockerfile
ARG CONTEXTURE_HERMES_TAG
FROM ghcr.io/ayxuerui/contexture-hermes:${CONTEXTURE_HERMES_TAG}

# …your own toolchain, your own provisioning script, your own write-safe roots
COPY setup.sh /usr/local/bin/setup.sh
RUN chmod +x /usr/local/bin/setup.sh
```

The image deliberately declares no `ENTRYPOINT`, `CMD`, `EXPOSE`, `HEALTHCHECK` or `VOLUME` —
those are deployment choices, and baking them in would silently override your compose file. It
ships no provisioning script either: how a store gets cloned, authenticated and reconciled is
policy, and it differs between deployments.

## The tag is the ctxr version

`contexture-hermes:0.10.0` contains `ctxr-cli@0.10.0`, and the build fails if that is not true.

This matters more than it looks. Since ctxr 0.10.0 the store schema gate is **both-directional**
— a CLI older *or* newer than a store's `contexture.yaml` `schema_version` is refused at config
load — and `ctxr migrate` was removed, so there is nothing to bridge a mismatch with. A drifted
pin doesn't degrade; every `ctxr` call fails outright, including the ones running from cron at
03:00. Putting the version in the tag makes the coupling visible at the point where a deployment
chooses it.

`CTXR_VERSION` at the repo root is the single source of truth. `watch-ctxr.yml` opens a PR when
npm publishes something newer; merging does not publish, tagging does.

## Layout

```
CTXR_VERSION                          the pin, single source of truth
lib/install-contexture-toolchain.sh   gh + ctxr + smoke tests; the only cross-harness file
harnesses/hermes/Dockerfile
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
