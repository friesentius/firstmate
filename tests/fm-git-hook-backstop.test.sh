#!/usr/bin/env bash
# Behavior tests for the deterministic commit-attribution backstop that
# bin/fm-git-hook-install.sh installs into every task worktree.
#
# The claude settings fm-spawn writes suppress the co-author trailer only by
# omitting an instruction from the model's prompt, so they are advisory and
# were measured leaking (docs/verification/runtime-backends.md). This hook is
# what makes the rule deterministic. These tests drive real git commits through
# the real hook, with no harness and no model, so CI enforces the guarantee.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-git-hook-backstop)
AGENT_TRAILER='Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>'
HUMAN_TRAILER='Co-Authored-By: A Human <human@example.com>'

# make_world <name>: a project with its own commit-msg hook plus a linked
# worktree, mirroring how a task worktree actually relates to the project.
# Sets PROJ and TASK_WT.
make_world() {
  local name=$1 root="$TMP_ROOT/$1"
  PROJ="$root/proj"
  TASK_WT="$root/task"
  mkdir -p "$PROJ"
  git init -q "$PROJ"
  git -C "$PROJ" config user.email backstop@example.invalid
  git -C "$PROJ" config user.name 'Backstop Test'
  printf 'base\n' > "$PROJ/base.txt"
  git -C "$PROJ" add -A
  git -C "$PROJ" commit -qm base
  # A project hook that must keep running and keep its power to reject.
  cat > "$PROJ/.git/hooks/commit-msg" <<'HOOK'
#!/bin/sh
grep -q FORBIDDEN "$1" && exit 1
exit 0
HOOK
  chmod +x "$PROJ/.git/hooks/commit-msg"
  git -C "$PROJ" worktree add -q "$TASK_WT" -b "wt-$name"
  git -C "$TASK_WT" config user.email backstop@example.invalid
  git -C "$TASK_WT" config user.name 'Backstop Test'
}

# commit_with <worktree> <file> <message> [agent-address-list]
# The optional address list is passed through git so it reaches the hook
# process git forks, which is the only place the proxy reads it.
commit_with() {
  local wt=$1 file=$2 message=$3 addresses=${4-}
  printf 'x\n' > "$wt/$file"
  git -C "$wt" add -A
  if [ -n "$addresses" ]; then
    FM_AGENT_COAUTHOR_ADDRESSES="$addresses" git -C "$wt" commit -q -F - <<EOF
$message
EOF
  else
    git -C "$wt" commit -q -F - <<EOF
$message
EOF
  fi
}

test_agent_trailer_stripped_and_human_kept() {
  make_world strip
  "$ROOT/bin/fm-git-hook-install.sh" "$TASK_WT" >/dev/null \
    || fail "install failed"
  commit_with "$TASK_WT" a.txt "add a

$HUMAN_TRAILER
$AGENT_TRAILER"
  local msg
  msg=$(git -C "$TASK_WT" log -1 --format='%B')
  case $msg in
    *"noreply@anthropic.com"*) fail "the agent co-author trailer survived the backstop" ;;
  esac
  case $msg in
    *"$HUMAN_TRAILER"*) : ;;
    *) fail "the backstop removed a legitimate human co-author" ;;
  esac
  pass "the backstop strips an agent co-author trailer and keeps a human one"
}

test_project_hook_still_runs_and_can_reject() {
  make_world delegate
  "$ROOT/bin/fm-git-hook-install.sh" "$TASK_WT" >/dev/null || fail "install failed"
  # Control: without delegation this commit would succeed, so a rejection here
  # proves the project's own hook still ran.
  if commit_with "$TASK_WT" b.txt "FORBIDDEN change" 2>/dev/null; then
    fail "the project's own commit-msg hook stopped running under the backstop"
  fi
  commit_with "$TASK_WT" c.txt "allowed change" || fail "an allowed commit was rejected"
  pass "the project's own hook still runs and keeps its power to reject"
}

test_primary_checkout_hook_behavior_does_not_leak() {
  # Scoped to HOOK BEHAVIOR deliberately. The install is not a no-op on the
  # project's shared config: it enables extensions.worktreeConfig there
  # permanently, asserted below so this test states what actually happens.
  # What must not leak is the hooks override itself.
  make_world scoped
  "$ROOT/bin/fm-git-hook-install.sh" "$TASK_WT" >/dev/null || fail "install failed"
  local leaked shared
  leaked=$(git -C "$PROJ" config --get core.hooksPath 2>/dev/null || true)
  [ -z "$leaked" ] \
    || fail "the backstop leaked core.hooksPath into the primary checkout: $leaked"
  # The primary checkout must still emit what the task worktree strips.
  commit_with "$PROJ" p.txt "primary commit

$AGENT_TRAILER"
  git -C "$PROJ" log -1 --format='%B' | grep -q 'noreply@anthropic.com' \
    || fail "the backstop changed the primary checkout's commits"
  # The one shared-config change the install really does make, recorded as a
  # fact rather than left to be discovered: it is additive and never unset.
  shared=$(git -C "$PROJ" config --local --get extensions.worktreeConfig 2>/dev/null || true)
  [ "$shared" = true ] \
    || fail "install must enable extensions.worktreeConfig in the shared config for worktree scoping to work (got '${shared:-unset}')"
  pass "the backstop's hook behavior stays in the task worktree; only the additive extensions.worktreeConfig reaches the shared config"
}

