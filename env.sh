#!/usr/bin/env bash
# symphony-claude-lane/env.sh
# Source this file to configure the Claude worker lane.
#
# Usage:
#   source path/to/symphony-claude-lane/env.sh
#
# Safe to source multiple times (idempotent). Heavy one-time setup (sourcing
# an upstream orchestration env.sh, if AUTONOMY_ROOT is set) is guarded so it
# only runs once per shell. CLAUDE_WORKER_MCP_CONFIG and
# CLAUDE_WORKER_ENV_ALLOWLIST re-evaluate on every source so toggling
# CLAUDE_WORKER_ENABLE_RUNPOD and re-sourcing picks up the change. Explicit
# operator overrides are preserved across re-sources via an autoset marker.

# ---------- Repo root detection ----------
# Detect the repo root in a way that works under both bash and zsh. The two
# shells expose the sourced-file path through different parameters:
#   bash: ${BASH_SOURCE[0]}
#   zsh:  ${(%):-%x}   (prompt-expansion %x → current sourced file)
# The zsh syntax is parser-invalid in bash, so we guard it behind `eval` to
# defer parsing until runtime. An operator who needs deterministic behavior
# in any other context can export SYMPHONY_CLAUDE_ROOT before sourcing.
if [[ -z "${SYMPHONY_CLAUDE_ROOT:-}" ]]; then
  _symphony_src=""
  if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    _symphony_src="${BASH_SOURCE[0]}"
  elif [[ -n "${ZSH_VERSION:-}" ]]; then
    # shellcheck disable=SC2016
    _symphony_src="$(eval 'printf %s "${(%):-%x}"')"
  fi
  if [[ -n "$_symphony_src" ]]; then
    SYMPHONY_CLAUDE_ROOT="$(cd "$(dirname "$_symphony_src")" && pwd)"
  else
    SYMPHONY_CLAUDE_ROOT="$PWD"
    printf 'symphony-claude-lane/env.sh: source-file detection failed; falling back to PWD=%s. Export SYMPHONY_CLAUDE_ROOT to silence this warning.\n' "$PWD" >&2
  fi
  unset _symphony_src
fi
export SYMPHONY_CLAUDE_ROOT

# Prepend the repo's bin/ to PATH so claude-doctor, claude-version, and
# claude-tmux-finalize are discoverable both by the operator's shell AND by
# any worker we spawn (since the env allowlist includes PATH and the worker
# inherits the PATH the dispatcher had at spawn time). Idempotent: only
# prepended if not already on PATH.
case ":${PATH:-}:" in
  *:"$SYMPHONY_CLAUDE_ROOT/bin":*) ;;
  *) PATH="$SYMPHONY_CLAUDE_ROOT/bin${PATH:+:$PATH}" ;;
esac
export PATH

# ---------- One-time upstream env (optional) ----------
# If you have a separate Symphony / orchestration env file, set AUTONOMY_ROOT
# before sourcing this file. We will source $AUTONOMY_ROOT/env.sh once.
# Skipped silently if AUTONOMY_ROOT is unset.
if [[ -z "${_SYMPHONY_CLAUDE_LANE_ENV_LOADED:-}" ]]; then
  if [[ -n "${AUTONOMY_ROOT:-}" && -r "$AUTONOMY_ROOT/env.sh" ]]; then
    # shellcheck disable=SC1091
    source "$AUTONOMY_ROOT/env.sh"
  fi
  export _SYMPHONY_CLAUDE_LANE_ENV_LOADED=1
fi

# ---------- Idempotent defaults ----------
# These use `${VAR:-default}` so a re-source preserves operator overrides while
# still working on first-source.

# Directory roots
export CLAUDE_WORKSPACES_ROOT="${CLAUDE_WORKSPACES_ROOT:-$SYMPHONY_CLAUDE_ROOT/workspaces}"
export CLAUDE_RUNS_ROOT="${CLAUDE_RUNS_ROOT:-$SYMPHONY_CLAUDE_ROOT/runs}"
export CLAUDE_LOGS_ROOT="${CLAUDE_LOGS_ROOT:-$SYMPHONY_CLAUDE_ROOT/logs}"

# Worker defaults
export CLAUDE_WORKER_MODEL="${CLAUDE_WORKER_MODEL:-claude-opus-4-7}"
export CLAUDE_WORKER_MAX_TURNS="${CLAUDE_WORKER_MAX_TURNS:-50}"
export CLAUDE_CLOSEOUT_STATE="${CLAUDE_CLOSEOUT_STATE:-In Review}"
export CLAUDE_SELF_CLOSE_STATE="${CLAUDE_SELF_CLOSE_STATE:-Done}"

