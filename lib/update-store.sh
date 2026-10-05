#!/bin/sh
# Bring a Contexture store up to the ctxr this image ships, through a reviewed pull request.
#
# Shipped as `ctxr-update-store`, and run once at container start by the `store-update` s6
# service, in every container of a stack unless CTXR_UPDATE_STORE_ENABLED=0. Every container
# runs this image, so the script elects itself rather than relying on the deployment to pick one:
# a container with a read-only store, or no gh credential, has nothing to do and says so; of the
# ones that remain, a lock on the store's git directory lets exactly one do the work, and the
# others step aside. Safe to run by hand, too, as the runtime user.
#
# WHY IT EXISTS. A store here gets a newer ctxr by image pull, not by anyone running the upgrade
# skill, so nothing re-renders its contexture-owned files afterwards -- the release advisory is
# silent because installed equals published. Worse, a release that raises the store schema
# version makes every ctxr command refuse the store, and the agent cannot run the skill that
# would fix it. Hermes has the same problem with its own config.yaml and migrates it at boot.
# This is the same idea, with one difference that shapes everything below: a store is a
# reviewed git repository, so the result is a PR, never a write in place.
#
# WHAT IT DOES, in order. Every step logs and moves on rather than failing:
#
#   1. Refresh the canonical clone, fast-forward only, and only when it is clean. A merged
#      migration PR does not reach `ctxr session start` -- which reads THIS checkout's
#      contexture.yaml -- until the clone moves. Dirty means in-flight agent work, and is left.
#   2. `ctxr update --worktree`: migrates (if the schema is behind) and re-renders on a branch
#      named for the release, in a worktree of its own. It never writes this checkout and
#      commits nothing. Nothing due -> it cleans up after itself and we are done.
#   3. Changes -> commit, push, open the PR.
#   4. The branch already exists -> one of three states:
#        merged (its patch is on the default branch)  delete it, local and remote, and go back to
#                                                     step 2 once. These repositories SQUASH-merge,
#                                                     so "merged" is `git cherry`, i.e. patch
#                                                     equivalence, never commit ancestry -- a
#                                                     squashed branch is never an ancestor.
#        pushed, PR open or pending                    make sure a PR exists, and leave it.
#        local only (an earlier push failed)           push it and open the PR.
#
# WHY IT NEVER EXITS NON-ZERO. It runs at boot. A failed push or an unreachable GitHub is not
# worth a container that will not start, and the next boot retries from wherever this left off:
# every state above is detected from git, not from a record this script keeps.
#
# Inputs, all optional:
#   STORE_DIR                 the store checkout   (default $CONTEXTURE_STORE_ROOT, else /store)
#   CTXR_UPDATE_STORE_ENABLED 0 = do not run at container start (read by the s6 service, not here)
#   CTXR_UPDATE_STORE_DRY_RUN 1 = report what would be committed/pushed, and change nothing remote
#
# Needs: git, ctxr (>= 0.19.0, for `update --worktree`), jq, gh -- authenticated under $HOME,
# which is how ctxr-provision leaves the agent's credential (never GH_TOKEN in the environment).
set -u

STORE="${STORE_DIR:-${CONTEXTURE_STORE_ROOT:-/store}}"
DRY_RUN="${CTXR_UPDATE_STORE_DRY_RUN:-0}"

log() { echo "[ctxr-update-store] $*"; }
store_git() { git -C "$STORE" "$@"; }

# >>> update-store (lib/tests/update-store-test.sh extracts between these markers) >>>

