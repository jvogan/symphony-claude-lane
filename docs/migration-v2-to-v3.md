# Migration: v2.0.1 → v3.0.0

If you adopted the v2.0.1 skill (`claude -p` backend) and want to move to v3.0.0 (tmux backend), here's what changes and what to update.

## The backend change

| | v2.0.1 | v3.0.0 |
|---|---|---|
| Worker invocation | `claude -p` subprocess (non-interactive) | Interactive `claude` session inside a detached tmux pane |
| Billing | Agent SDK credit bucket | Operator's Claude subscription |
| Completion signal | Exit code + `output.jsonl` `result` event parse | JSON sentinel file written by `bin/claude-tmux-finalize` |
| Status check | `kill -0 $pid` | `tmux has-session -t "=$session:"` + sentinel file check |
| Resume | `claude --resume <session_id>` | `tmux attach -t =$session` (live workers attachable) |
| Dispatcher dependencies | `claude`, `jq`, `python3`, `curl`, `git` | + `tmux` |

## What you need to do

### 1. Install tmux on the dispatcher host

```sh
brew install tmux   # macOS
apt install tmux    # Debian / Ubuntu
```

Run `bin/claude-doctor` to verify.

### 2. Update your launcher

If you adapted the v2.0.1 `claude-worker.reference.sh`, you'll need to update it. The v3 reference shows the new pattern in full. Key changes to graft:

- **Launch:** Replace `env -i ... claude -p < prompt.md > output.jsonl 2>&1` with `tmux new-session -d -s "$session" -c "$worktree" -- env -i $allowlisted=value ... claude --model ... --max-turns ... --dangerously-skip-permissions`. The isolation primitive remains `env -i` — it must wrap `claude` *inside* the tmux session command, because `tmux -e VAR=value` only *adds* to the session env, it does not *restrict* (worker would otherwise inherit the full dispatcher environment).
- **Completion:** Replace `output.jsonl` parsing with a sentinel-file poll loop. Read `.symphony-done` and validate with `jq -e 'type == "object"'` before extracting fields. Map malformed JSON to `exit_reason=sentinel_malformed`.
- **Dialog dismissal:** Real Claude shows trust + bypass-permissions dialogs in interactive mode. Add the `dismiss_first_launch_dialogs` helper (capture-pane → check for known dialog text → send the right keystrokes).
- **Settings file:** Copy `settings/claude-settings.tmux.json` into `<worktree>/.claude/settings.json` before starting the session.
- **Teardown:** After parsing the sentinel, send `/exit` to the tmux session, then `tmux kill-session`. Trap SIGTERM/SIGINT/EXIT so cleanup runs even if the dispatcher is killed.

### 3. Update your worker prompt template

The v3 worker prompt template (`assets/worker-prompt.template.md`) adds two new placeholders:

- `{{RUN_DIR}}` — absolute path to the worker's run directory
- `{{SENTINEL_PATH}}` — absolute path the worker writes the completion sentinel to

