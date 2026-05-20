#!/usr/bin/env bash
# test_env_isolation.sh — Verify the env -i allowlist build loop actually
# isolates the worker process environment.
#
# This guards the load-bearing safety property: the reference launcher MUST
# use `env -i $allowlist=value … claude …` so the worker process starts with
# a stripped environment containing only allowlisted vars. The earlier broken
# pattern `tmux new-session -e VAR=value` only ADDED vars; it did not RESTRICT,
# and silently passed the operator's whole shell env (including unrelated
# secrets) to the worker.
#
# Branches:
#   1. Default allowlist (no RunPod): LINEAR_API_KEY crosses; RUNPOD_API_KEY
#      and SECRET_UNLISTED do NOT cross.
#   2. RunPod opt-in: RUNPOD_API_KEY now crosses; SECRET_UNLISTED still does NOT.
#   3. The dispatcher's CLAUDE_TMUX_SENTINEL_PATH addendum is forwarded.
#
# Strategy: replicate the env_args build loop from
# `skills/.../assets/claude-worker.reference.sh` exactly, then invoke
# `/usr/bin/env -i "${env_args[@]}" /usr/bin/env` and inspect what survived.
# This is stronger than inspecting the array — it confirms the kernel-level
# execve boundary works as intended.
#
# Usage: bash tests/test_env_isolation.sh
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
  if (( FAIL_COUNT > 0 )); then
    echo ""
    echo "FAILED ASSERTIONS:"
    printf '  - %s\n' "${FAILED[@]}"
    exit 1
  fi
  exit 0
}
trap cleanup EXIT INT TERM

# Build env_args identically to claude-worker.reference.sh.
# Caller exports the relevant vars before calling.
build_env_args() {
  local allowlist="$1"
  local sentinel_path="$2"
  env_args=(env -i)
  for _var in $allowlist; do
    [[ "$_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    if [[ -n "${!_var+x}" ]]; then
      env_args+=("$_var=${!_var}")
    fi
  done
  env_args+=("CLAUDE_TMUX_SENTINEL_PATH=$sentinel_path")
}

# Returns 0 if NAME=value appears in the post-execve env, 1 otherwise.
# Uses /usr/bin/env to print the environment, then greps for NAME=.
env_contains() {
  local name="$1"
  shift  # remaining args = env_args
  /usr/bin/env -i "$@" /usr/bin/env | grep -qE "^${name}="
}

section "Branch 1: default allowlist (no RunPod) blocks unlisted secrets"
# Compute the default allowlist via env.sh in a clean subshell.
default_allowlist="$(env -i HOME="$HOME" PATH="$PATH" \
  bash -c "source $REPO_ROOT/env.sh >/dev/null 2>&1; echo \"\$CLAUDE_WORKER_ENV_ALLOWLIST\"")"
# Now in THIS shell, export real + fake vars and build env_args:
export LINEAR_API_KEY="legit-linear-key"
export RUNPOD_API_KEY="should-be-blocked"
export SECRET_UNLISTED="must-not-cross"
build_env_args "$default_allowlist" "/tmp/sentinel.json"

if env_contains LINEAR_API_KEY "${env_args[@]}"; then
  pass "LINEAR_API_KEY survives the env -i boundary"
else
  fail "LINEAR_API_KEY missing from worker env (regression — Linear API would break)"
fi
if env_contains RUNPOD_API_KEY "${env_args[@]}"; then
  fail "RUNPOD_API_KEY leaked into worker env (defense-in-depth gate broken)"
else
  pass "RUNPOD_API_KEY blocked (not in default allowlist)"
fi
if env_contains SECRET_UNLISTED "${env_args[@]}"; then
  fail "SECRET_UNLISTED leaked into worker env (env -i pattern broken)"
else
  pass "SECRET_UNLISTED blocked (not in allowlist)"
fi
if env_contains CLAUDE_TMUX_SENTINEL_PATH "${env_args[@]}"; then
  pass "CLAUDE_TMUX_SENTINEL_PATH dispatcher addendum forwarded"
else
  fail "CLAUDE_TMUX_SENTINEL_PATH missing — worker cannot signal completion"
fi
if env_contains PATH "${env_args[@]}"; then
  pass "PATH survives (needed for claude-tmux-finalize discovery)"
else
  fail "PATH missing — worker cannot find claude-tmux-finalize"
fi

section "Branch 2: RunPod opt-in allowlist lets RUNPOD_API_KEY through"
optin_allowlist="$(env -i HOME="$HOME" PATH="$PATH" CLAUDE_WORKER_ENABLE_RUNPOD=true \
  bash -c "source $REPO_ROOT/env.sh >/dev/null 2>&1; echo \"\$CLAUDE_WORKER_ENV_ALLOWLIST\"")"
build_env_args "$optin_allowlist" "/tmp/sentinel.json"

if env_contains RUNPOD_API_KEY "${env_args[@]}"; then
  pass "RUNPOD_API_KEY crosses when allowlist is opt-in"
else
  fail "RUNPOD_API_KEY blocked in opt-in mode (regression)"
fi
if env_contains LINEAR_API_KEY "${env_args[@]}"; then
  pass "LINEAR_API_KEY still survives in opt-in mode"
else
  fail "LINEAR_API_KEY dropped in opt-in mode (regression)"
fi
if env_contains SECRET_UNLISTED "${env_args[@]}"; then
  fail "SECRET_UNLISTED leaked even in opt-in mode (env -i pattern broken)"
else
  pass "SECRET_UNLISTED still blocked in opt-in mode"
fi

section "Branch 3: malformed allowlist entries are silently dropped"
# Garbage entries (with shell metachars) must not result in env -i seeing them.
build_env_args "LINEAR_API_KEY 'bad name' RUNPOD_API_KEY=baked-value VALID_NAME" "/tmp/s.json"
export VALID_NAME="hello"
build_env_args "LINEAR_API_KEY 'bad name' RUNPOD_API_KEY=baked-value VALID_NAME" "/tmp/s.json"
if env_contains LINEAR_API_KEY "${env_args[@]}"; then
  pass "valid var passes despite garbage neighbors"
else
  fail "valid var rejected — overly aggressive filter"
fi
# Confirm the regex actually filters: 'bad name' with a space and RUNPOD_API_KEY=baked
# should never produce an entry whose VALUE starts with 'baked-' (since the regex
# rejects names with `=` in them, the would-be RUNPOD_API_KEY=baked-value would
# split on whitespace not assignment).
leak_check="$(/usr/bin/env -i "${env_args[@]}" /usr/bin/env | grep -E '^RUNPOD_API_KEY=' || true)"
if [[ -z "$leak_check" || "$leak_check" == "RUNPOD_API_KEY=should-be-blocked" ]]; then
  pass "garbage allowlist tokens do not bake values into env"
else
  fail "unexpected RUNPOD_API_KEY value in env: $leak_check"
fi

section "Summary"
echo "  Passed: $PASS_COUNT"
echo "  Failed: $FAIL_COUNT"
