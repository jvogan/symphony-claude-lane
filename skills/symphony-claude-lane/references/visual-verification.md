# Visual Verification

Use this reference when the Claude lane owns UI or UX work.

## Default stance

Use **Playwright-first** visual verification.

Do not assume extension-based browser tooling will exist in unattended or headless Claude worker sessions. Playwright is a better default because it is explicit, scriptable, and portable.

## Verification contract

For tickets that change visual output, the lane contract should require:

1. Start the local dev server or preview target
2. Open the relevant page with Playwright
3. Read the page structure or accessibility snapshot
4. Capture desktop evidence
5. Capture mobile evidence
6. Re-run after fixes if visual issues are found
7. Close the browser and stop the dev server

## When visual verification is mandatory

Make it mandatory for tickets that affect:

- layout
- spacing
- color or theme behavior
- typography
- interaction states
- onboarding or empty-state surfaces
- modal, drawer, or dialog redesigns

## What to record

The worker or orchestrator should record enough evidence to support review:

- which pages or states were checked
- what viewport sizes were used
- whether the ticket passed both desktop and mobile checks
- any skipped verification and why

Keep that evidence privacy-safe:

- avoid capturing secrets, tokens, cookies, personal data, or raw customer payloads when a redacted environment is available
- redact screenshots or traces before sharing them in issue comments or review docs
- prefer synthetic or staging data over production data for verification

## Fallback rule

If the dev server cannot start or browser tools are unavailable, do not fake confidence. Note the skipped verification explicitly in the structured outcome or review comment.
