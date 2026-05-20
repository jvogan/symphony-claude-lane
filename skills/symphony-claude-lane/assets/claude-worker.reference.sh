#!/usr/bin/env bash
# ============================================================================
# Claude Worker - Reference Launcher (tmux backend)
# ============================================================================
#
# This is a REFERENCE IMPLEMENTATION, not a production-ready script.
# Adapt it to your environment: paths, auth, MCP config, env scoping, and
# error handling.
#
# WHY TMUX:
#   The worker runs as an INTERACTIVE Claude Code session inside a detached
#   tmux pane (no `claude -p` subprocess). This bills against the operator's
#   Claude subscription (not the Agent SDK credit bucket) and matches the
#   normal interactive session model. The trade-off is that there is no exit
#   code: the worker signals completion by invoking `claude-tmux-finalize`,
#   which writes a JSON sentinel file. This dispatcher polls for the sentinel.
#
# Usage:
#   ./claude-worker.reference.sh <ISSUE-ID> <REPO-PATH> [options]
#
# Options:
#   --branch <name>       Feature branch name (default: claude/<issue-id>)
#   --base <branch>       Base branch (default: main)
#   --model <model>       Claude model (default: $CLAUDE_WORKER_MODEL)
#   --max-turns <n>       Turn limit (default: 50)
#   --closeout <state>    Linear closeout state (default: In Review)
#   --self-close          Use CLAUDE_SELF_CLOSE_STATE instead of closeout default
#   --allow-unrouted      Allow dispatch when no routing guard matches
#   --dry-run             Validate issue/routing and print the plan; no files created
#   --timeout <seconds>   Max wait for sentinel before declaring timeout (default: 3600)
#   -h, --help            Show help
#
# Required environment:
#   LINEAR_API_KEY        Linear API key (never stored in this script).
#                         Must also be available to the Claude session at runtime
#                         so MCP config can resolve ${LINEAR_API_KEY}.
#
# Required on PATH: claude, jq, python3, curl, git, tmux
#
# Configuration (env-driven; see env.sh in the repo root for defaults):
#   CLAUDE_WORKSPACES_ROOT, CLAUDE_RUNS_ROOT, CLAUDE_TEMPLATE_PATH,
#   CLAUDE_WORKER_MCP_CONFIG, CLAUDE_WORKER_SETTINGS_PATH,
#   CLAUDE_WORKER_MODEL, CLAUDE_WORKER_MAX_TURNS,
#   CLAUDE_CLOSEOUT_STATE, CLAUDE_SELF_CLOSE_STATE,
#   CLAUDE_REQUIRE_ROUTING, CLAUDE_REQUIRED_LABEL,
#   CLAUDE_ALLOWED_PROJECT_REGEX, CLAUDE_ALLOWED_ASSIGNEE,
#   CLAUDE_WORKER_ENV_ALLOWLIST
#
# ============================================================================
set -euo pipefail

GRAPHQL_URL="https://api.linear.app/graphql"
TERMINAL_STATES=("Done" "Closed" "Cancelled" "Canceled" "Duplicate")

# Tmux session name pattern: cw-<issue-lower>. We use `=name:` everywhere as
# the target spec so tmux treats it as an EXACT match instead of prefix-matching
# (a known footgun: `tmux -t cw-team-12` would also match `cw-team-123`).
TMUX_SESSION_PREFIX="cw-"
TUI_BOOTSTRAP_SLEEP=8

usage() { sed -n '/^# Usage:/,/^# =====/p' "$0" | sed 's/^# \{0,1\}//' | head -n 30 >&2; }
die()   { echo "ERROR: $*" >&2; exit 1; }

truthy() {
  case "${1:-}" in 1|true|TRUE|yes|YES|on|ON) return 0 ;; *) return 1 ;; esac
}

reject_single_quote() {
  [[ "$2" != *"'"* ]] || die "$1 cannot contain single quotes: $2"
}

csv_contains() {
  local csv="$1" needle="$2" item
  [[ -n "$needle" ]] || return 1
  while IFS= read -r item; do [[ "$item" == "$needle" ]] && return 0; done < <(printf '%s' "$csv" | tr ',' '\n')
  return 1
}

