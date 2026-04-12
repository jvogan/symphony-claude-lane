---
name: symphony-claude-lane
description: Add a specialized Claude Code lane to an existing Symphony + Linear workflow. Use when an agent needs to decide what work belongs to Claude versus Codex, create a durable routing profile, prefer label-filtered Claude routing in the existing Linear control plane, and define Playwright-first visual verification, privacy, and closeout rules for a mixed-lane repo.
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
3. Confirm the base Symphony workflow already has workspace bootstrap assertions, a no-progress stop-loss, and a stable issue contract before recommending lane expansion.
4. Ask the user what Claude should own beyond the default UI-first lane. If the user is unavailable or vague, keep Claude UI-first, record that assumption in the routing profile, and document it in the repo-local lane guidance.
5. Create or update a repo-local routing profile from `assets/claude-lane-profile.example.yaml`, including queue strategy, privacy rules, and cleanup or retention rules for that adopter's actual storage hotspots.
6. Prefer same-project label-filtered lane routing first. Recommend a separate Claude queue or Linear project only when the adopter needs stronger operational separation.
7. Add Claude-lane guidance to the target repo's orchestration docs. Use `assets/claude-lane-guidance.snippet.md` as a starting point. Do not hardcode repo specifics back into this shared skill.
8. For visual tickets, default to Playwright-based verification before closeout.
9. Define closeout, retry, `In Review`, and cleanup behavior as part of the lane contract, including how worktrees, snapshots, and other heavy local artifacts are removed safely.

## Safety defaults

- Default Claude to UI, UX, design, browser-verified work, copy, and review.
- Keep ambiguous tickets in the Codex lane until the repo proves the Claude lane is stable.
- Prefer exact-match lane labels and label-filtered claiming. Use separate projects only when the adopter actually needs that extra separation.
- Persist user routing choices into the repo-local profile, not only in chat.
- Inherit the base workflow guardrails instead of treating the Claude lane as exempt from them.
- Prefer operator-reviewed closeout unless the adopter already has a safe self-close path.
- If issue state cannot be confirmed during closeout or cleanup, preserve artifacts and stop rather than guessing.
- Do not assume every adopter's storage pressure looks the same; document repo-specific cleanup hotspots in the repo-local profile.
- Do not put secrets, credentials, tokens, session cookies, personal data, or raw customer payloads into issues, comments, screenshots, traces, or other lane artifacts.

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
- explicit privacy and redaction rules for lane artifacts
- repo-local orchestration guidance describing what Claude owns
- a Playwright-first visual verification rule for frontend tickets
- inherited base-workflow guardrails called out explicitly
- explicit closeout and retry behavior for Claude-lane work
- a documented fallback for control-plane outages or missing tracker state
- a cleanup and retention policy that covers worktrees, snapshots, and repo-specific storage hotspots