test_relative_worktree_argument_still_arms_the_hook() {
  # A relative <worktree> used to produce a relative core.hooksPath, which git
  # resolves against the directory a hook runs from - so nothing was armed
  # while the install's own self-check compared two identical relative strings
  # and printed success. The proof has to be a real commit, not the config
  # value, because the config value was exactly what looked right.
  make_world relative
  local parent base
  parent=$(dirname "$TASK_WT")
  base=$(basename "$TASK_WT")
  ( cd "$parent" && "$ROOT/bin/fm-git-hook-install.sh" "./$base" >/dev/null ) \
    || fail "install via a relative worktree path failed"
  commit_with "$TASK_WT" r.txt "relative install

$AGENT_TRAILER"
  git -C "$TASK_WT" log -1 --format='%B' | grep -q 'noreply@anthropic.com' \
    && fail "a relative worktree argument reported success but armed no working hook"
  pass "installing via a relative worktree path still arms a working hook"
}

test_added_address_is_matched_literally() {
  # FM_AGENT_COAUTHOR_ADDRESSES is the documented extension point. An address
  # is not a regex: a `+` used to become a quantifier so the trailer survived,
  # and an unbalanced bracket used to make the pattern invalid and blank the
  # whole commit message.
  make_world literal
  "$ROOT/bin/fm-git-hook-install.sh" "$TASK_WT" >/dev/null || fail "install failed"
  local plus_trailer msg
  plus_trailer='Co-Authored-By: Some Agent <noreply+agent@example.com>'
  commit_with "$TASK_WT" plus.txt "add plus

mentions noreply+agent@example.com in prose
$HUMAN_TRAILER
$plus_trailer" 'noreply+agent@example.com' \
    || fail "the plus-address commit was rejected"
  msg=$(git -C "$TASK_WT" log -1 --format='%B')
  case $msg in
    *"$plus_trailer"*) fail "an address containing + was not matched literally, so the agent trailer survived" ;;
  esac
  case $msg in
    *"$HUMAN_TRAILER"*) : ;;
    *) fail "the literal match removed a legitimate human co-author" ;;
  esac
  case $msg in
    *"mentions noreply+agent@example.com in prose"*) : ;;
    *) fail "the literal match removed prose that merely mentions the address" ;;
  esac

  # An address the old code would have compiled into an invalid pattern must
  # leave the message exactly as written, never truncate it.
  commit_with "$TASK_WT" bad.txt "unmatched bracket subject

body that must survive" 'bad[unclosed@example.com' \
    || fail "the metacharacter-address commit was rejected"
  msg=$(git -C "$TASK_WT" log -1 --format='%B')
  case $msg in
    *"unmatched bracket subject"*) : ;;
    *) fail "an address with regex metacharacters blanked the commit subject" ;;
  esac
  case $msg in
    *"body that must survive"*) : ;;
    *) fail "an address with regex metacharacters blanked the commit body" ;;
  esac
  pass "an added address is matched literally and can neither miss its trailer nor blank the message"
}

test_reinstall_never_records_itself() {
  # A pooled worktree slot is reused, so install runs again over its own
  # previous state. If it ever recorded its own directory as the project's
  # original, delegation would be severed silently.
  make_world idempotent
  local i recorded
  for i in 1 2 3; do
    "$ROOT/bin/fm-git-hook-install.sh" "$TASK_WT" >/dev/null || fail "install $i failed"
  done
  recorded=$(cat "$TASK_WT/.fm-git-hooks/original-hooks-dir")
  [ "$recorded" != "$TASK_WT/.fm-git-hooks" ] \
    || fail "install recorded its own directory as the project's original hooks directory"
  if commit_with "$TASK_WT" d.txt "FORBIDDEN after reinstall" 2>/dev/null; then
    fail "delegation was lost after repeated installs"
  fi
  commit_with "$TASK_WT" e.txt "after reinstall

$AGENT_TRAILER"
  git -C "$TASK_WT" log -1 --format='%B' | grep -q 'noreply@anthropic.com' \
    && fail "stripping was lost after repeated installs"
  pass "repeated installs keep both delegation and stripping intact"
}

test_refuses_unsafe_repository_configurations() {
  make_world guarded
  git -C "$TASK_WT" config core.worktree /tmp/elsewhere
  if "$ROOT/bin/fm-git-hook-install.sh" "$TASK_WT" >/dev/null 2>&1; then
    fail "install proceeded with core.worktree set instead of refusing"
  fi
  git -C "$TASK_WT" config --unset core.worktree
  git -C "$PROJ" config core.bare true
  if "$ROOT/bin/fm-git-hook-install.sh" "$TASK_WT" >/dev/null 2>&1; then
    fail "install proceeded with core.bare true instead of refusing"
  fi
  git -C "$PROJ" config core.bare false
  "$ROOT/bin/fm-git-hook-install.sh" "$TASK_WT" >/dev/null \
    || fail "install refused a repository that is actually safe"
  pass "install refuses the unsafe repository configurations and still accepts a safe one"
}

test_agent_trailer_stripped_and_human_kept
test_project_hook_still_runs_and_can_reject
test_primary_checkout_hook_behavior_does_not_leak
test_relative_worktree_argument_still_arms_the_hook
test_added_address_is_matched_literally
test_reinstall_never_records_itself
test_refuses_unsafe_repository_configurations
