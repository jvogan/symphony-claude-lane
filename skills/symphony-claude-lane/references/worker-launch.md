# Worker Launch

Use this reference when setting up Claude worker dispatch alongside an existing Symphony/Codex workflow.

## Overview

A Claude worker is an **interactive Claude Code session running inside a detached tmux pane**, scoped to an isolated git worktree against a single Linear issue. The worker signals completion by writing a JSON sentinel file (via the bundled `bin/claude-tmux-finalize` helper); the dispatcher polls for that file and uses it to tear down the tmux session.

Why tmux (vs `claude -p` subprocess mode):

- **Billing.** Interactive sessions bill against the operator's Claude subscription, not the Agent SDK credit bucket.
- **Behavior parity.** The worker sees the same TUI surface, tool gating, and permission model as an attended interactive session — fewer surprises.
- **Observability.** `tmux attach -t =cw-<issue-lower>` lets the operator watch any worker mid-flight.

The trade-off: there is no exit code. Completion signaling moves to the sentinel JSON contract documented in `docs/architecture.md`.

The launch pattern is the same whether you run mixed-model (Claude + Codex) or Claude-only.

## Launch sequence

### Step 1 — Fetch the issue

Query Linear's GraphQL API for the issue's title, description, state, project, labels, and assignee.

```
POST https://api.linear.app/graphql
```

**Security:** Write the `Authorization: $LINEAR_API_KEY` header (bare, **not** `Bearer …` — Linear personal API keys use the bare form; OAuth access tokens and the Linear MCP HTTP transport use `Bearer`) to a temp file and pass it via `curl -H @file`. Delete the temp file immediately after the request. This prevents the API key from appearing in the process argument list (`ps aux`).

**Guard:** If the issue state is terminal (`Done`, `Closed`, `Cancelled`, `Canceled`, `Duplicate`), abort — never dispatch a worker against a completed issue.

**Routing guard:** A worker launcher should fail closed unless the issue is explicitly routed to Claude. Common portable guards are:

- a Linear label such as `lane:claude`
- a project name matching an operator-configured regex such as `Claude`
- a configured assignee id, email, or name

Provide an explicit override such as `--allow-unrouted` only for trusted manual dispatch.

### Step 2 — Create a git worktree

```bash
git -C "$REPO_PATH" worktree add "$WORKSPACES_ROOT/$ISSUE_ID" -b "$BRANCH" "$BASE_BRANCH"
```

Each worker gets its own worktree so multiple workers can run in parallel without conflicts. The branch name defaults to `claude/<issue-id-lowercase>`.

**Guard:** If the worktree already exists, abort and show a message explaining how to remove it.

**Per-worktree settings:** Copy `settings/claude-settings.tmux.json` into `<worktree>/.claude/settings.json` before starting the tmux session. The settings file enables `bypassPermissions` so the interactive Claude session does not prompt for tool approval. The trust model is bounded by the routing guard, the worktree boundary, and the per-issue branch.

**Input validation:** Reject single quotes in any value written to `meta.env`, including branch, base branch, repo path, model id, closeout state, required label, and assignee. Validate issue ids as `TEAM-123` and validate `--max-turns` as a positive integer.

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
| `{{MODEL}}` | Model identifier (e.g. `claude-opus-4-7`) |
| `{{CLOSEOUT_STATE}}` | Tracker state the worker should use after success, usually `In Review` |
| `{{RUN_DIR}}` | Absolute path to this worker's run directory |
| `{{SENTINEL_PATH}}` | Absolute path the worker writes the completion sentinel to |

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
model='claude-opus-4-7'
max_turns='50'
backend='tmux'
tmux_session='cw-team-42'
sentinel_path='/path/to/runs/TEAM-42/.symphony-done'
pid=''
session_id=''
exit_reason=''
end_time=''
status='running'
closeout_state='In Review'
self_close_requested='false'
closeout_verified='unchecked'
linear_state_actual=''
routing='label'
integrated='false'
```

**Security:** All values are single-quoted. This file must **never** be `source`d — always parse with `grep + sed`. A worker that writes malicious content to its run directory must not be able to execute arbitrary code through the status or cleanup scripts.

`closeout_verified` should use a small explicit vocabulary:

- `unchecked`: launcher has not yet verified tracker state
- `true`: worker completed and the issue reached the requested closeout state
- `false`: worker completed but the issue did not reach the requested state
- `check_failed`: tracker state could not be checked
- `not_applicable`: worker did not complete successfully

`exit_reason` should use this vocabulary (defined by the sentinel JSON contract):

- `normal`: worker finished successfully
- `blocker`: worker stopped on an external blocker
- `timeout`: worker hit its turn or wall-clock budget
- `partial`: worker delivered a subset of the acceptance criteria
- `session_died`: tmux session died before the worker wrote a sentinel
- `sentinel_malformed`: sentinel file existed but was not valid JSON (treat as `session_died` with corruption)

Status and health tooling should surface `false` and `check_failed` as warnings. A prompt instructing the worker to move an issue is not proof that the tracker state changed.

### Step 5 — Spawn the tmux session

```bash
tmux new-session -d -s "$TMUX_SESSION" -c "$WORKTREE_PATH" \
    -e "CLAUDE_TMUX_SENTINEL_PATH=$SENTINEL_PATH" \
    -e "LINEAR_API_KEY=$LINEAR_API_KEY" \
    -- claude --model "$MODEL" --max-turns "$MAX_TURNS" \
             --mcp-config "$MCP_CONFIG_PATH" \
             --dangerously-skip-permissions
