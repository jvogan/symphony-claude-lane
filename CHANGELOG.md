# Changelog

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
