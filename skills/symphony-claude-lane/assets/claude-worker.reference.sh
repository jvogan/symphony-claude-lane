#!/usr/bin/env bash
# ============================================================================
# Claude Worker - Reference Launcher
# ============================================================================
#
# This is a REFERENCE IMPLEMENTATION, not a production-ready script.
# Adapt it to your environment: paths, auth, MCP config, and error handling.
#
# Usage:
#   ./claude-worker.reference.sh <ISSUE-ID> <REPO-PATH> [options]
#
# Options:
#   --branch <name>       Feature branch name (default: claude/<issue-id>)
#   --base <branch>       Base branch (default: main)
#   --model <model>       Claude model (default: claude-opus-4-6)
#   --max-turns <n>       Turn limit (default: 50)
#   --closeout <state>    Linear closeout state (default: In Review)
#   --self-close          Use CLAUDE_SELF_CLOSE_STATE instead of closeout default
#   --allow-unrouted      Allow dispatch when no routing guard matches
#   --resume              Resume a previous session in an existing worktree
#   --dry-run             Validate issue/routing and print the plan; no files created
#   -h, --help            Show help
#
# Required environment:
#   LINEAR_API_KEY        Linear API key (never stored in this script).
#                         Must also be available to Claude Code at runtime
#                         so MCP config can resolve ${LINEAR_API_KEY}.
#
# Required on PATH:
#   claude, jq, python3, curl, git
#
# Configuration:
#   Set these env vars or edit the defaults below. Paths are relative to
#   the working directory when the script is invoked.
#
#   CLAUDE_WORKSPACES_ROOT    Where git worktrees are created (default: ./workspaces)
#   CLAUDE_RUNS_ROOT          Where per-run metadata lives (default: ./runs)
#   CLAUDE_TEMPLATE_PATH      Worker prompt template (default: ./assets/worker-prompt.template.md)
#   CLAUDE_MCP_CONFIG         MCP config for workers (default: ./mcp/worker-mcp.json)
#   CLAUDE_WORKER_MODEL       Default model (default: claude-opus-4-6)
#   CLAUDE_WORKER_MAX_TURNS   Default turn limit (default: 50)
#   CLAUDE_CLOSEOUT_STATE     Default closeout state (default: In Review)
#   CLAUDE_SELF_CLOSE_STATE   Self-close state when --self-close is used (default: Done)
#   CLAUDE_REQUIRE_ROUTING    Require a label/project/assignee guard (default: true)
#   CLAUDE_REQUIRED_LABEL     Required Linear label option (default: lane:claude)
#   CLAUDE_ALLOWED_PROJECT_REGEX  Allowed Linear project regex (default: unset)
#   CLAUDE_ALLOWED_ASSIGNEE   Allowed assignee id, email, or name (default: unset)
#   CLAUDE_WORKER_ENV_ALLOWLIST   Space-separated env vars passed to claude
#
# ============================================================================
set -euo pipefail

GRAPHQL_URL="https://api.linear.app/graphql"
TERMINAL_STATES=("Done" "Closed" "Cancelled" "Canceled" "Duplicate")

usage() {
  cat >&2 <<'USAGE'
Usage: claude-worker.reference.sh <ISSUE-ID> <REPO-PATH> [options]

Options:
  --branch <name>       Feature branch name (default: claude/<issue-id>)
  --base <branch>       Base branch (default: main)
  --model <model>       Claude model (default: CLAUDE_WORKER_MODEL or claude-opus-4-6)
  --max-turns <n>       Turn limit (default: CLAUDE_WORKER_MAX_TURNS or 50)
  --closeout <state>    Linear closeout state (default: CLAUDE_CLOSEOUT_STATE or In Review)
  --self-close          Use CLAUDE_SELF_CLOSE_STATE instead of closeout default
  --allow-unrouted      Allow dispatch when no routing guard matches
  --resume              Resume a previous session in an existing worktree
  --dry-run             Validate issue/routing and print the plan; no files created
  -h, --help            Show this help
USAGE
}

die() { echo "ERROR: $*" >&2; exit 1; }

truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

reject_single_quote() {
  local field_name="$1"
  local value="$2"
  if [[ "$value" == *"'"* ]]; then
    die "$field_name cannot contain single quotes: $value"
  fi
}

