# Troubleshooting

Use this reference when the Claude lane exists but is not behaving reliably.

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
- the lane becomes a second vague general-purpose queue
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
- the lane contract says one thing but the runtime does another

Recommended response:

- align closeout mode with the actual cleanup behavior
- default back to `In Review`
- make cleanup rules explicit in the adopter repo, not implied
- batch cleanup for larger campaigns instead of assuming one-shot reconciliation will always succeed
- watch disk usage during bigger waves and clean terminal artifacts promptly
- inspect repo-specific hotspots such as caches, generated assets, traces, or snapshot directories instead of looking only at worktrees
