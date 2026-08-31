#!/usr/bin/env bash
# Firstmate's git hook proxy, installed into a task worktree by
# bin/fm-git-hook-install.sh and reached through that worktree's own
# core.hooksPath.
#
# Two jobs, in this order:
#   1. Run the project's own hook of the same name, if it has one, unchanged.
#      Overriding core.hooksPath replaces the whole hooks directory, so without
#      this a project's husky or lint-staged hooks would silently stop running.
#      The project's hook keeps its exit status: a non-zero result still aborts
#      the operation exactly as it would with no proxy in place.
#   2. For commit-msg only, strip agent co-author trailers from the message.
#      AGENTS.md section 1 forbids adding an agent name as a commit co-author,
#      and the harness setting that suppresses them is prompt-mediated, so it
#      reduces but does not eliminate them (docs/verification/runtime-backends.md
#      records the measured leak). This strip is the deterministic backstop.
#
# The hook name comes from $0, so one script serves every proxied hook.
# Usage: invoked by git, never by hand.
set -u

HOOK_NAME=$(basename -- "$0")
PROXY_DIR="$(cd "$(dirname -- "$0")" && pwd)"
ORIGINAL_RECORD="$PROXY_DIR/original-hooks-dir"

# Delegate first so a project hook that rejects the commit still rejects it,
# and so its edits to the message file are what this proxy then strips.
if [ -f "$ORIGINAL_RECORD" ]; then
  ORIGINAL_DIR=$(cat "$ORIGINAL_RECORD" 2>/dev/null || true)
  if [ -n "$ORIGINAL_DIR" ] && [ "$ORIGINAL_DIR" != "$PROXY_DIR" ]; then
    ORIGINAL_HOOK="$ORIGINAL_DIR/$HOOK_NAME"
    if [ -x "$ORIGINAL_HOOK" ] && [ ! -d "$ORIGINAL_HOOK" ]; then
      "$ORIGINAL_HOOK" "$@" || exit $?
    fi
  fi
fi

[ "$HOOK_NAME" = commit-msg ] || exit 0

MSG_FILE=${1:-}
[ -n "$MSG_FILE" ] && [ -f "$MSG_FILE" ] || exit 0

# Only agent trailers are stripped. A human co-author is legitimate and must
# survive, so this matches the agent addresses firstmate's own harnesses sign
# with rather than every Co-Authored-By line. Extend this list together with
# evidence when another harness is verified to emit one.
FM_AGENT_COAUTHOR_ADDRESSES=${FM_AGENT_COAUTHOR_ADDRESSES:-noreply@anthropic.com}

STRIPPED="$MSG_FILE.fm-stripped.$$"
cp -- "$MSG_FILE" "$STRIPPED" || exit 0
for address in $FM_AGENT_COAUTHOR_ADDRESSES; do
  # Anchored on the trailer form so prose mentioning the address is untouched.
  grep -viE "^[[:space:]]*Co-Authored-By:.*<${address//./\\.}>[[:space:]]*$" \
    "$STRIPPED" > "$STRIPPED.next" 2>/dev/null || true
  [ -f "$STRIPPED.next" ] && mv -- "$STRIPPED.next" "$STRIPPED"
done

if ! cmp -s -- "$MSG_FILE" "$STRIPPED"; then
  cat -- "$STRIPPED" > "$MSG_FILE"
fi
rm -f -- "$STRIPPED" "$STRIPPED.next"
exit 0
