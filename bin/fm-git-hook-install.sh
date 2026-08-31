#!/usr/bin/env bash
# Install firstmate's commit-attribution backstop into one task worktree.
# Usage: fm-git-hook-install.sh <worktree>
#
# Installs bin/fm-git-hook-proxy.sh as this worktree's core.hooksPath, scoped
# with git's per-worktree config so the project's primary checkout and every
# other worktree keep the hooks they already had. A linked worktree resolves
# hooks through the SHARED common directory, so a plain hook file would fire in
# the captain's own checkout; the per-worktree config is what keeps this
# contained.
#
# One part of that is NOT worktree-scoped and is permanent: git honors a
# worktree's own config only once extensions.worktreeConfig is enabled, and that
# key is written into the project's SHARED config and is never unset, so it
# outlives the task worktree. The write is additive rather than behavioral: it
# only makes git read each worktree's own config file, and every other
# worktree's is empty, so no other checkout's hooks change. It is still a real
# change to the project's shared configuration and is recorded as one.
#
# Guardrails, each of which refuses rather than proceeding quietly:
#   - core.bare true or core.worktree set: git documents these as unsafe to
#     leave in shared config once extensions.worktreeConfig is on, so this
#     refuses instead of enabling the extension under them.
#   - a git that cannot write per-worktree config at all.
#
# Idempotent by design: a pooled worktree slot is reused by later tasks, so
# every spawn re-runs this and re-derives the project's original hooks
# directory rather than trusting what a previous task left behind.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROXY="$SCRIPT_DIR/fm-git-hook-proxy.sh"

[ "$#" -eq 1 ] || { echo "usage: fm-git-hook-install.sh <worktree>" >&2; exit 2; }
WT=$1
[ -d "$WT" ] || { echo "error: worktree '$WT' is not a directory" >&2; exit 2; }
# Resolve to an absolute path before deriving anything else from it. Git
# resolves a relative core.hooksPath against the directory a hook runs from, so
# storing a relative value arms nothing while every string comparison in this
# script still matches what was written.
WT=$(cd "$WT" && pwd) || { echo "error: could not resolve worktree '$1' to an absolute path" >&2; exit 2; }
[ -x "$PROXY" ] || { echo "error: hook proxy is missing or not executable: $PROXY" >&2; exit 1; }

git -C "$WT" rev-parse --git-dir >/dev/null 2>&1 \
  || { echo "error: '$WT' is not a git worktree" >&2; exit 1; }

# Refuse under the configurations git documents as unsafe for worktree config.
bare=$(git -C "$WT" config --get core.bare 2>/dev/null || true)
if [ "$bare" = true ]; then
  echo "error: refusing to install the commit-attribution backstop in '$WT': core.bare is true" >&2
  exit 1
fi
if git -C "$WT" config --get core.worktree >/dev/null 2>&1; then
  echo "error: refusing to install the commit-attribution backstop in '$WT': core.worktree is set" >&2
  exit 1
fi

HOOKS_DIR="$WT/.fm-git-hooks"

# Derive the project's ORIGINAL hooks directory, freshly on every run, so a
# pooled slot reused by a different project never inherits the last task's
# answer. Read the LOCAL scope only: our own override lives in the worktree
# scope, so --local reports what the project itself configured (husky and the
# like) and never reports us. Note that `rev-parse --git-path hooks` is NOT
# usable here - it resolves through core.hooksPath, so once this backstop is
# installed it reports our own directory and would record us as the original.
original=$(git -C "$WT" config --local --get core.hooksPath 2>/dev/null || true)
if [ -n "$original" ]; then
  case $original in
    /*) : ;;
    *) original="$WT/$original" ;;
  esac
else
  common=$(git -C "$WT" rev-parse --git-common-dir 2>/dev/null || true)
  if [ -n "$common" ]; then
    case $common in
      /*) : ;;
      *) common="$WT/$common" ;;
    esac
    original="$common/hooks"
  fi
fi
# Never record ourselves: that would silently sever delegation to the project.
[ "$original" != "$HOOKS_DIR" ] || original=

mkdir -p "$HOOKS_DIR" || { echo "error: could not create '$HOOKS_DIR'" >&2; exit 1; }
printf '%s\n' "$original" > "$HOOKS_DIR/original-hooks-dir"

# Proxy exactly the hooks the project actually has, plus commit-msg, which is
# the one this backstop exists for. Synthesizing proxies for hooks the project
# does not have would change git's behavior for query-style hooks, where an
# absent hook and a hook that exits 0 mean different things.
install_proxy() {
  local name=$1 dest="$HOOKS_DIR/$1"
  rm -f -- "$dest"
  ln -s -- "$PROXY" "$dest" 2>/dev/null || cp -- "$PROXY" "$dest" || return 1
  chmod +x "$dest" 2>/dev/null || true
}

# Clear proxies left by a previous task before re-deriving, so a slot reused by
# a project with fewer hooks does not keep stale ones.
find "$HOOKS_DIR" -mindepth 1 -maxdepth 1 ! -name original-hooks-dir -exec rm -f -- {} + 2>/dev/null || true

install_proxy commit-msg || { echo "error: could not install the commit-msg proxy" >&2; exit 1; }
if [ -n "$original" ] && [ -d "$original" ] && [ "$original" != "$HOOKS_DIR" ]; then
  for hook in "$original"/*; do
    [ -f "$hook" ] && [ -x "$hook" ] || continue
    name=$(basename -- "$hook")
    case $name in
      *.sample|commit-msg) continue ;;
    esac
    install_proxy "$name" || { echo "error: could not proxy the project's $name hook" >&2; exit 1; }
  done
fi

if ! git -C "$WT" config extensions.worktreeConfig true 2>/dev/null; then
  echo "error: could not enable per-worktree git config in '$WT'" >&2
  exit 1
fi
if ! git -C "$WT" config --worktree core.hooksPath "$HOOKS_DIR" 2>/dev/null; then
  echo "error: could not set a per-worktree core.hooksPath in '$WT'" >&2
  exit 1
fi

# Prove the scoping rather than assuming it: the value must be readable here.
got=$(git -C "$WT" config --get core.hooksPath 2>/dev/null || true)
[ "$got" = "$HOOKS_DIR" ] || {
  echo "error: core.hooksPath did not take effect in '$WT' (got '${got:-unset}')" >&2
  exit 1
}
# Comparing the configured string against what we wrote cannot catch a value
# git resolves somewhere else, so prove the hook is actually reachable at the
# path git will use. Reporting success while nothing is armed is the one
# failure mode this backstop must never have.
case $got in
  /*) resolved=$got ;;
  *) resolved="$WT/$got" ;;
esac
{ [ -f "$resolved/commit-msg" ] && [ -x "$resolved/commit-msg" ]; } || {
  echo "error: no executable commit-msg hook where git will look for it in '$WT' ('$resolved/commit-msg')" >&2
  exit 1
}
printf 'installed commit-attribution backstop in %s\n' "$WT"
