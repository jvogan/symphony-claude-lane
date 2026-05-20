<!-- Adapt this snippet into the adopter repo's AGENTS.md, orchestration docs, or
equivalent operator guide. Replace placeholders with repo-specific details. -->

## Multi-Model Routing

This repo uses smart routing to dispatch tasks to Claude Code or Codex based on what each task requires. Routing decisions are persisted in `.orchestration/claude-lane.yaml`.

### When tasks route to Claude

- Requires browser verification (visual changes, frontend behavior)
- Requires visual judgment (layout, design, typography, UX decisions)
- Requires deep reasoning (architecture, complex debugging, multi-file analysis)
- Requires external tools (MCP servers, APIs, database access, network calls)
- Involves security review (auth flows, trust boundaries, vulnerability analysis)
- Involves documentation (API docs, migration guides, technical writing)
- Involves code review (skeptical review, issue shaping, quality assessment)
- Involves product copy (user-facing text, onboarding, marketing)
- Breaks in Codex sandbox (E2E tests, integration tests, system-dependent work)

### When tasks route to Codex

- Bounded implementation with clear acceptance criteria
- Sandbox-compatible (no network, browser, or system access needed)
- Parallelizable batch of similar tasks
- Config, schema, type, or migration changes
- Test infrastructure (unit tests, fixtures, mocks)
- Mechanical refactors with well-defined transformations

### Routing policy

- Read `.orchestration/claude-lane.yaml` before routing ambiguous tickets.
- Label overrides (`lane:claude`, `lane:codex`, `kind:*`) take priority over task-characteristic analysis.
- When characteristics are ambiguous and no override exists, prefer the safer choice.
- If `ask_on_ambiguous_tickets` is true, ask the operator before routing.
- If a ticket expands beyond its routed scope mid-run, stop and hand it back for rerouting.
- Prefer same-project label routing unless the repo has a strong reason to split projects.

### Visual verification

- Tickets that affect rendered output must use the configured browser automation path before closeout.
- Capture both desktop and mobile evidence when the surface supports both.
- Do not capture or persist secrets, personal data, or raw customer payloads in screenshots or traces when a redacted path is available.
- If visual verification cannot be completed, record that explicitly and stop in `In Review`.

### Base guardrails

- All workers inherit the base workflow's workspace bootstrap assertions and no-progress stop-loss.
- If the base workflow is still failing on bad checkouts or burning tokens with no workspace diff, fix that first before expanding multi-model dispatch.

### Closeout

- Default: stop in `In Review` after posting a structured outcome.
- Allow self-close only for workflows that have already proven direct-branch or PR closeout is safe.
- If issue state cannot be confirmed because the tracker or control plane is unavailable, preserve artifacts and do not guess.

### Cleanup

- Cleanup is part of the routing contract, not an implicit side effect.
- Terminal issue state is necessary but not sufficient for cleanup. Before removing a worktree, verify the work was actually integrated (branch merged, PR merged, or snapshot promoted).
- If the branch still exists unmerged or the snapshot promotion marker is missing, treat the worktree as still needed regardless of issue state.
- If cleanup automation depends on tracker state and the tracker is unavailable, fail closed and retry later.
- Monitor storage during larger waves and clean terminal artifacts promptly.
- Check repo-specific hotspots documented in the routing profile.

### Privacy

- Do not paste secrets, credentials, tokens, session cookies, personal data, or raw customer payloads into issue bodies, comments, screenshots, traces, or notes.
- Use redacted identifiers and safe fixtures whenever possible.
