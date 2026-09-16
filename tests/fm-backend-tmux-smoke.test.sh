#!/usr/bin/env bash
# tests/fm-backend-tmux-smoke.test.sh - real tmux smoke test for the tmux
# session-provider adapter (bin/backends/tmux.sh), the P1 checklist item
# "run a real tmux smoke test (create session, send text + Enter, capture,
# list, kill)" from data/fm-backend-design-d7/report.md. Every other suite in
# this repo fakes tmux; this one is the one place that talks to a REAL tmux
# server, isolated on a private socket (`-L`) so it never touches the host's
# actual sessions.
#
# It also pins the ordered multi-key delivery fm_backend_tmux_send_key gives
# fm-send.sh's --key path, which .agents/skills/harness-adapters/references/
# harness/claude.md's Claude trust-dialog recipe depends on: a real two-option
# arrow-menu stand-in process (no Claude harness needed) proves that a bare
# Enter confirms whatever is highlighted by default while Down then Enter
# lands on the second option, so the two sequences provably diverge.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

wait_for_capture_text() {  # <target> <text> [samples]
  local target=$1 text=$2 samples=${3:-100} out i=0
  while [ "$i" -lt "$samples" ]; do
    out=$(fm_backend_tmux_capture "$target" 200 2>/dev/null || true)
    case "$out" in
      *"$text"*) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-backend-smoke-$$"
SHIM_DIR=
trap cleanup_all EXIT

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${SHIM_DIR:-}" ] && rm -rf "$SHIM_DIR"
}

# A `tmux` shim on PATH that transparently redirects every call to the private
# socket, so bin/backends/tmux.sh's bare `tmux ...` invocations never touch the
# host's real sessions.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-backend-smoke.XXXXXX")
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

SESSION="smoke"
WINDOW="fm-smoke1"
TARGET="$SESSION:$WINDOW"

# --- create session ----------------------------------------------------------

tmux new-session -d -s "$SESSION" -x 200 -y 50 \
  || fail "real tmux: new-session failed"
fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" \
  || fail "fm_backend_tmux_create_task failed to create the task window"
tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "$WINDOW" \
  || fail "created window is not visible in the real session"

# A second create for the SAME window name must refuse (mirrors fm-spawn.sh's
# duplicate-window guard).
if fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" 2>/dev/null; then
  fail "fm_backend_tmux_create_task should refuse an existing window name"
fi
pass "real tmux: fm_backend_tmux_create_task creates a window and refuses a duplicate"

# --- send text + Enter -------------------------------------------------------

# A newly-created interactive shell can exist before its startup files and line
# editor are ready to accept Enter. Prove command execution with an output token
# that does not appear contiguously in the command, retrying the harmless probe
# until the shell acknowledges it.
SHELL_READY=false
for _ in $(seq 1 100); do
  tmux send-keys -t "$TARGET" C-c
  tmux send-keys -t "$TARGET" -l "printf 'shell-%s\\n' ready"
  tmux send-keys -t "$TARGET" Enter
  if wait_for_capture_text "$TARGET" "shell-ready" 10; then
    SHELL_READY=true
    break
  fi
done
[ "$SHELL_READY" = true ] || fail "the tmux task shell did not become ready"

tmux send-keys -t "$TARGET" "cd /tmp && PS1='smoke\$ ' && clear && printf 'setup-%s\\n' ready" Enter
wait_for_capture_text "$TARGET" "setup-ready" || fail "the tmux task shell did not complete setup"

fm_backend_tmux_send_text_line "$TARGET" "printf 'captain-on-deck-%s\\n' line" \
  || fail "fm_backend_tmux_send_text_line failed"
wait_for_capture_text "$TARGET" "captain-on-deck-line" \
  || fail "fm_backend_tmux_send_text_line did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_text_line"
case "$out" in
  *captain-on-deck-line*) : ;;
  *) fail "real tmux: fm_backend_tmux_send_text_line did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_text_line sends literal text and submits with Enter"

