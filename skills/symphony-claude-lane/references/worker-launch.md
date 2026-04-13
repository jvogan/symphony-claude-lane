# Worker Launch

Use this reference when setting up Claude worker dispatch alongside an existing Symphony/Codex workflow.

## Overview

A Claude worker is a `claude -p` process running in an isolated git worktree against a single Linear issue. The launch pattern is the same regardless of whether you run mixed-model (Claude + Codex) or Claude-only.

## Launch sequence

### Step 1 — Fetch the issue

Query Linear's GraphQL API for the issue's title, description, and state.

```
POST https://api.linear.app/graphql
```

**Security:** Write the `Authorization: Bearer $LINEAR_API_KEY` header to a temp file and pass it via `curl -H @file`. Delete the temp file immediately after the request. This prevents the API key from appearing in the process argument list (`ps aux`).

**Guard:** If the issue state is terminal (`Done`, `Closed`, `Cancelled`, `Duplicate`), abort — never dispatch a worker against a completed issue.

### Step 2 — Create a git worktree

```bash
git -C "$REPO_PATH" worktree add "$WORKSPACES_ROOT/$ISSUE_ID" -b "$BRANCH" "$BASE_BRANCH"
```

Each worker gets its own worktree so multiple workers can run in parallel without conflicts. The branch name defaults to `claude/<issue-id-lowercase>`.

**Guard:** If the worktree already exists and this is not a `--resume`, abort and show a message explaining how to remove it or resume the previous session.

**Input validation:** Reject branch names containing single quotes to prevent shell injection into metadata files.

### Step 3 — Render the prompt

Use the worker prompt template (`assets/worker-prompt.template.md`) and substitute placeholder variables:

| Variable | Value |
|---|---|
| `{{ISSUE_ID}}` | The Linear issue identifier (e.g. `TEAM-42`) |
| `{{ISSUE_TITLE}}` | Issue title from Linear |
| `{{ISSUE_DESCRIPTION}}` | Issue body from Linear |
| `{{REPO_PATH}}` | Absolute path to the source repo |
| `{{WORKTREE_PATH}}` | Absolute path to this worker's worktree |
| `{{BRANCH}}` | Worker's feature branch name |
| `{{BASE_BRANCH}}` | Branch the worktree was created from |
| `{{ROUTING_PROFILE_PATH}}` | Path to `.orchestration/claude-lane.yaml` |
| `{{MODEL}}` | Model identifier (e.g. `claude-opus-4-6`) |

**Security:** Pass the issue description via **stdin** to the rendering script, not as a shell argument. This prevents shell expansion of user-supplied content that may contain backticks, quotes, dollar signs, or newlines.

Save the rendered prompt to `$RUNS_ROOT/$ISSUE_ID/prompt.md` for debugging and auditability.

### Step 4 — Write run metadata

Create a metadata file at `$RUNS_ROOT/$ISSUE_ID/meta.env`:

```
issue_id='TEAM-42'
repo_path='/path/to/repo'
worktree_path='/path/to/worktrees/TEAM-42'
branch='claude/team-42'
base_branch='main'
start_time='2026-04-13T08:00:00Z'
model='claude-opus-4-6'
max_turns='50'
pid=''
session_id=''
exit_code=''
end_time=''
status='starting'
```

**Security:** All values are single-quoted. This file must **never** be `source`d — always parse with `grep + sed`. A worker that writes malicious content to its run directory must not be able to execute arbitrary code through the status or cleanup scripts.

### Step 5 — Launch `claude -p`

```bash
cd "$WORKTREE_PATH"
claude -p "$RENDERED_PROMPT" \
    --model "$MODEL" \
    --name "claude-worker-${ISSUE_ID_LOWER}" \
    --mcp-config "$MCP_CONFIG_PATH" \
    --dangerously-skip-permissions \
    --max-turns "$MAX_TURNS" \
    --output-format stream-json \
    --verbose \
    > "$RUNS_ROOT/$ISSUE_ID/output.jsonl" 2>&1
```

Key flags:

