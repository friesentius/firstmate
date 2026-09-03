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
