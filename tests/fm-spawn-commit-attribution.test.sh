#!/usr/bin/env bash
# AGENTS.md section 1 forbids adding an agent name as a commit co-author, but
# Claude Code appends a Co-Authored-By trailer to its own git commits by
# default. Asking for the suppression in the brief is not enforcement: the
# trailer is emitted by the harness, so the only durable fix is configuration.
# bin/fm-spawn.sh writes it into every claude-harness crewmate and scout
# worktree; a secondmate home is a worktree of the firstmate repo itself, so it
# inherits the tracked .claude/settings.json instead.
#
# Two independent keys carry the suppression. On claude 2.1.251 an attribution
# object carrying a commit or pr value wins outright on the emission path, so
# attribution.commit="" empties the commit trailer there, while
# includeCoAuthoredBy=false is the branch that build actually takes when no
# such attribution object is present and is what older builds honor.
# attribution.commitTrailers is schema-accepted and read by the
# managed-settings policy normalizer but never consulted on the emission path,
# so it is deliberately not one of the keys asserted here.
#
# These tests run the REAL fm-spawn against a fake pane and an isolated git
# worktree and assert the generated settings carry the suppression, so a future
# edit to that generated JSON cannot silently drop it. The live proof that the
# keys actually change Claude's commit behavior is a harness-dependent fact and
# lives in docs/verification/runtime-backends.md.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-commit-attribution)

# spawn_case <name> <harness> <id>: build an isolated spawn world and set
# CASE_WT / CASE_SETTINGS / CASE_FAKEBIN / CASE_HOME / CASE_PROJ for it. This
# runs in the caller's shell rather than a command substitution so a helper that
# calls fail aborts the whole script instead of handing back an empty path that
# a later existence assertion would read as a pass.
spawn_case() {
  local name=$1 harness=$2 id=$3 case_dir
  case_dir="$TMP_ROOT/$name"
  CASE_HOME="$case_dir/home"
  CASE_PROJ="$case_dir/project"
  CASE_WT="$case_dir/wt"
  CASE_SETTINGS="$CASE_WT/.claude/settings.local.json"
  CASE_FAKEBIN=$(fm_test_make_spawn_fakebin "$case_dir/fake" claude codex)
  [ -d "$CASE_FAKEBIN" ] || fail "$name: the spawn fakebin was not created"
  fm_test_spawn_home "$CASE_HOME" "$harness"
  fm_git_worktree "$CASE_PROJ" "$CASE_WT" "wt-$name"
  fm_test_spawn_brief "$CASE_HOME" "$id"
}

# run_spawn <id>: run a real ship spawn for the current case. Every case here is
# a ship spawn, which carries an explicit delivery contract (AGENTS.md section
# 7); these tests are about the generated settings, so they pass a fixed valid
# one.
run_spawn() {
  GROK_HOME="$CASE_HOME/grok-home" \
    fm_test_run_spawn "$CASE_HOME" "$CASE_WT" "$CASE_FAKEBIN" "$1" "$CASE_PROJ" \
    --mode no-mistakes --yolo off
}

test_claude_spawn_suppresses_commit_trailers() {
  local out
  spawn_case claude-attribution claude attr-cl-1
  out=$(run_spawn attr-cl-1)
  expect_code 0 $? "claude spawn should succeed: $out"
  assert_contains "$out" 'spawned attr-cl-1 harness=claude' \
    "claude spawn did not complete normally"

  assert_present "$CASE_SETTINGS" "claude spawn did not write settings"
  jq -e . "$CASE_SETTINGS" >/dev/null || fail "generated claude settings are not valid JSON"

  # The modern attribution path: a commit value present and empty.
  jq -e '.attribution.commit == ""' "$CASE_SETTINGS" >/dev/null \
    || fail "generated claude settings must set attribution.commit to the empty string"
  # attribution.pr stays unset. On 2.1.251 that does not preserve PR
  # attribution, because the PR-body path short-circuits on
  # includeCoAuthoredBy=false and returns empty anyway; it is the lever for
  # restoring PR attribution later, and this change deliberately leaves it
  # unpulled rather than pinning a PR string the task never asked for.
  jq -e '.attribution | has("pr") | not' "$CASE_SETTINGS" >/dev/null \
    || fail "generated claude settings must leave attribution.pr unset"
  # The key the installed build actually takes when no attribution object wins,
  # and the only one older builds understand.
  jq -e '.includeCoAuthoredBy == false' "$CASE_SETTINGS" >/dev/null \
    || fail "generated claude settings must also set includeCoAuthoredBy=false"

  # Control: the suppression must be additive, not a rewrite that drops the
  # busy-state wiring the same file carries.
  local ev
  for ev in UserPromptSubmit Stop StopFailure SessionEnd; do
    jq -e ".hooks[\"$ev\"]" "$CASE_SETTINGS" >/dev/null \
      || fail "commit-attribution keys displaced the $ev hook wiring"
  done
  pass "a claude spawn writes commit-trailer suppression without disturbing the hook wiring"
}

test_non_claude_spawn_writes_no_claude_settings() {
  # Contrast case: the suppression is claude-specific, so a spawn on another
  # harness must not grow a stray .claude settings file. No other supported
  # harness has a verified equivalent key (see the PR evidence), and inventing
  # one here would assert unverified vendor behavior.
  #
  # The spawn's own success is asserted first: an absence assertion proves
  # nothing unless the run that was supposed to create the file actually ran.
  local out
  spawn_case codex-attribution codex attr-cx-1
  out=$(run_spawn attr-cx-1)
  expect_code 0 $? "codex spawn should succeed: $out"
  assert_contains "$out" 'spawned attr-cx-1 harness=codex' \
    "codex spawn did not complete normally"

  assert_absent "$CASE_SETTINGS" "a codex spawn must not write claude settings"
  pass "the commit-trailer suppression stays scoped to the claude harness"
}

test_firstmate_own_settings_suppress_commit_trailers() {
  # Firstmate itself commits to this repo when it changes shared tracked
  # material with an empty fleet, so its own settings need the same rule. A
  # secondmate home is a worktree of this same repo and inherits this file.
  local own="$ROOT/.claude/settings.json"
  assert_present "$own" "firstmate's own claude settings are missing"
  jq -e '.attribution.commit == ""' "$own" >/dev/null \
    || fail ".claude/settings.json must set attribution.commit to the empty string"
  jq -e '.attribution | has("pr") | not' "$own" >/dev/null \
    || fail ".claude/settings.json must leave attribution.pr unset"
  jq -e '.includeCoAuthoredBy == false' "$own" >/dev/null \
    || fail ".claude/settings.json must also set includeCoAuthoredBy=false"
  pass "firstmate's own claude settings suppress the commit co-author trailer"
}

test_claude_spawn_suppresses_commit_trailers
test_non_claude_spawn_writes_no_claude_settings
test_firstmate_own_settings_suppress_commit_trailers
