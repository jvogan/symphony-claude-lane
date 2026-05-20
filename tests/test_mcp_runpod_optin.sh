#!/usr/bin/env bash
# test_mcp_runpod_optin.sh — Verify the RunPod opt-in surface in env.sh:
#   1. Default (no env override): linear-only worker-mcp.json
#   2. CLAUDE_WORKER_ENABLE_RUNPOD=true: linear+runpod worker-mcp-runpod.json
#   3. CLAUDE_WORKER_MCP_CONFIG=<custom>: respected over both branches
#   4. Legacy pre-set CLAUDE_WORKER_MCP_CONFIG: passes through unchanged
#   5. Explicit =false: stays on default
#   6. Re-source after toggling CLAUDE_WORKER_ENABLE_RUNPOD picks up change
#      (regression guard for the env.sh idempotency-guard bug)
#   7. Default allowlist does NOT include RUNPOD_API_KEY / RUNPOD_NETWORK_VOLUME_ID / RUNPOD_DATACENTER
#   8. Opt-in allowlist DOES include RUNPOD_API_KEY / RUNPOD_NETWORK_VOLUME_ID / RUNPOD_DATACENTER
#   9. Operator override of CLAUDE_WORKER_ENV_ALLOWLIST preserved across re-source
#
# Why this exists: RunPod tooling carries paid-resource creation surface area.
# Defaulting OFF and requiring explicit env-var opt-in is the safer posture.
# This test guards env.sh selection logic AND the conditional secret allowlist
# against regression. Branches 1-5 use `env -i` fresh-shell isolation; branches
# 6-9 use a single shell with re-source to exercise the post-guard re-eval.
#
# Usage: bash tests/test_mcp_runpod_optin.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0
FAILED=()
pass() { echo "  PASS  $*"; PASS_COUNT=$(( PASS_COUNT + 1 )); }
fail() { echo "  FAIL  $*" >&2; FAIL_COUNT=$(( FAIL_COUNT + 1 )); FAILED+=("$*"); }
section() { echo ""; echo "=== $* ==="; }

cleanup() {
  local rc=$?
  if (( FAIL_COUNT > 0 )); then
    echo ""
    echo "FAILED ASSERTIONS:"
    printf '  - %s\n' "${FAILED[@]}"
    exit 1
  fi
  exit $rc
}
trap cleanup EXIT INT TERM

# Each branch runs env.sh in a clean subshell so state doesn't bleed.

section "Branch 1: default — Linear only"
result="$(env -i HOME="$HOME" PATH="$PATH" \
  bash -c "source $REPO_ROOT/env.sh >/dev/null 2>&1; echo \"\$CLAUDE_WORKER_MCP_CONFIG\"")"
expected="$REPO_ROOT/mcp/worker-mcp.json"
if [[ "$result" == "$expected" ]]; then
  pass "default selects $expected"
else
  fail "expected $expected, got $result"
fi

if [[ -f "$expected" ]]; then
  servers="$(jq -r '.mcpServers | keys | join(",")' "$expected" 2>/dev/null || echo "JQ_FAIL")"
  if [[ "$servers" == "linear" ]]; then
    pass "default config exposes only the linear MCP server"
  else
    fail "default config exposes servers '$servers' (expected just 'linear')"
  fi
else
  fail "default config file missing: $expected"
fi

section "Branch 2: CLAUDE_WORKER_ENABLE_RUNPOD=true — linear + runpod"
result="$(env -i HOME="$HOME" PATH="$PATH" CLAUDE_WORKER_ENABLE_RUNPOD=true \
  bash -c "source $REPO_ROOT/env.sh >/dev/null 2>&1; echo \"\$CLAUDE_WORKER_MCP_CONFIG\"")"
expected="$REPO_ROOT/mcp/worker-mcp-runpod.json"
if [[ "$result" == "$expected" ]]; then
  pass "opt-in selects $expected"
else
  fail "expected $expected, got $result"
fi

if [[ -f "$expected" ]]; then
  servers="$(jq -r '.mcpServers | keys | sort | join(",")' "$expected" 2>/dev/null || echo "JQ_FAIL")"
  if [[ "$servers" == "linear,runpod" ]]; then
    pass "opt-in config exposes linear AND runpod servers"
  else
    fail "opt-in config exposes servers '$servers' (expected 'linear,runpod')"
  fi
else
  fail "opt-in config file missing: $expected"
fi

section "Branch 3: explicit CLAUDE_WORKER_MCP_CONFIG override"
custom_path="/tmp/never-actually-used-$$.json"
result="$(env -i HOME="$HOME" PATH="$PATH" CLAUDE_WORKER_MCP_CONFIG="$custom_path" CLAUDE_WORKER_ENABLE_RUNPOD=true \
  bash -c "source $REPO_ROOT/env.sh >/dev/null 2>&1; echo \"\$CLAUDE_WORKER_MCP_CONFIG\"")"
if [[ "$result" == "$custom_path" ]]; then
  pass "explicit override beats CLAUDE_WORKER_ENABLE_RUNPOD branch"
else
  fail "expected $custom_path, got $result"
fi

section "Branch 4: legacy env.sh setting CLAUDE_WORKER_MCP_CONFIG=... still works"
# Some operators have shell config that sets CLAUDE_WORKER_MCP_CONFIG before
# sourcing env.sh. That should still pass through unchanged.
result="$(env -i HOME="$HOME" PATH="$PATH" CLAUDE_WORKER_MCP_CONFIG=/some/legacy/path.json \
  bash -c "source $REPO_ROOT/env.sh >/dev/null 2>&1; echo \"\$CLAUDE_WORKER_MCP_CONFIG\"")"