is_terminal_state() {
  local state="$1" terminal
  for terminal in "${TERMINAL_STATES[@]}"; do [[ "$state" == "$terminal" ]] && return 0; done
  return 1
}

# Routing guard: does CLAUDE_ALLOWED_ASSIGNEE match this issue's assignee?
# Accepts a match against id, email, OR name (operator picks which they configure).
assignee_matches() {
  local allowed="$1" id="$2" email="$3" name="$4"
  [[ -n "$allowed" ]] || return 1
  [[ "$allowed" == "$id" || "$allowed" == "$email" || "$allowed" == "$name" ]]
}

abspath_from_launch_cwd() {
  case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s/%s\n' "$launch_cwd" "$1" ;; esac
}

# Re-query Linear for an issue's current state. Used after the worker
# finishes to verify the issue was actually moved to the closeout state.
query_issue_state() {
  local team_key="$1" issue_num="$2" response state header_file query_payload
  header_file=$(mktemp) || return 1
  # Linear personal API keys use bare `Authorization: <key>` (NOT `Bearer …`).
  # OAuth access tokens use `Bearer`. We support the personal-key form here
  # because that's what `LINEAR_API_KEY` is documented to be.
  printf 'Authorization: %s' "$LINEAR_API_KEY" > "$header_file"
  query_payload=$(jq -nc --arg tk "$team_key" --argjson n "$issue_num" \
    '{query:"query($tk:String!,$n:Float!){issues(filter:{team:{key:{eq:$tk}},number:{eq:$n}},first:1){nodes{state{name}}}}", variables:{tk:$tk,n:$n}}')
  response=$(curl -fsS -X POST "$GRAPHQL_URL" -H "Content-Type: application/json" \
    -H @"$header_file" -d "$query_payload" 2>/dev/null || true)
  rm -f "$header_file"
  state=$(printf '%s' "${response:-{}}" | jq -r '.data.issues.nodes[0].state.name // empty' 2>/dev/null || true)
  [[ -n "$state" ]] || return 1
  printf '%s' "$state"
}

# Render the worker prompt to a file. Issue description is piped through stdin
# so it never enters argv (shell-escape safety for arbitrary issue body).
render_prompt_file() {
  local output_path="$1" vars_file
  vars_file=$(mktemp) || die "mktemp failed"
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
    --arg run_dir "$run_dir" \
    --arg sentinel_path "$sentinel_path" \
    '{issue_id:$issue_id, issue_title:$issue_title, worktree_path:$worktree_path,
      branch:$branch, base_branch:$base_branch, repo_path:$repo_path,
      routing_profile:$routing_profile, model:$model, closeout_state:$closeout_state,
      run_dir:$run_dir, sentinel_path:$sentinel_path}' > "$vars_file"

  printf '%s' "$issue_description" | python3 -c '
import json, sys
vars = json.load(open(sys.argv[1]))
template = open(sys.argv[2]).read()
description = sys.stdin.read()
result = template
for placeholder, key in [
    ("{{ISSUE_ID}}", "issue_id"), ("{{ISSUE_TITLE}}", "issue_title"),
    ("{{WORKTREE_PATH}}", "worktree_path"), ("{{BRANCH}}", "branch"),
    ("{{BASE_BRANCH}}", "base_branch"), ("{{REPO_PATH}}", "repo_path"),
    ("{{ROUTING_PROFILE_PATH}}", "routing_profile"), ("{{MODEL}}", "model"),
    ("{{CLOSEOUT_STATE}}", "closeout_state"), ("{{RUN_DIR}}", "run_dir"),
    ("{{SENTINEL_PATH}}", "sentinel_path"),
]:
    result = result.replace(placeholder, vars[key])
result = result.replace("{{ISSUE_DESCRIPTION}}", description)
print(result)
' "$vars_file" "$TEMPLATE_PATH" > "$output_path"
  rm -f "$vars_file"
}

