#!/usr/bin/env bash
# tests/fm-backend-herdr-project-secondmate-e2e.test.sh - mandatory ISOLATED
# end-to-end real-herdr test for the secondmate-routed leg of herdr's
# project-grouped workspace topology (docs/herdr-backend.md "Presentation
# spaces", config/herdr-presentation-spaces=project): when a registered
# secondmate's projects: list already covers the project being spawned into,
# placement reuses that secondmate's own live home-labeled workspace
# (2ndmate-<id>) instead of creating or reusing a separate proj-<name>
# workspace. Drives the REAL bin/fm-spawn.sh and bin/fm-teardown.sh, because
# the requirement under test only exists at fm-spawn.sh's herdr case arm and
# at fm-secondmate-registry-lib.sh's secondmate_registry_id_for_project; it is
# not exercised by tests/fm-backend-herdr-project-workspace-e2e.test.sh (no
# secondmate involved there) or by the per-home unit/adapter tests.
#
# Mirrors tests/fm-backend-herdr-project-workspace-e2e.test.sh's isolated-lab
# conventions: a private throwaway HERDR_SESSION (never the captain's
# default), a scratch FM_HOME, and scratch local-only projects.
#
# Safety (2026-07-02 incident, see tests/herdr-test-safety.sh): cleanup uses
# ONLY herdr_safe_stop_and_delete, never a bare/inline-prefixed `herdr server
# stop`.
#
# Covers, at minimum:
#   - with a registered secondmate whose projects: list names the project, a
#     primary-launched task's tab lands in that secondmate's OWN existing
#     home-labeled workspace, never a separate proj-<name> one, and no
#     project-workspace record is persisted for it
#   - a second primary-launched task for the SAME secondmate-covered project
#     converges on that same secondmate workspace too
#   - with no secondmate registered for a different project, placement is the
#     ordinary project-workspace behavior, unchanged (proj-<name> workspace,
#     persisted record) - the full behavior matrix for that ordinary path
#     stays owned by tests/fm-backend-herdr-project-workspace-e2e.test.sh
#   - the cross-home lock and cleanup-ownership invariants are unaffected: the
#     routed task's own metadata lives only in the PRIMARY's state/, tearing
#     it down needs only the PRIMARY's own overrides (never anything from the
#     secondmate's home), closes only that one tab, and leaves the
#     secondmate's own tab and the shared workspace untouched
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
assert_contains_local() {  # <haystack> <needle> <msg>
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3"$'\n'"--- got ---"$'\n'"$1" ;;
  esac
}

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found (required by fm-spawn.sh)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

