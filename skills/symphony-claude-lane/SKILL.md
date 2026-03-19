---
name: symphony-claude-lane
description: Add a specialized Claude Code lane to an existing Symphony + Linear workflow. Use when an agent needs to decide what work belongs to Claude versus Codex, create a durable routing profile, set up separate Claude queueing, and define Playwright-first visual verification and closeout rules for a mixed-lane repo.
metadata:
  short-description: Add a Claude lane to Symphony + Linear
---

# Symphony + Claude Lane

Use this skill when a team already has **Symphony + Linear** and wants Claude Code to join as a **specialized second lane** rather than replacing the main Codex/Symphony path.

## Prerequisites

- The target repo already uses Symphony + Linear, or is clearly intended to.
- The target repo has a place for durable orchestration guidance such as `AGENTS.md` or `.orchestration/`.
- Claude can be run separately from Symphony workers.
- Browser verification can be done with Playwright or an equivalent automation path.

If those conditions are not true, explain the gap and stop or redirect to a more appropriate setup skill.

## Required workflow

1. Inspect the target repo, existing `AGENTS.md`, workflow docs, and issue contract.
2. Confirm the repo is a real mixed-lane candidate, not just a generic coding repo.
3. Ask the user what Claude should own beyond the default UI-first lane. If the user is unavailable or vague, keep Claude UI-first, record that assumption in the routing profile, and document it in the repo-local lane guidance.
4. Create or update a repo-local routing profile from `assets/claude-lane-profile.example.yaml`, including cleanup and retention rules for that adopter's actual storage hotspots.
5. Recommend or create a separate Claude queue or Linear project, plus lane labels.
6. Add Claude-lane guidance to the target repo's orchestration docs. Use `assets/claude-lane-guidance.snippet.md` as a starting point. Do not hardcode repo specifics back into this shared skill.
7. For visual tickets, default to Playwright-based verification before closeout.
8. Define closeout, retry, `In Review`, and cleanup behavior as part of the lane contract, including how worktrees, snapshots, and other heavy local artifacts are removed safely.

## Safety defaults

- Default Claude to UI, UX, design, browser-verified work, copy, and review.
- Keep ambiguous tickets in the Codex lane until the repo proves the Claude lane is stable.
- Use separate active queues per lane.
- Persist user routing choices into the repo-local profile, not only in chat.
- Prefer operator-reviewed closeout unless the adopter already has a safe self-close path.
- If issue state cannot be confirmed during closeout or cleanup, preserve artifacts and stop rather than guessing.
- Do not assume every adopter's storage pressure looks the same; document repo-specific cleanup hotspots in the repo-local profile.

## Reference map

- Read `references/setup.md` first when deciding whether the target repo is ready.
- Read `references/routing.md` before asking the user what Claude should own.
- Read `references/dispatch.md` when defining queue split, labels, and worker lifecycle.
- Read `references/visual-verification.md` before writing browser-verification policy.
- Read `references/closeout.md` when defining `In Review`, outcome blocks, retry behavior, or self-close rules.
- Read `references/troubleshooting.md` when a lane stalls, exhausts turns, or drifts from the routing contract.
- Read `references/examples.md` when you need concrete ticket-shape examples or extension patterns.

## Output expectations

When this skill is applied well, the target repo should end up with:

- a durable Claude-lane routing profile
- clear lane labels or queueing rules
- repo-local orchestration guidance describing what Claude owns
- a Playwright-first visual verification rule for frontend tickets
- explicit closeout and retry behavior for Claude-lane work
- a documented fallback for control-plane outages or missing tracker state
- a cleanup and retention policy that covers worktrees, snapshots, and repo-specific storage hotspots
