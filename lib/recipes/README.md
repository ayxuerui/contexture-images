# Recipes

One directory per harness or tool the runtime image can install, read by `runtime-install`
(`lib/runtime-install.py`). A directory is a recipe when it holds `recipe.toml`; `_lib/` holds
helpers the recipes share. Everything a recipe installs goes into the agent's home, where the
publisher's own installer puts it, and the whole home is backed up.

- `recipe.toml`
  - `kind` -- `harness` (selected by `HARNESSES`) or `tool` (selected by `TOOLS`). Required.
  - `binaries` -- what must be in `~/.local/bin` once installed; the first is asked `--version`.
  - `npm = "<package>"` -- an npm package, installed with `npm install -g`. The image sets
    `NPM_CONFIG_PREFIX=~/.local`, so it lands in `~/.local/lib/node_modules` with its binaries in
    `~/.local/bin`, and updates to `@latest` daily.
  - `self_updating = true` -- installed once by its own installer, which then keeps it current
    (claude, codex, agy). Never updated by `runtime-install`; its version is only recorded.
  - `requires`, `restart_with` -- recipes it needs selected, and recipes whose update restarts its
    programs too.
  - `[services.<program>]` -- `command` list, optional `directory`, `environment` and `probe`.
    `${VAR}` expands from the container's environment when the supervisor config is rendered.
  - `[backup]` -- `snapshot`/`restore` scripts and `exclude` patterns for state that must not be
    copied file by file (a live database). `[config]` -- what the config repository keeps.
- `install` -- the publisher's installer, run as the agent with its real `HOME`. Without one, the
  recipe needs `npm`. Never writes outside the home, never uses sudo.
- `update` -- its own update command, run daily unless `self_updating`; npm recipes need none.
- `check` -- optional: exit 0 when the install is whole, where a binary alone does not prove it.
- `boot`, `updated`, `store-updated` -- hooks run at every boot, after its version moved, and after
  the store update.

`runtime-install` does the rest: installing what is missing at boot, the daily update, rendering
`HARNESS_SERVICES` into supervisor programs, and restarting a recipe's programs when its version
moves.
