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
#   --background          Run in background, print PID
#   --resume              Resume a previous session in an existing worktree
#   --dry-run             Print what would happen without executing
#
# Required environment:
#   LINEAR_API_KEY        Linear API key (never stored in this script)
#
# Required on PATH:
#   claude, jq, python3, curl, git
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

issue_id_upper=$(echo "$issue_id" | tr '[:lower:]' '[:upper:]')
issue_id_lower=$(echo "$issue_id" | tr '[:upper:]' '[:lower:]')

branch="claude/${issue_id_lower}"
base_branch="main"
model="$DEFAULT_MODEL"
max_turns="$DEFAULT_MAX_TURNS"
background=false
resume=false
dry_run=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)    branch="$2"; shift 2 ;;
    --base)      base_branch="$2"; shift 2 ;;
    --model)     model="$2"; shift 2 ;;
    --max-turns) max_turns="$2"; shift 2 ;;
    --background) background=true; shift ;;
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

# --- Preflight checks ---
for cmd in claude jq python3 curl git; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd not found on PATH" >&2; exit 1; }
done

[[ -n "${LINEAR_API_KEY:-}" ]] || { echo "ERROR: LINEAR_API_KEY not set" >&2; exit 1; }
[[ -d "$repo_path/.git" ]] || { echo "ERROR: $repo_path is not a git repo" >&2; exit 1; }
[[ -f "$TEMPLATE_PATH" ]] || { echo "ERROR: Template not found: $TEMPLATE_PATH" >&2; exit 1; }

# --- Derived paths ---
worktree_path="$WORKSPACES_ROOT/$issue_id_upper"
run_dir="$RUNS_ROOT/$issue_id_upper"
mkdir -p "$run_dir"

# --- Step 1: Fetch Linear issue ---
echo ">>> Fetching $issue_id_upper from Linear..."

# Parse TEAM-123 into team key and number
team_key=$(echo "$issue_id_upper" | sed 's/-[0-9]*$//')
issue_num=$(echo "$issue_id_upper" | grep -o '[0-9]*$')

# Security: write auth header to temp file, pass via -H @file
auth_file=$(mktemp)
echo "Authorization: Bearer $LINEAR_API_KEY" > "$auth_file"
trap "rm -f '$auth_file'" EXIT

query='{"query":"query($tk:String!,$n:Float!){issues(filter:{team:{key:{eq:$tk}},number:{eq:$n}},first:1){nodes{id identifier title description state{name} project{name}}}}","variables":{"tk":"'"$team_key"'","n":'"$issue_num"'}}'

response=$(curl -s -X POST https://api.linear.app/graphql \
  -H "Content-Type: application/json" \
  -H @"$auth_file" \
  -d "$query")

rm -f "$auth_file"
trap - EXIT

issue_title=$(echo "$response" | jq -r '.data.issues.nodes[0].title // empty')
issue_description=$(echo "$response" | jq -r '.data.issues.nodes[0].description // ""')
issue_state=$(echo "$response" | jq -r '.data.issues.nodes[0].state.name // "Unknown"')

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

# Security: pass issue description via stdin to avoid shell expansion
rendered_prompt=$(echo "$issue_description" | python3 -c "
import sys
template = open('$TEMPLATE_PATH').read()
description = sys.stdin.read()
print(template
    .replace('{{ISSUE_ID}}',              '$issue_id_upper')
    .replace('{{ISSUE_TITLE}}',           '''$(echo "$issue_title" | sed "s/'/'\\\\''/g")''')
    .replace('{{ISSUE_DESCRIPTION}}',     description)
    .replace('{{WORKTREE_PATH}}',         '$worktree_path')
    .replace('{{BRANCH}}',               '$branch')
    .replace('{{BASE_BRANCH}}',          '$base_branch')
    .replace('{{REPO_PATH}}',            '$repo_path')
    .replace('{{ROUTING_PROFILE_PATH}}', '$worktree_path/.orchestration/claude-lane.yaml')
    .replace('{{MODEL}}',                '$model')
)
")

echo "$rendered_prompt" > "$run_dir/prompt.md"

# --- Step 4: Write initial metadata ---
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

  # Validate session_id format
  if [[ -n "$sid" ]] && ! echo "$sid" | grep -qE '^[a-f0-9A-F-]+$'; then
    sid=""
  fi

  # Determine final status
  local final_status="incomplete"
  if [[ -f "$run_dir/output.jsonl" ]]; then
    local last_result
    last_result=$(grep '"type":"result"' "$run_dir/output.jsonl" 2>/dev/null | tail -1 || true)
    if [[ -n "$last_result" ]]; then
      local is_error
      is_error=$(echo "$last_result" | jq -r '.is_error // true' 2>/dev/null || echo "true")
      if [[ "$is_error" == "false" ]]; then
        final_status="completed"
      else
        final_status="failed"
      fi
    fi
  fi

  # Rewrite meta.env atomically
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

trap 'finalize 143' SIGTERM SIGINT

echo ">>> Launching claude -p (model: $model, max-turns: $max_turns)..."

cd "$worktree_path"
claude -p "$rendered_prompt" \
    --model "$model" \
    --name "claude-worker-${issue_id_lower}" \
    --mcp-config "$MCP_CONFIG_PATH" \
    --dangerously-skip-permissions \
    --max-turns "$max_turns" \
    --output-format stream-json \
    --verbose \
    > "$run_dir/output.jsonl" 2>&1 || true

finalize $?