# Per-tier model IDs. Used by:
#  - dispatcher --model alias resolver (opus|sonnet|haiku)
#  - dispatcher Linear label resolver (model:opus|model:sonnet|model:haiku)
# The bare CLAUDE_WORKER_MODEL remains the unconditional fallback.
export CLAUDE_WORKER_MODEL_OPUS="${CLAUDE_WORKER_MODEL_OPUS:-claude-opus-4-7}"
export CLAUDE_WORKER_MODEL_SONNET="${CLAUDE_WORKER_MODEL_SONNET:-claude-sonnet-4-6}"
export CLAUDE_WORKER_MODEL_HAIKU="${CLAUDE_WORKER_MODEL_HAIKU:-claude-haiku-4-5-20251001}"

# Tmux backend: Linear reconciliation on failure.
# When the dispatcher detects a failure/timeout/crash and the worker did NOT
# post its own outcome comment, the dispatcher posts a fallback outcome + moves
# the issue to CLAUDE_TMUX_FAILURE_STATE so the ticket doesn't get stuck
# In Progress with no Linear-side signal.
export CLAUDE_TMUX_RECONCILE="${CLAUDE_TMUX_RECONCILE:-true}"
export CLAUDE_TMUX_FAILURE_STATE="${CLAUDE_TMUX_FAILURE_STATE:-Todo}"

# Routing guardrails (fail-closed by default)
export CLAUDE_REQUIRE_ROUTING="${CLAUDE_REQUIRE_ROUTING:-true}"
export CLAUDE_REQUIRED_LABEL="${CLAUDE_REQUIRED_LABEL:-lane:claude}"
export CLAUDE_ALLOWED_PROJECT_REGEX="${CLAUDE_ALLOWED_PROJECT_REGEX:-Claude}"
export CLAUDE_ALLOWED_ASSIGNEE="${CLAUDE_ALLOWED_ASSIGNEE:-}"

# Cleanup defaults
export CLAUDE_CLEANUP_REQUIRE_INTEGRATED="${CLAUDE_CLEANUP_REQUIRE_INTEGRATED:-true}"

# ---------- RunPod-conditional selectors (re-evaluated each source) ----------
# These two values depend on CLAUDE_WORKER_ENABLE_RUNPOD. They re-evaluate on
# every source so an operator can:
#   source env.sh                              # default (no RunPod)
#   export CLAUDE_WORKER_ENABLE_RUNPOD=true
#   source env.sh                              # picks up the toggle
# Explicit operator overrides are detected via the autoset marker and preserved.

_symphony_compute_mcp_config() {
  if [[ "${CLAUDE_WORKER_ENABLE_RUNPOD:-false}" == "true" ]]; then
    printf '%s/mcp/worker-mcp-runpod.json' "$SYMPHONY_CLAUDE_ROOT"
  else
    printf '%s/mcp/worker-mcp.json' "$SYMPHONY_CLAUDE_ROOT"
  fi
}

_symphony_compute_allowlist() {
  local base="HOME PATH SHELL TMPDIR USER LOGNAME LANG LC_ALL LC_CTYPE SSH_AUTH_SOCK LINEAR_API_KEY ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR XDG_CONFIG_HOME XDG_CACHE_HOME PLAYWRIGHT_BROWSERS_PATH"
  if [[ "${CLAUDE_WORKER_ENABLE_RUNPOD:-false}" == "true" ]]; then
    base="$base RUNPOD_API_KEY RUNPOD_NETWORK_VOLUME_ID RUNPOD_DATACENTER"
  fi
  printf '%s' "$base"
}

# MCP config selection: respect operator override, otherwise re-evaluate.
_symphony_new_mcp="$(_symphony_compute_mcp_config)"
if [[ -z "${CLAUDE_WORKER_MCP_CONFIG:-}" ]] || \
   [[ "${CLAUDE_WORKER_MCP_CONFIG:-}" == "${_SYMPHONY_CLAUDE_MCP_AUTOSET:-}" ]]; then
  export CLAUDE_WORKER_MCP_CONFIG="$_symphony_new_mcp"
  export _SYMPHONY_CLAUDE_MCP_AUTOSET="$_symphony_new_mcp"
fi
unset _symphony_new_mcp

# Worker env allowlist: respect operator override, otherwise re-evaluate.
# Keep the worker process env narrow. RUNPOD_* vars are gated together with the
# RunPod MCP — the worker does not receive RunPod credentials unless
# CLAUDE_WORKER_ENABLE_RUNPOD=true.
_symphony_new_allowlist="$(_symphony_compute_allowlist)"
if [[ -z "${CLAUDE_WORKER_ENV_ALLOWLIST:-}" ]] || \
   [[ "${CLAUDE_WORKER_ENV_ALLOWLIST:-}" == "${_SYMPHONY_CLAUDE_ALLOWLIST_AUTOSET:-}" ]]; then
  export CLAUDE_WORKER_ENV_ALLOWLIST="$_symphony_new_allowlist"
  export _SYMPHONY_CLAUDE_ALLOWLIST_AUTOSET="$_symphony_new_allowlist"
fi
unset _symphony_new_allowlist