csv_contains() {
  local csv="$1"
  local needle="$2"
  local item
  local -a items
  [[ -n "$needle" ]] || return 1
  IFS=',' read -r -a items <<<"$csv"
  for item in "${items[@]}"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

assignee_matches() {
  local allowed="$1"
  local id="$2"
  local email="$3"
  local name="$4"
  [[ -n "$allowed" ]] || return 1
  [[ "$allowed" == "$id" || "$allowed" == "$email" || "$allowed" == "$name" ]]
}

is_terminal_state() {
  local state="$1"
  local terminal
  for terminal in "${TERMINAL_STATES[@]}"; do
    [[ "$state" == "$terminal" ]] && return 0
  done
  return 1
}

query_issue_state() {
  local query_team_key="$1"
  local query_issue_num="$2"
  local response state header_file query_payload

  header_file=$(mktemp) || return 1
  printf 'Authorization: Bearer %s' "$LINEAR_API_KEY" > "$header_file"
  query_payload=$(jq -nc --arg tk "$query_team_key" --argjson n "$query_issue_num" \
    '{query:"query($tk:String!,$n:Float!){issues(filter:{team:{key:{eq:$tk}},number:{eq:$n}},first:1){nodes{state{name}}}}", variables:{tk:$tk,n:$n}}')

  response=$(curl -fsS -X POST "$GRAPHQL_URL" \
    -H "Content-Type: application/json" \
    -H @"$header_file" \
    -d "$query_payload" 2>/dev/null || true)
  rm -f "$header_file"

  state=$(printf '%s' "${response:-{}}" | jq -r '.data.issues.nodes[0].state.name // empty' 2>/dev/null || true)
  [[ -n "$state" ]] || return 1
  printf '%s' "$state"
}

append_env_arg() {
  local var_name="$1"
  [[ "$var_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 0
  if [[ -n "${!var_name+x}" ]]; then
    claude_env+=("$var_name=${!var_name}")
  fi
}

abspath_from_launch_cwd() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$launch_cwd" "$1" ;;
  esac
}

render_prompt_file() {
  local output_path="$1"
  local vars_file

  vars_file=$(mktemp) || die "mktemp failed; check disk space and /tmp permissions"
  jq -n \
    --arg issue_id "$issue_id_upper" \
    --arg issue_title "$issue_title" \
    --arg worktree_path "$worktree_path" \
    --arg branch "$branch" \
    --arg base_branch "$base_branch" \
    --arg repo_path "$repo_path" \
    --arg routing_profile "$worktree_path/.orchestration/claude-lane.yaml" \
    --arg model "$model" \
    --arg closeout_state "$closeout_state" \
    '{issue_id: $issue_id, issue_title: $issue_title, worktree_path: $worktree_path,
      branch: $branch, base_branch: $base_branch, repo_path: $repo_path,
      routing_profile: $routing_profile, model: $model, closeout_state: $closeout_state}' \
    > "$vars_file"

  # Security: issue description is passed via stdin, not as a shell argument.
  printf '%s' "$issue_description" | python3 -c '
import json
import sys

vars_file = sys.argv[1]
template_path = sys.argv[2]
vars = json.load(open(vars_file))
template = open(template_path).read()
description = sys.stdin.read()

result = (template
    .replace("{{ISSUE_ID}}",              vars["issue_id"])
    .replace("{{ISSUE_TITLE}}",           vars["issue_title"])
    .replace("{{ISSUE_DESCRIPTION}}",     description)
    .replace("{{WORKTREE_PATH}}",         vars["worktree_path"])
    .replace("{{BRANCH}}",                vars["branch"])
    .replace("{{BASE_BRANCH}}",           vars["base_branch"])
    .replace("{{REPO_PATH}}",             vars["repo_path"])
    .replace("{{ROUTING_PROFILE_PATH}}",  vars["routing_profile"])
    .replace("{{MODEL}}",                 vars["model"])
    .replace("{{CLOSEOUT_STATE}}",        vars["closeout_state"])
)
print(result)
' "$vars_file" "$TEMPLATE_PATH" > "$output_path"

  rm -f "$vars_file"
}

# --- Configuration (adapt these to your environment) ---
WORKSPACES_ROOT="${CLAUDE_WORKSPACES_ROOT:-./workspaces}"
RUNS_ROOT="${CLAUDE_RUNS_ROOT:-./runs}"
TEMPLATE_PATH="${CLAUDE_TEMPLATE_PATH:-./assets/worker-prompt.template.md}"
MCP_CONFIG_PATH="${CLAUDE_MCP_CONFIG:-./mcp/worker-mcp.json}"
DEFAULT_MODEL="${CLAUDE_WORKER_MODEL:-claude-opus-4-6}"
DEFAULT_MAX_TURNS="${CLAUDE_WORKER_MAX_TURNS:-50}"
DEFAULT_CLOSEOUT_STATE="${CLAUDE_CLOSEOUT_STATE:-In Review}"
DEFAULT_SELF_CLOSE_STATE="${CLAUDE_SELF_CLOSE_STATE:-Done}"
REQUIRE_ROUTING="${CLAUDE_REQUIRE_ROUTING:-true}"
REQUIRED_LABEL="${CLAUDE_REQUIRED_LABEL:-lane:claude}"
ALLOWED_PROJECT_REGEX="${CLAUDE_ALLOWED_PROJECT_REGEX:-}"
ALLOWED_ASSIGNEE="${CLAUDE_ALLOWED_ASSIGNEE:-}"
WORKER_ENV_ALLOWLIST="${CLAUDE_WORKER_ENV_ALLOWLIST:-HOME PATH SHELL TMPDIR USER LOGNAME LANG LC_ALL LC_CTYPE SSH_AUTH_SOCK LINEAR_API_KEY ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR XDG_CONFIG_HOME XDG_CACHE_HOME PLAYWRIGHT_BROWSERS_PATH}"

if [[ $# -eq 0 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -lt 2 ]]; then
  usage
  exit 2
fi

# --- Argument parsing ---
issue_id="$1"
repo_path="$2"
shift 2

issue_id_upper=$(printf '%s' "$issue_id" | tr '[:lower:]' '[:upper:]')
issue_id_lower=$(printf '%s' "$issue_id_upper" | tr '[:upper:]' '[:lower:]')

branch="claude/${issue_id_lower}"
base_branch="main"
model="$DEFAULT_MODEL"
max_turns="$DEFAULT_MAX_TURNS"
closeout_state="$DEFAULT_CLOSEOUT_STATE"
resume=false
dry_run=false
allow_unrouted=false
self_close_requested=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)    branch="${2:?--branch requires a value}"; shift 2 ;;
    --base)      base_branch="${2:?--base requires a value}"; shift 2 ;;
    --model)     model="${2:?--model requires a value}"; shift 2 ;;
    --max-turns) max_turns="${2:?--max-turns requires a value}"; shift 2 ;;
    --closeout)  closeout_state="${2:?--closeout requires a value}"; shift 2 ;;
    --self-close) closeout_state="$DEFAULT_SELF_CLOSE_STATE"; self_close_requested=true; shift ;;
    --allow-unrouted) allow_unrouted=true; shift ;;
    --resume)    resume=true; shift ;;
    --dry-run)   dry_run=true; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

