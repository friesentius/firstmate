#!/usr/bin/env bash
# Contract tests for bin/fm-commit-attribution-scan.sh, the server-side
# backstop for AGENTS.md section 1's "never add an agent name as a commit
# co-author" rule (wired in from .github/workflows/ci.yml's "Commit
# attribution" job and .no-mistakes.yaml's commands.lint).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCAN="$ROOT/bin/fm-commit-attribution-scan.sh"

# fm_cas_repo <dir>: init a repo at <dir> on branch "main" with one commit, a
# fixed deterministic identity, and no host git config dependency (an explicit
# rename off whatever the host's init.defaultBranch happens to be).
fm_cas_repo() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" checkout -qb main
  fm_git_identity
  printf 'one\n' > "$dir/f.txt"
  git -C "$dir" add f.txt
  git -C "$dir" commit -q -m initial
}

test_clean_commits_pass() {
  local tmp
  tmp=$(fm_test_tmproot fm-cas-clean)
  fm_cas_repo "$tmp"
  git -C "$tmp" checkout -qb feature
  printf 'two\n' >> "$tmp/f.txt"
  git -C "$tmp" add f.txt
  git -C "$tmp" commit -q -m "ordinary change"

  local rc=0 out
  out=$(cd "$tmp" && "$SCAN" main feature 2>&1) || rc=$?
  expect_code 0 "$rc" "clean range exits 0"
  assert_contains "$out" "no agent co-author trailers found" \
    "clean range did not report a clean result"
  pass "a clean commit range passes"
}

test_agent_trailer_fails() {
  local tmp
  tmp=$(fm_test_tmproot fm-cas-bad)
  fm_cas_repo "$tmp"
  git -C "$tmp" checkout -qb feature
  printf 'two\n' >> "$tmp/f.txt"
  git -C "$tmp" add f.txt
  git -C "$tmp" commit -q -m "$(printf 'bad commit\n\nCo-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>\n')"

  local rc=0 out sha
  sha=$(git -C "$tmp" rev-parse --short HEAD)
  out=$(cd "$tmp" && "$SCAN" main feature 2>&1) || rc=$?
  expect_code 1 "$rc" "agent co-author trailer exits 1"
  assert_contains "$out" "$sha" "failure did not name the offending commit"
  assert_contains "$out" "noreply@anthropic.com" "failure did not quote the trailer"
  assert_contains "$out" "AGENTS.md section 1" "failure did not point at the rule it enforces"
  pass "a commit with an agent co-author trailer fails and names it"
}

test_lowercase_trailer_label_matches() {
  local tmp
  tmp=$(fm_test_tmproot fm-cas-lower)
  fm_cas_repo "$tmp"
  git -C "$tmp" checkout -qb feature
  printf 'two\n' >> "$tmp/f.txt"
  git -C "$tmp" add f.txt
  git -C "$tmp" commit -q -m "$(printf 'bad commit\n\nCo-authored-by: Claude <noreply@anthropic.com>\n')"

  local rc=0
  (cd "$tmp" && "$SCAN" main feature) >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "lowercase trailer label still matches"
  pass "the trailer label match is case-insensitive"
}

test_human_coauthor_survives() {
  local tmp
  tmp=$(fm_test_tmproot fm-cas-human)
  fm_cas_repo "$tmp"
  git -C "$tmp" checkout -qb feature
  printf 'two\n' >> "$tmp/f.txt"
  git -C "$tmp" add f.txt
  git -C "$tmp" commit -q -m "$(printf 'pair programmed\n\nCo-authored-by: Jane Human <jane@example.com>\n')"

  local rc=0 out
  out=$(cd "$tmp" && "$SCAN" main feature 2>&1) || rc=$?
  expect_code 0 "$rc" "a human co-author must not fail the scan"
  assert_contains "$out" "no agent co-author trailers found" \
    "human co-author range did not report a clean result"
  pass "a legitimate human co-author trailer survives"
}

test_prose_mention_does_not_false_positive() {
  local tmp
  tmp=$(fm_test_tmproot fm-cas-prose)
  fm_cas_repo "$tmp"
  git -C "$tmp" checkout -qb feature
  printf 'two\n' >> "$tmp/f.txt"
  git -C "$tmp" add f.txt
  git -C "$tmp" commit -q -m "$(printf 'docs: mention the vendor address\n\nnoreply@anthropic.com appears here as prose, not as a trailer.\n')"

  local rc=0
  (cd "$tmp" && "$SCAN" main feature) >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "prose mentioning the address must not fail the scan"
  pass "an address mentioned in prose (not a trailer) does not false-positive"
}