# --- send_literal + send_key(Enter), the two-step form fm-spawn.sh uses for the
# harness launch command (literal send, settle, then a separate Enter) --------

fm_backend_tmux_send_literal "$TARGET" "printf 'literal-then-key-%s\\n' captain" \
  || fail "fm_backend_tmux_send_literal failed"
fm_backend_tmux_send_key "$TARGET" Enter || fail "fm_backend_tmux_send_key Enter failed"
wait_for_capture_text "$TARGET" "literal-then-key-captain" \
  || fail "fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_literal+send_key"
case "$out" in
  *literal-then-key-captain*) : ;;
  *) fail "real tmux: send_literal + send_key(Enter) did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter submit as two separate steps"

# --- capture bounds -----------------------------------------------------------
# Print enough numbered lines to overflow the pane's visible height, then
# confirm a small capture window (-S -N) surfaces only the RECENT tail (the
# earliest lines scroll out of a small window) while a large one reaches back
# far enough to still see the earliest line - the same -S -N bounding fm-peek.sh
# and fm-watch.sh rely on for a bounded, cheap pane read.
fm_backend_tmux_send_text_line "$TARGET" "for i in \$(seq 1 80); do echo tag-line-\$i; done"
wait_for_capture_text "$TARGET" "tag-line-80" \
  || fail "the numbered output did not complete before capture"
small=$(fm_backend_tmux_capture "$TARGET" 3) || fail "fm_backend_tmux_capture (small window) failed"
case "$small" in
  *tag-line-1$'\n'*) fail "a 3-line capture should not still see the very first numbered line"$'\n'"$small" ;;
esac
case "$small" in
  *tag-line-80*) : ;;
  *) fail "a 3-line capture should still contain the most recent output"$'\n'"$small" ;;
esac
large=$(fm_backend_tmux_capture "$TARGET" 200) || fail "fm_backend_tmux_capture (large window) failed"
case "$large" in
  *tag-line-1$'\n'*) : ;;
  *) fail "a 200-line capture should reach back far enough to see the first numbered line"$'\n'"$large" ;;
esac
pass "real tmux: fm_backend_tmux_capture's -S -N bound trims old history for a small window and reaches it for a large one"

# --- resolve_bare_selector (live-window-listing) -----------------------------

resolved=$(fm_backend_tmux_resolve_bare_selector "$WINDOW") \
  || fail "fm_backend_tmux_resolve_bare_selector failed to find the live window"
[ "$resolved" = "$TARGET" ] || fail "fm_backend_tmux_resolve_bare_selector resolved to '$resolved', expected '$TARGET'"
pass "real tmux: fm_backend_tmux_resolve_bare_selector (list-live) finds the created window by name"

if fm_backend_tmux_resolve_bare_selector "no-such-window-xyz" 2>/dev/null; then
  fail "fm_backend_tmux_resolve_bare_selector should fail for a nonexistent window"
fi
pass "real tmux: fm_backend_tmux_resolve_bare_selector fails for a window that does not exist"

# --- kill and recovery-grade missing-window classification ------------------

fm_backend_tmux_kill "$TARGET"
if tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$WINDOW"; then
  fail "fm_backend_tmux_kill did not remove the window"
fi
state=$(fm_backend_agent_state tmux "$TARGET")
[ "$state" = missing ] \
  || fail "a real missing window in a readable session should classify as missing, got '$state'"
# Best-effort contract: killing an already-gone window must not error.
fm_backend_tmux_kill "$TARGET" || fail "fm_backend_tmux_kill on an already-dead target must stay best-effort (never fail)"
pass "real tmux: kill removes the window and the readable session inventory authoritatively classifies it missing"

# --- fm_backend_tmux_send_key: ordered multi-key delivery to a real process --

