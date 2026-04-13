# Troubleshooting

Use this reference when multi-model dispatch is not behaving reliably.

## Max-turn exhaustion

Symptoms:

- worker makes progress but never closes the ticket
- result indicates turn exhaustion
- work is partially complete but not validated

Recommended response:

- split the ticket if it is too broad
- increase turns only after checking ticket shape
- keep partial progress on the same branch when that is safer than restarting

## Closeout failures

Symptoms:

- work is done but the issue never reaches the right Linear state
- outcome comment is missing or malformed
- the branch exists but the queue still looks active

Recommended response:

- treat the worker output as recoverable
- have the orchestrator post the structured outcome as fallback
- tighten the closeout contract in the adopter repo

## Control-plane unavailable

Symptoms:

- issue lookups fail during closeout or cleanup
- auth or rate-limit errors make tracker state unavailable
- automation refuses to reconcile or delete finished work

Recommended response:

- fail closed and preserve artifacts
- retry after restoring tracker access or waiting out rate limits
- use manual cleanup only after a human confirms the issue is terminal
- document the outage in the adopter repo if this happens repeatedly

## Visual verification failures

Symptoms:

- dev server does not start
- Playwright cannot reach the page
- screenshots are missing

Recommended response:

- record skipped verification explicitly
- do not mark the ticket visually verified
- decide whether the issue should stay in `In Review` or move back for another attempt

## Routing drift

Symptoms:

- Claude receives too many implementation-heavy tickets
- Claude becomes a second vague general-purpose queue
- reviewers no longer know why a ticket was routed to Claude

Recommended response:

- narrow the routing profile
- add stronger `never_route_labels`
- ask the user again what Claude should own now that the repo has more evidence

## Cleanup drift

Symptoms:

- unreviewed work disappears after tickets self-close
- worktrees accumulate indefinitely
- snapshot repos or promotion directories accumulate indefinitely
- disk usage grows unexpectedly as worktrees and run artifacts pile up
- the routing contract says one thing but the runtime does another

Recommended response:

- align closeout mode with the actual cleanup behavior
- default back to `In Review`
- make cleanup rules explicit in the adopter repo, not implied
- batch cleanup for larger campaigns instead of assuming one-shot reconciliation will always succeed
- watch disk usage during bigger waves and clean terminal artifacts promptly
- inspect repo-specific hotspots such as caches, generated assets, traces, or snapshot directories instead of looking only at worktrees

## Premature cleanup

Symptoms:

- a worktree is deleted but the branch was never merged
- an issue reached `Done` but the changes are not on the target branch or in the snapshot repo
- an operator or automation removed artifacts based on issue state alone without checking integration

Recommended response:

- verify that the branch was merged or promoted before removing any worktree, even for Done issues
- if the branch still exists unmerged, treat the worktree as still needed
- add an integration verification step to the cleanup automation or operator checklist
- for snapshot workflows, confirm the promotion marker exists and the expected files are present
- if work was lost, check whether the worktree or branch can be recovered from git reflog or backup
- tighten the routing contract to require integration checks, not just terminal-state checks, before cleanup