```

Key elements:

| Element | Purpose |
|---|---|
| `tmux new-session -d` | Detached session (operator can attach with `tmux attach`) |
| `-s "$TMUX_SESSION"` | Stable session name pattern (e.g. `cw-<issue-id-lower>`) |
| `-c "$WORKTREE_PATH"` | Start the session inside the worktree |
| `-e VAR=value` | Per-session environment (no broad operator-shell leak) |
| `claude --model` | Explicit model selection from the routing profile |
| `--max-turns` | Hard cap on agent turns (default 50) |
| `--mcp-config` | Points to the MCP config giving the worker Linear access |
| `--dangerously-skip-permissions` | Full filesystem access, no interactive prompts |

**Exact-match target convention:** When sending tmux commands to the session, use `=$TMUX_SESSION:` (with the trailing colon for the default pane) or `=$TMUX_SESSION` (for the session itself). The bare `-t $name` form prefix-matches and will silently target the wrong session if any other session shares the prefix (e.g. `cw-team-12` would match both `cw-team-12` and `cw-team-123`).

**First-launch dialogs:** Real Claude Code shows two modal dialogs on first launch in a directory: the "trust this folder" dialog and (occasionally) a "bypass permissions" warning. Neither is suppressed by command flags as of Claude Code 2.1.143. The launcher should detect and dismiss these via `tmux capture-pane` + `tmux send-keys` before pasting the prompt. See `docs/lessons.md` for the specific sequence.

**Prompt paste:** After the TUI bootstraps and any dialogs are dismissed, load the rendered prompt into a tmux buffer and paste it:

```bash
tmux load-buffer -b "claude-prompt-$TMUX_SESSION" "$RUNS_ROOT/$ISSUE_ID/prompt.md"
tmux paste-buffer -b "claude-prompt-$TMUX_SESSION" -t "=$TMUX_SESSION:" -d
tmux send-keys -t "=$TMUX_SESSION:" Enter
```

`load-buffer` + `paste-buffer` handles multi-line content and special characters correctly. Sending the prompt one keystroke at a time via `send-keys` is fragile and slow.

**Working directory** must be the worktree, not the source repo. The worker should only see and modify files in its own worktree.

**Environment isolation primitive: `env -i`, not `tmux new-session -e`.** `tmux -e VAR=value` ADDS to the session env; it does NOT RESTRICT. To actually scope what the worker sees, wrap the `claude` invocation in `env -i $allowlisted_var=value ... claude …` and pass that to tmux as the session's startup command. The worker process then sees ONLY the allowlisted vars (plus the dispatcher-set `CLAUDE_TMUX_SENTINEL_PATH`). This is load-bearing: a worker with extraneous secrets in its env can bypass MCP gates and leak through model output. The reference launcher demonstrates the pattern.

**Dry run:** A safe `--dry-run` should validate the issue and routing, render the prompt to a temporary file, verify the `<issue_body>` trust boundary is present, then print the worktree, branch, model, closeout state, and tmux session name without creating a worktree, run directory, prompt, or tmux session.

### Step 6 — Monitor & finalize

The monitor loop polls for the sentinel file, detects early tmux session death, and enforces a wall-clock timeout:

```bash
elapsed=0
while (( elapsed < TIMEOUT_SEC )); do
  if [[ -f "$SENTINEL_PATH" ]]; then
    # Sentinel arrived — parse it.
    break
  fi
  if ! tmux has-session -t "=$TMUX_SESSION:" 2>/dev/null; then
    # tmux session died before the worker wrote a sentinel.
    break
  fi
  sleep 5
  elapsed=$(( elapsed + 5 ))
done
```

**Sentinel JSON validation (load-bearing):** Before extracting fields, validate the sentinel is a JSON object. A partial / truncated / corrupted sentinel would silently coerce to `incomplete` without this guard:

```bash
sentinel_json="$(cat "$SENTINEL_PATH")"
if ! printf '%s' "$sentinel_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
  final_status="failed"
  exit_reason="sentinel_malformed"