command -v python3 >/dev/null 2>&1 || fail "python3 is required for the ordered-key-delivery check"
MENU_PY="$SHIM_DIR/menu.py"
cat > "$MENU_PY" <<'PY'
#!/usr/bin/env python3
import sys, termios, tty

options = ["wrong", "right"]
idx = 0

def render():
    for i, o in enumerate(options):
        sys.stdout.write("%s %s\r\n" % ('>' if i == idx else ' ', o))
    sys.stdout.flush()

fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
tty.setraw(fd)
render()
try:
    while True:
        ch = sys.stdin.read(1)
        if ch == '\x1b':
            ch2 = sys.stdin.read(1)
            if ch2 in ('[', 'O'):
                ch3 = sys.stdin.read(1)
                if ch3 == 'B':
                    idx = (idx + 1) % len(options)
                elif ch3 == 'A':
                    idx = (idx - 1) % len(options)
            render()
        elif ch in ('\r', '\n'):
            termios.tcsetattr(fd, termios.TCSADRAIN, old)
            sys.stdout.write("CONFIRMED:%s\r\n" % options[idx])
            sys.stdout.flush()
            break
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
PY
chmod +x "$MENU_PY"

MENU_WIN1="fm-smoke-menu1"
MENU_TARGET1="$SESSION:$MENU_WIN1"
tmux new-window -d -t "$SESSION:" -n "$MENU_WIN1" -- bash -c "python3 '$MENU_PY'; sleep 5" \
  || fail "could not launch the ordered-key-delivery menu stub"
wait_for_capture_text "$MENU_TARGET1" "> wrong" || fail "menu stub did not render its default-highlighted state"

fm_backend_tmux_send_key "$MENU_TARGET1" Enter || fail "fm_backend_tmux_send_key Enter (bare) failed"
wait_for_capture_text "$MENU_TARGET1" "CONFIRMED:" || fail "bare Enter did not confirm a choice"
out=$(fm_backend_tmux_capture "$MENU_TARGET1" 20) || fail "fm_backend_tmux_capture failed after bare Enter"
case "$out" in
  *CONFIRMED:wrong*) : ;;
  *) fail "bare Enter should confirm the default-highlighted (wrong) option, got:"$'\n'"$out" ;;
esac
fm_backend_tmux_kill "$MENU_TARGET1"
pass "real tmux: fm_backend_tmux_send_key(Enter) alone confirms the default-highlighted option"

MENU_WIN2="fm-smoke-menu2"
MENU_TARGET2="$SESSION:$MENU_WIN2"
tmux new-window -d -t "$SESSION:" -n "$MENU_WIN2" -- bash -c "python3 '$MENU_PY'; sleep 5" \
  || fail "could not launch the second ordered-key-delivery menu stub"
wait_for_capture_text "$MENU_TARGET2" "> wrong" || fail "second menu stub did not render its default-highlighted state"
fm_backend_tmux_send_key "$MENU_TARGET2" Down || fail "fm_backend_tmux_send_key Down failed"
wait_for_capture_text "$MENU_TARGET2" "> right" || fail "Down did not move the highlight to the second option"
fm_backend_tmux_send_key "$MENU_TARGET2" Enter || fail "fm_backend_tmux_send_key Enter (after Down) failed"
wait_for_capture_text "$MENU_TARGET2" "CONFIRMED:" || fail "Enter after Down did not confirm a choice"
out=$(fm_backend_tmux_capture "$MENU_TARGET2" 20) || fail "fm_backend_tmux_capture failed after Down+Enter"
case "$out" in
  *CONFIRMED:right*) : ;;
  *) fail "Down then Enter should confirm the second option, got:"$'\n'"$out" ;;
esac
fm_backend_tmux_kill "$MENU_TARGET2"
pass "real tmux: fm_backend_tmux_send_key(Down) then send_key(Enter) confirms the second option, distinguishing it from bare Enter"

cleanup_all
trap - EXIT
