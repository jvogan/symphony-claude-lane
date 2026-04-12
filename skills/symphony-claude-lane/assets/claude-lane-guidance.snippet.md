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
- Prefer one Linear project with explicit lane labels unless the repo has a strong reason to split projects.
- If the user has not broadened the lane, keep Claude UI-first.
- If a ticket is ambiguous and the routing profile says to ask, ask before routing.
- If a ticket expands beyond the Claude-owned scope mid-run, stop and hand it back for rerouting.
- Claude lane labels should coexist with the base workflow's model or complexity labels rather than replacing them.

Visual verification:

- Tickets that affect rendered output must use the configured browser automation path before closeout.
- Capture both desktop and mobile evidence when the surface supports both.
- Do not capture or persist secrets, personal data, or raw customer payloads in screenshots or traces when a redacted path is available.
- If visual verification cannot be completed, record that explicitly and stop in `In Review`.

Base guardrails:

- The Claude lane should inherit the base workflow's workspace bootstrap assertions and no-progress stop-loss.
- If the base workflow is still failing on bad checkouts or burning tokens with no workspace diff, fix that first before expanding Claude ownership.

Closeout:

- Default Claude tickets stop in `In Review` after posting a structured outcome.
- Allow self-close only for workflows that have already proven direct-branch or PR closeout is safe.
- If issue state cannot be confirmed because the tracker or control plane is unavailable, preserve artifacts and do not guess.

Cleanup:

- Cleanup is part of the lane contract, not an implicit side effect.
- Terminal issue state is necessary but not sufficient for cleanup. Before removing a worktree, verify the work was actually integrated (branch merged, PR merged, or snapshot promoted). An issue can reach `Done` without its changes being on the target branch.
- If the branch still exists unmerged or the snapshot promotion marker is missing, treat the worktree as still needed regardless of issue state.
- If cleanup automation depends on tracker state and the tracker is unavailable, fail closed and retry later.
- Worktrees and snapshot repos are often the main disk cost in the lane; monitor storage during larger waves and clean terminal artifacts promptly.
- Check repo-specific hotspots such as caches, generated assets, screenshots, traces, or dependency trees instead of assuming every adopter accumulates space the same way.

Privacy:

- Do not paste secrets, credentials, tokens, session cookies, personal data, or raw customer payloads into issue bodies, comments, screenshots, traces, or lane notes.
- Use redacted identifiers and safe fixtures whenever possible.
