# Examples

Use these examples to shape good Claude-lane tickets and avoid vague routing.

## Good Claude-lane ticket: UI redesign with browser verification

**Summary:** Redesign the onboarding modal so the hero, feature list, and primary action feel clearer and more premium.

**Why Claude:** The task depends on visual judgment, hierarchy, motion, and browser verification.

**Expected route:** Claude lane

**Acceptance criteria:**

- onboarding modal hierarchy is clearer on desktop and mobile
- primary and secondary actions remain obvious in both themes
- browser verification covers desktop and mobile
- validation commands pass

## Keep in Codex: broad implementation bundle

**Summary:** Upgrade dependencies, refactor the data layer, fix flaky tests, rework the CI cache, and clean up TypeScript errors.

**Why not Claude:** This is mostly implementation, refactoring, and infra work with too many moving parts and no strong design or browser-verification center.

**Expected route:** Codex lane

## Extend Claude lane: docs and review

A reasonable extension after the lane proves stable:

- keep UI, UX, design, browser verification, copy
- add docs
- add review-oriented tickets such as skeptical diff review or issue shaping

Persist that change in the routing profile rather than relying on a one-off chat instruction.

## Example user questions to ask

- Do you want Claude to stay UI-focused, or should it also own docs and review work?
- Which labels should always route to Claude?
- Which labels should never route to Claude?
- Should all UI tickets require Playwright verification, or only higher-risk surfaces?
- Do you want Claude tickets to stop in `In Review`, or can some self-close to `Done`?

## Example fallback when the user does not answer

If the user is unavailable or does not want to decide yet:

- keep Claude UI, UX, design, browser verification, copy, and review only
- keep docs, research, and E2E outside the lane for now
- require `In Review` before `Done`
- write those assumptions into `.orchestration/claude-lane.yaml` and the repo guidance so they are easy to revise later
