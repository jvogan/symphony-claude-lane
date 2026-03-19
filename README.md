# Symphony + Claude Lane

A portable skill and reference kit for adding a **Claude Code lane** to an existing **OpenAI Symphony + Linear** workflow.

This repo is for teams that already have Symphony and Linear in place and want a second agent lane that is better suited to **UI/UX, design, browser-verified work, product copy, and higher-judgment review**. The default stance is intentionally narrow: Claude starts as a specialist lane, not as a second general-purpose scheduler.

The core deliverable is the [`symphony-claude-lane` skill](skills/symphony-claude-lane/SKILL.md). It teaches an agent how to:

- inspect a target repo and confirm it is a good mixed-lane candidate
- decide what work belongs in Claude versus Codex
- ask the adopter which extra responsibilities Claude should own
- persist those decisions into a repo-local routing profile
- document a durable mixed-lane contract in the target repo
- default to Playwright-based visual verification for frontend work
- keep closeout and cleanup safe when tracker state cannot be verified

## Why this exists

Symphony is strong at scheduling and isolating workers. Codex is strong at implementation-heavy tickets inside that model. Many teams still want Claude Code involved for work where **visual judgment, browser interaction, writing quality, or skeptical review** matter more than raw implementation speed.

This repo captures that operating model in a reusable way without shipping machine-specific scripts, background services, or local secrets assumptions.

## What this is not

This is a **portable blueprint**, not a fully runnable starter kit.

It does **not** bundle:

- a universal `claude-worker` launcher
- a machine-specific `env.sh`
- a background watchdog
- a one-size-fits-all Linear schema
- hardcoded assumptions about your repo layout or branch strategy
- an implicit cleanup daemon or retention policy

Those belong in the adopter's local tooling or repo-specific orchestration layer.

## Storage and retention warning

Claude lanes commonly use separate git worktrees plus run artifacts such as logs, prompts, screenshots, traces, and validation output. Those add up quickly, especially in frontend repos with large dependency trees or generated assets.
Some adopters also retain snapshot repos or promotion directories, which can multiply storage usage further.

Adopters should treat cleanup and retention as part of the lane design:

- document who cleans terminal-state worktrees and when
- document when snapshot repos or promotion directories can be cleaned
- keep `In Review` artifacts until integration or final validation is complete
- monitor disk usage during larger waves instead of assuming cleanup will happen implicitly
- make sure cleanup fails closed when tracker state cannot be confirmed
- record repo-specific storage hotspots in the routing profile instead of assuming the same storage pattern everywhere

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

## What the skill produces in adopter repos

The skill is designed to create or update a repo-local routing file such as:

```text
.orchestration/claude-lane.yaml
```

That file is where adopters record their own answers about:

- default lane mode
- Claude focus areas
- labels that always or never route to Claude
- whether visual verification is mandatory
- preferred Claude models
- closeout behavior
- how the lane should behave when control-plane checks fail
- cleanup and retention policy for worktrees, snapshots, and repo-specific storage hotspots

Those decisions belong in the adopter repo, not in this shared skill.

## What's inside

| Path | Purpose |
|---|---|
| `skills/symphony-claude-lane/SKILL.md` | Main mixed-lane orchestration skill |
| `skills/.../references/` | Setup, routing, dispatch, visual verification, closeout, troubleshooting, examples |
| `skills/.../assets/claude-lane-profile.example.yaml` | Example repo-local routing profile |
| `skills/.../assets/claude-lane-guidance.snippet.md` | Starter snippet for adopter repo orchestration docs |
| `skills/.../assets/worker-prompt.template.md` | Reusable worker prompt template for adopters who build local launchers |
| `skills/.../assets/linear-outcome-block.example.md` | Example machine-readable closeout comments |
| `skills/.../agents/openai.yaml` | UI metadata for the skill |
| `llms.txt` | Agent-oriented summary of the repo |

## Design defaults

This repo defaults to:

- **UI-first + extensible** Claude routing
- **separate Claude and Codex Linear projects**
- **Playwright-first visual verification**
- **repo-local routing profiles instead of chat-only preferences**
- **operator-reviewed closeout by default**, with self-close allowed only where the adopter's workflow supports it safely
- **safe non-deletion when issue state cannot be confirmed**

These defaults are meant to be useful for many teams, not perfect for every team.

## License

[MIT](LICENSE)