test_custom_address_list() {
  local tmp
  tmp=$(fm_test_tmproot fm-cas-custom)
  fm_cas_repo "$tmp"
  git -C "$tmp" checkout -qb feature
  printf 'two\n' >> "$tmp/f.txt"
  git -C "$tmp" add f.txt
  git -C "$tmp" commit -q -m "$(printf 'bad commit\n\nCo-Authored-By: Some Other Agent <noreply@example-vendor.invalid>\n')"

  local rc=0 out
  # Not in the default list: must pass without the override.
  out=$(cd "$tmp" && "$SCAN" main feature 2>&1) || rc=$?
  expect_code 0 "$rc" "an address outside the default list must not fail by default"

  rc=0
  out=$(cd "$tmp" && FM_AGENT_COAUTHOR_ADDRESSES='noreply@anthropic.com noreply@example-vendor.invalid' \
    "$SCAN" main feature 2>&1) || rc=$?
  expect_code 1 "$rc" "FM_AGENT_COAUTHOR_ADDRESSES did not extend the match list"
  assert_contains "$out" "noreply@example-vendor.invalid" \
    "failure did not quote the custom-listed address"
  pass "FM_AGENT_COAUTHOR_ADDRESSES extends the matched address list"
}

test_whitespace_only_address_list_fails_closed() {
  local tmp
  tmp=$(fm_test_tmproot fm-cas-whitespace-addrs)
  fm_cas_repo "$tmp"
  git -C "$tmp" checkout -qb feature
  printf 'two\n' >> "$tmp/f.txt"
  git -C "$tmp" add f.txt
  git -C "$tmp" commit -q -m "$(printf 'bad commit\n\nCo-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>\n')"

  local rc=0 out
  out=$(cd "$tmp" && FM_AGENT_COAUTHOR_ADDRESSES=' ' "$SCAN" main feature 2>&1) || rc=$?
  expect_code 2 "$rc" "a whitespace-only address list must fail closed, not pass silently"
  assert_contains "$out" "zero addresses" \
    "whitespace-only address list did not name the zero-addresses cause"
  case "$out" in
    *"no agent co-author trailers found"*)
      fail "whitespace-only address list must never report a clean pass, even with a real agent trailer present"
      ;;
  esac
  pass "a whitespace-only FM_AGENT_COAUTHOR_ADDRESSES fails closed instead of scanning nothing"
}

test_unresolvable_base_fails_closed() {
  local tmp
  tmp=$(fm_test_tmproot fm-cas-unresolvable)
  fm_cas_repo "$tmp"

  local rc=0 out
  out=$(cd "$tmp" && "$SCAN" no-such-ref main 2>&1) || rc=$?
  expect_code 2 "$rc" "an unresolvable base must fail closed, not pass silently"
  assert_contains "$out" "is not a resolvable commit" \
    "unresolvable base did not report a clear diagnostic"
  pass "an unresolvable base ref fails closed with a clear diagnostic"
}

test_empty_range_is_a_clean_pass() {
  local tmp
  tmp=$(fm_test_tmproot fm-cas-empty)
  fm_cas_repo "$tmp"

  local rc=0 out
  out=$(cd "$tmp" && "$SCAN" main main 2>&1) || rc=$?
  expect_code 0 "$rc" "an empty range must pass"
  assert_contains "$out" "no commits in range" \
    "an empty range did not report itself explicitly (silent no-op)"
  pass "an empty commit range reports itself explicitly and passes"
}

test_no_args_mode_uses_local_main_merge_base() {
  local tmp
  tmp=$(fm_test_tmproot fm-cas-noargs)
  fm_cas_repo "$tmp"
  git -C "$tmp" checkout -qb feature
  printf 'two\n' >> "$tmp/f.txt"
  git -C "$tmp" add f.txt
  git -C "$tmp" commit -q -m "$(printf 'bad commit\n\nCo-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>\n')"

  local rc=0 out
  out=$(cd "$tmp" && "$SCAN" 2>&1) || rc=$?
  expect_code 1 "$rc" "no-args mode did not use the local main merge-base"
  assert_contains "$out" "noreply@anthropic.com" \
    "no-args mode did not scan the commit carrying the trailer"
  pass "no-args mode auto-detects the range against local main"
}

