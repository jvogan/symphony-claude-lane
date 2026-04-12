# Symphony + Claude Lane

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Agent Skill](https://img.shields.io/badge/Agent_Skill-v1.0.0-8A2BE2.svg)](#install)

![Symphony + Claude Lane](assets/social-preview.png)

**Add Claude Code as a specialist worker lane in your Symphony + Linear workflow.**

If you already run [Codex](https://openai.com/index/codex/) workers through [Symphony](https://github.com/openai/symphony) and [Linear](https://linear.app), this [agent skill](https://agentskills.io/specification) lets you bring in [Claude Code](https://docs.anthropic.com/en/docs/claude-code) for work that benefits from visual judgment, browser verification, or design sensibility — without disrupting your existing Codex pipeline.

You install the skill, point it at a repo, and your agent sets up a routing profile that defines what Claude owns, what stays in Codex, and how the two lanes coordinate through Linear.

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

## Why two lanes?

Different AI agents have different strengths. Codex is fast and excels at bounded implementation tasks in a sandbox. Claude Code has visual judgment, can run a browser via Playwright to verify frontend changes, and handles design-sensitive or copy-heavy work where tone and aesthetics matter. Running both against the same Linear backlog — each claiming tickets that match its strengths — gives you better output than either alone.

## Prerequisites

Before installing, make sure you have:

- An **existing Symphony + Linear workflow** (see [symphony-linear-starter](https://github.com/jvogan/symphony-linear-starter) if you need to set one up)
- **[Claude Code](https://docs.anthropic.com/en/docs/claude-code)** installed (the runtime for the Claude lane)
- **[Linear](https://linear.app)** account with an API key (`LINEAR_API_KEY` in your environment)
- **[Playwright](https://playwright.dev/)** or equivalent browser automation for visual verification
- A target git repo that already has Symphony orchestration configured

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
See @skills/symphony-claude-lane/SKILL.md for Claude lane orchestration.
```

Or copy the skill folder into your project and reference `skills/symphony-claude-lane/SKILL.md` directly from your agent instructions.

## How it works

1. Point an agent at a repo that already uses Symphony + Linear.
2. The skill inspects the repo and confirms it is a mixed-lane candidate.
3. It confirms the base workflow has bootstrap assertions and a no-progress stop-loss before expanding.
4. It asks you what Claude should own — default is UI-first.
5. It creates a routing profile (`.orchestration/claude-lane.yaml`) in your repo.
6. It documents the lane contract so both human operators and agents know which tickets go where.

The default stance is intentionally narrow: Claude starts as a specialist, not a second general-purpose scheduler. Expand the lane with evidence, not assumptions.

## Example prompts

```
Use $symphony-claude-lane to add a Claude lane to this Symphony + Linear repo
for UI and browser-verified work.
```
```
Use $symphony-claude-lane to define what work belongs to Claude versus Codex,
then persist the decision into a repo-local routing profile.
```
```
Use $symphony-claude-lane to keep one Linear project but add exact-match Claude
lane labels and mixed-lane guidance to this repo.
```
```
Use $symphony-claude-lane to keep Claude UI-only for now and document the lane contract.
```
```
Use $symphony-claude-lane to extend the default Claude lane so it also owns
docs and review work.
```

## What the skill produces

The skill creates or updates a repo-local routing file:

```text
.orchestration/claude-lane.yaml
```

That file records the adopter's decisions about:

- queue strategy: same-project label routing or a separate project
- default lane mode and Claude focus areas
- labels that always or never route to Claude
- whether visual verification is mandatory
- preferred Claude models
- which base-workflow guardrails the Claude lane depends on
- closeout and retry behavior
- how the lane behaves when control-plane checks fail
- cleanup and retention policy for worktrees, snapshots, and repo-specific storage hotspots
- privacy rules for issue bodies, comments, screenshots, traces, and other run artifacts

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
- **Same Linear project plus exact-match lane labels** by default, with separate projects optional
- **Inherit the base workflow guardrails** before expanding the Claude lane
- **Playwright-first visual verification**
- **Repo-local routing profiles** instead of chat-only preferences
- **Operator-reviewed closeout by default**, with self-close allowed only where the adopter's workflow supports it safely
- **Safe non-deletion** when issue state cannot be confirmed
- **Security/privacy hygiene** so secrets, tokens, cookies, personal data, and raw customer payloads do not leak into issues, comments, screenshots, or traces

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

- **[symphony-linear-starter](https://github.com/jvogan/symphony-linear-starter)** — The base orchestration skill for Symphony + Linear, with self-improving runbooks, bootstrap scripts, and issue contracts. Install this first if you don't have Symphony + Linear set up yet.

## Links

- [OpenAI Symphony](https://github.com/openai/symphony) — the dispatch and isolation runtime
- [Linear](https://linear.app) — issue tracker used for routing and state
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) — the agent runtime for the Claude lane
- [Codex](https://openai.com/index/codex/) — the primary worker runtime in the Codex lane
- [Agent Skills spec](https://agentskills.io/specification) — the open standard this skill follows

Contributions and feedback welcome via [GitHub issues](https://github.com/jvogan/symphony-claude-lane/issues).

## License

[MIT](LICENSE)
