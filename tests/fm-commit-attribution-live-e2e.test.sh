#!/usr/bin/env bash
# Opt-in live proof that the commit-trailer suppression bin/fm-spawn.sh writes
# actually changes the installed Claude's git-commit behavior.
#
# Whether a Co-Authored-By trailer appears is emitted by the vendor, so no stub
# can prove it: a fake agent only confirms the assumption written into the fake.
# This guard drives the REAL claude binary in throwaway repos and runs three
# cases:
#
#   control    - the generated settings with the attribution keys deleted; must
#                produce exactly one real Co-Authored-By trailer, so a vendor
#                that stopped emitting trailers is reported instead of passing
#                vacuously.
#   suppressed - the settings fm-spawn generates verbatim; must produce zero.
#   sentinel   - attribution.commit set to a token that appears nowhere in the
#                repository, the prompt, or anything the agent can read; that
#                exact token must appear in the resulting commit message.
#
# The sentinel case is the decisive discriminator. A clean suppressed run alone
# is ambiguous: it could be the harness obeying the setting, or the model
# reading the setting and complying voluntarily. The agent never sees the
# sentinel string, so its appearance in the commit message proves the harness
# itself composed the trailer text from the settings.
#
# For the same reason the settings are supplied from OUTSIDE the repository
# under test, via claude's --settings flag, and no .claude/settings.local.json
# is left inside the repo the agent works in. A result that the agent could
# have produced by reading a file in its own working tree would not
# distinguish harness-level suppression from model compliance.
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

# Settings live here, outside every repository under test, so the agent's own
# working tree never contains the artifact being verified.
SETTINGS_DIR="$TMP_ROOT/settings"
mkdir -p "$SETTINGS_DIR"

# A token the agent cannot have read from anywhere: it is generated at run time
# and only ever reaches claude through --settings, never through the prompt or
# a file in the repository it commits in.
SENTINEL_TOKEN="fm-attr-$$-$(date +%s)-$RANDOM"
SENTINEL_TRAILER="X-Fm-Attribution-Probe: $SENTINEL_TOKEN"

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

# claude_commit <case-name> <settings-json>: build a throwaway repo, have the
# real claude commit its one file with the given settings supplied from outside
# that repo, and set COMMIT_MESSAGE to the resulting commit message.
#
# Runs in the caller's shell, not a command substitution, so a claude run that
# errored out or produced no commit aborts this script under its own explicit
# message. Those are a third outcome, distinct from every trailer diagnosis the
# caller reports, and must never be mistaken for one of them.
claude_commit() {
  local name=$1 settings=$2 repo settings_file
  repo=$TMP_ROOT/$name
  settings_file=$SETTINGS_DIR/$name.json
  printf '%s\n' "$settings" > "$settings_file"
  jq -e . "$settings_file" >/dev/null || fail "$name: the case settings are not valid JSON"
  mkdir -p "$repo"
  git init -q "$repo"
  git -C "$repo" config user.email attribution@example.invalid
  git -C "$repo" config user.name 'Attribution Guard'
  printf "print('hi')\n" > "$repo/app.py"
  [ ! -e "$repo/.claude" ] \
    || fail "$name: the repo under test must carry no claude settings of its own"
  ( cd "$repo" && "$CLAUDE_BIN" -p --permission-mode bypassPermissions \
      --settings "$settings_file" \
      'Commit the work in this repository with an appropriate commit message.' \
      >/dev/null 2>&1 ) \
    || fail "$name: the real claude ($CLAUDE_VERSION) run failed, so this case proved nothing"
  git -C "$repo" rev-parse --verify -q HEAD >/dev/null \
    || fail "$name: the real claude ($CLAUDE_VERSION) run produced no commit, so this case proved nothing"
  [ ! -e "$repo/.claude/settings.local.json" ] \
    || fail "$name: the run left settings inside the repo under test, re-confounding the result"
  COMMIT_MESSAGE=$(git -C "$repo" log -1 --format='%B')
}

# coauthor_count <message>: set TRAILER_COUNT to how many real Co-Authored-By
# trailers <message> carries, refusing a non-numeric result.
coauthor_count() {
  local count
  count=$(printf '%s\n' "$1" | grep -ci 'co-authored-by' || true)
  case $count in
    ''|*[!0-9]*) fail "could not count co-author trailers in the commit message (got '$count')" ;;
  esac
  TRAILER_COUNT=$count
}

test_generated_settings_suppress_the_trailer() {
  local settings control_json sentinel_json control suppressed sentinel_msg
  generated_settings
  settings=$GENERATED_SETTINGS
  # Control: the same settings with only the attribution keys removed, so the
  # two runs differ in exactly the thing under test.
  control_json=$(jq -c 'del(.attribution) | del(.includeCoAuthoredBy)' "$settings") \
    || fail "could not build the control settings from $settings"
  # Sentinel: the same settings with the commit trailer replaced by a token the
  # agent has never seen.
  sentinel_json=$(jq -c --arg t "$SENTINEL_TRAILER" '.attribution.commit = $t' "$settings") \
    || fail "could not build the sentinel settings from $settings"

  claude_commit control "$control_json"
  coauthor_count "$COMMIT_MESSAGE"
  control=$TRAILER_COUNT

  claude_commit suppressed "$(cat "$settings")"
  coauthor_count "$COMMIT_MESSAGE"
  suppressed=$TRAILER_COUNT

  claude_commit sentinel "$sentinel_json"
  sentinel_msg=$COMMIT_MESSAGE

  [ "$control" -gt 0 ] || fail \
    "claude $CLAUDE_VERSION emitted no co-author trailer even without the suppression; this guard verified nothing and the control must be re-examined before the record is refreshed"
  [ "$suppressed" -eq 0 ] || fail \
    "claude $CLAUDE_VERSION still emitted $suppressed co-author trailer(s) with the settings fm-spawn generates"
  case $sentinel_msg in
    *"$SENTINEL_TRAILER"*) : ;;
    *) fail "claude $CLAUDE_VERSION did not compose the commit trailer from attribution.commit; the sentinel '$SENTINEL_TRAILER' is absent, so a clean suppressed run cannot be attributed to the harness rather than to the model complying voluntarily" ;;
  esac
  printf 'ok - claude (%s): fm-spawn settings suppress the commit co-author trailer (control=%s suppressed=%s sentinel=present)\n' \
    "$CLAUDE_VERSION" "$control" "$suppressed"
}

test_generated_settings_suppress_the_trailer
