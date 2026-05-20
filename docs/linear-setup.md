# Linear setup

The Claude lane uses a handful of Linear labels for routing and model selection. This doc explains what to set up and why.

## Required: routing labels

The dispatcher refuses to dispatch a Claude worker unless the issue is explicitly routed. The default routing guard is the label `lane:claude`. Without it (or a project-name match, or a configured assignee), `claude-worker-tmux` exits with an error.

### Routing label

| Label | Effect | Required? |
|---|---|---|
| `lane:claude` | Routes the ticket to the Claude lane (vs Codex/Symphony). Default required label. | One of the three routing guards must match. |

You can change the required label name via env vars (see below) — `lane:claude` is just the default.

### Routing guard env vars

```sh
CLAUDE_REQUIRED_LABEL=lane:claude            # default
CLAUDE_ALLOWED_PROJECT_REGEX=Claude          # default
CLAUDE_ALLOWED_ASSIGNEE=                      # unset by default
CLAUDE_REQUIRE_ROUTING=true                  # fail-closed (default)
```

A ticket is considered routed if **any** of these match:

- Carries the `$CLAUDE_REQUIRED_LABEL`
- Belongs to a Linear project whose name matches `$CLAUDE_ALLOWED_PROJECT_REGEX`
- Is assigned to a user matching `$CLAUDE_ALLOWED_ASSIGNEE` (id, email, or name)

Set `CLAUDE_REQUIRE_ROUTING=false` to drop the routing guard entirely (not recommended). Use `--allow-unrouted` for a deliberate trusted one-off dispatch.

## Optional: model selection labels

If your workspace has tickets that should run on different Claude models (cost/quality trade-offs), add per-tier labels:

| Label | Resolves to env var | Default model |
|---|---|---|
| `model:opus` | `$CLAUDE_WORKER_MODEL_OPUS` | `claude-opus-4-7` |
| `model:sonnet` | `$CLAUDE_WORKER_MODEL_SONNET` | `claude-sonnet-4-6` |
| `model:haiku` | `$CLAUDE_WORKER_MODEL_HAIKU` | `claude-haiku-4-5-20251001` |
| _(none)_ | `$CLAUDE_WORKER_MODEL` | `claude-opus-4-7` |

### Model resolution precedence (highest first)

1. CLI `--model <id|alias>` on the dispatcher. Aliases `opus`/`sonnet`/`haiku` resolve to the env tier vars. An explicit ID is used as-is.
2. Linear label `model:opus` | `model:sonnet` | `model:haiku`.
3. `$CLAUDE_WORKER_MODEL` env default.

### Examples

```sh
# Default model
./bin/claude-worker-tmux TEAM-42 /path/to/repo

# Force opus regardless of labels
./bin/claude-worker-tmux TEAM-42 /path/to/repo --model opus

# Force a specific model id
./bin/claude-worker-tmux TEAM-42 /path/to/repo --model claude-opus-4-7

# Apply a Linear label and re-dispatch (the dispatcher will pick it up)
# In Linear: add label "model:sonnet" to TEAM-42
./bin/claude-worker-tmux TEAM-42 /path/to/repo
```

(Note: `claude-worker-tmux` itself is **not** shipped in this skill — adapt the reference launcher at `skills/symphony-claude-lane/assets/claude-worker.reference.sh` to your environment.)

## Label scope: workspace vs team

Linear labels can be **workspace-scoped** (visible everywhere) or **team-scoped** (only on issues in a specific team). The dispatcher accepts both. We recommend **workspace-scoped** for `lane:claude` and the `model:*` family — they apply across teams and are easier to manage centrally.

To create a workspace-scoped label in Linear:

1. Open Workspace settings → Labels (top-level, not within a team)
2. Create the label name + color (e.g. `lane:claude` in a distinctive color)
3. The label is now available on every team's issues

To create a team-scoped label:

1. Open Team settings → Labels
2. Create the label
3. It's only available on issues in that team

If a label exists at workspace scope, no team-scoped duplicate is needed.

## States the lane uses

| State | When | Configurable via |
|---|---|---|
| `Backlog` / `Triage` / any `unstarted` | Default for new tickets | — |
| `In Progress` | Dispatcher transitions the ticket here at the start of dispatch | — (hardcoded) |
| `In Review` | Default closeout state — successful workers move here | `$CLAUDE_CLOSEOUT_STATE` |
| `Done` | When `--self-close` is used (trusted direct-Done flows only) | `$CLAUDE_SELF_CLOSE_STATE` |
| `Todo` | Fallback state when the worker fails/timeouts without posting an outcome | `$CLAUDE_TMUX_FAILURE_STATE` |
| Any terminal (`Done`, `Closed`, `Cancelled`, `Canceled`, `Duplicate`) | Dispatcher refuses to start | — (hardcoded) |

The dispatcher posts a fallback `<!-- symphony-outcome -->` comment and moves the issue to `$CLAUDE_TMUX_FAILURE_STATE` when a worker dies before posting its own outcome. This prevents stuck-in-In-Progress tickets. Set `CLAUDE_TMUX_RECONCILE=false` to disable the fallback.

## Linear API key

The dispatcher and the worker both need a Linear API key. Export `LINEAR_API_KEY` in your shell before sourcing `env.sh`:

```sh
export LINEAR_API_KEY="lin_api_..."
source path/to/symphony-claude-lane/env.sh
```

The reference launcher reads the key from the env and:

1. Writes the `Authorization: $LINEAR_API_KEY` header to a temp file (bare, **not** `Bearer …` — Linear personal API keys use the bare form; OAuth access tokens use `Bearer`)
2. Passes it via `curl -H @file` to keep the key out of `ps aux`
3. Deletes the temp file immediately

The Linear MCP config (`mcp/worker-mcp.json`) references `${LINEAR_API_KEY}` with `Bearer` because the Linear MCP server expects that prefix at its HTTP transport. The raw GraphQL API at `https://api.linear.app/graphql` does NOT — these two endpoints have different auth conventions. Claude Code resolves `${LINEAR_API_KEY}` from the environment at MCP launch time; the key is never written into any config file.

## Verifying setup

After exporting `LINEAR_API_KEY` and sourcing `env.sh`, run:

```sh
./bin/claude-doctor
```

The doctor's "Linear connectivity" section will:

1. Query the Linear `viewer` to confirm the key works
2. Query for the `lane:claude` label (or whatever `$CLAUDE_REQUIRED_LABEL` is set to) and fail if missing

If both pass, you're routed-and-keyed. Add the label to a test ticket and dispatch.
