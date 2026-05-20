# Architecture

The patterns the v0.8.x hardening round produced for the tmux backend. This doc is for adopters who want to understand the *why* before adapting the reference launcher.

## Why tmux instead of `claude -p`

Three reasons:

1. **Billing.** Interactive Claude Code sessions bill against the operator's Claude subscription. `claude -p` subprocess invocations bill against the Agent SDK credit bucket. For long-running batch work, the subscription model is dramatically cheaper.
2. **Behavior parity.** The interactive session is the canonical Claude Code surface — TUI rendering, tool gating, permission prompts, MCP loading, dialog handling all work the same way as a normal session. A `claude -p` subprocess takes a different code path that occasionally diverges from interactive behavior.
3. **Observability.** `tmux attach -t =cw-<issue-lower>` lets an operator watch any live worker mid-flight. That's not possible with a backgrounded `-p` subprocess piping stream-json.

The trade-off: there is no exit code. A `claude -p` subprocess emits its final `result` event to stdout, then exits. A tmux-backed session is just a TUI in a pane — no exit signal. Completion signaling moves to the **sentinel JSON contract** below.

## Sentinel JSON contract

The worker invokes `bin/claude-tmux-finalize` as its very last step. The helper writes an atomic JSON sentinel file at a known path (`$RUN_DIR/.symphony-done` by default). The dispatcher polls for the sentinel.

### Schema

```json
{
  "sentinel_version": 1,
  "status": "completed" | "failed",
  "exit_reason": "normal" | "blocker" | "timeout" | "partial",
  "ended_at": "2026-05-17T05:34:58Z",
  "outcome_posted": true | false,
  "files_touched": "comma,separated,list" | null,
  "validation_summary": "one line" | null,
  "notes": "free form" | null,
  "session_id": "<from claude>" | null
}
```

### Writer guarantees

1. **Atomic.** The helper writes to `$SENTINEL.XXXXXX` via `mktemp`, then `mv`s into place. A reader observing the path can only see either no file or a fully-written file — never a partial.
2. **Type validated.** Status is `completed` or `failed`. Exit reason is one of the four canonical values. Any other input is rejected with `exit 2`.
3. **Sentinel directory must exist and be writable.** The helper refuses to write outside an absolute path.

### Reader guarantees

The dispatcher polls for the sentinel and, when it arrives, validates the content is a JSON object before extracting fields:

```bash
if ! printf '%s' "$sentinel_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
  final_status="failed"
  exit_reason="sentinel_malformed"
else
  final_status="$(jq -r '.status // "incomplete"' <<<"$sentinel_json")"
  exit_reason="$(jq -r '.exit_reason // "normal"' <<<"$sentinel_json")"
  ...
fi
```

**Why the `jq -e 'type == "object"'` guard:** without it, a corrupted sentinel (truncated, non-JSON, a bare string, an array, etc.) silently coerces to `final_status=""` (jq returns empty stdout, exit non-zero, but our `// "incomplete"` fallback already fired). The dispatcher's reconcile logic then mis-classifies what should be a clear failure. The guard rejects non-object sentinels explicitly and surfaces `exit_reason=sentinel_malformed` so the operator sees the corruption.

### exit_reason taxonomy

| Value | Source | Meaning |
|---|---|---|
| `normal` | worker | Clean completion |
| `blocker` | worker | External dependency stopped the work |
| `timeout` | worker OR dispatcher | Worker hit its turn or wall-clock budget |
| `partial` | worker | Worker delivered a subset of the acceptance criteria |
| `session_died` | dispatcher | tmux session died before the worker wrote a sentinel |
| `sentinel_malformed` | dispatcher | Sentinel file existed but was not valid JSON (treat as `session_died` with corruption) |

## Dispatch lock TOCTOU mitigation

A batch dispatcher that drains a queue of tickets must guarantee only one instance is running against a `(repo, label)` key at a time. The naive `mkdir`-as-mutex pattern has a TOCTOU window:

```
mkdir lock_dir        # syscall 1 — succeeds, you win
printf "$$" > .holder # syscall 2 — racing dispatcher reads here
```

A racing loser lands between those two syscalls, sees the directory but no `.holder` file (or `pid` file), and could mis-classify the live lock as stale.

The mitigation: when you see a lock dir with no pid file, retry the pid-read 5× at 100ms intervals before declaring it stale:

```bash
if [[ -z "$holder" ]]; then
  for _pid_retry in 1 2 3 4 5; do
    sleep 0.1
    [[ -r "$lock_dir/pid" ]] && holder="$(cat "$lock_dir/pid" 2>/dev/null)"
    [[ -n "$holder" ]] && break
  done
fi
```

500ms is well inside any human-scale dispatch latency and gives the winner plenty of time to write its pid. If the pid is *still* missing after 500ms, the lock is genuinely stale (the holder crashed between mkdir and pid-write).