| Flag | Purpose |
|---|---|
| `--model` | Explicit model selection from the routing profile |
| `--name` | Human-readable label for the session |
| `--mcp-config` | Points to the MCP config giving workers Linear access |
| `--dangerously-skip-permissions` | Full filesystem access, no interactive prompts |
| `--max-turns` | Hard cap on agent turns (default 50) |
| `--output-format stream-json` | Each event is a JSON line for parsing |

**Working directory** must be the worktree, not the source repo. The worker should only see and modify files in its own worktree.

**Background mode (optional):** If your orchestrator needs non-blocking dispatch, wrap the launch in a subshell backgrounded with `&`. Write the PID to `$RUNS_ROOT/$ISSUE_ID/worker.pid` atomically from inside the subshell. The outer process reads back the PID and exits. The reference launcher runs in foreground by default — adapt to background if needed.

### Step 6 — Finalize

After `claude -p` exits:

1. Parse `output.jsonl` for the last `result` event to extract `session_id` and determine status.
2. **Validate `session_id`** against `/^[a-f0-9A-F-]+$/` before writing to meta.env — prevents injection of shell metacharacters through the output stream.
3. Determine final status: `is_error=false` + `subtype=success` → `completed`; otherwise `failed`; no result event → `incomplete`.
4. Rewrite `meta.env` atomically (write to temp file, then `mv`).
5. If the session failed and a valid `session_id` was found, print the resume command: `claude --resume <session_id>`.

**Signal handling:** Trap `SIGTERM`/`SIGINT` to set exit code 143 and still run finalization, ensuring metadata and session ID are captured even on kill or timeout.

## MCP configuration

Workers need Linear access to read issue details and post closeout comments. A minimal MCP config:

```json
{
  "mcpServers": {
    "linear": {
      "type": "http",
      "url": "https://mcp.linear.app/mcp",
      "headers": {
        "Authorization": "Bearer ${LINEAR_API_KEY}"
      }
    }
  }
}
```

The `${LINEAR_API_KEY}` reference is resolved by Claude Code at launch time from the environment. The key is never written into the config file itself.

## Status checking

Scan `$RUNS_ROOT/*/meta.env` for active runs:

1. Parse each `meta.env` with `grep + sed` (never `source`).
2. Liveness check: `kill -0 $pid` to detect if the worker process is still running.
3. Optionally re-query Linear for current issue state.
4. Compute elapsed time from `start_time`.

## Cleanup

For each completed run:

1. Skip any run whose worker PID is still alive.
2. Check Linear for terminal issue state (unless forcing).
3. Apply age filter (default: keep runs younger than 1 day).
4. Remove the git worktree: `git -C $REPO_PATH worktree remove --force $WORKTREE_PATH`.
5. Attempt soft branch delete: `git -C $REPO_PATH branch -d $BRANCH` (only works if merged).
6. Remove the run directory.

**Integration verification:** Terminal issue state alone is not sufficient. Verify the branch was actually merged or the snapshot was promoted before removing the worktree. See `references/closeout.md` for details.

## Resume

If a worker fails or is interrupted and a `session_id` was captured:

```bash
cd "$WORKTREE_PATH"
claude --resume "$SESSION_ID" \
    --model "$MODEL" \
    --mcp-config "$MCP_CONFIG_PATH" \
    --dangerously-skip-permissions \
    --max-turns "$MAX_TURNS"
```

The worktree and branch are preserved. The worker picks up where it left off.

## Security checklist

| Practice | Why |
|---|---|
| API key via temp file + `curl -H @file` | Prevents key appearing in `ps aux` |
| Issue description via stdin | Prevents shell expansion of user content |
| Branch name validation (reject `'`) | Prevents injection into single-quoted meta.env |
| meta.env never `source`d | Prevents code execution from worker-written files |
| session_id regex validation | Prevents metacharacter injection from output stream |
| Prompt injection boundary (`<issue_body>` tags) | Worker treats issue content as data, not instructions |
| Worktree isolation | Workers can only modify their own copy of the repo |
| `--max-turns` hard cap | Prevents runaway sessions from burning unlimited tokens |
