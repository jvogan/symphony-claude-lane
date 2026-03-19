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

## Integration verification before cleanup

Terminal issue state is necessary but **not sufficient** for cleanup. An issue can reach `Done` without its changes being integrated — the operator may have moved it prematurely, self-close may have fired before the branch was merged, or snapshot promotion may have failed silently.

Before removing a worktree or its artifacts, verify that the work was actually integrated:

- **Branch-based workflows**: confirm the branch was merged or the PR was closed-as-merged. If the branch still exists unmerged, the work may not be on the target branch even if the issue is Done.
- **Snapshot-based workflows**: confirm the changes were promoted into the snapshot repo. If the promotion marker is missing or the snapshot does not contain the expected files, the work is not integrated.
- **PR-based workflows**: confirm the PR was merged, not just closed.

If integration cannot be confirmed, treat the worktree as still needed regardless of issue state. Leave a clear operator note and escalate rather than deleting.

The lane contract should define which integration check applies to the adopter's workflow and who is responsible for running it.

## Storage and retention

Worktrees, snapshot repos, and run artifacts are a real operational cost, not just incidental scratch space.

For many frontend or JavaScript-heavy repos, a single worktree can be large once dependencies, build outputs, screenshots, or traces are present. Snapshot-based workflows can add another layer of retained storage. Larger waves can consume substantial disk if cleanup is deferred.

The lane contract should therefore define:

- when terminal-state worktrees are eligible for removal, **and how integration is verified first**
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

If manual cleanup is ever needed, require a human or orchestrator to confirm the issue is truly terminal **and that the work was integrated** before deleting artifacts.
