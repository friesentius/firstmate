#!/usr/bin/env bash
# Disposable emulation of a no-mistakes gate mirror: bare repo with
# extensions.worktreeConfig, run worktrees with core.hooksPath pinned per
# worktree to the mirror's hooks dir (as `no-mistakes init` does). Runs the
# commands.prepare block exactly as written in .no-mistakes.yaml (via sh -c,
# from the run worktree), then exercises commits, isolation, rerun, teardown.
set -u
SRC=$1          # the change's worktree
MODE=${2:-new}  # new | nochmod (prepare with the chmod line removed, the pre-fix variant)
T=$(mktemp -d "${TMPDIR:-/tmp}/nm-gate-e2e.XXXXXX")
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
step() { printf '\n=== %s\n' "$*"; }
git clone -q --bare "$SRC" "$T/gate.git"
G="$T/gate.git"
git -C "$G" config --unset core.bare  # real gate mirror config carries no core.bare (see its config)
git -C "$G" config extensions.worktreeConfig true
printf '#!/bin/sh\nexit 0\n' > "$G/hooks/pre-receive"; chmod +x "$G/hooks/pre-receive"
HEADSHA=$(git -C "$SRC" rev-parse HEAD)
for r in runA runB; do
  git -C "$G" worktree add -q --detach "$T/$r" "$HEADSHA"
  git -C "$T/$r" config --worktree core.hooksPath "$G/hooks"
  git -C "$T/$r" config user.name gate-agent; git -C "$T/$r" config user.email agent@example.invalid
done
# extract commands.prepare literal block from the real config file
PREP=$(awk '/^commands:/{c=1;next} c&&/^  prepare: \|/{p=1;next} p&&/^  [a-z]/{exit} p{sub(/^    /,"");print}' "$SRC/.no-mistakes.yaml")
[ "$MODE" = nochmod ] && PREP=$(printf '%s\n' "$PREP" | grep -v 'chmod u+w')
step "commands.prepare as executed ($MODE)"; printf '%s\n' "$PREP"
cfg_before=$(sha256sum "$G/config")
step "run prepare in runA (sh -c, cwd=run worktree)"
(cd "$T/runA" && sh -c "$PREP"); echo "prepare exit=$?"
step "runA effective core.hooksPath"; git -C "$T/runA" config --show-origin --get-all core.hooksPath
ls -ld "$(git -C "$T/runA" rev-parse --git-dir)/fm-no-coauthor-hooks"
step "S1 agent commit in runA with AI + human co-author trailers"
cd "$T/runA"; echo change >> README.md; git add README.md
git commit -q -F - <<'M'
fix(ci): repair flaky check

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Co-authored-by: Jane Human <jane@example.com>
M
echo "commit exit=$?"; git log -1 --format='%B' | sed 's/^/  | /'
step "S2 isolation: shared mirror config unchanged, sibling runB untouched"
[ "$cfg_before" = "$(sha256sum "$G/config")" ] && echo "shared config: UNCHANGED" || echo "shared config: CHANGED"
git -C "$T/runB" config --show-origin --get-all core.hooksPath
cd "$T/runB"; echo change >> README.md; git add README.md
git commit -q -m "other lane" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git log -1 --format='%B' | sed 's/^/  | /'
step "S3 prepare rerun in runA is idempotent"
(cd "$T/runA" && sh -c "$PREP"); echo "rerun exit=$?"
cd "$T/runA"; echo again >> README.md; git add README.md
git commit -q -m "second" -m "Co-authored-by: Cursor Agent <cursoragent@cursor.com>"; git log -1 --format='%B' | sed 's/^/  | /'
step "S4 run teardown: git worktree remove --force runA, then prune"
git -C "$G" worktree remove --force "$T/runA"; echo "worktree remove exit=$?"
git -C "$G" worktree prune; echo "prune exit=$?"
echo "remaining worktree metadata:"; ls "$G/worktrees" 2>&1
git -C "$G" worktree list