If you customized the v2 template, copy these into yours. The worker also needs to invoke `claude-tmux-finalize` as its final step (see the new template's "Completion protocol" section).

### 4. Update your `meta.env` schema

Three new fields, one rename:

| Field | Notes |
|---|---|
| `backend='tmux'` | New marker (was implicitly `-p`) |
| `tmux_session='cw-<issue-lower>'` | New — session name for status/cleanup tooling |
| `sentinel_path='/abs/.../runs/<ISSUE>/.symphony-done'` | New — absolute path |
| `exit_reason='normal'` (etc.) | New — replaces `exit_code` |
| `exit_code` | **Removed** in v3 (tmux backend has no subprocess exit code) |

Status tools that read `meta.env` need to branch on `backend='tmux'`:

- tmux session alive, no sentinel → `running`
- tmux session dead, sentinel present → `completed` or `orphan_finalize_pending`
- tmux session dead, no sentinel → `orphan_dead`

### 5. Adopt the new env.sh patterns

If you're using `env.sh`, the v3 version adds:

- **Cross-shell path detection** — `SYMPHONY_CLAUDE_ROOT` auto-detects from the env.sh location under both bash (via `${BASH_SOURCE[0]}`) and zsh (via prompt-expansion `${(%):-%x}`). Override by exporting before sourcing if you need deterministic behavior in another shell.
- **AUTONOMY_ROOT is now optional** — v2 didn't have a separate orchestration env file. v3 sources `$AUTONOMY_ROOT/env.sh` only if set.
- **Autoset-marker pattern** for `CLAUDE_WORKER_MCP_CONFIG` and `CLAUDE_WORKER_ENV_ALLOWLIST` — operator overrides are now preserved across re-source while auto-toggling on `CLAUDE_WORKER_ENABLE_RUNPOD` works correctly.
- **RunPod env-var split** — `RUNPOD_API_KEY`, `RUNPOD_NETWORK_VOLUME_ID`, and `RUNPOD_DATACENTER` are NOT in the default allowlist. They join only when `CLAUDE_WORKER_ENABLE_RUNPOD=true`.

### 6. `source env.sh` is now mandatory before launching a worker

The v3 reference launcher hard-requires `SYMPHONY_CLAUDE_ROOT` and `CLAUDE_WORKER_ENV_ALLOWLIST` to be set (it asserts both during preflight and aborts otherwise). The supported way to set these is `source env.sh` — env.sh also prepends `$SYMPHONY_CLAUDE_ROOT/bin` to PATH so the worker can find `claude-tmux-finalize`.

The v2 launcher could be run bare with all variables coming from a separate orchestration shell. In v3, this no longer works:

```sh
# v2 (legacy, no longer supported)
./bin/claude-worker TEAM-42 /path/to/repo

# v3 (required)
source path/to/symphony-claude-lane/env.sh
./bin/claude-worker-tmux TEAM-42 /path/to/repo
```

If your orchestration layer already sources `env.sh` (or sets `SYMPHONY_CLAUDE_ROOT`, the allowlist, and PATH manually), no change is needed at the operator-shell level — but per-dispatch wrappers that previously called the launcher bare will need to ensure env.sh has been sourced in the enclosing shell.

## What stays the same

Everything in the routing and Linear story carries forward unchanged:

- `lane:claude` label — same routing guard
- `.orchestration/claude-lane.yaml` routing profile — same schema
- `<issue_body>` prompt-injection trust boundary in the worker prompt — same
- Outcome block format — `<!-- symphony-outcome ... -->` — same (the only addition is the optional `backend: tmux` line)
- Closeout verification flow — re-query Linear, compare to `closeout_state`, record `closeout_verified` and `linear_state_actual`
- Worktree isolation, single-quote rejection in meta.env, atomic meta.env rewrites
- Codex/Claude routing story — Symphony still dispatches Codex, this skill still adds Claude

## What's gone

- The `claude -p` invocation pattern is removed from the maintained reference launcher. It can still be reintroduced deliberately when a team wants API-priced headless execution; see [`backend-options.md`](backend-options.md).
- `output.jsonl` parsing for the `result` event
- `claude --resume <session_id>` advice (replaced by `tmux attach`)
- The `--max-turns` flag is **kept** (Claude accepts it in interactive mode too)
- The argv-exposure caveat (no argv prompt in the tmux backend)

## Why v3 is breaking, not additive

Two reasons:

1. **The reference launcher fundamentally changes shape.** The v2 launcher's launch block, output parsing, and resume mechanics all become inapplicable in tmux. An operator who copied the v2 launcher and ran it against v3 docs would have a confused tool.
2. **Subscription-billing was a real driver.** Anthropic's Agent SDK billing model made `claude -p` increasingly expensive for batch workloads. The tmux backend's subscription billing is the maintained default path for v3.

The shipped v2-style launcher is end-of-life. Security and correctness fixes only land on v3+.