# Dismiss the two first-launch dialogs Claude Code shows in interactive mode:
#   1. "Yes, I trust this folder"  (cannot be skipped via flags as of 2.1.143)
#   2. "Bypass Permissions" warning (suppressed by --dangerously-skip-permissions
#      but kept defensive in case flag behavior changes)
# Each match is gated by capture-pane content; no dialog = no-op.
dismiss_first_launch_dialogs() {
  local session="$1" captured tries=0
  while (( tries < 6 )); do
    captured="$(tmux capture-pane -t "=$session:" -p 2>/dev/null | tr -d '\r' || true)"
    if [[ "$captured" == *"trust this folder"* ]]; then
      echo "[dispatch] trust dialog visible — sending Enter to accept"
      tmux send-keys -t "=$session:" Enter
      sleep 2; tries=$(( tries + 1 )); continue
    fi
    if [[ "$captured" == *"Bypass Permissions"* ]] && [[ "$captured" == *"accept"* ]]; then
      echo "[dispatch] bypass-mode warning visible — sending 2 + Enter"
      tmux send-keys -t "=$session:" "2"; sleep 1
      tmux send-keys -t "=$session:" Enter
      sleep 2; tries=$(( tries + 1 )); continue
    fi
    break
  done
}

# --- Configuration defaults ---
WORKSPACES_ROOT="${CLAUDE_WORKSPACES_ROOT:-./workspaces}"
RUNS_ROOT="${CLAUDE_RUNS_ROOT:-./runs}"
TEMPLATE_PATH="${CLAUDE_TEMPLATE_PATH:-./skills/symphony-claude-lane/assets/worker-prompt.template.md}"
MCP_CONFIG_PATH="${CLAUDE_WORKER_MCP_CONFIG:-./mcp/worker-mcp.json}"
SETTINGS_PATH="${CLAUDE_WORKER_SETTINGS_PATH:-./settings/claude-settings.tmux.json}"
DEFAULT_MODEL="${CLAUDE_WORKER_MODEL:-claude-opus-4-7}"
DEFAULT_MAX_TURNS="${CLAUDE_WORKER_MAX_TURNS:-50}"
DEFAULT_CLOSEOUT_STATE="${CLAUDE_CLOSEOUT_STATE:-In Review}"
DEFAULT_SELF_CLOSE_STATE="${CLAUDE_SELF_CLOSE_STATE:-Done}"
REQUIRE_ROUTING="${CLAUDE_REQUIRE_ROUTING:-true}"
REQUIRED_LABEL="${CLAUDE_REQUIRED_LABEL:-lane:claude}"
ALLOWED_PROJECT_REGEX="${CLAUDE_ALLOWED_PROJECT_REGEX:-}"
ALLOWED_ASSIGNEE="${CLAUDE_ALLOWED_ASSIGNEE:-}"

[[ $# -eq 0 || "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -lt 2 ]] && { usage; exit 2; }

issue_id="$1"; repo_path="$2"; shift 2
issue_id_upper=$(printf '%s' "$issue_id" | tr '[:lower:]' '[:upper:]')
issue_id_lower=$(printf '%s' "$issue_id_upper" | tr '[:upper:]' '[:lower:]')

branch="claude/${issue_id_lower}"
base_branch="main"
model="$DEFAULT_MODEL"
max_turns="$DEFAULT_MAX_TURNS"
closeout_state="$DEFAULT_CLOSEOUT_STATE"
self_close_requested=false
dry_run=false
allow_unrouted=false
timeout_sec=3600

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)         branch="${2:?--branch requires a value}"; shift 2 ;;
    --base)           base_branch="${2:?--base requires a value}"; shift 2 ;;
    --model)          model="${2:?--model requires a value}"; shift 2 ;;
    --max-turns)      max_turns="${2:?--max-turns requires a value}"; shift 2 ;;
    --closeout)       closeout_state="${2:?--closeout requires a value}"; shift 2 ;;
    --self-close)     closeout_state="$DEFAULT_SELF_CLOSE_STATE"; self_close_requested=true; shift ;;
    --allow-unrouted) allow_unrouted=true; shift ;;
    --dry-run)        dry_run=true; shift ;;
    --timeout)        timeout_sec="${2:?--timeout requires seconds}"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

launch_cwd=$(pwd -P)
repo_path=$(abspath_from_launch_cwd "$repo_path")
WORKSPACES_ROOT=$(abspath_from_launch_cwd "$WORKSPACES_ROOT")
RUNS_ROOT=$(abspath_from_launch_cwd "$RUNS_ROOT")
TEMPLATE_PATH=$(abspath_from_launch_cwd "$TEMPLATE_PATH")
MCP_CONFIG_PATH=$(abspath_from_launch_cwd "$MCP_CONFIG_PATH")
SETTINGS_PATH=$(abspath_from_launch_cwd "$SETTINGS_PATH")

