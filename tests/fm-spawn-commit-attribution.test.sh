#!/usr/bin/env bash
# AGENTS.md section 1 forbids adding an agent name as a commit co-author, but
# Claude Code appends a Co-Authored-By trailer to its own git commits by
# default. Asking for the suppression in the brief is not enforcement: the
# trailer is emitted by the harness, so the only durable fix is the settings
# bin/fm-spawn.sh writes for every claude-harness crewmate, scout, and
# secondmate.
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

# spawn_settings <name> <harness> <id>: run a real ship spawn and echo the path
# of the worktree's generated claude settings file (which may not exist).
spawn_settings() {
  local name=$1 harness=$2 id=$3 case_dir home proj wt fakebin out
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake" claude codex)
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  out=$(GROK_HOME="$home/grok-home" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" \
    --mode no-mistakes --yolo off) || fail "$harness spawn failed: $out"
  printf '%s\n' "$wt/.claude/settings.local.json"
}

test_claude_spawn_suppresses_commit_trailers() {
  local settings
  settings=$(spawn_settings claude-attribution claude attr-cl-1)
  assert_present "$settings" "claude spawn did not write settings"
  jq -e . "$settings" >/dev/null || fail "generated claude settings are not valid JSON"

  jq -e '.attribution.commitTrailers == false' "$settings" >/dev/null \
    || fail "generated claude settings must set attribution.commitTrailers=false"
  # The deprecated predecessor is written alongside the current key so an older
  # installed Claude, which does not know attribution, still honors the rule.
  jq -e '.includeCoAuthoredBy == false' "$settings" >/dev/null \
    || fail "generated claude settings must also set includeCoAuthoredBy=false"

  # Control: the suppression must be additive, not a rewrite that drops the
  # busy-state wiring the same file carries.
  local ev
  for ev in UserPromptSubmit Stop StopFailure SessionEnd; do
    jq -e ".hooks[\"$ev\"]" "$settings" >/dev/null \
      || fail "commit-attribution keys displaced the $ev hook wiring"
  done
  pass "a claude spawn writes commit-trailer suppression without disturbing the hook wiring"
}

test_non_claude_spawn_writes_no_claude_settings() {
  # Contrast case: the suppression is claude-specific, so a spawn on another
  # harness must not grow a stray .claude settings file. No other supported
  # harness has a verified equivalent key (see the PR evidence), and inventing
  # one here would assert unverified vendor behavior.
  local settings
  settings=$(spawn_settings codex-attribution codex attr-cx-1)
  assert_absent "$settings" "a codex spawn must not write claude settings"
  pass "the commit-trailer suppression stays scoped to the claude harness"
}

test_firstmate_own_settings_suppress_commit_trailers() {
  # Firstmate itself commits to this repo when it changes shared tracked
  # material with an empty fleet, so its own settings need the same rule.
  local own="$ROOT/.claude/settings.json"
  assert_present "$own" "firstmate's own claude settings are missing"
  jq -e '.attribution.commitTrailers == false' "$own" >/dev/null \
    || fail ".claude/settings.json must set attribution.commitTrailers=false"
  jq -e '.includeCoAuthoredBy == false' "$own" >/dev/null \
    || fail ".claude/settings.json must also set includeCoAuthoredBy=false"
  pass "firstmate's own claude settings suppress the commit co-author trailer"
}

test_claude_spawn_suppresses_commit_trailers
test_non_claude_spawn_writes_no_claude_settings
test_firstmate_own_settings_suppress_commit_trailers