launch_cwd=$(pwd -P)
repo_path=$(abspath_from_launch_cwd "$repo_path")
WORKSPACES_ROOT=$(abspath_from_launch_cwd "$WORKSPACES_ROOT")
RUNS_ROOT=$(abspath_from_launch_cwd "$RUNS_ROOT")
TEMPLATE_PATH=$(abspath_from_launch_cwd "$TEMPLATE_PATH")
MCP_CONFIG_PATH=$(abspath_from_launch_cwd "$MCP_CONFIG_PATH")

# --- Input validation ---
[[ "$issue_id_upper" =~ ^[A-Z][A-Z0-9]*-[0-9]+$ ]] || die "Invalid issue ID: $issue_id (expected TEAM-123)"
[[ "$max_turns" =~ ^[0-9]+$ ]] || die "--max-turns must be a positive integer"
[[ "$max_turns" -gt 0 ]] || die "--max-turns must be greater than 0"

# These values are written to meta.env. Reject single quotes so status and
# cleanup tooling can parse metadata without sourcing worker-writable files.
reject_single_quote "Branch name" "$branch"
reject_single_quote "Base branch" "$base_branch"
reject_single_quote "Repo path" "$repo_path"
reject_single_quote "Workspaces root" "$WORKSPACES_ROOT"
reject_single_quote "Runs root" "$RUNS_ROOT"
reject_single_quote "Model" "$model"
reject_single_quote "Closeout state" "$closeout_state"
reject_single_quote "Required label" "$REQUIRED_LABEL"
reject_single_quote "Allowed assignee" "$ALLOWED_ASSIGNEE"