# --- Input validation (also written to meta.env, so reject single quotes) ---
[[ "$issue_id_upper" =~ ^[A-Z][A-Z0-9]*-[0-9]+$ ]] || die "Invalid issue ID: $issue_id (expected TEAM-123)"
[[ "$max_turns" =~ ^[0-9]+$ && "$max_turns" -gt 0 ]] || die "--max-turns must be a positive integer"
[[ "$timeout_sec" =~ ^[0-9]+$ && "$timeout_sec" -gt 0 ]] || die "--timeout must be a positive integer"
for field in "Branch:$branch" "Base:$base_branch" "Repo:$repo_path" "Workspaces:$WORKSPACES_ROOT" \
             "Runs:$RUNS_ROOT" "Model:$model" "Closeout:$closeout_state" \
             "Label:$REQUIRED_LABEL" "Assignee:$ALLOWED_ASSIGNEE"; do
  reject_single_quote "${field%%:*}" "${field#*:}"
done

team_key="${issue_id_upper%%-*}"
issue_num="${issue_id_upper##*-}"
tmux_session="${TMUX_SESSION_PREFIX}${issue_id_lower}"

# --- Preflight ---
# env.sh must be sourced first — both for SYMPHONY_CLAUDE_ROOT (used by
# claude-doctor etc.) and for the PATH prepend that puts bin/claude-tmux-finalize
# in the operator's PATH so it propagates to the worker session.
[[ -n "${SYMPHONY_CLAUDE_ROOT:-}" ]] || die "SYMPHONY_CLAUDE_ROOT not set. Source env.sh first:
    source /path/to/symphony-claude-lane/env.sh"

for cmd in claude jq python3 curl git tmux; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd not found on PATH"
done
[[ -n "${LINEAR_API_KEY:-}" ]] || die "LINEAR_API_KEY not set"
[[ -d "$repo_path/.git" ]]    || die "$repo_path is not a git repo"
[[ -f "$TEMPLATE_PATH" ]]     || die "Template not found: $TEMPLATE_PATH"
[[ -f "$MCP_CONFIG_PATH" ]]   || die "MCP config not found: $MCP_CONFIG_PATH"
[[ -f "$SETTINGS_PATH" ]]     || die "Settings file not found: $SETTINGS_PATH"

# --- Step 1: Fetch Linear issue (auth header via temp file to keep it out of argv) ---
echo ">>> Fetching $issue_id_upper from Linear..."

auth_file=$(mktemp) || die "mktemp failed"
# Linear personal API keys use bare `Authorization: <key>` (NOT `Bearer …`).
printf 'Authorization: %s' "$LINEAR_API_KEY" > "$auth_file"
trap 'rm -f "$auth_file"' EXIT

query=$(jq -nc --arg tk "$team_key" --argjson n "$issue_num" \
  '{query:"query($tk:String!,$n:Float!){issues(filter:{team:{key:{eq:$tk}},number:{eq:$n}},first:1){nodes{id identifier title description state{name} project{name} assignee{id email name} labels{nodes{name}}}}}", variables:{tk:$tk,n:$n}}')

response=$(curl -fsS -X POST "$GRAPHQL_URL" -H "Content-Type: application/json" \
  -H @"$auth_file" -d "$query" 2>/dev/null || echo '{}')
rm -f "$auth_file"; trap - EXIT

issue_title=$(printf '%s' "$response"       | jq -r '.data.issues.nodes[0].title // empty')
issue_description=$(printf '%s' "$response" | jq -r '.data.issues.nodes[0].description // ""')
issue_state=$(printf '%s' "$response"       | jq -r '.data.issues.nodes[0].state.name // "Unknown"')
project_name=$(printf '%s' "$response"      | jq -r '.data.issues.nodes[0].project.name // ""')
assignee_id=$(printf '%s' "$response"       | jq -r '.data.issues.nodes[0].assignee.id // ""')
assignee_email=$(printf '%s' "$response"    | jq -r '.data.issues.nodes[0].assignee.email // ""')
assignee_name=$(printf '%s' "$response"     | jq -r '.data.issues.nodes[0].assignee.name // ""')
issue_labels=$(printf '%s' "$response"      | jq -r '.data.issues.nodes[0].labels.nodes[]?.name' | paste -sd ',' -)