if [[ "$result" == "/some/legacy/path.json" ]]; then
  pass "pre-set CLAUDE_WORKER_MCP_CONFIG preserved"
else
  fail "expected /some/legacy/path.json, got $result"
fi

section "Branch 5: explicit CLAUDE_WORKER_ENABLE_RUNPOD=false stays on default"
result="$(env -i HOME="$HOME" PATH="$PATH" CLAUDE_WORKER_ENABLE_RUNPOD=false \
  bash -c "source $REPO_ROOT/env.sh >/dev/null 2>&1; echo \"\$CLAUDE_WORKER_MCP_CONFIG\"")"
expected="$REPO_ROOT/mcp/worker-mcp.json"
if [[ "$result" == "$expected" ]]; then
  pass "explicit =false stays on linear-only default"
else
  fail "expected $expected, got $result"
fi

section "Branch 6: re-source picks up CLAUDE_WORKER_ENABLE_RUNPOD toggle"
# Regression for env.sh idempotency-guard bug. Source default, set the toggle,
# re-source, expect MCP config to flip. All within ONE bash shell (not env -i).
result="$(env -i HOME="$HOME" PATH="$PATH" \
  bash -c "
    source $REPO_ROOT/env.sh >/dev/null 2>&1
    first=\"\$CLAUDE_WORKER_MCP_CONFIG\"
    export CLAUDE_WORKER_ENABLE_RUNPOD=true
    source $REPO_ROOT/env.sh >/dev/null 2>&1
    second=\"\$CLAUDE_WORKER_MCP_CONFIG\"
    echo \"\$first|\$second\"
  ")"
first="${result%%|*}"
second="${result##*|}"
if [[ "$first" == "$REPO_ROOT/mcp/worker-mcp.json" ]] && \
   [[ "$second" == "$REPO_ROOT/mcp/worker-mcp-runpod.json" ]]; then
  pass "re-source after toggle flips MCP config (was: $first → now: $second)"
else
  fail "re-source did not flip — first=$first second=$second (expected default → runpod)"
fi

section "Branch 7: default allowlist excludes RunPod secrets"
result="$(env -i HOME="$HOME" PATH="$PATH" \
  bash -c "source $REPO_ROOT/env.sh >/dev/null 2>&1; echo \"\$CLAUDE_WORKER_ENV_ALLOWLIST\"")"
if echo "$result" | tr ' ' '\n' | grep -qx 'RUNPOD_API_KEY'; then
  fail "default allowlist includes RUNPOD_API_KEY (should be opt-in only)"
else
  pass "default allowlist excludes RUNPOD_API_KEY"
fi
if echo "$result" | tr ' ' '\n' | grep -qx 'RUNPOD_NETWORK_VOLUME_ID'; then
  fail "default allowlist includes RUNPOD_NETWORK_VOLUME_ID"
else
  pass "default allowlist excludes RUNPOD_NETWORK_VOLUME_ID"
fi
if echo "$result" | tr ' ' '\n' | grep -qx 'RUNPOD_DATACENTER'; then
  fail "default allowlist includes RUNPOD_DATACENTER"
else
  pass "default allowlist excludes RUNPOD_DATACENTER"
fi
# Sanity: non-RunPod vars stay
if echo "$result" | tr ' ' '\n' | grep -qx 'LINEAR_API_KEY'; then
  pass "default allowlist still includes LINEAR_API_KEY"
else
  fail "default allowlist missing LINEAR_API_KEY (regression)"
fi
if echo "$result" | tr ' ' '\n' | grep -qx 'PLAYWRIGHT_BROWSERS_PATH'; then
  pass "default allowlist still includes PLAYWRIGHT_BROWSERS_PATH (not a RunPod var)"
else
  fail "default allowlist missing PLAYWRIGHT_BROWSERS_PATH (regression)"
fi

section "Branch 8: opt-in allowlist includes RunPod secrets"
result="$(env -i HOME="$HOME" PATH="$PATH" CLAUDE_WORKER_ENABLE_RUNPOD=true \
  bash -c "source $REPO_ROOT/env.sh >/dev/null 2>&1; echo \"\$CLAUDE_WORKER_ENV_ALLOWLIST\"")"
for v in RUNPOD_API_KEY RUNPOD_NETWORK_VOLUME_ID RUNPOD_DATACENTER; do
  if echo "$result" | tr ' ' '\n' | grep -qx "$v"; then
    pass "opt-in allowlist includes $v"
  else
    fail "opt-in allowlist missing $v"
  fi
done

section "Branch 9: operator allowlist override preserved across re-source"
result="$(env -i HOME="$HOME" PATH="$PATH" \
  bash -c "
    export CLAUDE_WORKER_ENV_ALLOWLIST='OPERATOR_ONLY'
    source $REPO_ROOT/env.sh >/dev/null 2>&1
    first=\"\$CLAUDE_WORKER_ENV_ALLOWLIST\"
    export CLAUDE_WORKER_ENABLE_RUNPOD=true
    source $REPO_ROOT/env.sh >/dev/null 2>&1
    second=\"\$CLAUDE_WORKER_ENV_ALLOWLIST\"
    echo \"\$first|\$second\"
  ")"
first="${result%%|*}"
second="${result##*|}"
if [[ "$first" == "OPERATOR_ONLY" ]] && [[ "$second" == "OPERATOR_ONLY" ]]; then
  pass "operator allowlist override preserved across toggle re-source"
else
  fail "operator override clobbered — first=$first second=$second (both should be OPERATOR_ONLY)"
fi

section "Summary"
echo "  Passed: $PASS_COUNT"
echo "  Failed: $FAIL_COUNT"
