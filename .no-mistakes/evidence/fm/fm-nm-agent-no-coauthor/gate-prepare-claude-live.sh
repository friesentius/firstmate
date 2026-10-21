#!/usr/bin/env bash
# Live agent path: real Claude Code CLI (machine's normal login, project
# settings disabled like the gate's disable_project_settings) commits inside a
# disposable gate-emulated run worktree, once without and once with prepare.
set -u
SRC=$1
T=$(mktemp -d "${TMPDIR:-/tmp}/nm-gate-claude.XXXXXX")
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
git clone -q --bare "$SRC" "$T/gate.git"; G="$T/gate.git"
git -C "$G" config --unset core.bare; git -C "$G" config extensions.worktreeConfig true
PREP=$(awk '/^commands:/{c=1;next} c&&/^  prepare: \|/{p=1;next} p&&/^  [a-z]/{exit} p{sub(/^    /,"");print}' "$SRC/.no-mistakes.yaml")
for r in baseline prepared; do
  git -C "$G" worktree add -q --detach "$T/$r" HEAD
  git -C "$T/$r" config --worktree core.hooksPath "$G/hooks"
  git -C "$T/$r" config user.name gate-agent; git -C "$T/$r" config user.email agent@example.invalid
  [ "$r" = prepared ] && (cd "$T/$r" && sh -c "$PREP") && echo "[$r] prepare ran, hooksPath=$(git -C "$T/$r" config --get core.hooksPath)"
  (cd "$T/$r" && env -u NO_MISTAKES_GATE claude -p < /dev/null --setting-sources user --allowedTools 'Bash(git:*),Bash(echo:*),Edit,Write' --permission-mode acceptEdits \
    "Append the line 'ci repair' to the end of README.md, then stage it and create a git commit with the subject 'fix(ci): repair check' whose message body ends with the exact trailer line 'Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>' (use git commit -F with a heredoc or file). Do not push. Reply only with the commit sha." ) 2>&1 | tail -3 | sed "s/^/[$r] claude: /"
  echo "[$r] resulting commit message:"; git -C "$T/$r" log -1 --format='%B' | sed 's/^/  | /'
done
git -C "$G" worktree remove --force "$T/prepared"; echo "teardown of prepared run worktree exit=$?"