test_help_prints_usage() {
  local out rc=0
  out=$("$SCAN" --help 2>&1) || rc=$?
  expect_code 0 "$rc" "--help must exit 0"
  assert_contains "$out" "Usage:" "--help did not print a usage block"
  pass "--help prints usage and exits 0"
}

test_upstream_sync_ref_excludes_upstream_commit_but_still_scans_a_later_fork_commit() {
  local tmp
  tmp=$(fm_test_tmproot fm-cas-sync-fork-after)
  fm_cas_repo "$tmp"
  git -C "$tmp" checkout -qb upstream
  printf 'up\n' >> "$tmp/f.txt"
  git -C "$tmp" add f.txt
  git -C "$tmp" commit -q -m "upstream work"
  local upstream_sha
  upstream_sha=$(git -C "$tmp" rev-parse HEAD)
  git -C "$tmp" checkout -q main
  git -C "$tmp" merge -q --no-ff -m "Merge upstream" upstream
  printf 'fork\n' >> "$tmp/f.txt"
  git -C "$tmp" add f.txt
  git -C "$tmp" commit -q -m "$(printf 'fork change\n\nCo-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>\n')"
  local fork_sha
  fork_sha=$(git -C "$tmp" rev-parse --short HEAD)
  local initial_sha
  initial_sha=$(git -C "$tmp" rev-parse "main~2")

  local rc=0 out
  out=$(cd "$tmp" && FM_UPSTREAM_SYNC_REF="$upstream_sha" "$SCAN" "$initial_sha" main 2>&1) || rc=$?
  expect_code 1 "$rc" "a fork commit after a merged upstream commit must still fail"
  assert_contains "$out" "$fork_sha" "failure did not name the fork commit"
  case "$out" in
    *"$(git -C "$tmp" rev-parse --short "$upstream_sha")"*)
      fail "the excluded upstream commit must not be named in the failure output"
      ;;
  esac
  pass "FM_UPSTREAM_SYNC_REF excludes the upstream commit while a later fork commit with a trailer still fails"
}

test_upstream_sync_ref_excludes_a_trailer_already_carried_by_upstream() {
  local tmp
  tmp=$(fm_test_tmproot fm-cas-sync-upstream-trailer)
  fm_cas_repo "$tmp"
  git -C "$tmp" checkout -qb upstream
  printf 'up\n' >> "$tmp/f.txt"
  git -C "$tmp" add f.txt
  git -C "$tmp" commit -q -m "$(printf 'upstream agent commit\n\nCo-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>\n')"
  local upstream_sha
  upstream_sha=$(git -C "$tmp" rev-parse HEAD)
  git -C "$tmp" checkout -q main
  git -C "$tmp" merge -q --no-ff -m "Merge upstream" upstream
  local initial_sha
  initial_sha=$(git -C "$tmp" rev-parse "main~1")

  local rc=0 out
  out=$(cd "$tmp" && "$SCAN" "$initial_sha" main 2>&1) || rc=$?
  expect_code 1 "$rc" "without the exclusion, the upstream commit's own trailer must still fail the scan"

  rc=0
  out=$(cd "$tmp" && FM_UPSTREAM_SYNC_REF="$upstream_sha" "$SCAN" "$initial_sha" main 2>&1) || rc=$?
  expect_code 0 "$rc" "with the exclusion, a trailer already carried by the excluded upstream commit must pass"
  assert_contains "$out" "no agent co-author trailers found in 1 commit(s) ($initial_sha..main, excluding commits reachable from upstream $upstream_sha)" \
    "the exclusion did not report a clean result naming the exclusion"
  pass "a legitimate upstream-reachable commit with a trailer is excluded only when FM_UPSTREAM_SYNC_REF names it"
}

