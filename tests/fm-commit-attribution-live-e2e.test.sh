#!/usr/bin/env bash
# Opt-in live proof that the commit-trailer suppression bin/fm-spawn.sh writes
# actually changes the installed Claude's git-commit behavior.
#
# Whether a Co-Authored-By trailer appears is emitted by the vendor, so no stub
# can prove it: a fake agent only confirms the assumption written into the fake.
# This guard drives the REAL claude binary twice in two throwaway repos - once
# with the settings fm-spawn generates and once without them - and requires the
# suppressed run to be clean AND the control run to actually produce a trailer,
# so a vendor change that stops emitting trailers at all is reported instead of
# passing vacuously.
#
# Run this after every Claude Code upgrade and refresh the dated record in
# docs/verification/runtime-backends.md from its output.
set -u

if [ "${FM_COMMIT_ATTRIBUTION_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_COMMIT_ATTRIBUTION_LIVE_E2E=1 to drive the real claude binary"
  exit 0
fi

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

CLAUDE_BIN=${FM_CLAUDE_BIN:-$(command -v claude || true)}
[ -n "$CLAUDE_BIN" ] || fail "claude is not installed; this guard cannot verify commit attribution"
command -v jq >/dev/null 2>&1 || fail "jq not found"
CLAUDE_VERSION=$("$CLAUDE_BIN" --version 2>&1 | head -1)

TMP_ROOT=$(fm_test_tmproot fm-commit-attribution-live)

# The generated settings are the artifact under test, so they come from a REAL
# fm-spawn run rather than a copy hand-written here.
#
# Sets GENERATED_SETTINGS. Runs in the caller's shell, not a command
# substitution, so a failed spawn aborts this script with its own diagnosis
# instead of leaving the caller an empty path.
generated_settings() {
  local case_dir=$TMP_ROOT/generator home proj wt fakebin out
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake" claude)
  [ -d "$fakebin" ] || fail "the spawn fakebin was not created"
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" wt-attribution
  fm_test_spawn_brief "$home" attr-live-1
  out=$(GROK_HOME="$home/grok-home" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" attr-live-1 "$proj" \
    --mode no-mistakes --yolo off) || fail "fm-spawn failed: $out"
  [ -f "$wt/.claude/settings.local.json" ] || fail "fm-spawn wrote no claude settings"
  GENERATED_SETTINGS="$wt/.claude/settings.local.json"
}

# commit_trailer_count <case-name> <settings-json-or-empty>: build a throwaway
# repo, have the real claude commit its one file, and set TRAILER_COUNT to how
# many Co-Authored-By trailers the resulting commit message carries.
#
# Runs in the caller's shell, not a command substitution, so a claude run that
# errored out or produced no commit aborts this script under its own explicit
# message. Those are a third outcome, distinct from both trailer diagnoses the
# caller reports, and must never be mistaken for either of them.
commit_trailer_count() {
  local name=$1 settings=$2 repo count
  repo=$TMP_ROOT/$name
  mkdir -p "$repo/.claude"
  git init -q "$repo"
  git -C "$repo" config user.email attribution@example.invalid
  git -C "$repo" config user.name 'Attribution Guard'
  printf "print('hi')\n" > "$repo/app.py"
  printf '%s\n' "$settings" > "$repo/.claude/settings.local.json"
  ( cd "$repo" && "$CLAUDE_BIN" -p --permission-mode bypassPermissions \
      'Commit the work in this repository with an appropriate commit message.' \
      >/dev/null 2>&1 ) \
    || fail "$name: the real claude ($CLAUDE_VERSION) run failed, so neither trailer count is meaningful and this guard verified nothing"
  git -C "$repo" rev-parse --verify -q HEAD >/dev/null \
    || fail "$name: the real claude ($CLAUDE_VERSION) run produced no commit, so neither trailer count is meaningful and this guard verified nothing"
  count=$(git -C "$repo" log -1 --format='%B' | grep -ci 'co-authored-by' || true)
  case $count in
    ''|*[!0-9]*)
      fail "$name: could not count co-author trailers in the resulting commit (got '$count')" ;;
  esac
  TRAILER_COUNT=$count
}

test_generated_settings_suppress_the_trailer() {
  local settings control_json control suppressed
  generated_settings
  settings=$GENERATED_SETTINGS
  # Control: the same settings with only the attribution keys removed, so the
  # two runs differ in exactly the thing under test.
  control_json=$(jq -c 'del(.attribution) | del(.includeCoAuthoredBy)' "$settings") \
    || fail "could not build the control settings from $settings"

  commit_trailer_count control "$control_json"
  control=$TRAILER_COUNT
  commit_trailer_count suppressed "$(cat "$settings")"
  suppressed=$TRAILER_COUNT

  [ "$control" -gt 0 ] || fail \
    "claude $CLAUDE_VERSION emitted no co-author trailer even without the suppression; this guard verified nothing and the control must be re-examined before the record is refreshed"
  [ "$suppressed" -eq 0 ] || fail \
    "claude $CLAUDE_VERSION still emitted $suppressed co-author trailer(s) with the settings fm-spawn generates"
  printf 'ok - claude (%s): fm-spawn settings suppress the commit co-author trailer (control=%s suppressed=%s)\n' \
    "$CLAUDE_VERSION" "$control" "$suppressed"
}

test_generated_settings_suppress_the_trailer