# Parse TEAM-123 into team key and number.
team_key="${issue_id_upper%%-*}"
issue_num="${issue_id_upper##*-}"

# --- Preflight checks ---
for cmd in claude jq python3 curl git; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd not found on PATH"
done

[[ -n "${LINEAR_API_KEY:-}" ]] || die "LINEAR_API_KEY not set"
[[ -d "$repo_path/.git" ]]    || die "$repo_path is not a git repo"
[[ -f "$TEMPLATE_PATH" ]]     || die "Template not found: $TEMPLATE_PATH"
[[ -f "$MCP_CONFIG_PATH" ]]   || die "MCP config not found: $MCP_CONFIG_PATH (see worker-launch.md for the expected format)"

# --- Step 1: Fetch Linear issue ---
echo ">>> Fetching $issue_id_upper from Linear..."

auth_file=$(mktemp) || die "mktemp failed; check disk space and /tmp permissions"
printf 'Authorization: Bearer %s' "$LINEAR_API_KEY" > "$auth_file"
trap 'rm -f "$auth_file"' EXIT

# Note: Linear uses Float! for issue numbers (not Int!). This is a Linear GraphQL quirk.
query=$(jq -nc --arg tk "$team_key" --argjson n "$issue_num" \
  '{query:"query($tk:String!,$n:Float!){issues(filter:{team:{key:{eq:$tk}},number:{eq:$n}},first:1){nodes{id identifier title description state{name} project{name} assignee{id email name} labels{nodes{name}}}}}", variables:{tk:$tk,n:$n}}')

response=$(curl -fsS -X POST "$GRAPHQL_URL" \
  -H "Content-Type: application/json" \
  -H @"$auth_file" \
  -d "$query" 2>/dev/null || echo '{}')

rm -f "$auth_file"
trap - EXIT

issue_title=$(printf '%s' "$response" | jq -r '.data.issues.nodes[0].title // empty')
issue_description=$(printf '%s' "$response" | jq -r '.data.issues.nodes[0].description // ""')
issue_state=$(printf '%s' "$response" | jq -r '.data.issues.nodes[0].state.name // "Unknown"')
project_name=$(printf '%s' "$response" | jq -r '.data.issues.nodes[0].project.name // ""')
assignee_id=$(printf '%s' "$response" | jq -r '.data.issues.nodes[0].assignee.id // ""')
assignee_email=$(printf '%s' "$response" | jq -r '.data.issues.nodes[0].assignee.email // ""')
assignee_name=$(printf '%s' "$response" | jq -r '.data.issues.nodes[0].assignee.name // ""')
issue_labels=$(printf '%s' "$response" | jq -r '.data.issues.nodes[0].labels.nodes[]?.name' | paste -sd ',' -)

[[ -n "$issue_title" ]] || die "Issue $issue_id_upper not found in Linear"

if is_terminal_state "$issue_state"; then
  die "Issue $issue_id_upper is already $issue_state"
fi

echo "    Title: $issue_title"
echo "    State: $issue_state"
[[ -n "$project_name" ]] && echo "    Project: $project_name"
[[ -n "$assignee_email" || -n "$assignee_name" ]] && echo "    Assignee: ${assignee_email:-$assignee_name}"
[[ -n "$issue_labels" ]] && echo "    Labels: $issue_labels"

# --- Routing guardrails ---
routing_reasons=()
if csv_contains "$issue_labels" "$REQUIRED_LABEL"; then
  routing_reasons+=("label")
fi
if [[ -n "$ALLOWED_PROJECT_REGEX" ]] && [[ "$project_name" =~ $ALLOWED_PROJECT_REGEX ]]; then
  routing_reasons+=("project")