test_upstream_sync_ref_still_scans_a_merged_side_branch_fork_commit() {
  local tmp
  tmp=$(fm_test_tmproot fm-cas-sync-side-branch)
  fm_cas_repo "$tmp"
  local initial_sha
  initial_sha=$(git -C "$tmp" rev-parse HEAD)

  git -C "$tmp" checkout -qb upstream
  printf 'up\n' >> "$tmp/f.txt"
  git -C "$tmp" add f.txt
  git -C "$tmp" commit -q -m "unrelated upstream work"
  local upstream_sha
  upstream_sha=$(git -C "$tmp" rev-parse HEAD)

  git -C "$tmp" checkout -q main
  git -C "$tmp" checkout -qb side
  printf 'side\n' >> "$tmp/f.txt"
  git -C "$tmp" add f.txt
  git -C "$tmp" commit -q -m "$(printf 'side-branch change\n\nCo-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>\n')"
  local side_sha
  side_sha=$(git -C "$tmp" rev-parse --short HEAD)
  git -C "$tmp" checkout -q main
  git -C "$tmp" merge -q --no-ff -m "Merge side branch" side

  local rc=0 out
  out=$(cd "$tmp" && FM_UPSTREAM_SYNC_REF="$upstream_sha" "$SCAN" "$initial_sha" main 2>&1) || rc=$?
  expect_code 1 "$rc" "a fork commit landed on a merged side branch must still fail, not be skipped like --first-parent would"
  assert_contains "$out" "$side_sha" "failure did not name the side-branch fork commit"
  pass "FM_UPSTREAM_SYNC_REF does not hide a fork commit on a merged side branch (non-first-parent scan)"
}

test_upstream_sync_ref_unresolvable_warns_and_scans_full_range() {
  local tmp
  tmp=$(fm_test_tmproot fm-cas-sync-unresolvable)
  fm_cas_repo "$tmp"
  git -C "$tmp" checkout -qb feature
  printf 'two\n' >> "$tmp/f.txt"
  git -C "$tmp" add f.txt
  git -C "$tmp" commit -q -m "ordinary change"

  local rc=0 out
  out=$(cd "$tmp" && FM_UPSTREAM_SYNC_REF='no-such-upstream-ref' "$SCAN" main feature 2>&1) || rc=$?
  expect_code 0 "$rc" "an unresolvable FM_UPSTREAM_SYNC_REF alone must not fail a clean range"
  assert_contains "$out" "warning: FM_UPSTREAM_SYNC_REF=no-such-upstream-ref is not a resolvable commit" \
    "an unresolvable ref did not print a clear warning"
  assert_contains "$out" "no agent co-author trailers found in 1 commit(s) (main..feature)" \
    "an unresolvable ref did not scan the full range"

  git -C "$tmp" commit -q --allow-empty -m "$(printf 'bad commit\n\nCo-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>\n')"
  rc=0
  out=$(cd "$tmp" && FM_UPSTREAM_SYNC_REF='no-such-upstream-ref' "$SCAN" main feature 2>&1) || rc=$?
  expect_code 1 "$rc" "an unresolvable FM_UPSTREAM_SYNC_REF must still fail on a trailer in the full range"
  pass "FM_UPSTREAM_SYNC_REF set to an unresolvable ref warns and scans the full range"
}

test_upstream_sync_ref_excluding_every_commit_says_so() {
  local tmp
  tmp=$(fm_test_tmproot fm-cas-sync-all-excluded)
  fm_cas_repo "$tmp"
  local initial_sha
  initial_sha=$(git -C "$tmp" rev-parse HEAD)
  printf 'up\n' >> "$tmp/f.txt"
  git -C "$tmp" add f.txt
  git -C "$tmp" commit -q -m "upstream work"
  local upstream_sha
  upstream_sha=$(git -C "$tmp" rev-parse HEAD)

  local rc=0 out
  out=$(cd "$tmp" && FM_UPSTREAM_SYNC_REF="$upstream_sha" "$SCAN" "$initial_sha" main 2>&1) || rc=$?
  expect_code 0 "$rc" "a range fully excluded as upstream-reachable is a clean pass"
  assert_contains "$out" "no commits in range $initial_sha..main, excluding commits reachable from upstream $upstream_sha" \
    "a fully excluded range was not distinguishable from an empty one"
  pass "a range fully excluded as upstream-reachable names the exclusion"
}

# fm_cas_lint_repo <dir>: a fixture whose main carries a stub bin/fm-lint.sh
# and the real scan script, so .no-mistakes.yaml's commands.lint can run in it
# against a trusted base copy, plus a feature branch checked out on top.
fm_cas_lint_repo() {
  local dir=$1
  fm_cas_repo "$dir"
  mkdir -p "$dir/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/bin/fm-lint.sh"
  cp "$SCAN" "$dir/bin/fm-commit-attribution-scan.sh"
  chmod +x "$dir/bin/fm-lint.sh" "$dir/bin/fm-commit-attribution-scan.sh"
  git -C "$dir" add bin
  git -C "$dir" commit -q -m "add lint scripts"
  git -C "$dir" checkout -qb feature
}

