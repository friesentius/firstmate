#!/usr/bin/env bash
# fm-commit-attribution-scan.sh - fail when a commit message in a range carries
# an agent co-author trailer.
#
# AGENTS.md section 1: "Never add an agent name as a commit co-author." A local
# git commit-msg hook can strip that trailer deterministically, but it only
# runs on the machine that makes the commit: `git commit --no-verify`, an
# interactive rebase, or `git filter-branch` can all land a commit with the
# trailer intact and no hook in the path to catch it. This script re-checks
# the commit messages actually reaching a PR, independent of how they got
# there, from two server-side surfaces neither of which a contributor's own
# checkout controls:
#
#   - .github/workflows/ci.yml's "Commit attribution" job, given the pull
#     request's exact base and head SHAs by the pull_request event. Since
#     GitHub runs a pull_request-triggered job's own DEFINITION from the PR's
#     branch (not the base branch), pinning this script's content does not
#     pin the CI job's existence: a PR could still remove or alter the job in
#     ci.yml itself, and this repo currently has no branch protection
#     requiring any CI job to pass before merge. That is a real, structural
#     gap shared by every job in this workflow, not specific to this script.
#   - .no-mistakes.yaml's commands.lint, chained after bin/fm-lint.sh.
#     kunchenguid/no-mistakes's repo-config reference documents that
#     commands.* is read only from the repository's trusted default-branch
#     copy of .no-mistakes.yaml, never from a pushed branch, so once this
#     lands on main a contributor cannot weaken or remove it from their PR.
#
# Neither surface runs this script as it exists in the checkout under
# validation: both fetch this script's content from the trusted base ref
# (`git show <base-sha>:bin/fm-commit-attribution-scan.sh`) into a temp file
# and execute that instead, so a PR cannot defeat the check by editing its own
# copy of this script (for example to `exit 0`). When the base ref predates
# this script's existence (true only until this first lands on the default
# branch), both surfaces fall back to the working-tree copy with a visible
# warning, since there is no trusted copy to fetch yet. This still leaves the
# ci.yml job-definition gap above: fetching the script content raises the bar
# from "edit one obscure regex" to "edit or delete a whole CI job," which is a
# more conspicuous change for review to catch, but it does not close the gap.
#
# no-mistakes has no generic custom-gate/step hook as of this writing (only
# named steps, with commands.{test,lint,format} letting you override a named
# step's own command) - see that same repo-config reference. Reusing
# commands.lint is the closest fit and the only one available without an
# undocumented, unverified config key.
#
# Only known agent-vendor addresses are matched in a `Co-Authored-By:`
# trailer, never every such trailer, so a legitimate human co-author survives.
# Extend FM_AGENT_COAUTHOR_ADDRESSES (space- or newline-separated) with
# evidence when another harness is verified to emit one. A value that resolves
# to zero addresses after word-splitting (unset, empty, or whitespace-only) is
# refused with a nonzero exit rather than silently scanning nothing and
# reporting a clean pass.
#
# Known limitation: a PR that never reaches either surface above (for example
# one opened by a route that skips both CI and the no-mistakes gate) is not
# covered. AGENTS.md's "Require no-mistakes" workflow already requires every
# non-bot PR to carry a no-mistakes pipeline attestation, and CI itself runs
# on every pull_request event, so this is believed to cover all real PRs, but
# nothing on this script's side proves that requirement stays wired up.
#
# Usage:
#   fm-commit-attribution-scan.sh                scan this branch's commits
#                                                 since its merge-base with
#                                                 origin/main (or local main)
#   fm-commit-attribution-scan.sh <base> <head>   scan exactly <base>..<head>;
#                                                 both must be resolvable
#                                                 commit-ishes. <base> is used
#                                                 as given, with no merge-base
#                                                 recomputation, so a caller
#                                                 that already knows the exact
#                                                 PR base SHA (CI) gets exactly
#                                                 that range.
#   fm-commit-attribution-scan.sh --help          print this usage
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/fm-commit-attribution-scan.sh"

# Deliberately no `cd` to this script's own repo root: unlike fm-lint.sh (which
# always lints firstmate's own canonical file set), this script's git commands
# must operate on whatever repository the caller's working directory is in -
# the real target in CI and the no-mistakes pipeline, and a throwaway fixture
# repo in tests.
fm_cas_usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$SELF"
}

case "${1:-}" in
  --help|-h)
    fm_cas_usage
    exit 0
    ;;
