# Symphony + Claude Lane

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Agent Skill](https://img.shields.io/badge/Agent_Skill-v1.0.0-8A2BE2.svg)](#install)

A portable skill for adding a **Claude Code lane** to an existing **OpenAI Symphony + Linear** workflow.

```
                         Linear (issues & state)
                        /                       \
            ┌──────────┐                         ┌──────────┐
            │Codex Lane│                         │Claude Lane│
            │(Symphony)│                         │(this skill)│
            └──────────┘                         └──────────┘
            implementation                       UI / UX / design
            refactors                            browser-verified work
            infra & CI                           product copy
            types & migrations                   skeptical review
```

## How it works

1. Point an agent at a repo that already uses Symphony + Linear.
2. The skill inspects the repo and confirms it is a mixed-lane candidate.
3. It asks you what Claude should own — default is UI-first.
4. It creates a routing profile (`.orchestration/claude-lane.yaml`) in your repo.
5. It documents the lane contract so both human operators and agents know which tickets go where.

The default stance is intentionally narrow: Claude starts as a specialist, not a second general-purpose scheduler. Expand the lane with evidence, not assumptions.

## Install

### Skills CLI (recommended)

```bash
npx skills add jvogan/symphony-claude-lane
```

### Codex (manual)

```bash
mkdir -p "${CODEX_HOME:-$HOME/.codex}/skills"
cp -R skills/symphony-claude-lane "${CODEX_HOME:-$HOME/.codex}/skills/"
```

Restart Codex after installing so the skill is discoverable.

### Claude Code (manual)

Point Claude Code at:

```text
skills/symphony-claude-lane/SKILL.md
```

You can also copy the skill folder into a shared skills location if your Claude setup supports that pattern.

## Example prompts

- `Use $symphony-claude-lane to add a Claude lane to this Symphony + Linear repo for UI and browser-verified work.`
- `Use $symphony-claude-lane to define what work belongs to Claude versus Codex, then persist the decision into a repo-local routing profile.`
- `Use $symphony-claude-lane to add a separate Claude Linear project and mixed-lane guidance to this repo.`
- `Use $symphony-claude-lane to keep Claude UI-only for now and document the lane contract.`
- `Use $symphony-claude-lane to extend the default Claude lane so it also owns docs and review work.`

## What the skill produces

The skill creates or updates a repo-local routing file:

```text
.orchestration/claude-lane.yaml
```

That file records the adopter's decisions about:

- default lane mode and Claude focus areas
- labels that always or never route to Claude
- whether visual verification is mandatory
- preferred Claude models
- closeout and retry behavior
- how the lane behaves when control-plane checks fail
- cleanup and retention policy for worktrees, snapshots, and repo-specific storage hotspots

Those decisions belong in the adopter repo, not in this shared skill.

## What's inside

| Path | Purpose |
|---|---|
| `skills/symphony-claude-lane/SKILL.md` | Main mixed-lane orchestration skill |
| `skills/.../references/` | Setup, routing, dispatch, visual verification, closeout, troubleshooting, examples |
| `skills/.../assets/claude-lane-profile.example.yaml` | Example repo-local routing profile |
| `skills/.../assets/claude-lane-guidance.snippet.md` | Starter snippet for adopter repo orchestration docs |
| `skills/.../assets/worker-prompt.template.md` | Reusable worker prompt template for local launchers |
| `skills/.../assets/linear-outcome-block.example.md` | Example machine-readable closeout comments |
| `skills/.../agents/openai.yaml` | Skill metadata |
| `llms.txt` | Agent-oriented summary of the repo |

## Design defaults

- **UI-first + extensible** Claude routing
- **Separate Claude and Codex Linear projects**
- **Playwright-first visual verification**
- **Repo-local routing profiles** instead of chat-only preferences
- **Operator-reviewed closeout by default**, with self-close allowed only where the adopter's workflow supports it safely
- **Safe non-deletion** when issue state cannot be confirmed

These defaults are meant to be useful for many teams, not perfect for every team.

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

Claude lanes commonly use git worktrees plus run artifacts (logs, screenshots, traces, validation output). Those add up quickly, especially in frontend repos with large dependency trees.

Adopters should treat cleanup as part of the lane design:

- document who cleans terminal-state worktrees and when
- keep `In Review` artifacts until integration is complete
- monitor disk usage during larger waves
- make sure cleanup fails closed when tracker state cannot be confirmed
- record repo-specific storage hotspots in the routing profile

## Related

- **[symphony-linear-starter](https://github.com/jvogan/symphony-linear-starter)** — The base orchestration skill for Symphony + Linear, with self-improving runbooks, bootstrap scripts, and issue contracts

## Links

- [OpenAI Symphony](https://github.com/openai/symphony) — the orchestrator this skill extends
- [Linear](https://linear.app) — issue tracker used for routing and state
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) — the agent runtime for the Claude lane
- [Codex](https://openai.com/index/codex/) — the primary worker runtime in the Codex lane
- [Agent Skills spec](https://agentskills.io/specification) — the open standard this skill follows

## License

[MIT](LICENSE)
