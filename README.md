# Symphony + Claude Lane

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![CI](https://github.com/jvogan/symphony-claude-lane/actions/workflows/test.yml/badge.svg)](https://github.com/jvogan/symphony-claude-lane/actions/workflows/test.yml)
[![Agent Skill](https://img.shields.io/badge/Agent_Skill-v3.0.0--rc2-8A2BE2.svg)](#install)

![Symphony + Claude Lane](assets/banner.jpg)

**Long-horizon multi-agent orchestration via Linear. Claude Code workers run subscription-billed in attachable tmux sessions, optionally paired with Codex via Symphony.**

[Symphony](https://github.com/openai/symphony) dispatches [Codex](https://openai.com/index/codex/) workers through its Elixir runtime. This [agent skill](https://agentskills.io/specification) adds [Claude Code](https://docs.anthropic.com/en/docs/claude-code) workers to the same workflow — running as **interactive sessions inside detached tmux panes** in isolated git worktrees, tracked through the same [Linear](https://linear.app) backlog, with smart routing that sends each task to the agent best suited for it.

You install the skill, point it at a repo, and your orchestrator agent learns how to route tasks between models, launch Claude workers securely, verify frontend output with Playwright, and close out work through Linear.

```
                     Orchestrator
                    /            \
            Symphony              claude (tmux)
            (Elixir)              (interactive session)
               |                      |
          Codex workers          Claude workers
          (sandbox, fast,        (browser, reasoning,
           parallel)              tools, review)
               |                      |
               \________Linear________/
                (shared issues & state)
```

> **Current release candidate: v3.0.0-rc2.** The default backend runs Claude workers as interactive sessions in tmux panes instead of `claude -p` subprocesses. This bills against the operator's Claude subscription, matches the normal interactive session model, and gives operators attachable long-running workers. Teams that prefer API-priced / headless `claude -p` can adapt the launcher intentionally; see [`docs/backend-options.md`](docs/backend-options.md).

## Why this exists

Long-horizon AI work needs more than "send one prompt and hope." Complex product, infrastructure, and research tasks need a harness: durable issue state, isolated worktrees, observable workers, model-specific routing, validation evidence, closeout checks, and cleanup rules. This skill turns Linear into the shared control plane for that harness, with Claude Code handling work that benefits from visual judgment, deep reasoning, browser verification, or external tools, and Codex/Symphony handling bounded parallel implementation when that is the better fit.

## Why run both?

Different AI agents have different strengths. Running both against the same Linear backlog — each claiming tasks that match what it's best at — produces better output than either alone.

| Claude Code | Codex |
|---|---|
| Browser verification, visual judgment | Bounded, sandbox-compatible implementation |
| Deep reasoning (architecture, debugging) | Config, schema, type, migration changes |
| External tools (APIs, databases, MCP) | Test infrastructure (unit tests, fixtures) |
| Security review, code review | Mechanical refactors |
| Documentation, product copy | Parallelizable batch of similar tasks |
| E2E tests (sandbox-incompatible) | Fast execution where speed > judgment |

The skill also supports **Claude-only** setups for teams that don't use Codex. With the default tmux backend, no API plumbing is required — both Codex and Claude Code are subscription tools with built-in agent capabilities.

## Backend choice

The bundled reference launcher defaults to **tmux-backed interactive Claude Code** because it is attachable, observable, and subscription-billed. It is the recommended path for long-running workers.

If your team prefers API-priced or fully headless execution, keep the same routing profile, Linear state machine, prompt-injection boundary, outcome block, and cleanup rules, then adapt the launcher back to a deliberate `claude -p` subprocess backend. The skill includes migration notes for both directions in [`docs/backend-options.md`](docs/backend-options.md); the important part is choosing one backend explicitly and keeping its billing, observability, and completion semantics documented.

## Prerequisites

Before installing, make sure you have:

- An **existing Symphony + Linear workflow** (see [symphony-linear-starter](https://github.com/jvogan/symphony-linear-starter) if you need to set one up)
- **[Claude Code](https://docs.anthropic.com/en/docs/claude-code)** and/or **[Codex](https://openai.com/index/codex/)** installed
- **[Linear](https://linear.app)** account with an API key (`LINEAR_API_KEY` in your environment)
- **[Playwright](https://playwright.dev/)** or equivalent browser automation for visual verification (recommended)
- A target git repo with orchestration configured
- On the dispatcher host: **`tmux`**, `jq`, `git`, `curl`, `python3` (run `bin/claude-doctor` after install to verify)

## Install

### Skills CLI (recommended)

```bash
npx skills add jvogan/symphony-claude-lane
```

This clones the skill into your local skills directory (e.g. `~/.codex/skills/`) so your agent can discover it.

### Codex (manual)

```bash
mkdir -p "${CODEX_HOME:-$HOME/.codex}/skills"
cp -R skills/symphony-claude-lane "${CODEX_HOME:-$HOME/.codex}/skills/"
```

Restart Codex after installing so the skill is discoverable.

### Claude Code (manual)

Copy the skill folder into your project, then add it as a context reference in your `CLAUDE.md`:

```markdown
<!-- In your project's CLAUDE.md -->
See @skills/symphony-claude-lane/SKILL.md for multi-model routing.
```

## 60-second quickstart

```bash
git clone https://github.com/jvogan/symphony-claude-lane.git
cd symphony-claude-lane
export LINEAR_API_KEY="<linear-api-key>"
source ./env.sh
bin/claude-doctor
```

Then install the skill into your agent, add the `lane:claude` label in Linear, and ask the agent to configure your target repo:

```text
Use $symphony-claude-lane to set up long-horizon multi-agent routing for this
Symphony + Linear repo. Use tmux-backed Claude workers by default, preserve
Codex/Symphony for bounded parallel work, and document closeout and cleanup.
```

For the expanded setup path, see [`docs/quickstart.md`](docs/quickstart.md).

## How it works

**Setup** (the skill helps your orchestrator do this):

1. Inspect a repo that already uses Symphony + Linear.
2. Confirm the base workflow has guardrails (bootstrap assertions, stop-loss) before adding Claude workers.
3. Analyze the repo's work patterns and ask about routing preferences.
4. Create a routing profile (`.orchestration/claude-lane.yaml`) with model selection criteria, label overrides, privacy rules, and cleanup policy.
5. Set up the Claude worker launcher — the secure process for dispatching interactive `claude` sessions in tmux panes against Linear issues in isolated git worktrees.
6. Document the routing contract so both human operators and agents know how tasks get dispatched.

**Dispatch** (how it runs after setup):

1. The orchestrator plans issues in Linear with routing labels or task analysis.
2. Symphony picks up Codex-routed issues and dispatches Codex workers through its Elixir runtime.
3. The Claude launcher picks up Claude-routed issues and dispatches interactive Claude sessions in tmux panes in isolated worktrees.
4. Both types of workers post structured outcomes back to Linear when done.
5. The orchestrator reviews all output in one place, integrates changes, and promotes learnings.

**Routing strategies:**

- **task-characteristic** (default): The orchestrator analyzes each issue and picks the best model based on what the task requires. Labels serve as overrides.
- **label-only**: Routing is determined entirely by Linear labels. Simpler but less adaptive.

The skill includes a [reference launcher script](skills/symphony-claude-lane/assets/claude-worker.reference.sh) and [worker launch docs](skills/symphony-claude-lane/references/worker-launch.md) with a full security checklist you can adapt to your environment.

## Example prompts

```
Use $symphony-claude-lane to set up smart multi-model routing for this repo —
analyze what types of work appear in the backlog and recommend which agent
handles what.
```
```
Use $symphony-claude-lane to add task-characteristic routing to this
Symphony + Linear repo with label overrides for UI and infra work.
```
```
Use $symphony-claude-lane to configure this repo for Claude-only workers
without Codex.
```
```
Use $symphony-claude-lane to update the routing profile so Claude also handles
security reviews and complex debugging.
```
```
Use $symphony-claude-lane to review the current routing and recommend changes
based on how the last wave performed.
```

## What the skill produces

The skill creates or updates a repo-local routing file:

```text
.orchestration/claude-lane.yaml
```

That file records the adopter's decisions about:

- routing strategy: task-characteristic analysis or label-only
- backend selection: tmux by default, `claude -p` by deliberate adaptation, or a hybrid split
- model selection criteria: what task characteristics prefer Claude vs Codex
- label overrides: which labels always route to a specific model
- whether this is a mixed-model or Claude-only setup
- whether visual verification is mandatory for frontend work
- preferred Claude models
- which base-workflow guardrails all workers inherit
- closeout and retry behavior
- cleanup and retention policy for worktrees, snapshots, and repo-specific storage hotspots
- privacy rules for issue bodies, comments, screenshots, traces, and other artifacts

Those decisions belong in the adopter repo, not in this shared skill.

## What's inside

| Path | Purpose |
|---|---|
| `skills/symphony-claude-lane/SKILL.md` | Main routing and dispatch skill |
| `skills/.../references/` | Setup, routing, dispatch, worker launch, visual verification, closeout, troubleshooting, examples |
| `skills/.../assets/claude-lane-profile.example.yaml` | Example repo-local routing profile |
| `skills/.../assets/claude-lane-guidance.snippet.md` | Starter snippet for adopter repo orchestration docs |
| `skills/.../assets/claude-worker.reference.sh` | Reference tmux-backed launcher (adapt to your environment) |
| `skills/.../assets/review-audit.reference.py` | Reference parser for current and legacy outcome comments |
| `skills/.../assets/worker-prompt.template.md` | Worker prompt template with trust boundary, capabilities, and closeout protocol |
| `skills/.../assets/linear-outcome-block.example.md` | Example machine-readable closeout comments |
| `skills/.../agents/openai.yaml` | Skill metadata |
| `bin/claude-doctor` | Preflight battery — verify env, deps, Linear connectivity, lane state |
| `bin/claude-version` | Print install root, branch/commit, default model env, and `claude` CLI version |
| `bin/claude-tmux-finalize` | Worker-invoked helper that writes the completion sentinel JSON |
| `env.sh` | Source to set lane defaults (paths, model, routing label, MCP config, env allowlist) |
| `mcp/worker-mcp.json` | Default MCP config (Linear only) |
| `mcp/worker-mcp-runpod.json` | Opt-in MCP config (Linear + RunPod) |
| `settings/claude-settings.tmux.json` | Per-worktree `.claude/settings.json` with `bypassPermissions` |
| `tests/` | Three fully-isolated regression tests (sentinel-malformed, MCP opt-in, env isolation) |
| `docs/architecture.md` | Sentinel JSON contract, dispatch lock semantics, autoset-marker pattern |
| `docs/backend-options.md` | How to choose tmux, `claude -p`, or a hybrid backend intentionally |
| `docs/lessons.md` | Bug-by-bug postmortems from the tmux backend build |
| `docs/linear-setup.md` | How to set up `lane:claude` + `model:*` labels in a Linear workspace |
| `docs/migration-v2-to-v3.md` | What changes if you adopted v2.0.1 |
| `llms.txt` | Agent-oriented summary of the repo |

## Design defaults

- **Task-characteristic routing** as the default strategy, with labels as overrides
- **Smart model selection** based on what the task requires, not static lane assignment
- **Claude-only mode** supported for teams without Codex
- **Inherit the base workflow guardrails** before expanding routing
- **Playwright-first visual verification** for work affecting rendered output
- **Repo-local routing profiles** instead of chat-only preferences
- **Fail-closed Claude routing guards** before launching full-access workers
- **Operator-reviewed closeout by default**, with self-close allowed only where proven safe
- **Explicit closeout state** rendered into worker prompts
- **Worker environment allowlists** instead of inheriting the full operator shell
- **No-side-effect dry-runs** for launcher validation
- **Safe non-deletion** when issue state cannot be confirmed
- **Closeout verification** so launcher/status tooling distinguishes a clean worker session exit from verified tracker state
- **Outcome parser compatibility** for current `symphony-outcome` blocks and legacy `symphony:outcome verdict=pass` comments during migration
- **Dry-run prompt validation** without leaving worktree or run artifacts
- **Security/privacy hygiene** so secrets, tokens, and personal data stay out of artifacts

## Safety contract

These are the operational defaults the lane assumes. Operator-adapted launchers should keep them.

- **Explicit routing required.** Workers refuse to dispatch unless the issue carries `lane:claude` (or a project name matching `$CLAUDE_ALLOWED_PROJECT_REGEX`, or a configured assignee). Override only with `--allow-unrouted` for deliberate trusted dispatch.
- **Allowlisted worker environment.** The worker session is started with `env -i $allowlisted=value … claude …` as the tmux session command, so the worker sees only what the dispatcher explicitly forwards — not the full operator shell. `tmux new-session -e VAR=value` only *adds* to the session env; it does not *restrict*, so it is not sufficient on its own.
- **In Review by default.** Successful workers move issues to `In Review` and stop. Use `--self-close` only on trusted direct-Done flows.
- **Cleanup requires integration verification.** Don't remove worktrees just because the tracker says `Done` — verify the branch was actually merged or the snapshot promoted first.
- **Fallback outcome on failure.** When a worker dies before posting its outcome, a dispatcher should post a fallback `<!-- symphony-outcome -->` comment and move the issue to `$CLAUDE_TMUX_FAILURE_STATE` (default `Todo`). Prevents stuck-in-In-Progress tickets.
- **First-launch dialogs handled defensively.** Real Claude Code shows trust + bypass-permissions dialogs in interactive mode (no flag suppresses them). The dispatcher must detect and dismiss them via `tmux capture-pane` + `tmux send-keys` before pasting the prompt. See `docs/lessons.md`.
- **MCP defense-in-depth.** Tools (`mcp__runpod__*`) and credentials (`RUNPOD_API_KEY`) are jointly opt-in. A worker cannot bypass the MCP gate by calling RunPod via raw `curl` because the credentials are also withheld.

## Scope boundaries

This is a **portable blueprint** with a reference implementation, not a turnkey production system.

It includes a **reference launcher script** (`claude-worker.reference.sh`) and **worker launch docs** (`references/worker-launch.md`) that show the full secure launch pattern. Adapt these to your environment.

The reference launcher spawns an interactive `claude` session inside a detached tmux pane (`tmux new-session -d`). The session command is `env -i $allowlisted=value … claude …` so the worker process starts with a stripped environment containing only the allowlisted variables — `tmux -e` is not used because it adds vars without restricting them. Workers signal completion through a JSON sentinel file written by the bundled `bin/claude-tmux-finalize` helper.

It does **not** bundle:

- a machine-specific `env.sh` or auth setup
- a background watchdog or queue poller
- a one-size-fits-all Linear schema
- hardcoded assumptions about your repo layout or branch strategy
- an implicit cleanup daemon or retention policy

Those belong in the adopter's local tooling or repo-specific orchestration layer.

## Storage and retention

Multi-model workflows commonly use git worktrees plus run artifacts (logs, screenshots, traces, validation output). Those add up quickly, especially in frontend repos with large dependency trees.

Adopters should treat cleanup as part of the routing design:

- document who cleans terminal-state worktrees and when
- keep `In Review` artifacts until integration is complete
- monitor disk usage during larger waves
- make sure cleanup fails closed when tracker state cannot be confirmed
- record repo-specific storage hotspots in the routing profile

## FAQ

### How do I run Claude Code workers from Linear issues?

Use Linear labels, projects, or assignee filters to route issues to Claude, then launch a worker into an isolated git worktree. The tmux reference launcher reads the issue, renders a bounded worker prompt, starts `claude` in an attachable tmux session, and waits for `bin/claude-tmux-finalize` to write the completion sentinel.

### How is this different from `claude -p`?

`claude -p` is headless and API-priced; tmux-backed Claude Code is interactive, attachable, and subscription-billed. The default reference launcher uses tmux because it is better for long-horizon work where an operator may need to observe or recover a live session. If you prefer API pricing or a fully non-interactive subprocess, adapt the launcher using [`docs/backend-options.md`](docs/backend-options.md).

### Can I use this without Codex?

Yes. In Claude-only mode, Linear is still the control plane and this skill still gives you routing profiles, closeout rules, prompt safety, visual verification guidance, and cleanup policy. Symphony/Codex becomes optional instead of required.

### Why use Linear as the control plane?

Long-running multi-agent work needs durable state outside any one chat or terminal. Linear gives operators a shared queue, assignment and label controls, status transitions, and a permanent audit trail for outcomes.

### How are RunPod credentials isolated?

RunPod is opt-in at two layers: MCP tools are only loaded from `mcp/worker-mcp-runpod.json`, and RunPod environment variables only enter the worker allowlist when `CLAUDE_WORKER_ENABLE_RUNPOD=true`. The default worker environment excludes `RUNPOD_API_KEY`.

## Related

- **[symphony-linear-starter](https://github.com/jvogan/symphony-linear-starter)** — The base orchestration skill for Symphony + Linear, with self-improving runbooks, bootstrap scripts, and issue contracts. Install this first if you don't have Symphony + Linear set up yet.

## Links

- [OpenAI Symphony](https://github.com/openai/symphony) — Elixir-based dispatch and isolation runtime for Codex workers
- [Linear](https://linear.app) — issue tracker used for routing and state
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) — agent runtime for Claude workers
- [Codex](https://openai.com/index/codex/) — agent runtime for Codex workers
- [Agent Skills spec](https://agentskills.io/specification) — the open standard this skill follows

Contributions and feedback welcome via [GitHub issues](https://github.com/jvogan/symphony-claude-lane/issues).

## License

[MIT](LICENSE)