else
  final_status="$(jq -r '.status // "incomplete"' <<<"$sentinel_json")"
  exit_reason="$(jq -r '.exit_reason // "normal"' <<<"$sentinel_json")"
  sentinel_session_id="$(jq -r '.session_id // ""' <<<"$sentinel_json")"
fi
```

The sentinel JSON schema is documented in full in `docs/architecture.md`.

**Closeout verification:** If `final_status == completed`, re-query Linear and compare the actual issue state to the rendered closeout state. Record `closeout_verified` and `linear_state_actual`.

**Atomic meta.env rewrite:** Write the updated metadata to a temp file in the same directory, then `mv` it over the original. This prevents readers from seeing a partial file.

**Teardown:** After parsing, attempt a clean `/exit` if the tmux session is still alive, give it a couple seconds, then `tmux kill-session -t "=$TMUX_SESSION:"`. Cleanup must run even if the dispatcher itself is killed — set a trap on `SIGTERM`/`SIGINT`/`EXIT` that kills the session.

**Resume:** Tmux sessions are inherently attachable while live. To watch a running worker: `tmux attach -t =cw-<issue-lower>`. After teardown, the worktree and branch are preserved; a fuller dispatcher can offer an explicit `--resume` flow.

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

**RunPod opt-in:** If a worker needs the RunPod MCP, switch to `mcp/worker-mcp-runpod.json` (or set `CLAUDE_WORKER_ENABLE_RUNPOD=true` and re-source `env.sh`). The RunPod MCP and the `RUNPOD_API_KEY` env var are jointly gated — the worker does not receive RunPod credentials unless the lane explicitly opts in. See `docs/architecture.md` §"MCP defense-in-depth" for the rationale.

## Status checking

Scan `$RUNS_ROOT/*/meta.env` for active runs:

1. Parse each `meta.env` with `grep + sed` (never `source`).
2. **Liveness check** depends on the `backend` field. For `backend='tmux'`, use `tmux has-session -t "=$tmux_session:"` and check for the sentinel file. For each combination, the live/done/orphan branch is:
   - tmux session alive, no sentinel → `running`
   - tmux session alive, sentinel present → `cleanup_pending` (rare, race)
   - tmux session dead, sentinel present → `completed` or `orphan_finalize_pending`
   - tmux session dead, no sentinel → `orphan_dead`
3. Optionally re-query Linear for current issue state.
4. Compute elapsed time from `start_time`.
5. Surface `closeout_verified=false` and `closeout_verified=check_failed` as warnings instead of assuming a clean worker exit means the issue was moved correctly.

## Cleanup

For each completed run:

1. Skip any run whose tmux session is still alive (`tmux has-session -t "=$tmux_session:"`).
2. Check Linear for terminal issue state (unless forcing).
3. Apply age filter (default: keep runs younger than 1 day).
4. Remove the git worktree: `git -C $REPO_PATH worktree remove --force $WORKTREE_PATH`.
5. Attempt soft branch delete: `git -C $REPO_PATH branch -d $BRANCH` (only works if merged).
6. Remove the run directory.

**Integration verification:** Terminal issue state alone is not sufficient. Verify the branch was actually merged or the snapshot was promoted before removing the worktree. See `references/closeout.md` for details.

## Security checklist

| Practice | Why |
|---|---|
| API key via temp file + `curl -H @file` | Prevents key appearing in `ps aux` |
| Issue description via stdin | Prevents shell expansion of user content |
| Routing guard before dispatch | Prevents unrelated Linear issues from driving full-access workers |
| Input validation for meta.env fields | Prevents injection into single-quoted meta.env |
| meta.env never `source`d | Prevents code execution from worker-written files |
| Prompt injection boundary (`<issue_body>` tags) | Worker treats issue content as data, not instructions |
| Worktree isolation | Workers can only modify their own copy of the repo |
| `env -i $allowlisted=value ... claude` inside tmux | Restricts the worker's env to the allowlist (tmux's own `-e` flag only ADDS, not RESTRICTS — `env -i` is the actual isolation primitive) |
| Exact-target `=name:` in all tmux commands | Prevents prefix-match accidents (`cw-12` matching `cw-123`) |
| `--max-turns` hard cap | Prevents runaway sessions from burning unlimited tokens |
| Sentinel JSON validation (`jq -e 'type == "object"'`) | Prevents silent coercion of a corrupted sentinel to "incomplete" |
| Closeout verification metadata | Separates worker success from verified tracker state |
| MCP + env allowlist jointly gated on RunPod opt-in | A worker cannot bypass the MCP gate via raw `curl` if RunPod creds are also withheld |
| `.claude/settings.json` per worktree | bypassPermissions is scoped, not session-wide |