esac

FM_AGENT_COAUTHOR_ADDRESSES=${FM_AGENT_COAUTHOR_ADDRESSES:-noreply@anthropic.com}

# Word-splitting FM_AGENT_COAUTHOR_ADDRESSES is the intended way to accept a
# space- or newline-separated address list.
AGENT_ADDRESSES=()
# shellcheck disable=SC2086
for address in $FM_AGENT_COAUTHOR_ADDRESSES; do
  [ -n "$address" ] || continue
  AGENT_ADDRESSES+=("$address")
done

if [ "${#AGENT_ADDRESSES[@]}" -eq 0 ]; then
  printf 'fm-commit-attribution-scan.sh: FM_AGENT_COAUTHOR_ADDRESSES resolved to zero addresses after word-splitting; refusing to scan with an empty match list instead of silently reporting a clean pass.\n' >&2
  exit 2
fi

fm_cas_escape_ere() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//./\\.}
  s=${s//\*/\\*}
  s=${s//^/\\^}
  s=${s//\$/\\$}
  s=${s//(/\\(}
  s=${s//)/\\)}
  s=${s//+/\\+}
  s=${s//\?/\\?}
  s=${s//\{/\\\{}
  s=${s//\}/\\\}}
  s=${s//|/\\|}
  s=${s//[/\\[}
  s=${s//]/\\]}
  printf '%s' "$s"
}

if [ "$#" -eq 0 ]; then
  if git rev-parse --verify -q origin/main >/dev/null 2>&1; then
    base_ref=origin/main
  elif git rev-parse --verify -q main >/dev/null 2>&1; then
    base_ref=main
  else
    printf 'fm-commit-attribution-scan.sh: could not resolve origin/main or main to diff against.\n' >&2
    exit 2
  fi
  head_ref=HEAD
  range_start=$(git merge-base "$base_ref" "$head_ref" 2>/dev/null) || {
    printf 'fm-commit-attribution-scan.sh: could not find a merge base between %s and %s.\n' \
      "$base_ref" "$head_ref" >&2
    exit 2
  }
elif [ "$#" -eq 2 ]; then
  range_start=$1
  head_ref=$2
  git rev-parse --verify -q "$range_start" >/dev/null 2>&1 || {
    printf 'fm-commit-attribution-scan.sh: base %s is not a resolvable commit.\n' "$range_start" >&2
    exit 2
  }
  git rev-parse --verify -q "$head_ref" >/dev/null 2>&1 || {
    printf 'fm-commit-attribution-scan.sh: head %s is not a resolvable commit.\n' "$head_ref" >&2
    exit 2
  }
else
  printf 'usage: fm-commit-attribution-scan.sh [<base> <head>]\n' >&2
  exit 2
fi

COMMITS=()
while IFS= read -r sha; do
  [ -n "$sha" ] || continue
  COMMITS+=("$sha")
done < <(git rev-list "$range_start..$head_ref" 2>/dev/null)

if [ "${#COMMITS[@]}" -eq 0 ]; then
  printf 'fm-commit-attribution-scan.sh: no commits in range %s..%s\n' "$range_start" "$head_ref"
  exit 0
fi

overall_rc=0
checked=0
for sha in "${COMMITS[@]}"; do
  checked=$((checked + 1))
  msg=$(git log -1 --format=%B "$sha" 2>/dev/null) || continue
  for address in "${AGENT_ADDRESSES[@]}"; do
    match=$(printf '%s\n' "$msg" \
      | grep -iE "^[[:space:]]*Co-Authored-By:.*<$(fm_cas_escape_ere "$address")>[[:space:]]*\$") || continue
    subject=$(git log -1 --format=%s "$sha" 2>/dev/null)
    printf 'fm-commit-attribution-scan.sh: agent co-author trailer in %s (%s): %s\n' \
      "$(git rev-parse --short "$sha")" "$subject" "$match" >&2
    overall_rc=1
  done
done

if [ "$overall_rc" -eq 0 ]; then
  printf 'fm-commit-attribution-scan.sh: no agent co-author trailers found in %s commit(s) (%s..%s)\n' \
    "$checked" "$range_start" "$head_ref"
else
  printf 'fm-commit-attribution-scan.sh: AGENTS.md section 1 forbids an agent name as a commit co-author. Remove the trailer(s) above (for example with git commit --amend or an interactive rebase) and update the branch.\n' >&2
fi

exit "$overall_rc"
