# Dispatch

Use this reference when defining how the Claude lane enters a mixed Symphony workflow.

## Queue split

Use a **distinct active queue contract** for the Claude lane.

Recommended patterns:

- one Linear project with exact-match lane labels such as `lane:claude`
- separate Symphony or Claude claimers that filter on those labels
- separate reporting or review filter for Claude outcomes
- separate Linear project for Claude-lane issues only when the adopter needs stronger operational separation

Avoid a shared active queue where Claude and Codex claim from the same unstructured pool without exact routing filters.

Lane labels should coexist with the base workflow's model or complexity labels rather than replacing them.

## Worker lifecycle

At a high level, the Claude lane should follow:

1. Select a Claude-owned ticket from the Claude-routed queue
2. Work in an isolated branch or worktree
3. Follow repo guidance and acceptance criteria
4. Run validation
5. Run Playwright-based visual verification when required
6. Post a structured outcome
7. Move to `In Review` or `Done`, depending on the repo's closeout model
8. Clean terminal-state worktrees, snapshots, and other lane artifacts according to the repo-local retention policy

## Inherited base guardrails

The Claude lane should inherit the same run-quality floor as the main Symphony workflow.

At minimum, the adopter should already have:

- workspace bootstrap assertions for branch and repo-anchor paths
- a no-progress stop-loss that requeues obviously stuck work
- a stable issue contract with acceptance criteria, validation commands, and touched areas

If those are still broken in the main workflow, fix them before scaling the Claude lane.

## Ticket shape expectations

Claude-lane tickets should still be bounded and concrete.

Each ticket should ideally include:

- summary
- acceptance criteria
- validation commands
- touched areas
- any visual surfaces that must be checked
- any privacy constraints on screenshots, traces, or customer-facing data

Claude does not replace issue discipline. It benefits from it.

## Concurrency guidance

Default to modest Claude concurrency, especially when browser state is involved.

Recommended starting point:

- one Claude worker for stateful browser-heavy flows
- one to two Claude workers for lighter design, copy, or review work

Increase only after the lane proves stable in the adopter environment.

## Retention and cleanup

Do not assume every adopter accumulates storage in the same places.

When documenting dispatch and operations, account for:

- git worktrees created per Claude ticket
- snapshot repos or promotion directories, if the adopter uses them
- browser screenshots, traces, and other QA artifacts
- build outputs, dependency trees, and repo-specific local caches

The adopter repo should name who cleans these up, when they are eligible for removal, what stays retained until integration is complete, and how integration is verified before artifacts are removed.
