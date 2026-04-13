#!/usr/bin/env bash
# ============================================================================
# Claude Worker — Reference Launcher
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
#   --resume              Resume a previous session in an existing worktree
#   --dry-run             Print what would happen without executing
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
#   CLAUDE_WORKSPACES_ROOT   Where git worktrees are created (default: ./workspaces)
#   CLAUDE_RUNS_ROOT         Where per-run metadata lives (default: ./runs)
#   CLAUDE_TEMPLATE_PATH     Worker prompt template (default: ./assets/worker-prompt.template.md)
#   CLAUDE_MCP_CONFIG        MCP config for workers (default: ./mcp/worker-mcp.json)
#   CLAUDE_WORKER_MODEL      Default model (default: claude-opus-4-6)
#   CLAUDE_WORKER_MAX_TURNS  Default turn limit (default: 50)
#
# ============================================================================
set -euo pipefail

# --- Configuration (adapt these to your environment) ---
WORKSPACES_ROOT="${CLAUDE_WORKSPACES_ROOT:-./workspaces}"
RUNS_ROOT="${CLAUDE_RUNS_ROOT:-./runs}"
TEMPLATE_PATH="${CLAUDE_TEMPLATE_PATH:-./assets/worker-prompt.template.md}"
MCP_CONFIG_PATH="${CLAUDE_MCP_CONFIG:-./mcp/worker-mcp.json}"
DEFAULT_MODEL="${CLAUDE_WORKER_MODEL:-claude-opus-4-6}"
DEFAULT_MAX_TURNS="${CLAUDE_WORKER_MAX_TURNS:-50}"

# --- Argument parsing ---
issue_id="${1:?Usage: $0 <ISSUE-ID> <REPO-PATH> [options]}"
repo_path="${2:?Usage: $0 <ISSUE-ID> <REPO-PATH> [options]}"
shift 2

issue_id_upper=$(printf '%s' "$issue_id" | tr '[:lower:]' '[:upper:]')
issue_id_lower=$(printf '%s' "$issue_id" | tr '[:upper:]' '[:lower:]')

branch="claude/${issue_id_lower}"
base_branch="main"
model="$DEFAULT_MODEL"
max_turns="$DEFAULT_MAX_TURNS"
resume=false
dry_run=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)    branch="$2"; shift 2 ;;
    --base)      base_branch="$2"; shift 2 ;;
    --model)     model="$2"; shift 2 ;;
    --max-turns) max_turns="$2"; shift 2 ;;
    --resume)    resume=true; shift ;;
    --dry-run)   dry_run=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# --- Input validation ---
# Reject branch names with single quotes (prevents injection into meta.env)
if [[ "$branch" == *"'"* ]]; then
  echo "ERROR: Branch name cannot contain single quotes: $branch" >&2
  exit 1
fi

# Parse TEAM-123 into team key and number
team_key=$(printf '%s' "$issue_id_upper" | sed 's/-[0-9]*$//')
issue_num=$(printf '%s' "$issue_id_upper" | grep -o '[0-9]*$')

# Validate team_key is alphanumeric and issue_num is a positive integer
if ! printf '%s' "$team_key" | grep -qE '^[A-Z][A-Z0-9]*$'; then
  echo "ERROR: Invalid team key in issue ID: $team_key (expected uppercase alphanumeric)" >&2
  exit 1
fi
if ! printf '%s' "$issue_num" | grep -qE '^[0-9]+$'; then
  echo "ERROR: Invalid issue number in issue ID: $issue_num (expected positive integer)" >&2
  exit 1
fi

# --- Preflight checks ---
for cmd in claude jq python3 curl git; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd not found on PATH" >&2; exit 1; }
done

[[ -n "${LINEAR_API_KEY:-}" ]] || { echo "ERROR: LINEAR_API_KEY not set" >&2; exit 1; }
[[ -d "$repo_path/.git" ]]    || { echo "ERROR: $repo_path is not a git repo" >&2; exit 1; }
[[ -f "$TEMPLATE_PATH" ]]     || { echo "ERROR: Template not found: $TEMPLATE_PATH" >&2; exit 1; }
[[ -f "$MCP_CONFIG_PATH" ]]   || { echo "ERROR: MCP config not found: $MCP_CONFIG_PATH (see worker-launch.md for the expected format)" >&2; exit 1; }