[[ -n "$issue_title" ]] || die "Issue $issue_id_upper not found in Linear"
is_terminal_state "$issue_state" && die "Issue $issue_id_upper is already $issue_state"

echo "    Title: $issue_title"
echo "    State: $issue_state"
[[ -n "$project_name" ]] && echo "    Project: $project_name"
[[ -n "$assignee_email" || -n "$assignee_name" ]] && echo "    Assignee: ${assignee_email:-$assignee_name}"
[[ -n "$issue_labels" ]] && echo "    Labels: $issue_labels"

# --- Routing guardrails (fail-closed by default) ---
# Three independent guards. ANY match is sufficient.
routing_reasons=()
csv_contains "$issue_labels" "$REQUIRED_LABEL" && routing_reasons+=("label")
[[ -n "$ALLOWED_PROJECT_REGEX" && "$project_name" =~ $ALLOWED_PROJECT_REGEX ]] && routing_reasons+=("project")
assignee_matches "$ALLOWED_ASSIGNEE" "$assignee_id" "$assignee_email" "$assignee_name" && routing_reasons+=("assignee")
routing_summary="none"
(( ${#routing_reasons[@]} > 0 )) && routing_summary=$(IFS=,; echo "${routing_reasons[*]}")

if truthy "$REQUIRE_ROUTING" && [[ "$allow_unrouted" != "true" ]] && (( ${#routing_reasons[@]} == 0 )); then
  die "Issue $issue_id_upper is not explicitly routed to Claude (required label: $REQUIRED_LABEL).
    Actual labels: ${issue_labels:-<none>}
    Use --allow-unrouted only for a deliberate trusted dispatch."
fi
echo "    Routing: $routing_summary"
echo "    Closeout: $closeout_state"

# --- Derived paths ---
worktree_path="$WORKSPACES_ROOT/$issue_id_upper"
run_dir="$RUNS_ROOT/$issue_id_upper"
sentinel_path="$run_dir/.symphony-done"

# --- Dry run: render prompt to a temp file, validate trust boundary, exit ---
if [[ "$dry_run" == true ]]; then
  dry_prompt=$(mktemp) || die "mktemp failed"
  render_prompt_file "$dry_prompt"
  grep -q '<issue_body>' "$dry_prompt"   || die "Rendered prompt missing <issue_body> boundary"
  grep -q '</issue_body>' "$dry_prompt"  || die "Rendered prompt missing </issue_body> boundary"
  rm -f "$dry_prompt"
  echo ""
  echo "=== DRY RUN ==="
  echo "Would create worktree:  $worktree_path"
  echo "Would create branch:    $branch from $base_branch"
  echo "Would create tmux:      $tmux_session"
  echo "Would render prompt to: $run_dir/prompt.md"
  echo "Worker will signal via: $sentinel_path"
  echo "Would close out as:     $closeout_state"
  exit 0
fi

# --- Step 2: Stale-sentinel guard ---
# If a prior run left a sentinel, refuse to dispatch. The operator must clean
# up the run dir (or use --resume in a fuller dispatcher).
[[ -e "$sentinel_path" ]] && die "Stale sentinel exists at $sentinel_path — refusing to dispatch"

mkdir -p "$run_dir" "$WORKSPACES_ROOT"

# --- Step 3: Create worktree ---
if [[ -d "$worktree_path" ]]; then
  die "Worktree already exists: $worktree_path
    To remove: git -C $repo_path worktree remove --force $worktree_path"
fi
echo ">>> Creating worktree: $worktree_path (branch: $branch from $base_branch)"
git -C "$repo_path" worktree add "$worktree_path" -b "$branch" "$base_branch"

# --- Step 4: Copy per-worktree settings so Claude honors bypassPermissions ---
mkdir -p "$worktree_path/.claude"
cp "$SETTINGS_PATH" "$worktree_path/.claude/settings.json"

# --- Step 5: Render prompt ---
echo ">>> Rendering prompt..."
render_prompt_file "$run_dir/prompt.md"

# --- Step 6: Write initial metadata ---
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
backend='tmux'
tmux_session='$tmux_session'
sentinel_path='$sentinel_path'
pid='$$'
session_id=''
exit_reason=''
outcome_posted=''
end_time=''
status='running'
closeout_state='$closeout_state'
self_close_requested='$self_close_requested'
closeout_verified='unchecked'
linear_state_actual=''
routing='$routing_summary'
integrated='false'
METAEOF

# --- Step 7: Spawn the tmux-backed Claude session ---
# Notes:
#   - We use `=$session:` everywhere (exact-pane match). Bare `-t $session`
#     would prefix-match and could target the wrong session.
#   - The `claude` invocation is interactive (no `-p`). The worker will read
#     the prompt we paste with `tmux send-keys` next.
#   - **Env isolation primitive: `env -i`, NOT `tmux new-session -e`.**
#     `tmux -e VAR=value` ADDS vars; it does not RESTRICT. To actually scope
#     the worker's env to just the allowlist, we wrap the `claude` invocation
#     in `env -i $allowlisted_var=value ... claude …`. The worker process then
#     sees ONLY the allowlisted vars (plus the dispatcher-set sentinel path).
#     This is the load-bearing safety primitive.

echo ">>> Spawning tmux session: $tmux_session (model: $model, max-turns: $max_turns)"

# Build the `env -i` prefix from $CLAUDE_WORKER_ENV_ALLOWLIST. Forward each
# var only if it's actually set in the dispatcher's env; missing vars are
# omitted (no `VAR=` empty entries that could mask absence).
worker_allowlist="${CLAUDE_WORKER_ENV_ALLOWLIST:-HOME PATH SHELL TMPDIR USER LOGNAME LANG LC_ALL LC_CTYPE SSH_AUTH_SOCK LINEAR_API_KEY ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR XDG_CONFIG_HOME XDG_CACHE_HOME PLAYWRIGHT_BROWSERS_PATH}"
env_args=(env -i)
for _var in $worker_allowlist; do
  [[ "$_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue   # ignore garbage names
  if [[ -n "${!_var+x}" ]]; then
    env_args+=("$_var=${!_var}")
  fi
done
# The dispatcher always tells the worker where to write the sentinel.
env_args+=("CLAUDE_TMUX_SENTINEL_PATH=$sentinel_path")

tmux new-session -d -s "$tmux_session" -c "$worktree_path" \
  -- "${env_args[@]}" \
     claude --model "$model" --max-turns "$max_turns" \
            --mcp-config "$MCP_CONFIG_PATH" \
            --dangerously-skip-permissions

# Cleanup: if dispatcher setup fails before the monitor takes over, kill the
# session so we don't leak. Disarmed once monitor_and_teardown is in charge.
_handoff_complete=false
cleanup_on_failure() {
  [[ "$_handoff_complete" == "true" ]] && return
  tmux has-session -t "=$tmux_session:" 2>/dev/null && \
    tmux kill-session -t "=$tmux_session:" 2>/dev/null || true
}
trap cleanup_on_failure EXIT

# Wait for TUI to bootstrap (Claude's startup splash, MCP load, etc.)
sleep "$TUI_BOOTSTRAP_SLEEP"

# Dismiss first-launch dialogs (trust + bypass warning) before pasting the prompt.
dismiss_first_launch_dialogs "$tmux_session"
sleep 1

# Paste the prompt via load-buffer → paste-buffer (handles multi-line + special chars).
tmux load-buffer -b "claude-prompt-$tmux_session" "$run_dir/prompt.md"
tmux paste-buffer -b "claude-prompt-$tmux_session" -t "=$tmux_session:" -d
sleep 1
tmux send-keys -t "=$tmux_session:" Enter

echo ">>> Worker started. Polling for sentinel at $sentinel_path (timeout: ${timeout_sec}s)..."
echo "    Attach to watch live: tmux attach -t =$tmux_session"

# --- Step 8: Monitor — poll for sentinel, detect early session death, enforce timeout ---
final_status="incomplete"
exit_reason=""
sentinel_session_id=""
sentinel_outcome_posted="false"
elapsed=0
poll_interval=5

while (( elapsed < timeout_sec )); do
  if [[ -f "$sentinel_path" ]]; then
    echo "[monitor] sentinel detected after ${elapsed}s"
    sentinel_json="$(cat "$sentinel_path" 2>/dev/null || echo '{}')"

    # Validate sentinel is a JSON object before extracting fields. Without this
    # guard a partial / truncated / corrupted sentinel would silently coerce to
    # "incomplete" — we instead detect and surface the corruption.
    if ! printf '%s' "$sentinel_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
      echo "[monitor] sentinel at $sentinel_path is malformed JSON — treating as session_died (corrupted sentinel)" >&2
      final_status="failed"
      exit_reason="sentinel_malformed"
    else
      final_status="$(jq -r '.status // "incomplete"' <<<"$sentinel_json")"
      exit_reason="$(jq -r '.exit_reason // "normal"' <<<"$sentinel_json")"
      sentinel_session_id="$(jq -r '.session_id // ""' <<<"$sentinel_json")"
      # outcome_posted tells the dispatcher whether the worker successfully
      # posted its outcome comment to Linear. A `completed` run with
      # outcome_posted=false is the classic case for a dispatcher to post a
      # fallback comment (the internal lane does this via
      # $CLAUDE_TMUX_RECONCILE; this abridged reference just records it).
      sentinel_outcome_posted="$(jq -r '.outcome_posted // false' <<<"$sentinel_json")"
    fi
    break
  fi

  # Detect tmux session death before the worker wrote a sentinel.
  if ! tmux has-session -t "=$tmux_session:" 2>/dev/null; then
    echo "[monitor] tmux session died before sentinel — worker crashed?" >&2
    final_status="failed"
    exit_reason="session_died"
    break
  fi

  sleep "$poll_interval"
  elapsed=$(( elapsed + poll_interval ))
done

if [[ "$final_status" == "incomplete" ]]; then
  echo "[monitor] timeout after ${timeout_sec}s — declaring failed"
  final_status="failed"
  exit_reason="timeout"
fi

# Try to send a clean /exit if the session is still alive, then kill it.
if tmux has-session -t "=$tmux_session:" 2>/dev/null; then
  tmux send-keys -t "=$tmux_session:" "/exit" Enter 2>/dev/null || true
  sleep 2
  tmux kill-session -t "=$tmux_session:" 2>/dev/null || true
fi

# --- Step 9: Closeout verification via Linear re-query ---
linear_state_actual=""
closeout_verified="not_applicable"
if [[ "$final_status" == "completed" ]]; then
  if linear_state_actual=$(query_issue_state "$team_key" "$issue_num" 2>/dev/null); then
    linear_state_actual="${linear_state_actual//\'/}"
    if [[ "$linear_state_actual" == "$closeout_state" ]]; then
      closeout_verified="true"
    else
      closeout_verified="false"
    fi
  else
    closeout_verified="check_failed"
  fi
fi

# --- Step 10: Rewrite meta.env atomically ---
tmp_meta=$(mktemp "${run_dir}/meta.env.XXXXXX")
cat > "$tmp_meta" <<METAEOF2
issue_id='$issue_id_upper'
repo_path='$repo_path'
worktree_path='$worktree_path'
branch='$branch'
base_branch='$base_branch'
start_time='$start_time'
model='$model'
max_turns='$max_turns'
backend='tmux'
tmux_session='$tmux_session'
sentinel_path='$sentinel_path'
pid=''
session_id='$sentinel_session_id'
exit_reason='$exit_reason'
outcome_posted='$sentinel_outcome_posted'
end_time='$(date -u +%Y-%m-%dT%H:%M:%SZ)'
status='$final_status'
closeout_state='$closeout_state'
self_close_requested='$self_close_requested'
closeout_verified='$closeout_verified'
linear_state_actual='$linear_state_actual'
routing='$routing_summary'
integrated='false'
METAEOF2
mv "$tmp_meta" "$run_dir/meta.env"

_handoff_complete=true
trap - EXIT

echo ""
echo ">>> Worker finished: $final_status (exit_reason: $exit_reason)"
[[ "$final_status" == "completed" ]] && echo "    Closeout verified: $closeout_verified"
[[ -n "$linear_state_actual" ]] && echo "    Linear state: $linear_state_actual"

[[ "$final_status" == "completed" ]] && exit 0
exit 1
