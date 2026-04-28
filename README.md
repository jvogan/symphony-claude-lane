# Symphony + Claude Lane

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Agent Skill](https://img.shields.io/badge/Agent_Skill-v2.0.0-8A2BE2.svg)](#install)

![Symphony + Claude Lane](assets/social-preview.png)

**Run Claude Code workers alongside Codex in your Symphony + Linear workflow.**

[Symphony](https://github.com/openai/symphony) dispatches [Codex](https://openai.com/index/codex/) workers through its Elixir runtime. This [agent skill](https://agentskills.io/specification) adds [Claude Code](https://docs.anthropic.com/en/docs/claude-code) workers to the same workflow — running via `claude -p` in isolated git worktrees, tracked through the same [Linear](https://linear.app) backlog, with smart routing that sends each task to the agent best suited for it.

You install the skill, point it at a repo, and your orchestrator agent learns how to route tasks between models, launch Claude workers securely, verify frontend output with Playwright, and close out work through Linear.

```
                     Orchestrator
                    /            \
            Symphony              claude -p
            (Elixir)              (direct launch)
               |                      |
          Codex workers          Claude workers
          (sandbox, fast,        (browser, reasoning,
           parallel)              tools, review)
               |                      |
               \________Linear________/
                (shared issues & state)
```

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

The skill also supports **Claude-only** setups for teams that don't use Codex. No API plumbing required — both Codex and Claude Code are subscription tools with built-in agent capabilities.

## Prerequisites

Before installing, make sure you have:

- An **existing Symphony + Linear workflow** (see [symphony-linear-starter](https://github.com/jvogan/symphony-linear-starter) if you need to set one up)
- **[Claude Code](https://docs.anthropic.com/en/docs/claude-code)** and/or **[Codex](https://openai.com/index/codex/)** installed
- **[Linear](https://linear.app)** account with an API key (`LINEAR_API_KEY` in your environment)
- **[Playwright](https://playwright.dev/)** or equivalent browser automation for visual verification (recommended)
- A target git repo with orchestration configured

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

## How it works

**Setup** (the skill helps your orchestrator do this):

1. Inspect a repo that already uses Symphony + Linear.
2. Confirm the base workflow has guardrails (bootstrap assertions, stop-loss) before adding Claude workers.
3. Analyze the repo's work patterns and ask about routing preferences.
4. Create a routing profile (`.orchestration/claude-lane.yaml`) with model selection criteria, label overrides, privacy rules, and cleanup policy.
5. Set up the Claude worker launcher — the secure process for dispatching `claude -p` against Linear issues in isolated git worktrees.
6. Document the routing contract so both human operators and agents know how tasks get dispatched.

**Dispatch** (how it runs after setup):

1. The orchestrator plans issues in Linear with routing labels or task analysis.
2. Symphony picks up Codex-routed issues and dispatches Codex workers through its Elixir runtime.
3. The Claude launcher picks up Claude-routed issues and dispatches `claude -p` workers in isolated worktrees.
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
| `skills/.../assets/claude-worker.reference.sh` | Reference launcher script (adapt to your environment) |
| `skills/.../assets/worker-prompt.template.md` | Worker prompt template with trust boundary, capabilities, and closeout protocol |
| `skills/.../assets/linear-outcome-block.example.md` | Example machine-readable closeout comments |
| `skills/.../agents/openai.yaml` | Skill metadata |
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
- **Security/privacy hygiene** so secrets, tokens, and personal data stay out of artifacts

## Scope boundaries

This is a **portable blueprint** with a reference implementation, not a turnkey production system.

It includes a **reference launcher script** (`claude-worker.reference.sh`) and **worker launch docs** (`references/worker-launch.md`) that show the full secure launch pattern. Adapt these to your environment.

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
