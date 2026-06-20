# Setup

Use this reference when deciding whether a repo is ready for **multi-model dispatch** — routing tasks to Claude, Codex, or both based on what the work requires.

## Candidate checklist

A repo is a good candidate when most of these are true:

- Symphony already exists, or the team has clearly chosen Symphony as the worker scheduler
- Linear is the source of truth for issue planning and state
- The repo already has orchestration guidance in `AGENTS.md`, `.orchestration/`, or similar
- The backlog includes a mix of task types: some bounded implementation, some requiring reasoning, visual judgment, browser verification, or external tool access
- The team is willing to route tasks explicitly, whether by task-characteristic analysis or label matching
- Alternatively: the team wants to run Claude-only workers against Linear issues without Codex
- Alternatively: the team has only Claude Code/Codex + GitHub and wants the worker→release-manager flow with no Linear/Symphony — see GitHub-only mode (`docs/github-only-quickstart.md` in the repo root)

## Red flags

Do not recommend multi-model dispatch yet when:

- the repo does not use Linear and has no intention to — this is only a red flag for **full Symphony + Linear dispatch**. It is **not** a red flag for GitHub-only mode (`docs/github-only-quickstart.md` in the repo root), which runs the worker→release-manager flow with no tracker (PR + `release:*` labels are the control plane). Offer that path instead of stopping.
- the repo does not have stable issue bodies, acceptance criteria, or validation commands
- the team is trying to use multiple models as a substitute for ticket-shaping discipline
- the main problem is actually poor Symphony onboarding, not missing model capability
- the team has no way to evaluate whether routing decisions are producing better output

## Required capabilities

At adoption time, the environment should support:

- Claude Code access
- Linear access *(full mode)*
- a browser automation path, preferably Playwright
- a place to store repo-local orchestration policy such as `.orchestration/claude-lane.yaml`
- a base Symphony workflow that already has workspace bootstrap assertions and a no-progress stop-loss *(full mode)*

**GitHub-only mode** (no Linear/Symphony) needs only:

- Claude Code and/or Codex access
- the `gh` CLI authenticated (`gh auth status`)
- a GitHub repo where you can create the `release:*` labels (the handoff state machine)

See `docs/github-only-quickstart.md` in the repo root.

## Preflight checks

Before trusting multi-model dispatch operationally, verify:

- Claude can actually read and update the issue tracker used for routing and closeout
- browser automation can reach the local app or preview environment
- the repo has stable validation commands for Claude-owned tickets
- the base Symphony workflow already fails fast on bad workspaces and does not burn indefinitely with no real progress
- the team has a documented place to store routing policy and operator notes
- the team has a documented cleanup owner and retention cadence for worktrees, snapshot repos, and run artifacts
- the team has identified repo-specific storage hotspots such as caches, generated assets, screenshots, traces, or dependency trees
- the repo has a documented redaction rule for secrets, personal data, and raw customer payloads in issues and run artifacts

## What this repo intentionally does not bundle

This blueprint does not assume:

- a universal `claude-worker` script
- a shared `env.sh`
- a watchdog or queue poller
- a specific branch naming convention
- a specific GitHub handoff model
- a specific way of launching Claude in the adopter environment

Those details should be decided locally and documented in the adopter repo.