fi
if assignee_matches "$ALLOWED_ASSIGNEE" "$assignee_id" "$assignee_email" "$assignee_name"; then
  routing_reasons+=("assignee")
fi

routing_summary="none"
if [[ ${#routing_reasons[@]} -gt 0 ]]; then
  routing_summary=$(IFS=,; echo "${routing_reasons[*]}")
fi

if truthy "$REQUIRE_ROUTING" && [[ "$allow_unrouted" != "true" ]] && [[ ${#routing_reasons[@]} -eq 0 ]]; then
  die "Issue $issue_id_upper is not explicitly routed to Claude.
    Required label: ${REQUIRED_LABEL:-<unset>}
    Allowed project regex: ${ALLOWED_PROJECT_REGEX:-<unset>}
    Allowed assignee: ${ALLOWED_ASSIGNEE:-<unset>}
    Actual project: ${project_name:-<none>}
    Actual labels: ${issue_labels:-<none>}
    Actual assignee: ${assignee_email:-${assignee_name:-<none>}}
    Use --allow-unrouted only for a deliberate trusted dispatch."
fi

echo "    Routing: $routing_summary"
echo "    Closeout: $closeout_state"

# --- Derived paths ---
worktree_path="$WORKSPACES_ROOT/$issue_id_upper"
run_dir="$RUNS_ROOT/$issue_id_upper"

# --- Dry run exit: no worktree, run directory, prompt, or metadata is created. ---
if [[ "$dry_run" == true ]]; then
  dry_prompt=$(mktemp) || die "mktemp failed; check disk space and /tmp permissions"
  render_prompt_file "$dry_prompt"
  grep -q '<issue_body>' "$dry_prompt" || die "Rendered prompt is missing <issue_body> boundary"
  grep -q '</issue_body>' "$dry_prompt" || die "Rendered prompt is missing </issue_body> boundary"
  rm -f "$dry_prompt"

  echo ""
  echo "=== DRY RUN ==="
  echo "Would create worktree: $worktree_path"
  echo "Would create branch:   $branch from $base_branch"
  echo "Would render prompt:   $TEMPLATE_PATH (validated in a temporary file)"
  echo "Would launch:          env -i <allowlisted worker env> claude -p < prompt.md --model $model --max-turns $max_turns"
  echo "Would close out as:    $closeout_state"
  echo "Would self-close:      $self_close_requested"
  exit 0
fi

mkdir -p "$run_dir" "$WORKSPACES_ROOT"

# --- Step 2: Create worktree ---
if [[ "$resume" == true ]]; then
  if [[ ! -d "$worktree_path" ]]; then
    die "--resume but worktree does not exist: $worktree_path"
  fi
  echo ">>> Resuming in existing worktree: $worktree_path"
else
  if [[ -d "$worktree_path" ]]; then
    echo "ERROR: Worktree already exists: $worktree_path" >&2
    echo "    To resume: $0 $issue_id $repo_path --resume" >&2
    echo "    To remove: git -C $repo_path worktree remove --force $worktree_path" >&2
    exit 1
  fi
  echo ">>> Creating worktree: $worktree_path (branch: $branch from $base_branch)"
  git -C "$repo_path" worktree add "$worktree_path" -b "$branch" "$base_branch"
fi

# --- Step 3: Render prompt ---
echo ">>> Rendering prompt..."
render_prompt_file "$run_dir/prompt.md"

# --- Step 4: Write initial metadata ---
# Note: the routing profile at .orchestration/claude-lane.yaml must be committed
# to the repo for it to appear in the worktree.
start_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat > "$run_dir/meta.env" <<METAEOF
issue_id='$issue_id_upper'
repo_path='$repo_path'
worktree_path='$worktree_path'
branch='$branch'
base_branch='$base_branch'
start_time='$start_time'
model='$model'
max_turns='$max_turns'
pid='$$'
session_id=''
exit_code=''
end_time=''
status='running'
closeout_state='$closeout_state'
self_close_requested='$self_close_requested'
closeout_verified='unchecked'
linear_state_actual=''
routing='$routing_summary'
integrated='false'
METAEOF

# --- Step 5: Launch ---
finalize() {
  local ec="${1:-$?}"
  local sid=""
  local final_status="incomplete"
  local result_event=""
  local linear_state_actual=""
  local closeout_verified="not_applicable"

  if [[ -f "$run_dir/output.jsonl" ]]; then
    sid=$(jq -r 'select(.type == "result") | .session_id // empty' \
      "$run_dir/output.jsonl" 2>/dev/null | tail -1 || true)
    if [[ -z "$sid" ]]; then
      sid=$(jq -r 'select(.type == "system") | .sessionId // empty' \
        "$run_dir/output.jsonl" 2>/dev/null | head -1 || true)
    fi
    result_event=$(jq -c 'select(.type == "result")' "$run_dir/output.jsonl" 2>/dev/null | tail -1 || true)
  fi

  # Validate session_id: only hex digits and hyphens.
  if [[ -n "$sid" ]] && ! printf '%s' "$sid" | grep -qE '^[a-f0-9A-F-]+$'; then
    sid=""
  fi

  if [[ -n "$result_event" ]]; then
    local is_error subtype
    is_error=$(printf '%s' "$result_event" | jq -r '.is_error // false' 2>/dev/null || echo "true")
    subtype=$(printf '%s' "$result_event" | jq -r '.subtype // "unknown"' 2>/dev/null || echo "unknown")
    if [[ "$is_error" == "false" && "$subtype" == "success" ]]; then
      final_status="completed"
    else
      final_status="failed"
    fi
  elif [[ "$ec" != "0" ]]; then
    final_status="failed"
  fi

  if [[ "$final_status" == "completed" ]]; then
    if linear_state_actual=$(query_issue_state "$team_key" "$issue_num" 2>/dev/null); then
      linear_state_actual="${linear_state_actual//\'/}"
      if [[ "$linear_state_actual" == "$closeout_state" ]]; then
        closeout_verified="true"
      else
        closeout_verified="false"
      fi
    else
      linear_state_actual=""
      closeout_verified="check_failed"
    fi
  fi

  # Rewrite meta.env atomically (write to temp, then mv).
  local tmp
  tmp=$(mktemp "${run_dir}/meta.env.XXXXXX")
  cat > "$tmp" <<METAEOF2
issue_id='$issue_id_upper'
repo_path='$repo_path'
worktree_path='$worktree_path'
branch='$branch'
base_branch='$base_branch'
start_time='$start_time'
model='$model'
max_turns='$max_turns'
pid=''
session_id='$sid'
exit_code='$ec'
end_time='$(date -u +%Y-%m-%dT%H:%M:%SZ)'
status='$final_status'
closeout_state='$closeout_state'
self_close_requested='$self_close_requested'
closeout_verified='$closeout_verified'
linear_state_actual='$linear_state_actual'
routing='$routing_summary'
integrated='false'
METAEOF2
  mv "$tmp" "$run_dir/meta.env"

  echo ""
  echo ">>> Worker finished: $final_status (exit code: $ec)"
  if [[ "$final_status" == "completed" ]]; then
    echo "    Closeout verified: $closeout_verified"
    [[ -n "$linear_state_actual" ]] && echo "    Linear state: $linear_state_actual"
  fi
  if [[ "$final_status" == "failed" && -n "$sid" ]]; then
    echo "    Resume: cd $worktree_path && claude --resume $sid"
  fi
}

# Trap both SIGTERM and SIGINT and still record metadata.
trap 'finalize 143; exit 143' SIGTERM SIGINT

echo ">>> Launching claude -p (model: $model, max-turns: $max_turns)..."

cd "$worktree_path"
claude_env=(env -i)
for env_name in $WORKER_ENV_ALLOWLIST; do
  append_env_arg "$env_name"
done

worker_exit=0
"${claude_env[@]}" claude -p \
  --model "$model" \
  --name "claude-worker-${issue_id_lower}" \
  --mcp-config "$MCP_CONFIG_PATH" \
  --dangerously-skip-permissions \
  --max-turns "$max_turns" \
  --output-format stream-json \
  --verbose \
  < "$run_dir/prompt.md" \
  > "$run_dir/output.jsonl" 2>&1 || worker_exit=$?

trap - SIGTERM SIGINT
finalize "$worker_exit"
exit "$worker_exit"
