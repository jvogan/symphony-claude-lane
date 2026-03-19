<!-- Adapt this snippet into the adopter repo's AGENTS.md, orchestration docs,
or equivalent operator guide. Replace placeholders with repo-specific details. -->

## Claude Lane

Use the Claude lane as a specialist lane, not as a second generic queue.

Default Claude ownership:

- UI and UX work where visual judgment matters
- browser-verified frontend changes
- copy, onboarding text, and higher-touch writing
- skeptical review or issue-shaping work if the routing profile allows it

Default Codex ownership:

- implementation-heavy backend work
- refactors, migrations, and type changes
- CI, infra, and test-plumbing work

Routing policy:

- Read `.orchestration/claude-lane.yaml` before routing ambiguous tickets.
- If the user has not broadened the lane, keep Claude UI-first.
- If a ticket is ambiguous and the routing profile says to ask, ask before routing.
- If a ticket expands beyond the Claude-owned scope mid-run, stop and hand it back for rerouting.

Visual verification:

- Tickets that affect rendered output must use the configured browser automation path before closeout.
- Capture both desktop and mobile evidence when the surface supports both.
- If visual verification cannot be completed, record that explicitly and stop in `In Review`.

Closeout:

- Default Claude tickets stop in `In Review` after posting a structured outcome.
- Allow self-close only for workflows that have already proven direct-branch or PR closeout is safe.
- If issue state cannot be confirmed because the tracker or control plane is unavailable, preserve artifacts and do not guess.

Cleanup:

- Cleanup is part of the lane contract, not an implicit side effect.
- Only remove worktrees or run artifacts after terminal issue state is confirmed.
- If cleanup automation depends on tracker state and the tracker is unavailable, fail closed and retry later.
- Worktrees and snapshot repos are often the main disk cost in the lane; monitor storage during larger waves and clean terminal artifacts promptly.
- Check repo-specific hotspots such as caches, generated assets, screenshots, traces, or dependency trees instead of assuming every adopter accumulates space the same way.