# --- Derived paths ---
worktree_path="$WORKSPACES_ROOT/$issue_id_upper"
run_dir="$RUNS_ROOT/$issue_id_upper"
mkdir -p "$run_dir" "$WORKSPACES_ROOT"

# --- Step 1: Fetch Linear issue ---
echo ">>> Fetching $issue_id_upper from Linear..."

# Security: write auth header to temp file, pass via -H @file, delete immediately.
# This prevents the API key from appearing in the process argument list (ps aux).
auth_file=$(mktemp) || { echo "ERROR: mktemp failed — check disk space and /tmp permissions" >&2; exit 1; }
printf 'Authorization: Bearer %s' "$LINEAR_API_KEY" > "$auth_file"
trap "rm -f '$auth_file'" EXIT

# Note: Linear uses Float! for issue numbers (not Int!). This is a Linear GraphQL quirk.
query='{"query":"query($tk:String!,$n:Float!){issues(filter:{team:{key:{eq:$tk}},number:{eq:$n}},first:1){nodes{id identifier title description state{name} project{name}}}}","variables":{"tk":"'"$team_key"'","n":'"$issue_num"'}}'

response=$(curl -s -X POST https://api.linear.app/graphql \
  -H "Content-Type: application/json" \
  -H @"$auth_file" \
  -d "$query")

rm -f "$auth_file"
trap - EXIT

issue_title=$(printf '%s' "$response" | jq -r '.data.issues.nodes[0].title // empty')
issue_description=$(printf '%s' "$response" | jq -r '.data.issues.nodes[0].description // ""')
issue_state=$(printf '%s' "$response" | jq -r '.data.issues.nodes[0].state.name // "Unknown"')

if [[ -z "$issue_title" ]]; then
  echo "ERROR: Issue $issue_id_upper not found in Linear" >&2
  exit 1
fi

# Guard: don't dispatch against completed issues
case "$issue_state" in
  Done|Closed|Cancelled|Canceled|Duplicate)
    echo "ERROR: Issue $issue_id_upper is already $issue_state" >&2
    exit 1 ;;
esac

echo "    Title: $issue_title"
echo "    State: $issue_state"

# --- Step 2: Create worktree ---
if [[ "$resume" == true ]]; then
  if [[ ! -d "$worktree_path" ]]; then
    echo "ERROR: --resume but worktree does not exist: $worktree_path" >&2
    exit 1
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

# Security: all variable values are written to a JSON file and read by Python,
# avoiding shell expansion of user-supplied content (especially issue_title
# and issue_description which can contain backticks, quotes, and dollar signs).
vars_file=$(mktemp)
jq -n \
  --arg issue_id "$issue_id_upper" \
  --arg issue_title "$issue_title" \
  --arg worktree_path "$worktree_path" \
  --arg branch "$branch" \
  --arg base_branch "$base_branch" \
  --arg repo_path "$repo_path" \
  --arg routing_profile "$worktree_path/.orchestration/claude-lane.yaml" \
  --arg model "$model" \
  '{issue_id: $issue_id, issue_title: $issue_title, worktree_path: $worktree_path,
    branch: $branch, base_branch: $base_branch, repo_path: $repo_path,
    routing_profile: $routing_profile, model: $model}' \
  > "$vars_file"