## Per-repo mkdir mutex (sorted acquisition)

A multi-repo dispatcher (`--repo-map A=path,B=path`) needs to lock each `(repo, label)` key independently so disjoint repos don't serialize each other. The lock-dir key is `sha1(repo|label) | cut -c1-12`. Acquisition order matters for deadlock avoidance: if two operators dispatch overlapping repo sets, they could acquire locks in different orders and deadlock.

Fix: **sort lock keys lexicographically before acquiring.** Both operators acquire in the same order, so the second always waits on the first instead of holding `A` while waiting on `B`.

## env.sh idempotency + autoset-marker pattern

The lane's env vars are sourced from `env.sh`. Sourcing must be idempotent (multiple sources don't double-up PATH or duplicate state). But the RunPod-conditional selectors (MCP config + worker env allowlist) must re-evaluate on every source so an operator can toggle `CLAUDE_WORKER_ENABLE_RUNPOD` and re-source to pick up the change.

The autoset-marker pattern keeps these two requirements in tension cleanly:

```bash
_symphony_new_mcp="$(_symphony_compute_mcp_config)"
if [[ -z "${CLAUDE_WORKER_MCP_CONFIG:-}" ]] || \
   [[ "${CLAUDE_WORKER_MCP_CONFIG:-}" == "${_SYMPHONY_CLAUDE_MCP_AUTOSET:-}" ]]; then
  export CLAUDE_WORKER_MCP_CONFIG="$_symphony_new_mcp"
  export _SYMPHONY_CLAUDE_MCP_AUTOSET="$_symphony_new_mcp"
fi
```

Logic: if `CLAUDE_WORKER_MCP_CONFIG` is empty (first source) OR it equals the prior autoset value (meaning nobody manually overrode it), re-export to the freshly-computed value AND update the marker. An operator who manually exports `CLAUDE_WORKER_MCP_CONFIG=/custom/path.json` will have their override preserved across re-sources because the marker won't match.

Same pattern for `CLAUDE_WORKER_ENV_ALLOWLIST`. Test `tests/test_mcp_runpod_optin.sh` Branch 9 verifies operator overrides survive a re-source-with-toggle.

## MCP defense-in-depth

The default MCP config (`mcp/worker-mcp.json`) exposes only Linear. The RunPod-opt-in config (`mcp/worker-mcp-runpod.json`) adds the RunPod MCP server. The selection is driven by `CLAUDE_WORKER_ENABLE_RUNPOD=true`.

The naive design is: "if the worker shouldn't have RunPod, just don't load the MCP." That's insufficient. A worker with `RUNPOD_API_KEY` in its environment could bypass the MCP gate by calling `curl https://api.runpod.io/...` directly.

The fix: **gate tools AND credentials together.** `env.sh` computes the worker env allowlist conditionally on `CLAUDE_WORKER_ENABLE_RUNPOD`:

```bash
_symphony_compute_allowlist() {
  local base="HOME PATH SHELL ... LINEAR_API_KEY ..."
  if [[ "${CLAUDE_WORKER_ENABLE_RUNPOD:-false}" == "true" ]]; then
    base="$base RUNPOD_API_KEY RUNPOD_NETWORK_VOLUME_ID RUNPOD_DATACENTER"
  fi
  printf '%s' "$base"
}
```

When RunPod is opted out (the default), the worker session is launched via `env -i $allowlisted=value … claude …` as the tmux session command — only allowlisted vars cross the boundary, so `RUNPOD_API_KEY` is not in the worker's environment even if it's set in the operator's shell. The worker has neither the tool nor the credential.

> **Why `env -i` and not `tmux new-session -e`.** `tmux -e VAR=value` *adds* `VAR` to the session env; it does not *restrict* what the session inherits. The real isolation primitive is `env -i` (clear the environment, then re-add only allowlisted assignments) wrapping the `claude` invocation. Passing that whole command as the tmux session's startup command is what gives the worker process a stripped env.

The worker prompt template (`skills/.../assets/worker-prompt.template.md`) reinforces this in plain English: *"Both the tools and the credentials are opt-in together."*

## Exact-target tmux convention (`=name` / `=name:`)

`tmux send-keys -t cw-team-12 Enter` *prefix-matches* the target spec. If you happen to have a session called `cw-team-123` running simultaneously, the keys can land in the wrong session. This is a footgun — for batch dispatchers running many parallel workers with similar names, it's an active bug.

The fix is per-tmux docs: prefix the spec with `=` for an **exact** match:

- `=cw-team-12` — exact session match
- `=cw-team-12:` — exact pane match (trailing colon = default pane in the session)

Use `=name:` for `send-keys`, `paste-buffer`, `capture-pane`, `kill-session`, and `has-session`. A grep guard over all `bin/` and `tests/` files (e.g. `! grep -rE 'tmux [a-z-]+ -t [a-z]' bin/ tests/`) is the recommended way to fail-build if a bare `-t name` slips back in — drop it into your adapter's test suite alongside the bundled tests in this skill.