# This suite runs against its own isolated lab session, so a Herdr pane
# inherited from the terminal it was launched in must not follow spawn into it
# as a cross-session parent identity (tests/herdr-test-safety.sh).
herdr_forget_inherited_pane

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-proj-sm-e2e.XXXXXX")
SESSION="fm-lab-herdr-proj-sm-e2e-$$"
export HERDR_SESSION="$SESSION"
WT_CM1=; WT_CM2=; WT_CM3=
cleanup_all() {
  [ -n "$WT_CM1" ] && command -v treehouse >/dev/null 2>&1 && treehouse return --force "$WT_CM1" >/dev/null 2>&1
  [ -n "$WT_CM2" ] && command -v treehouse >/dev/null 2>&1 && treehouse return --force "$WT_CM2" >/dev/null 2>&1
  [ -n "$WT_CM3" ] && command -v treehouse >/dev/null 2>&1 && treehouse return --force "$WT_CM3" >/dev/null 2>&1
  herdr_safe_stop_and_delete "$SESSION"
  rm -rf "$TMP_ROOT"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

# --- floor check: this leg reuses an already-live workspace exactly like the
# per-home lookup's own unconditional label search (docs/herdr-backend.md
# "Presentation spaces"), so it is NOT gated by the 0.8.0 project-grouping
# floor - it must behave identically on every release. Still measure this
# lab's real release so a below-floor run does not silently pass for the
# wrong reason. ---------------------------------------------------------

FLOOR_STATUS=$(fm_backend_herdr_cli "$SESSION" status --json 2>/dev/null) \
  || fail "could not read the lab session's herdr release"
FLOOR_VERSION=$(printf '%s' "$FLOOR_STATUS" | jq -r 'if .server.running then .server.version else .client.version end')
FLOOR_PROTOCOL=$(printf '%s' "$FLOOR_STATUS" | jq -r 'if .server.running then .server.protocol else .client.protocol end')
FLOOR_VERDICT=$(bash -c '
  . "$0/bin/backends/herdr.sh"
  status=0
  fm_backend_herdr_release_floor_verdict "$1" "$2" || status=$?
  printf "%s\n" "$status"
' "$ROOT" "$FLOOR_PROTOCOL" "$FLOOR_VERSION")
[ "$FLOOR_VERDICT" = 0 ] || [ "$FLOOR_VERDICT" = 1 ] \
  || fail "herdr $FLOOR_VERSION protocol $FLOOR_PROTOCOL could not be classified against the project-workspace floor"

# --- scratch world: one primary home opted into project grouping, one
# registered secondmate covering ONE of two scratch projects -----------------

PRIMARY_HOME="$TMP_ROOT/primary-home"
mkdir -p "$PRIMARY_HOME/state" "$PRIMARY_HOME/data/cm1" "$PRIMARY_HOME/data/cm2" "$PRIMARY_HOME/data/cm3" "$PRIMARY_HOME/config"
printf 'project\n' > "$PRIMARY_HOME/config/herdr-presentation-spaces"
for t in cm1 cm2 cm3; do
  cat > "$PRIMARY_HOME/data/$t/brief.md" <<EOF
# Task
## Captain's intent
Exercise herdr secondmate-routed project placement for $t.

## Firstmate spec
Verify the crewmate lands per the secondmate-routed placement rule.
EOF
done

SM_HOME="$TMP_ROOT/secondmate-home"
mkdir -p "$SM_HOME/state" "$SM_HOME/data/smtask" "$SM_HOME/config" "$SM_HOME/projects" "$SM_HOME/bin"
printf '# scratch secondmate home AGENTS.md placeholder\n' > "$SM_HOME/AGENTS.md"
printf 'e2esm1\n' > "$SM_HOME/.fm-secondmate-home"
printf 'trivial e2e secondmate charter: nothing to do.\n' > "$SM_HOME/data/charter.md"

make_scratch_project() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# scratch\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$dir" "$dir.origin.git"
  git -C "$dir" remote add origin "file://$dir.origin.git"
}

PROJ1="$TMP_ROOT/proj-alpha"; make_scratch_project "$PROJ1"   # covered by the secondmate
PROJ2="$TMP_ROOT/proj-beta"; make_scratch_project "$PROJ2"    # NOT covered - control case
PROJ1_NAME=$(basename "$PROJ1")
KEY1=$(fm_backend_herdr_project_key_for_path "$PROJ1") || fail "could not derive project alpha's project key"
KEY2=$(fm_backend_herdr_project_key_for_path "$PROJ2") || fail "could not derive project beta's project key"
BASENAME2=$(fm_backend_herdr_project_key_basename "$PROJ2") || fail "could not derive project beta's display basename"
PROJ2_LABEL="proj-$BASENAME2"
PROJ1_RECORD="$PRIMARY_HOME/state/proj-$KEY1.herdr-workspace"
PROJ2_RECORD="$PRIMARY_HOME/state/proj-$KEY2.herdr-workspace"

# The registry's projects: CSV deliberately carries extra whitespace and an
# unrelated second entry to exercise secondmate_registry_projects_contains's
# per-item trim, and never names project beta at all (the control case).
cat > "$PRIMARY_HOME/data/secondmates.md" <<EOF
- e2esm1 - trivial e2e secondmate charter (home: $SM_HOME; scope: everything; projects:  $PROJ1_NAME , some-other-project ; added 2026-09-20)
EOF

# --- 0. bring up the secondmate's own live home workspace first, exactly as
# the primary's --secondmate launch already does (AGENTS.md section 4/7) ----

SM_OUT="$TMP_ROOT/sm.out"; SM_ERR="$TMP_ROOT/sm.err"
FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" e2esm1 "$SM_HOME" "sh -c 'echo secondmate-launch-ok'" --secondmate --backend herdr \
  >"$SM_OUT" 2>"$SM_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "the primary's --secondmate spawn of e2esm1 failed"$'\n'"--- stdout ---"$'\n'"$(cat "$SM_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$SM_ERR")"
SM_META="$PRIMARY_HOME/state/e2esm1.meta"
[ -f "$SM_META" ] || fail "no meta written for e2esm1"
SM_PANE=$(grep '^herdr_pane_id=' "$SM_META" | cut -d= -f2-)
[ -n "$SM_PANE" ] || fail "e2esm1 meta missing herdr_pane_id"
SM_WSID=$(herdr pane get "$SM_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ -n "$SM_WSID" ] || fail "could not read e2esm1's pane workspace_id"
SM_WS_LABEL=$(herdr workspace list --session "$SESSION" 2>&1 | jq -r --arg id "$SM_WSID" '.result.workspaces[]? | select(.workspace_id == $id) | .label')
[ "$SM_WS_LABEL" = "2ndmate-e2esm1" ] || fail "e2esm1 should land in '2ndmate-e2esm1', got '$SM_WS_LABEL'"
pass "real herdr E2E: the secondmate's own home workspace is live before any routed placement is tested"

if [ "$FLOOR_VERDICT" != 0 ]; then
  # Below the 0.8.0 floor, only the ordinary project-workspace leg falls back
  # flat (docs/herdr-backend.md "Presentation spaces"); the secondmate-routed
  # leg has no floor at all, so it must still converge on the secondmate's
  # workspace even here. Cover that one assertion and stop - the rest of this
  # suite exercises the below-floor fallback of the ORDINARY leg, which
  # tests/fm-backend-herdr-project-workspace-e2e.test.sh already owns.
  CM1_OUT="$TMP_ROOT/cm1.out"; CM1_ERR="$TMP_ROOT/cm1.err"
  FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" cm1 "$PROJ1" "sh -c 'echo cm1-ok'" --mode no-mistakes --yolo off --backend herdr \
    >"$CM1_OUT" 2>"$CM1_ERR"
  rc=$?
  [ "$rc" -eq 0 ] || fail "cm1 spawn failed"$'\n'"--- stdout ---"$'\n'"$(cat "$CM1_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$CM1_ERR")"
  CM1_META="$PRIMARY_HOME/state/cm1.meta"
  WT_CM1=$(grep '^worktree=' "$CM1_META" | cut -d= -f2-)
  CM1_PANE=$(grep '^herdr_pane_id=' "$CM1_META" | cut -d= -f2-)
  CM1_WSID=$(herdr pane get "$CM1_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
  [ "$CM1_WSID" = "$SM_WSID" ] \
    || fail "below-floor herdr $FLOOR_VERSION: a secondmate-covered project should still route to the secondmate's workspace $SM_WSID, got '$CM1_WSID'"
  pass "real herdr E2E: secondmate-routed placement is unconditional (below-floor herdr $FLOOR_VERSION still converges)"
  fm_backend_herdr_kill "$SESSION:$CM1_PANE"
  fm_backend_herdr_kill "$SESSION:$SM_PANE"
  cleanup_all
  trap - EXIT
  exit 0
fi

# --- 1. a primary-launched task for the SECONDMATE-COVERED project lands in
# the secondmate's own workspace, never a separate proj-<name> one ----------

CM1_OUT="$TMP_ROOT/cm1.out"; CM1_ERR="$TMP_ROOT/cm1.err"
FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" cm1 "$PROJ1" "sh -c 'echo cm1-ok'" --mode no-mistakes --yolo off --backend herdr \
  >"$CM1_OUT" 2>"$CM1_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "cm1 spawn failed"$'\n'"--- stdout ---"$'\n'"$(cat "$CM1_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$CM1_ERR")"
CM1_META="$PRIMARY_HOME/state/cm1.meta"
[ -f "$CM1_META" ] || fail "no meta written for cm1"
WT_CM1=$(grep '^worktree=' "$CM1_META" | cut -d= -f2-)
CM1_PANE=$(grep '^herdr_pane_id=' "$CM1_META" | cut -d= -f2-)
[ -n "$CM1_PANE" ] || fail "cm1 meta missing herdr_pane_id"
[ ! -e "$PRIMARY_HOME/state/cm1.herdr-presentation" ] \
  || fail "a project-grouped task must never get a per-task presentation journal"
pass "real herdr E2E: cm1 (secondmate-covered project) spawns successfully"

sleep 1
CM1_CAPTURE=$(fm_backend_herdr_capture "$SESSION:$CM1_PANE" 30) || fail "capture failed on cm1's pane"
assert_contains_local "$CM1_CAPTURE" "cm1-ok" "cm1's raw launch command did not run in its herdr pane"

CM1_WSID=$(herdr pane get "$CM1_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ -n "$CM1_WSID" ] || fail "could not read cm1's pane workspace_id"
[ "$CM1_WSID" = "$SM_WSID" ] \
  || fail "cm1 (project alpha, covered by e2esm1) should land in e2esm1's workspace $SM_WSID, got '$CM1_WSID'"
[ ! -f "$PROJ1_RECORD" ] \
  || fail "a secondmate-routed spawn must never persist a project-workspace record: $PROJ1_RECORD"
pass "real herdr E2E: cm1 lands in the covering secondmate's OWN workspace, never a separate project workspace, and persists no project record"

# --- 2. a SECOND primary-launched task for the same covered project also
# converges on the secondmate's workspace, not a fresh one of its own -------

CM3_OUT="$TMP_ROOT/cm3.out"; CM3_ERR="$TMP_ROOT/cm3.err"
FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" cm3 "$PROJ1" "sh -c 'echo cm3-ok'" --mode no-mistakes --yolo off --backend herdr \
  >"$CM3_OUT" 2>"$CM3_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "cm3 spawn failed"$'\n'"--- stdout ---"$'\n'"$(cat "$CM3_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$CM3_ERR")"
CM3_META="$PRIMARY_HOME/state/cm3.meta"
[ -f "$CM3_META" ] || fail "no meta written for cm3"
WT_CM3=$(grep '^worktree=' "$CM3_META" | cut -d= -f2-)
CM3_PANE=$(grep '^herdr_pane_id=' "$CM3_META" | cut -d= -f2-)
[ -n "$CM3_PANE" ] || fail "cm3 meta missing herdr_pane_id"
CM3_WSID=$(herdr pane get "$CM3_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ "$CM3_WSID" = "$SM_WSID" ] \
  || fail "cm3, a second task for the same covered project, should also land in e2esm1's workspace $SM_WSID, got '$CM3_WSID'"
pass "real herdr E2E: a second task for the same secondmate-covered project converges on the same secondmate workspace"

# --- 3. a project with NO covering secondmate keeps the ordinary
# project-workspace behavior, unchanged --------------------------------------

CM2_OUT="$TMP_ROOT/cm2.out"; CM2_ERR="$TMP_ROOT/cm2.err"
FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" cm2 "$PROJ2" "sh -c 'echo cm2-ok'" --mode no-mistakes --yolo off --backend herdr \
  >"$CM2_OUT" 2>"$CM2_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "cm2 spawn failed"$'\n'"--- stdout ---"$'\n'"$(cat "$CM2_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$CM2_ERR")"
CM2_META="$PRIMARY_HOME/state/cm2.meta"
[ -f "$CM2_META" ] || fail "no meta written for cm2"
WT_CM2=$(grep '^worktree=' "$CM2_META" | cut -d= -f2-)
CM2_PANE=$(grep '^herdr_pane_id=' "$CM2_META" | cut -d= -f2-)
[ -n "$CM2_PANE" ] || fail "cm2 meta missing herdr_pane_id"
CM2_WSID=$(herdr pane get "$CM2_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ -n "$CM2_WSID" ] || fail "could not read cm2's pane workspace_id"
[ "$CM2_WSID" != "$SM_WSID" ] \
  || fail "project beta (no covering secondmate) must NOT land in e2esm1's workspace"
CM2_WS_LABEL=$(herdr workspace list --session "$SESSION" 2>&1 | jq -r --arg id "$CM2_WSID" '.result.workspaces[]? | select(.workspace_id == $id) | .label')
[ "$CM2_WS_LABEL" = "$PROJ2_LABEL" ] || fail "cm2 should land in its own project workspace '$PROJ2_LABEL', got '$CM2_WS_LABEL'"
[ -f "$PROJ2_RECORD" ] || fail "no persisted project-workspace record at $PROJ2_RECORD for the uncovered project"
assert_contains_local "$(cat "$PROJ2_RECORD")" "workspace_id=$CM2_WSID" "project-beta record missing its own workspace id"
pass "real herdr E2E: a project with no covering secondmate keeps the ordinary project-workspace behavior, unchanged"

# --- 4. cross-home invariants: tearing down cm1 (the secondmate-routed task)
# needs only the PRIMARY's own overrides, closes only its own tab, and never
# touches the secondmate's own tab or its shared workspace ------------------

TD1_OUT="$TMP_ROOT/td1.out"
FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$PRIMARY_HOME/state" FM_DATA_OVERRIDE="$PRIMARY_HOME/data" \
  FM_CONFIG_OVERRIDE="$PRIMARY_HOME/config" \
  "$ROOT/bin/fm-teardown.sh" cm1 >"$TD1_OUT" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "fm-teardown.sh failed for cm1 (PRIMARY-only overrides, no reference to the secondmate's home)"$'\n'"$(cat "$TD1_OUT")"
WT_CM1=
[ ! -e "$CM1_META" ] || fail "cm1's own metadata should have been retired by its teardown"
[ ! -e "$SM_HOME/state/cm1.meta" ] \
  || fail "cm1 must never have any metadata in the secondmate's own state/; it is the primary's task throughout"
if herdr workspace list --session "$SESSION" 2>/dev/null | jq -e --arg id "$SM_WSID" '.result.workspaces[]? | select(.workspace_id == $id)' >/dev/null 2>&1; then
  : # cm3's tab and e2esm1's own tab both keep the shared workspace alive - expected.
else
  fail "tearing down cm1 must not remove the shared secondmate workspace - cm3 and e2esm1's own tab still occupy it"
fi
if ! herdr pane get "$SM_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "tearing down cm1 must not have closed the secondmate's OWN pane"
fi
if ! herdr pane get "$CM3_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "tearing down cm1 must not have closed cm3's pane (same shared workspace, wrong tab closed)"
fi
pass "real herdr E2E: tearing down the secondmate-routed cm1 uses only the primary's own overrides, closes only its own tab, and leaves the secondmate's own tab and shared workspace untouched"

fm_backend_herdr_kill "$SESSION:$CM2_PANE"
fm_backend_herdr_kill "$SESSION:$CM3_PANE"
fm_backend_herdr_kill "$SESSION:$SM_PANE"

cleanup_all
trap - EXIT
