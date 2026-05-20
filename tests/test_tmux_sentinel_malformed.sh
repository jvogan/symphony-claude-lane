#!/usr/bin/env bash
# test_tmux_sentinel_malformed.sh — Regression guard for malformed sentinel
# handling in the monitor loop of the reference launcher.
#
# Background:
#   The dispatcher polls `$sentinel_path` (`.symphony-done`) and reads fields
#   via `jq`. The worker writes this atomically via `claude-tmux-finalize`,
#   but a crashed worker / disk-full mid-write / manual operator interference
#   could leave a truncated or non-JSON file.
#
#   Bug pre-fix: jq on malformed JSON exits non-zero with empty stdout, so
#   final_status / exit_reason silently coerced to empty string. Reconcile
#   then mis-classified what should be a clear failure.
#
#   Fix: validate JSON with `jq -e 'type == "object"'` before extracting
#   fields; on failure, set status=failed exit_reason=sentinel_malformed.
#
# This test:
#   1. Exercises the validation predicate against valid object, valid non-object
#      (array, string, number, boolean), empty file, truncated/garbage, trailing
#      comma JSON, and well-formed JSON.
#   2. Greps the reference launcher to ensure the validation guard is still
#      present and that the sentinel_malformed exit_reason is wired in.
#
# Usage: bash tests/test_tmux_sentinel_malformed.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REFERENCE_LAUNCHER="$REPO_ROOT/skills/symphony-claude-lane/assets/claude-worker.reference.sh"

PASS_COUNT=0
FAIL_COUNT=0
FAILED=()
pass() { echo "  PASS  $*"; PASS_COUNT=$(( PASS_COUNT + 1 )); }
fail() { echo "  FAIL  $*" >&2; FAIL_COUNT=$(( FAIL_COUNT + 1 )); FAILED+=("$*"); }
section() { echo ""; echo "=== $* ==="; }

# Temp files this test creates — cleaned up by the cleanup() trap below so
# we don't have to replace the EXIT trap mid-test.
TEMP_FILES=()

cleanup() {
  local rc=$?
  for f in "${TEMP_FILES[@]:-}"; do
    [[ -n "$f" ]] && rm -f "$f"
  done
  if (( FAIL_COUNT > 0 )); then
    echo ""
    echo "FAILED ASSERTIONS:"
    printf '  - %s\n' "${FAILED[@]}"
    exit 1
  fi
  exit $rc
}
trap cleanup EXIT INT TERM

# ---------- Validate-as-object predicate ----------
# This is the exact predicate the reference launcher uses, hoisted into a
# function so the test can call it directly without spinning up a real dispatch.
validate_sentinel() {
  local json="$1"
  if ! printf '%s' "$json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

section "Predicate accepts well-formed JSON object"
if validate_sentinel '{"status":"completed","exit_reason":"normal","session_id":"abc","outcome_posted":true}'; then
  pass "valid object accepted"
else
  fail "valid object rejected"
fi

if validate_sentinel '{}'; then
  pass "empty object accepted (jq fallbacks handle missing keys)"
else
  fail "empty object rejected"
fi

section "Predicate REJECTS non-object JSON"
if ! validate_sentinel '[]'; then
  pass "JSON array rejected (sentinels must be objects, not arrays)"
else
  fail "JSON array was accepted — sentinel handler would mis-parse"
fi

if ! validate_sentinel '"some string"'; then
  pass "bare JSON string rejected"
else
  fail "bare string accepted"
fi

if ! validate_sentinel '42'; then
  pass "JSON number rejected"
else
  fail "JSON number accepted"
fi

if ! validate_sentinel 'true'; then
  pass "JSON boolean rejected"
else
  fail "JSON boolean accepted"
fi

section "Predicate REJECTS malformed JSON"
if ! validate_sentinel ''; then
  pass "empty string rejected"
else
  fail "empty string accepted — would falsely look like a sentinel"
fi

if ! validate_sentinel '{"status":'; then
  pass "truncated JSON rejected"
else
  fail "truncated JSON accepted"
fi

if ! validate_sentinel 'this is not json at all'; then
  pass "garbage text rejected"
else
  fail "garbage text accepted"
fi

if ! validate_sentinel '{"status":"completed",}'; then
  pass "trailing comma JSON rejected (strict JSON)"
else
  fail "non-strict JSON accepted"
fi

section "Reference launcher retains the validation guard"

[[ -f "$REFERENCE_LAUNCHER" ]] || fail "reference launcher not found at $REFERENCE_LAUNCHER"

guard="$(grep -nE 'jq -e .type == .object.' "$REFERENCE_LAUNCHER" 2>/dev/null || true)"
if [[ -n "$guard" ]]; then
  pass "reference launcher contains the validation guard ($guard)"
else
  fail "reference launcher is missing the validation guard — malformed sentinel would silently coerce to empty fields"
fi

reason="$(grep -nE 'exit_reason=.?sentinel_malformed.?' "$REFERENCE_LAUNCHER" 2>/dev/null || true)"
if [[ -n "$reason" ]]; then
  pass "fallback exit_reason='sentinel_malformed' is set when validation fails"
else
  fail "no sentinel_malformed exit_reason found — fix may have regressed"
fi

# The reference launcher should also document sentinel_malformed in the exit_reason
# vocabulary of references/worker-launch.md so adopters know to handle it.
WORKER_LAUNCH_MD="$REPO_ROOT/skills/symphony-claude-lane/references/worker-launch.md"
if [[ -f "$WORKER_LAUNCH_MD" ]]; then
  if grep -qE 'sentinel_malformed' "$WORKER_LAUNCH_MD"; then
    pass "references/worker-launch.md documents the sentinel_malformed exit_reason"
  else
    fail "references/worker-launch.md does not document sentinel_malformed — adopters won't know to handle it"
  fi
else
  fail "references/worker-launch.md not found at $WORKER_LAUNCH_MD"
fi

section "Summary"
echo "  Passed: $PASS_COUNT"
echo "  Failed: $FAIL_COUNT"
