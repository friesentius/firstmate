#!/usr/bin/env bash
# tests/fm-backend-herdr-project-workspace-e2e.test.sh - mandatory ISOLATED
# end-to-end real-herdr test for herdr's project-grouped workspace topology
# (docs/herdr-backend.md "Project workspace grouping",
# config/herdr-presentation-spaces=project). Drives the REAL bin/fm-spawn.sh
# and bin/fm-teardown.sh, because the requirement under test - two tasks for
# the SAME project sharing one persistent workspace, a different project
# getting its own, and that workspace self-healing after it drains to zero
# tasks - only exists at fm-spawn.sh's herdr case arm and at
# fm_backend_herdr_project_workspace_ensure's create-or-adopt logic; neither
# is exercised by the adapter-primitive unit tests.
#
# Mirrors tests/fm-backend-herdr-workspace-per-home-e2e.test.sh's isolated-lab
# conventions: a private throwaway HERDR_SESSION (never the captain's
# default), a scratch FM_HOME, and scratch local-only projects.
#
# Safety (2026-07-02 incident, see tests/herdr-test-safety.sh): cleanup uses
# ONLY herdr_safe_stop_and_delete, never a bare/inline-prefixed `herdr server
# stop`.
#
# Covers, at minimum:
#   - two tasks for the same project land in the SAME project workspace, and
#     no per-task presentation journal is ever created for them
#   - a different project gets its OWN, distinct workspace
#   - the persisted per-project record (state/proj-<key>.herdr-workspace)
#     is written with the exact fields fm_backend_herdr_project_workspace_ensure
#     promises
#   - tearing down the project's last task removes the whole workspace, and
#     the record's live-verification then self-heals on the next spawn for
#     that same project (fresh workspace, record rewritten) rather than
#     erroring or reusing the stale id
#   - a pre-existing, unrelated workspace that happens to carry the exact
#     label a project's own container would use is never adopted - unlike the
#     per-home label lookup, project-grouped placement trusts only its own
#     persisted, live-verified record, never a bare label search
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

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-proj-e2e.XXXXXX")
SESSION="fm-lab-herdr-proj-e2e-$$"
export HERDR_SESSION="$SESSION"
WT1=; WT2=; WT3=; WT4=
cleanup_all() {
  [ -n "$WT1" ] && command -v treehouse >/dev/null 2>&1 && treehouse return --force "$WT1" >/dev/null 2>&1
  [ -n "$WT2" ] && command -v treehouse >/dev/null 2>&1 && treehouse return --force "$WT2" >/dev/null 2>&1
  [ -n "$WT3" ] && command -v treehouse >/dev/null 2>&1 && treehouse return --force "$WT3" >/dev/null 2>&1
  [ -n "$WT4" ] && command -v treehouse >/dev/null 2>&1 && treehouse return --force "$WT4" >/dev/null 2>&1
  herdr_safe_stop_and_delete "$SESSION"
  rm -rf "$TMP_ROOT"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

# --- scratch world: one home opted into project grouping, two projects -----

PRIMARY_HOME="$TMP_ROOT/primary-home"
mkdir -p "$PRIMARY_HOME/state" "$PRIMARY_HOME/data/cm1" "$PRIMARY_HOME/data/cm2" \
  "$PRIMARY_HOME/data/cm3" "$PRIMARY_HOME/data/cm4" "$PRIMARY_HOME/config"
printf 'project\n' > "$PRIMARY_HOME/config/herdr-presentation-spaces"
for t in cm1 cm2 cm3 cm4; do
  cat > "$PRIMARY_HOME/data/$t/brief.md" <<EOF
# Task
## Captain's intent
Exercise herdr project-grouped placement for $t.

## Firstmate spec
Verify the crewmate lands in its project's shared workspace.
EOF
done

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

PROJ1="$TMP_ROOT/proj-alpha"; make_scratch_project "$PROJ1"
PROJ2="$TMP_ROOT/proj-beta"; make_scratch_project "$PROJ2"
PROJ1_LABEL="proj-$(basename "$PROJ1")"
PROJ2_LABEL="proj-$(basename "$PROJ2")"
PROJ1_RECORD="$PRIMARY_HOME/state/$PROJ1_LABEL.herdr-workspace"
PROJ2_RECORD="$PRIMARY_HOME/state/$PROJ2_LABEL.herdr-workspace"

# --- 0. a pre-existing, unrelated workspace already carries PROJ2's own
# label. Project-grouped placement must never adopt it by label search alone
# (the exact incident class tests/fm-backend-herdr-prune-safety-e2e.test.sh
# fixes for the per-home path) - it only trusts its own persisted record. ---

fm_backend_herdr_server_ensure "$SESSION" || fail "could not ensure the isolated lab session's herdr server"
DECOY_OUT=$(herdr workspace create --cwd "$TMP_ROOT" --label "$PROJ2_LABEL" --no-focus --session "$SESSION" 2>&1) \
  || fail "could not create the decoy label-colliding workspace"$'\n'"$DECOY_OUT"
DECOY_WSID=$(printf '%s' "$DECOY_OUT" | jq -r '.result.workspace.workspace_id // empty')
[ -n "$DECOY_WSID" ] || fail "decoy workspace create returned no workspace_id"

# --- 1. two tasks for the SAME project (PROJ1) share one workspace ---------

CM1_OUT="$TMP_ROOT/cm1.out"; CM1_ERR="$TMP_ROOT/cm1.err"
FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" cm1 "$PROJ1" "sh -c 'echo cm1-ok'" --mode no-mistakes --yolo off --backend herdr \
  >"$CM1_OUT" 2>"$CM1_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "cm1 spawn failed"$'\n'"--- stdout ---"$'\n'"$(cat "$CM1_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$CM1_ERR")"
CM1_META="$PRIMARY_HOME/state/cm1.meta"
[ -f "$CM1_META" ] || fail "no meta written for cm1"
WT1=$(grep '^worktree=' "$CM1_META" | cut -d= -f2-)
CM1_PANE=$(grep '^herdr_pane_id=' "$CM1_META" | cut -d= -f2-)
[ -n "$CM1_PANE" ] || fail "cm1 meta missing herdr_pane_id"
[ ! -e "$PRIMARY_HOME/state/cm1.herdr-presentation" ] \
  || fail "a project-grouped task must never get a per-task presentation journal"
pass "real herdr E2E: project grouping spawns cm1 into project alpha's shared workspace"

sleep 1
CM1_CAPTURE=$(fm_backend_herdr_capture "$SESSION:$CM1_PANE" 30) || fail "capture failed on cm1's pane"
assert_contains_local "$CM1_CAPTURE" "cm1-ok" "cm1's raw launch command did not run in its herdr pane"

CM1_WSID=$(herdr pane get "$CM1_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ -n "$CM1_WSID" ] || fail "could not read cm1's pane workspace_id"
CM1_WS_LABEL=$(herdr workspace list --session "$SESSION" 2>&1 | jq -r --arg id "$CM1_WSID" '.result.workspaces[]? | select(.workspace_id == $id) | .label')
[ "$CM1_WS_LABEL" = "$PROJ1_LABEL" ] || fail "cm1 should land in '$PROJ1_LABEL', got '$CM1_WS_LABEL'"
[ -f "$PROJ1_RECORD" ] || fail "no persisted project-workspace record at $PROJ1_RECORD"
assert_contains_local "$(cat "$PROJ1_RECORD")" "project=$(basename "$PROJ1")" "project record missing its project key"
assert_contains_local "$(cat "$PROJ1_RECORD")" "home=$PRIMARY_HOME" "project record missing its home"
assert_contains_local "$(cat "$PROJ1_RECORD")" "session=$SESSION" "project record missing its session"
assert_contains_local "$(cat "$PROJ1_RECORD")" "workspace_id=$CM1_WSID" "project record missing its workspace id"
assert_contains_local "$(cat "$PROJ1_RECORD")" "label=$PROJ1_LABEL" "project record missing its label"
pass "real herdr E2E: cm1 landed in the persisted project-alpha workspace with a correct record"

CM2_OUT="$TMP_ROOT/cm2.out"; CM2_ERR="$TMP_ROOT/cm2.err"
FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" cm2 "$PROJ1" "sh -c 'echo cm2-ok'" --mode no-mistakes --yolo off --backend herdr \
  >"$CM2_OUT" 2>"$CM2_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "cm2 spawn failed"$'\n'"--- stdout ---"$'\n'"$(cat "$CM2_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$CM2_ERR")"
CM2_META="$PRIMARY_HOME/state/cm2.meta"
[ -f "$CM2_META" ] || fail "no meta written for cm2"
WT2=$(grep '^worktree=' "$CM2_META" | cut -d= -f2-)
CM2_PANE=$(grep '^herdr_pane_id=' "$CM2_META" | cut -d= -f2-)
[ -n "$CM2_PANE" ] || fail "cm2 meta missing herdr_pane_id"
CM2_WSID=$(herdr pane get "$CM2_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ "$CM2_WSID" = "$CM1_WSID" ] || fail "cm2 (same project as cm1) must share cm1's workspace $CM1_WSID, got '$CM2_WSID'"
pass "real herdr E2E: cm2, a second task for the SAME project, lands in cm1's own shared workspace"

# --- 2. a different project (PROJ2) gets its own distinct workspace, never
# the pre-existing decoy that happens to carry the same label -------------

CM3_OUT="$TMP_ROOT/cm3.out"; CM3_ERR="$TMP_ROOT/cm3.err"
FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" cm3 "$PROJ2" "sh -c 'echo cm3-ok'" --mode no-mistakes --yolo off --backend herdr \
  >"$CM3_OUT" 2>"$CM3_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "cm3 spawn failed"$'\n'"--- stdout ---"$'\n'"$(cat "$CM3_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$CM3_ERR")"
CM3_META="$PRIMARY_HOME/state/cm3.meta"
[ -f "$CM3_META" ] || fail "no meta written for cm3"
WT3=$(grep '^worktree=' "$CM3_META" | cut -d= -f2-)
CM3_PANE=$(grep '^herdr_pane_id=' "$CM3_META" | cut -d= -f2-)
[ -n "$CM3_PANE" ] || fail "cm3 meta missing herdr_pane_id"
CM3_WSID=$(herdr pane get "$CM3_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ -n "$CM3_WSID" ] || fail "could not read cm3's pane workspace_id"
[ "$CM3_WSID" != "$CM1_WSID" ] || fail "project beta's task must not land in project alpha's workspace"
[ "$CM3_WSID" != "$DECOY_WSID" ] || fail "project-grouped placement adopted a pre-existing label-colliding workspace instead of creating its own - the exact class of incident this design avoids"
[ -f "$PROJ2_RECORD" ] || fail "no persisted project-workspace record at $PROJ2_RECORD"
assert_contains_local "$(cat "$PROJ2_RECORD")" "workspace_id=$CM3_WSID" "project-beta record missing its own workspace id"
pass "real herdr E2E: project beta gets its own workspace, never the pre-existing decoy sharing its label"

# --- 3. tearing down project alpha's tasks removes the shared workspace once
# it drains to zero, and the next spawn for that project self-heals ---------

TD1_OUT="$TMP_ROOT/td1.out"
FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$PRIMARY_HOME/state" FM_DATA_OVERRIDE="$PRIMARY_HOME/data" \
  FM_CONFIG_OVERRIDE="$PRIMARY_HOME/config" \
  "$ROOT/bin/fm-teardown.sh" cm1 >"$TD1_OUT" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "fm-teardown.sh failed for cm1"$'\n'"$(cat "$TD1_OUT")"
if herdr workspace list --session "$SESSION" 2>/dev/null | jq -e --arg id "$CM1_WSID" '.result.workspaces[]? | select(.workspace_id == $id)' >/dev/null 2>&1; then
  : # cm2's tab keeps the shared workspace alive - expected.
else
  fail "tearing down cm1 (not the project's last task) must not remove the shared workspace"
fi
if ! herdr pane get "$CM2_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "tearing down cm1 must not have closed cm2's pane (same shared workspace, wrong tab closed)"
fi
WT1=
pass "real herdr E2E: tearing down cm1 leaves project alpha's still-populated workspace and cm2 untouched"

TD2_OUT="$TMP_ROOT/td2.out"
FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$PRIMARY_HOME/state" FM_DATA_OVERRIDE="$PRIMARY_HOME/data" \
  FM_CONFIG_OVERRIDE="$PRIMARY_HOME/config" \
  "$ROOT/bin/fm-teardown.sh" cm2 >"$TD2_OUT" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "fm-teardown.sh failed for cm2"$'\n'"$(cat "$TD2_OUT")"
WT2=
if herdr workspace list --session "$SESSION" 2>/dev/null | jq -e --arg id "$CM1_WSID" '.result.workspaces[]? | select(.workspace_id == $id)' >/dev/null 2>&1; then
  fail "tearing down cm2 (project alpha's LAST task) should have removed the drained shared workspace $CM1_WSID"
fi
pass "real herdr E2E: tearing down cm2, project alpha's last task, removes the drained shared workspace"

CM4_OUT="$TMP_ROOT/cm4.out"; CM4_ERR="$TMP_ROOT/cm4.err"
FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" cm4 "$PROJ1" "sh -c 'echo cm4-ok'" --mode no-mistakes --yolo off --backend herdr \
  >"$CM4_OUT" 2>"$CM4_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "cm4 (re-spawn into a drained project) failed"$'\n'"--- stdout ---"$'\n'"$(cat "$CM4_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$CM4_ERR")"
CM4_META="$PRIMARY_HOME/state/cm4.meta"
[ -f "$CM4_META" ] || fail "no meta written for cm4"
WT4=$(grep '^worktree=' "$CM4_META" | cut -d= -f2-)
CM4_PANE=$(grep '^herdr_pane_id=' "$CM4_META" | cut -d= -f2-)
[ -n "$CM4_PANE" ] || fail "cm4 meta missing herdr_pane_id"
CM4_WSID=$(herdr pane get "$CM4_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ -n "$CM4_WSID" ] || fail "could not read cm4's pane workspace_id"
[ "$CM4_WSID" != "$CM1_WSID" ] || fail "cm4 must get a FRESH workspace, not the stale removed id $CM1_WSID"
CM4_WS_LABEL=$(herdr workspace list --session "$SESSION" 2>&1 | jq -r --arg id "$CM4_WSID" '.result.workspaces[]? | select(.workspace_id == $id) | .label')
[ "$CM4_WS_LABEL" = "$PROJ1_LABEL" ] || fail "the self-healed project-alpha workspace should still be labeled '$PROJ1_LABEL', got '$CM4_WS_LABEL'"
assert_contains_local "$(cat "$PROJ1_RECORD")" "workspace_id=$CM4_WSID" "project-alpha record was not rewritten to the self-healed workspace id"
pass "real herdr E2E: a spawn into a drained project self-heals with a fresh workspace and a rewritten record"

# --- 4. project beta's workspace was never touched by any of the above -----

if ! herdr pane get "$CM3_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "project beta's pane must have survived project alpha's teardown/respawn churn"
fi
CM3_WSID_AFTER=$(herdr pane get "$CM3_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ "$CM3_WSID_AFTER" = "$CM3_WSID" ] || fail "project beta's workspace id must not change from unrelated project-alpha churn"
pass "real herdr E2E: project beta's workspace and task were never affected by project alpha's teardown/self-heal"

fm_backend_herdr_kill "$SESSION:$CM3_PANE"
fm_backend_herdr_kill "$SESSION:$CM4_PANE"
herdr workspace delete "$DECOY_WSID" --session "$SESSION" >/dev/null 2>&1 || true

cleanup_all
trap - EXIT
