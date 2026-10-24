# Harness recipes

One directory per harness the runtime image can install, read by `harness-install`
(`lib/harness-install.py`). A directory is a recipe when it holds `recipe.toml`; `_lib/` holds
helpers the recipes share.

- `recipe.toml` -- `binaries` (the first is the one asked for `--version`), optional `requires`,
  `pinnable` (false when the installer cannot be told a version), `rebuild_on` (`node-major`:
  reinstall when the platform's Node major changes), and `[services.<program>]` tables, each a
  `command` list with optional `directory` and `environment`. `${VAR}` in those values expands
  from the container's environment when the supervisor config is rendered.
- `install` -- installs exactly `$HARNESS_VERSION` into `$HARNESS_PREFIX`, an empty directory that
  is this version's for good, leaving each binary at `$HARNESS_PREFIX/bin/<name>`. It must not
  write anywhere else: not `/usr/local`, not the agent's home.
- `latest` -- prints the newest version on the harness's channel, and nothing else.

`harness-install` does the rest: choosing the version, the `--version` smoke test, flipping
`current`, linking `/opt/harnesses/bin`, keeping the previous version for a rollback, and
restarting the harness's programs after an update.
