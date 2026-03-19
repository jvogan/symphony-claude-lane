# Closeout

Use this reference when defining how Claude-lane work reaches a terminal state.

## Default recommendation

Default to **operator-reviewed closeout** for new adopters.

That usually means:

1. Claude completes the work
2. Claude posts a structured outcome
3. The issue moves to `In Review`
4. The orchestrator or human reviewer validates and moves it to `Done`

## When self-close can be allowed

Self-close is reasonable only when:

- the adopter repo already uses direct branch or PR closeout safely
- the lane has proven reliable on that repo
- cleanup behavior will not destroy unreviewed work
- outcome comments are machine-readable and consistently posted
- issue-tracker state can be checked reliably at closeout time

## Snapshot-style repos

For snapshot or promotion-based repos, prefer `In Review` by default. Avoid auto-`Done` if downstream promotion, integration, or cleanup can race with review.

## Control-plane dependency

Closeout and cleanup often depend on tracker state, auth, and other control-plane checks.

If the lane cannot confirm issue state because the tracker is unavailable, rate-limited, or unauthenticated:

- do not guess that the issue is terminal
- do not delete worktrees or run artifacts
- stop in `In Review` or an equivalent non-terminal review state
- leave a clear operator note describing what could not be verified

## Storage and retention

Worktrees, snapshot repos, and run artifacts are a real operational cost, not just incidental scratch space.

For many frontend or JavaScript-heavy repos, a single worktree can be large once dependencies, build outputs, screenshots, or traces are present. Snapshot-based workflows can add another layer of retained storage. Larger waves can consume substantial disk if cleanup is deferred.

The lane contract should therefore define:

- when terminal-state worktrees are eligible for removal
- when snapshots or promotion directories are eligible for removal
- who is responsible for cleanup after each wave or campaign
- whether `In Review` artifacts are retained until final integration
- how disk pressure is noticed before it becomes a failure mode
- which repo-specific directories or caches should be watched because they are unusually large in that adopter environment

## Outcome comments

Use a machine-readable block so the lane can be monitored and reviewed consistently. See `assets/linear-outcome-block.example.md`.

At minimum, capture:

- status
- branch or artifact location
- files touched
- validation summary
- suggested next action when the work is incomplete

## Retry and resume

Document how the adopter should handle:

- max-turn exhaustion
- partial progress
- reruns after validation failure
- interrupted sessions that need a resume path

The lane contract should explicitly say whether the retried worker reuses the same branch, same worktree, or a fresh one.

If manual cleanup is ever needed, require a human or orchestrator to confirm the issue is truly terminal before deleting artifacts.