## First-launch dialog dismissal

Real Claude Code shows two modal dialogs on first launch in a directory:

1. **"Yes, I trust this folder"** workspace trust dialog
2. **"Bypass Permissions"** warning (occasionally; suppressed by `--dangerously-skip-permissions` but not deterministically as of Claude Code 2.1.143)

Neither can be suppressed by command flags. The dispatcher must detect and dismiss them before pasting the prompt, otherwise the worker blocks forever waiting on keyboard input:

```bash
dismiss_first_launch_dialogs() {
  local session="$1" captured tries=0
  while (( tries < 6 )); do
    captured="$(tmux capture-pane -t "=$session:" -p 2>/dev/null | tr -d '\r' || true)"
    if [[ "$captured" == *"trust this folder"* ]]; then
      tmux send-keys -t "=$session:" Enter
      sleep 2; tries=$(( tries + 1 )); continue
    fi
    if [[ "$captured" == *"Bypass Permissions"* ]] && [[ "$captured" == *"accept"* ]]; then
      tmux send-keys -t "=$session:" "2"; sleep 1
      tmux send-keys -t "=$session:" Enter
      sleep 2; tries=$(( tries + 1 )); continue
    fi
    break
  done
}
```

The loop tries up to 6 times × 2s = 12s. The bypass dialog sometimes appears after the trust dialog dismissal settles, so a single capture-pane pass isn't enough. See `docs/lessons.md` §8 for the full story.

## Per-worktree `.claude/settings.json`

The dispatcher copies `settings/claude-settings.tmux.json` into `<worktree>/.claude/settings.json` before starting the tmux session. The settings file sets:

```json
{ "permissions": { "defaultMode": "bypassPermissions" } }
```

This scopes `bypassPermissions` to the worktree (it does NOT affect the operator's other Claude Code sessions). The trust model is bounded by:

1. **Routing guard** — the dispatcher refused to dispatch unless the issue carries `lane:claude` or matches another configured route
2. **Worktree boundary** — the worker can only modify files in its own copy
3. **Per-issue branch** — work lands on `claude/<issue-id>`, never directly on `main`

## Stale-sentinel pre-dispatch guard

The dispatcher refuses to start a new session if a prior sentinel exists at the target path:

```bash
[[ -e "$sentinel_path" ]] && die "Stale sentinel exists at $sentinel_path — refusing to dispatch."
```

This prevents accidentally overwriting evidence of a prior failed run. The operator must explicitly move the worktree aside, delete the sentinel, and re-dispatch — a small friction that surfaces "this issue already ran and something went wrong."

## meta.env schema (tmux backend)

```
issue_id='TEAM-123'
repo_path='/abs/path/to/repo'
worktree_path='/abs/path/to/worktrees/TEAM-123'
branch='claude/team-123'
base_branch='main'
start_time='2026-05-17T08:00:00Z'
model='claude-opus-4-7'
max_turns='50'
backend='tmux'                    # backend marker
tmux_session='cw-team-123'        # session name (for status/cleanup)
sentinel_path='/abs/.../runs/TEAM-123/.symphony-done'
pid=''                            # cleared by final write
session_id='<from sentinel>'      # populated by finalize
exit_reason=''                    # populated by finalize
end_time=''                       # populated by finalize
status='running'                  # → completed | failed | incomplete
closeout_state='In Review'
self_close_requested='false'
closeout_verified='unchecked'     # → true | false | check_failed | not_applicable
linear_state_actual=''            # populated by closeout re-query
routing='label'                   # which guard matched (label | project | assignee | none)
integrated='false'                # set by claude-mark-integrated
```

All values single-quoted. **Never `source`** this file — always parse with `grep + sed`. A worker that writes adversarial content to its run directory must not be able to execute code through the dispatcher.

## Closeout verification

A worker that exits with `status='completed'` is not proof the tracker actually moved to the closeout state. The worker could have failed to post the outcome comment, the Linear MCP call could have errored, the network could have flaked.

The dispatcher re-queries Linear after the sentinel arrives:

```bash
linear_state_actual=$(query_issue_state "$team_key" "$issue_num")
if [[ "$linear_state_actual" == "$closeout_state" ]]; then
  closeout_verified="true"
else
  closeout_verified="false"
fi
```

`closeout_verified` uses this vocabulary:

- `unchecked` — dispatcher hasn't tried yet (transient)
- `true` — completed and tracker confirms closeout state
- `false` — completed but tracker does NOT match closeout state (operator should investigate)
- `check_failed` — re-query failed (network, auth, rate limit) — operator should re-check
- `not_applicable` — worker did not complete successfully

Status and health tooling should surface `false` and `check_failed` as warnings.