# The default branch, from what the clone itself knows: origin/HEAD as `git clone` records it,
# else the store's declared git.default_branch, else main. Reading contexture.yaml with sed is
# crude, but it is a fallback behind git's own answer and never the primary source.
default_branch() {
  _ref=$(store_git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
  if [ -n "$_ref" ]; then echo "${_ref#origin/}"; return; fi
  _decl=$(sed -n 's/^[[:space:]]*default_branch:[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$STORE/contexture.yaml" 2>/dev/null | head -1)
  if [ -n "$_decl" ]; then echo "$_decl"; else echo main; fi
}

refresh_canonical() {
  if [ -n "$(store_git status --porcelain 2>/dev/null)" ]; then
    log "canonical clone has uncommitted changes - not pulling, so in-flight work is never touched"
    return
  fi
  if store_git pull -q --ff-only 2>/dev/null; then
    log "canonical clone at $(store_git log --oneline -1 2>/dev/null)"
  else
    log "WARNING: fast-forward pull failed (diverged, or the remote is unreachable); continuing"
  fi
}

# Is every commit on branch $1 already on the default branch, by patch? `git cherry` prints one
# line per commit on the branch: "-" when an equivalent patch is upstream, "+" when it is not.
branch_merged() {
  _branch=$1
  _def=$(default_branch)
  store_git fetch -q origin "$_def" 2>/dev/null || true
  if store_git rev-parse --verify --quiet "refs/remotes/origin/$_branch" >/dev/null 2>&1 \
     || store_git fetch -q origin "$_branch:refs/remotes/origin/$_branch" 2>/dev/null; then
    _tip="origin/$_branch"
  else
    _tip="$_branch"
  fi
  _cherry=$(store_git cherry "origin/$_def" "$_tip" 2>/dev/null) || return 1
  [ -n "$_cherry" ] || return 0
  ! printf '%s\n' "$_cherry" | grep -q '^+'
}

remote_has_branch() {
  [ -n "$(store_git ls-remote --heads origin "$1" 2>/dev/null)" ]
}

# Idempotent: opens the PR only when the branch has none, open or closed-unmerged alike.
ensure_pr() {
  _branch=$1; _title=$2
  if (cd "$STORE" && gh pr view "$_branch" --json number >/dev/null 2>&1); then
    log "a pull request already exists for $_branch - leaving it for review"
    return
  fi
  if [ "$DRY_RUN" = 1 ]; then log "DRY RUN: would open a pull request: $_title"; return; fi
  _body="Produced by \`ctxr-update-store\` at container start: \`ctxr update --worktree\` with the ctxr this image ships ($(ctxr --version 2>/dev/null)). It migrated and/or re-rendered on this branch only, and never wrote the canonical clone. Review it like any other change; once merged, the next start pulls it into the canonical clone and removes this branch."
  if _url=$(cd "$STORE" && gh pr create --base "$(default_branch)" --head "$_branch" --title "$_title" --body "$_body" 2>&1); then
    log "opened $_url"
  else
    log "WARNING: could not open the pull request (the next start retries): $_url"
  fi
}

push_branch() {
  if [ "$DRY_RUN" = 1 ]; then log "DRY RUN: would push $1"; return 0; fi
  if store_git push -q -u origin "$1" 2>/dev/null; then return 0; fi
  log "WARNING: push of $1 failed (the next start retries)"
  return 1
}

delete_branch() {
  _branch=$1
  if [ "$DRY_RUN" = 1 ]; then log "DRY RUN: would delete merged branch $_branch"; return; fi
  _wt=$(store_git worktree list --porcelain 2>/dev/null \
    | awk -v ref="refs/heads/$_branch" '/^worktree /{p=$2} $0=="branch " ref {print p}')
  [ -n "$_wt" ] && store_git worktree remove --force "$_wt" 2>/dev/null
  store_git branch -q -D "$_branch" 2>/dev/null
  if remote_has_branch "$_branch"; then
    store_git push -q origin --delete "$_branch" 2>/dev/null \
      || log "WARNING: could not delete the merged remote branch $_branch"
  fi
  log "removed $_branch: its change is already on the default branch"
}

title_for() {
  _version=$(ctxr --version 2>/dev/null)
  _from=$(printf '%s' "$1" | jq -r '.data.migrated.from // empty')
  _to=$(printf '%s' "$1" | jq -r '.data.migrated.to // empty')
  if [ -n "$_from" ]; then
    echo "Migrate store schema $_from to $_to and re-render for ctxr $_version"
  else
    echo "Re-render contexture-owned files for ctxr $_version"
  fi
}

# One `ctxr update --worktree` and everything that follows from its answer. Returns 2 when a
# merged branch was removed, so the caller runs it once more.
update_once() {
  if ! _out=$(cd "$STORE" && ctxr update --worktree --json 2>/dev/null); then
    _msg=$(printf '%s' "$_out" | jq -r '.findings[0].message // empty' 2>/dev/null)
    log "WARNING: ctxr update refused or failed: ${_msg:-no envelope}"
    return 1
  fi
  _branch=$(printf '%s' "$_out" | jq -r '.data.branch // empty')
  _worktree=$(printf '%s' "$_out" | jq -r '.data.worktree // empty')
  _existing=$(printf '%s' "$_out" | jq -r '.data.existing // false')
  _changed=$(printf '%s' "$_out" | jq -r '.data.changed | length')

  if [ "$_existing" = true ]; then
    if branch_merged "$_branch"; then
      delete_branch "$_branch"
      return 2
    fi
    if store_git rev-parse --verify --quiet "refs/heads/$_branch" >/dev/null 2>&1 && ! remote_has_branch "$_branch"; then
      log "resuming $_branch: committed earlier but never pushed"
      push_branch "$_branch" || return 1
    fi
    ensure_pr "$_branch" "$(store_git log -1 --format=%s "$_branch" 2>/dev/null || title_for "$_out")"
    return 0
  fi

  if [ -z "$_worktree" ] || [ "$_changed" = 0 ]; then
    log "store is already up to date with ctxr $(ctxr --version 2>/dev/null)"
    return 0
  fi

  _title=$(title_for "$_out")
  log "$_changed file(s) changed on $_branch: $(printf '%s' "$_out" | jq -r '.data.changed | join(", ")')"
  if [ "$DRY_RUN" = 1 ]; then
    log "DRY RUN: would commit, push and open: $_title"
    return 0
  fi
  # The store's own pre-commit hook runs `ctxr doctor --staged` here, so the commit is held to
  # exactly the gate any other change is. A refusal is logged and the worktree is left for a
  # person to inspect. The branch then carries no commit of its own, which `git cherry` reads as
  # nothing pending, so the next start removes it and tries again with whatever has changed since.
  if ! git -C "$_worktree" add -A || ! git -C "$_worktree" commit -q -m "$_title" 2>/dev/null; then
    log "WARNING: commit on $_branch was refused; leaving the worktree at $_worktree for inspection"
    return 1
  fi
  push_branch "$_branch" || return 1
  ensure_pr "$_branch" "$_title"
  return 0
}

update_store() {
  if [ ! -f "$STORE/contexture.yaml" ]; then
    log "no provisioned store at $STORE - nothing to do"
    return 0
  fi
  # A store that is there but that git refuses -- most often "dubious ownership", a checkout
  # owned by a uid other than the one running this -- must say so, not pass for an absent one.
  if ! _gitdir=$(store_git rev-parse --git-dir 2>&1); then
    log "WARNING: $STORE has a contexture.yaml but git refuses it: $(printf '%s' "$_gitdir" | head -1)"
    return 0
  fi
  # Not every container that runs this image can act on the store, and that is normal rather
  # than a fault: a read-only mount (a browsing server), or no gh credential to push with. Both
  # are reported plainly and are not warnings, since a stack with the default on hits them on
  # every start.
  _common=$(cd "$STORE" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  if [ ! -w "$STORE" ] || [ ! -w "$_common" ]; then
    log "$STORE is read-only in this container - nothing to do here"
    return 0
  fi
  for _tool in ctxr jq gh; do
    command -v "$_tool" >/dev/null 2>&1 || { log "WARNING: $_tool is not on PATH - skipping"; return 0; }
  done
  if ! gh auth status >/dev/null 2>&1; then
    log "no gh credential under HOME=$HOME - nothing to push with, so nothing to do here"
    return 0
  fi
  # One updater per store, across every container sharing it. Non-blocking on purpose: the
  # first container to start does the work, and one that finds the lock held has nothing to add
  # -- the same release, the same branch, the same result. The lock lives in the git directory
  # because that is the one thing every container sharing this store sees as the same file, and
  # it is released when this process exits, however it exits.
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$_common/ctxr-update-store.lock"
    if ! flock -n 9; then
      log "another container is updating this store - leaving it to that one"
      return 0
    fi
  fi
  refresh_canonical
  update_once
  if [ $? -eq 2 ]; then
    update_once
  fi
  return 0
}
# <<< update-store <<<

update_store
exit 0
