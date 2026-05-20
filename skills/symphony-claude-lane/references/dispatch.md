# Dispatch

Use this reference when defining how tasks get dispatched to the right model in a multi-model workflow.

## Model selection

When `routing_strategy` is `task-characteristic`, the orchestrator should analyze each issue before dispatch:

1. Check for label overrides (`always_route_to_claude`, `always_route_to_codex`). If matched, use that model.
2. Analyze the task against `prefer_claude_when` and `prefer_codex_when` characteristics.
3. If characteristics point to one model, route there.
4. If ambiguous and `ask_on_ambiguous_tickets` is true, ask the operator.
5. If ambiguous and the operator is unavailable, prefer the safer choice: Claude for tasks requiring judgment, Codex for bounded sandbox-compatible work.

When `routing_strategy` is `label-only`, skip characteristic analysis and route entirely by labels.

When `claude_only` is true, route all tasks to Claude.

## Queue split

Use a **distinct active queue contract** for each model's tasks.

Recommended patterns:

- one Linear project with exact-match labels such as `lane:claude` and `lane:codex`
- separate claimers that filter on those labels
- separate reporting or review filter for each model's outcomes
- separate Linear project per model only when the adopter needs stronger operational separation

Avoid a shared active queue where both models claim from the same unstructured pool without routing filters.

## Worker lifecycle

Regardless of model, each worker should follow:

1. Select a task from the appropriately routed queue
2. Work in an isolated branch or worktree
3. Follow repo guidance and acceptance criteria
4. Run validation
5. Run Playwright-based visual verification when required (Claude workers)
6. Post a structured outcome
7. Move to `In Review` or `Done`, depending on the repo's closeout model
8. Clean terminal-state worktrees, snapshots, and other artifacts according to the repo-local retention policy

## Inherited base guardrails

All workers should inherit the same run-quality floor as the main Symphony workflow.

At minimum, the adopter should already have:

- workspace bootstrap assertions for branch and repo-anchor paths
- a no-progress stop-loss that requeues obviously stuck work
- a stable issue contract with acceptance criteria, validation commands, and touched areas

If those are still broken in the main workflow, fix them before scaling to multiple models.

## Ticket shape expectations

Tickets should be bounded and concrete regardless of which model handles them.

Each ticket should ideally include:

- summary
- acceptance criteria
- validation commands
- touched areas
- any visual surfaces that must be checked (for Claude browser-verified work)
- any privacy constraints on screenshots, traces, or customer-facing data

Good routing does not replace issue discipline. It benefits from it.

## Concurrency guidance

Default to modest concurrency, especially when browser state is involved.

Recommended starting point:

- one Claude worker for stateful browser-heavy flows
- one to two Claude workers for reasoning, review, or documentation work
- one to three Codex workers for bounded parallel implementation
- increase only after routing proves stable in the adopter environment

## Claude-only mode

For teams running without Codex, set `claude_only: true` in the routing profile. All tasks route to Claude. The rest of the dispatch contract (queue structure, worker lifecycle, guardrails, cleanup) still applies.

## Retention and cleanup

Do not assume every adopter accumulates storage in the same places.

When documenting dispatch and operations, account for:

- git worktrees created per ticket
- snapshot repos or promotion directories, if the adopter uses them
- browser screenshots, traces, and other QA artifacts
- build outputs, dependency trees, and repo-specific local caches

The adopter repo should name who cleans these up, when they are eligible for removal, what stays retained until integration is complete, and how integration is verified before artifacts are removed.
