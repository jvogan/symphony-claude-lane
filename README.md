# Symphony + Claude Lane

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Agent Skill](https://img.shields.io/badge/Agent_Skill-v2.0.0-8A2BE2.svg)](#install)

![Symphony + Claude Lane](assets/social-preview.png)

**Teach your orchestrator to pick the right AI agent for each task.**

This is an installable [agent skill](https://agentskills.io/specification) for [Codex](https://openai.com/index/codex/) and [Claude Code](https://docs.anthropic.com/en/docs/claude-code). It teaches an orchestrator how to analyze tasks and route them to the model that will produce the best output — Claude Code for work requiring visual judgment, deep reasoning, browser verification, or external tools; Codex for fast, bounded, sandbox-compatible implementation.

You install the skill, point it at a repo, and your agent gains a multi-model routing system: task-characteristic analysis, label overrides, visual verification rules, and a durable routing profile that the whole team can see.

```
                       Orchestrator
                           |
                    Linear (issues & state)
                           |
                     Smart Router
                    /      |      \
              Codex     Claude    Either
              workers   workers   (ambiguous →
              (fast,    (visual,   ask operator
               bounded,  complex,  or pick the
               sandbox)  tools,    safer choice)
                         review)
```

## Why smart model selection?

Different AI agents have different strengths. Using both against the same backlog — each claiming tasks that match what it's best at — produces better output than either alone.

| Route to Claude Code | Route to Codex |
|---|---|
| Requires browser verification | Bounded, sandbox-compatible implementation |
| Requires visual judgment (UI, design, UX) | Config, schema, type, migration changes |
| Requires deep reasoning (architecture, debugging) | Test infrastructure (unit tests, fixtures) |
| Requires external tools (APIs, databases, MCP) | Mechanical refactors |
| Security review, code review | Parallelizable batch of similar tasks |
| Documentation, product copy | Fast execution where speed matters more than judgment |
| E2E tests (sandbox-incompatible) | |

The skill also supports **Claude-only** setups for teams that don't use Codex.

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

Add the skill as a context reference in your project's `CLAUDE.md`:

```markdown
<!-- In your project's CLAUDE.md -->
See @skills/symphony-claude-lane/SKILL.md for multi-model routing.
```

Or copy the skill folder into your project and reference `skills/symphony-claude-lane/SKILL.md` directly from your agent instructions.

## How it works

1. Point an agent at a repo that already uses Symphony + Linear.
2. The skill inspects the repo and confirms it's a candidate for multi-model dispatch.
3. It confirms the base workflow has guardrails (bootstrap assertions, stop-loss) before adding routing.
4. It analyzes the repo's work patterns and asks about routing preferences.
5. It creates a routing profile (`.orchestration/claude-lane.yaml`) with model selection criteria, label overrides, privacy rules, and cleanup policy.
6. It documents the routing contract so both human operators and agents know how tasks get dispatched.

The routing profile supports two strategies:

- **task-characteristic** (default): The orchestrator analyzes each issue and picks the best model based on what the task requires. Labels serve as overrides.
- **label-only**: Routing is determined entirely by Linear labels. Simpler but less adaptive.

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
| `skills/.../references/` | Setup, routing, dispatch, visual verification, closeout, troubleshooting, examples |
| `skills/.../assets/claude-lane-profile.example.yaml` | Example repo-local routing profile |
| `skills/.../assets/claude-lane-guidance.snippet.md` | Starter snippet for adopter repo orchestration docs |
| `skills/.../assets/worker-prompt.template.md` | Reusable worker prompt template for Claude workers |
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
- **Operator-reviewed closeout by default**, with self-close allowed only where proven safe
- **Safe non-deletion** when issue state cannot be confirmed
- **Security/privacy hygiene** so secrets, tokens, and personal data stay out of artifacts

## Scope boundaries

This is a **portable blueprint**, not a fully runnable starter kit.

It does **not** bundle:

- a universal `claude-worker` launcher
- a machine-specific `env.sh`
- a background watchdog
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

- [OpenAI Symphony](https://github.com/openai/symphony) — the dispatch and isolation runtime
- [Linear](https://linear.app) — issue tracker used for routing and state
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) — agent runtime for Claude workers
- [Codex](https://openai.com/index/codex/) — agent runtime for Codex workers
- [Agent Skills spec](https://agentskills.io/specification) — the open standard this skill follows

Contributions and feedback welcome via [GitHub issues](https://github.com/jvogan/symphony-claude-lane/issues).

## License

[MIT](LICENSE)
