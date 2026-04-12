# Setup

Use this reference when deciding whether a repo is ready for a mixed **Symphony + Claude** lane.

## Candidate checklist

A repo is a good candidate when most of these are true:

- Symphony already exists, or the team has clearly chosen Symphony as the worker scheduler
- Linear is the source of truth for issue planning and state
- The repo already has orchestration guidance in `AGENTS.md`, `.orchestration/`, or similar
- The work includes some tickets where browser interaction, visual judgment, copy quality, or skeptical review matter
- The team is willing to route Claude explicitly, usually with exact-match lane labels in the same Linear project

## Red flags

Do not recommend a Claude lane yet when:

- the repo does not use Linear and has no intention to
- the repo does not have stable issue bodies, acceptance criteria, or validation commands
- the team is trying to use Claude as a vague second general-purpose lane without ticket-shaping discipline
- there is no way to do browser verification for frontend work
- the main problem is actually poor Symphony onboarding, not missing Claude capability

## Required capabilities

At adoption time, the environment should support:

- Claude Code access
- Linear access
- a browser automation path, preferably Playwright
- a place to store repo-local orchestration policy such as `.orchestration/claude-lane.yaml`
- a base Symphony workflow that already has workspace bootstrap assertions and a no-progress stop-loss

## Preflight checks

Before trusting the lane operationally, verify:

- Claude can actually read and update the issue tracker used for routing and closeout
- browser automation can reach the local app or preview environment
- the repo has stable validation commands for Claude-owned tickets
- the base Symphony workflow already fails fast on bad workspaces and does not burn indefinitely with no real progress
- the team has a documented place to store lane policy and operator notes
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
