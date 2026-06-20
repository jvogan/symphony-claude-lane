# Changelog

## Unreleased

### Goal layer (autonomous long-horizon goals)

- Added a **goal layer** above the release lane so an agent can pursue a durable goal — a north star, acceptance criteria, and a budget — across many waves of work, unattended. See `docs/goal-layer.md`.
- `bin/goal-manager`: holds durable goal state in a Linear project and owns all termination guards (dedup, task/pass budgets, no-new-work halt). Subcommands: `init`, `status`, `add-tasks`, `next-planner`, `complete`, `halt`, and a `tick`/`--loop` heartbeat that merges via the release lane and mints the next planner when the backlog runs low. Dry-run by default; mutations require `--apply`.
- `/goal` command (`commands/goal.md`) bootstraps a goal and wires the loop; `skills/.../assets/goal-planner-prompt.template.md` is the planner agent prompt (its output is the next wave of tickets, never a PR).
- Planner passes are dispatched as `goal:planner` Linear tickets; the planner is ephemeral and re-derives the plan from durable state each pass — mirroring the release lane's stateless, idempotent design one level up.
- Added `tests/test_goal_manager.sh` (isolated, fake Linear) and `GOAL_MANAGER_*` env defaults.

### Goal-layer hardening

- Fail closed against a forged goal-state block: validate every state-block integer before it reaches shell arithmetic (blocks an arithmetic-injection RCE), refuse a description carrying more than one state block, and neutralize comment markers in human goal text.
- Paginate the project issue set so the budget/dedup/pass counts are exact at any size (a truncated window previously could silently let creation run past the budget); refuse past a hard issue cap.
- Lag-proof single-planner guarantee: reserve the mint slot in durable state before creating the ticket, so the heartbeat and a planner agent cannot double-mint during Linear's list-propagation lag.
- Require the outcome label when closing a planner ticket so a transient label error cannot reset the no-new-work halt; count any non-terminal planner (incl. custom state types) as pending; never overwrite durable state on a transient read; shred the Linear auth-header temp file on signal.

## v3.0.0-rc3

- Added GitHub-only mode (`--no-linear`): the release manager and worker launcher operate on GitHub labels alone, with no Linear dependency.
- Added an event-driven release Action template (`docs/examples/release-on-ready.yml`) that merges ready, CI-green PRs serially with no long-running process.
- Added `release-status` (read-only monitor), `routing-feedback`, and conflict-aware redispatch with bounded, fail-closed rebase retries.
- Hardened the single-writer release lane: reclaim of orphaned `release:queued` PRs, a PID-reuse lock guard, and per-pass loop resilience.
- Fixed immediate merge strategies (squash/merge/rebase) to reach the terminal `release:merged` label — and move the Linear issue to Done — without `--wait-merge`.
- Fixed `--loop` to exit promptly and release its lock on SIGINT/SIGTERM.
- Fixed Linear issue state transitions that failed because a GraphQL query declared an unused variable.
- Fixed the release Action template to grant the `checks`, `statuses`, and `actions` read scopes its CI gate requires.
- Expanded the shellcheck CI gate and the isolated regression suite.

## v3.0.0-rc2

- Added CI for shell syntax, JSON config validation, and isolated regression tests.
- Added public contribution and security guidance.
- Added quickstart and backend-selection documentation.
- Clarified tmux as the default backend while documenting deliberate `claude -p` / API-priced adaptations.
- Updated README positioning for long-horizon multi-agent orchestration.
- Fixed README test-count drift and banner asset extension mismatch.

## v3.0.0-rc1

- Ported the reference launcher to the tmux backend.
- Added `env.sh`, MCP configs, Claude settings, doctor/version/finalize helpers, and isolated tests.
- Added architecture, Linear setup, migration, and hardening lessons documentation.