# fm_cas_run_lint <dir> <upstream-url>: run the parsed commands.lint in <dir>
# with the upstream fetch URL rewritten to <upstream-url>, so no test touches
# the network.
fm_cas_run_lint() {
  local dir=$1 upstream_url=$2 lint
  lint=$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0])["commands"]["lint"]' "$ROOT/.no-mistakes.yaml") \
    || fail "failed to parse commands.lint from .no-mistakes.yaml"
  (cd "$dir" && GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0="url.$upstream_url.insteadOf" \
    GIT_CONFIG_VALUE_0="https://github.com/kunchenguid/firstmate.git" \
    bash -c "$lint" 2>&1)
}

test_lint_upstream_fetch_failure_warns_and_scans_full_range() {
  command -v ruby >/dev/null 2>&1 || fail "ruby is required to parse .no-mistakes.yaml"
  local tmp
  tmp=$(fm_test_tmproot fm-cas-lint-fetch-fail)
  fm_cas_lint_repo "$tmp"
  git -C "$tmp" commit -q --allow-empty -m "ordinary change"
  git -C "$tmp" commit -q --allow-empty -m "second ordinary change"

  local rc=0 out
  out=$(fm_cas_run_lint "$tmp" "file://$tmp/no-such-upstream") || rc=$?
  expect_code 0 "$rc" "an upstream fetch failure alone must not fail lint"
  assert_contains "$out" "warning: could not fetch kunchenguid/firstmate main" \
    "an upstream fetch failure did not print a clear warning"
  assert_contains "$out" "no agent co-author trailers found in 2 commit(s)" \
    "an upstream fetch failure did not scan every commit in the range"
  assert_not_contains "$out" "excluding commits reachable from upstream" \
    "an upstream fetch failure must not apply any exclusion"

  git -C "$tmp" commit -q --allow-empty -m "$(printf 'bad commit\n\nCo-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>\n')"
  rc=0
  out=$(fm_cas_run_lint "$tmp" "file://$tmp/no-such-upstream") || rc=$?
  expect_code 1 "$rc" "an upstream fetch failure must still fail lint on a trailer"
  pass "commands.lint warns and scans the full range when the upstream fetch fails"
}

test_lint_upstream_fetch_success_applies_exclusion() {
  command -v ruby >/dev/null 2>&1 || fail "ruby is required to parse .no-mistakes.yaml"
  local tmp
  tmp=$(fm_test_tmproot fm-cas-lint-fetch-ok)
  fm_cas_lint_repo "$tmp"
  git -C "$tmp" checkout -qb upstream-src main
  git -C "$tmp" commit -q --allow-empty -m "$(printf 'upstream agent commit\n\nCo-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>\n')"
  local upstream_sha
  upstream_sha=$(git -C "$tmp" rev-parse HEAD)
  git clone -q --bare "$tmp" "$tmp/upstream.git"
  git -C "$tmp/upstream.git" update-ref refs/heads/main "$upstream_sha"
  git -C "$tmp" checkout -q feature
  git -C "$tmp" merge -q --no-ff -m "Merge upstream" upstream-src

  local rc=0 out
  out=$(fm_cas_run_lint "$tmp" "file://$tmp/upstream.git") || rc=$?
  expect_code 0 "$rc" "a trailer carried only by the fetched upstream must not fail lint"
  assert_contains "$out" "excluding commits reachable from upstream $upstream_sha" \
    "lint did not apply the fetched upstream exclusion"
  pass "commands.lint excludes the fetched upstream's own commits"
}

test_clean_commits_pass
test_agent_trailer_fails
test_lowercase_trailer_label_matches
test_human_coauthor_survives
test_prose_mention_does_not_false_positive
test_custom_address_list
test_whitespace_only_address_list_fails_closed
test_unresolvable_base_fails_closed
test_empty_range_is_a_clean_pass
test_no_args_mode_uses_local_main_merge_base
test_help_prints_usage
test_upstream_sync_ref_excludes_upstream_commit_but_still_scans_a_later_fork_commit
test_upstream_sync_ref_excludes_a_trailer_already_carried_by_upstream
test_upstream_sync_ref_still_scans_a_merged_side_branch_fork_commit
test_upstream_sync_ref_unresolvable_warns_and_scans_full_range
test_upstream_sync_ref_excluding_every_commit_says_so
test_lint_upstream_fetch_failure_warns_and_scans_full_range
test_lint_upstream_fetch_success_applies_exclusion