# Issue description passed via stdin — never as a shell argument.
rendered_prompt=$(printf '%s' "$issue_description" | python3 -c "
import sys, json

vars = json.load(open('$vars_file'))
template = open('$TEMPLATE_PATH').read()
description = sys.stdin.read()

result = (template
    .replace('{{ISSUE_ID}}',              vars['issue_id'])
    .replace('{{ISSUE_TITLE}}',           vars['issue_title'])
    .replace('{{ISSUE_DESCRIPTION}}',     description)
    .replace('{{WORKTREE_PATH}}',         vars['worktree_path'])
    .replace('{{BRANCH}}',               vars['branch'])
    .replace('{{BASE_BRANCH}}',          vars['base_branch'])
    .replace('{{REPO_PATH}}',            vars['repo_path'])
    .replace('{{ROUTING_PROFILE_PATH}}', vars['routing_profile'])
    .replace('{{MODEL}}',                vars['model'])
)
print(result)
")

rm -f "$vars_file"
printf '%s' "$rendered_prompt" > "$run_dir/prompt.md"

# --- Step 4: Write initial metadata ---
# Note: the routing profile at .orchestration/claude-lane.yaml must be committed
# to the repo for it to appear in the worktree.
cat > "$run_dir/meta.env" <<METAEOF
issue_id='$issue_id_upper'
repo_path='$repo_path'
worktree_path='$worktree_path'
branch='$branch'
base_branch='$base_branch'
start_time='$(date -u +%Y-%m-%dT%H:%M:%SZ)'
model='$model'
max_turns='$max_turns'
pid=''
session_id=''
exit_code=''
end_time=''
status='starting'
METAEOF

# --- Dry run exit ---
if [[ "$dry_run" == true ]]; then
  echo ""
  echo "=== DRY RUN ==="
  echo "Would launch:"
  echo "  cd $worktree_path"
  echo "  claude -p <prompt> --model $model --max-turns $max_turns"
  echo ""
  echo "Prompt saved to: $run_dir/prompt.md"
  echo "Metadata saved to: $run_dir/meta.env"
  exit 0
fi

# --- Step 5: Launch ---
finalize() {
  local ec="${1:-$?}"

  # Extract session_id from output stream
  local sid=""
  if [[ -f "$run_dir/output.jsonl" ]]; then
    sid=$(grep -o '"session_id":"[^"]*"' "$run_dir/output.jsonl" 2>/dev/null \
      | tail -1 | sed 's/"session_id":"//;s/"//' || true)
  fi

  # Validate session_id: only hex digits and hyphens
  if [[ -n "$sid" ]] && ! printf '%s' "$sid" | grep -qE '^[a-f0-9A-F-]+$'; then
    sid=""
  fi

  # Determine final status from the last result event
  local final_status="incomplete"
  if [[ -f "$run_dir/output.jsonl" ]]; then
    local last_result
    last_result=$(grep '"type":"result"' "$run_dir/output.jsonl" 2>/dev/null | tail -1 || true)
    if [[ -n "$last_result" ]]; then
      local is_error
      is_error=$(printf '%s' "$last_result" | jq -r '.is_error // true' 2>/dev/null || echo "true")
      if [[ "$is_error" == "false" ]]; then
        final_status="completed"
      else
        final_status="failed"
      fi
    fi
  fi

  # Rewrite meta.env atomically (write to temp, then mv)
  local tmp
  tmp=$(mktemp)
  cat > "$tmp" <<METAEOF2
issue_id='$issue_id_upper'
repo_path='$repo_path'
worktree_path='$worktree_path'
branch='$branch'
base_branch='$base_branch'
start_time='$(grep "^start_time=" "$run_dir/meta.env" | sed "s/^start_time='//;s/'$//")'
model='$model'
max_turns='$max_turns'
pid='$$'
session_id='$sid'
exit_code='$ec'
end_time='$(date -u +%Y-%m-%dT%H:%M:%SZ)'
status='$final_status'
METAEOF2
  mv "$tmp" "$run_dir/meta.env"

  echo ""
  echo ">>> Worker finished: $final_status (exit code: $ec)"
  if [[ "$final_status" == "failed" && -n "$sid" ]]; then
    echo "    Resume: claude --resume $sid"
  fi
}

# Trap both SIGTERM and SIGINT — both record exit code 143 for simplicity.
trap 'finalize 143' SIGTERM SIGINT

echo ">>> Launching claude -p (model: $model, max-turns: $max_turns)..."

# Working directory is the worktree, not the source repo.
# The rendered prompt is saved to $run_dir/prompt.md and passed as a file
# reference to avoid ARG_MAX limits with large issue bodies.
cd "$worktree_path"
claude -p "$(cat "$run_dir/prompt.md")" \
    --model "$model" \
    --name "claude-worker-${issue_id_lower}" \
    --mcp-config "$MCP_CONFIG_PATH" \
    --dangerously-skip-permissions \
    --max-turns "$max_turns" \
    --output-format stream-json \
    --verbose \
    > "$run_dir/output.jsonl" 2>&1 || true

finalize $?
