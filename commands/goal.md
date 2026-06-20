---
description: Start or continue autonomous work toward a long-horizon goal (goal layer over the release lane)
argument-hint: "<goal description>  |  continue <project-id>"
allowed-tools: Bash, Read, Edit, Write
---

You are the orchestrator for the **goal layer** of this repo's Symphony + Claude lane.
The user wants autonomous progress toward a goal that spans many waves of work, not a
single task. Drive it through `bin/goal-manager`, which holds durable goal state in a
Linear project and dispatches ephemeral "planner" passes that mint the next wave of work.

User request: **$ARGUMENTS**

Read `docs/goal-layer.md` first for the full model. Then proceed:

## 0. Preconditions (check, don't assume)

- `source ./env.sh` (so `goal-manager`, `release-manager` are on PATH and defaults load).
- Confirm `LINEAR_API_KEY` is set and a Linear **team key** is known (ask if not; or use
  `$GOAL_MANAGER_TEAM_KEY`). Confirm the repo's release lane labels exist (the worker →
  `release:ready` → release-manager flow from `docs/release-manager-lane.md`).
- If the request is `continue <project-id>`, skip to step 3 with that goal id.

## 1. Frame the goal (this is the durable contract — get it right)

Translate the request into:
- a **north star**: one paragraph, the outcome that defines success;
- **acceptance criteria**: a short, checkable list the planner will judge against to decide
  when to STOP. Vague criteria = a goal that never terminates. Make them concrete.
- a **budget**: `--budget-tasks` (hard cap on total tickets), `--budget-passes` (hard cap on
  planner passes), `--no-new-work-halt` (stop after N planner passes that add nothing).

If the goal or acceptance is ambiguous, ask the user ONE round of clarifying questions before
creating anything. Do not guess the acceptance criteria.

## 2. Create the goal (dry-run, confirm, then apply)

```
goal-manager init --team <KEY> --name "<short name>" \
  --north-star "<paragraph>" --acceptance "<criteria>" \
  --budget-tasks <N> --budget-passes <K> --no-new-work-halt <S>
```
Run it WITHOUT `--apply` first and show the user the planned state JSON. On confirmation,
re-run with `--apply`. It prints the new goal/project id and mints the first planner ticket.
Optionally seed wave-1 directly with `--tasks-file wave1.json` (same JSON shape as the planner
writes; see `docs/goal-layer.md`).

## 3. Run the loop

The system now has: durable goal state, work tickets (maybe), and a pending **planner ticket**
(label `goal:planner`). Two things must happen on a cadence — dispatch and merge:

- **Dispatch**: whatever runs your lane (Symphony, the worker launcher, or you in this session)
  must launch agents against the open tickets. For a `goal:planner` ticket, launch a planner
  using `skills/symphony-claude-lane/assets/goal-planner-prompt.template.md` (NOT the worker
  prompt) — its output is the next wave of tickets, not a PR. For ordinary work tickets, launch
  workers as usual; they open PRs and mark them `release:ready`.
- **Merge + replenish heartbeat**: run
  ```
  goal-manager tick --goal <id> --with-release-manager --repo "$PWD" --apply --loop --interval 120
  ```
  Each tick merges ready PRs (via release-manager) and, when the backlog runs low and no planner
  is pending, mints the next planner ticket. It stops itself when the goal reaches a terminal
  state (acceptance met → `done`, or a guard → `halted`).

If you are driving dispatch yourself in this session rather than via Symphony, after each heartbeat
inspect `goal-manager status --goal <id>`, launch agents for any open planner/work tickets, and
let the loop continue. Stop and report when `status` shows the goal `done` or `halted`.

## Safety

- Never bypass the guards. The budget caps and the no-new-work halt are what make hours-long
  autonomy safe to leave unattended — do not raise them mid-run to "keep going".
- The planner only creates tickets; it never merges. Merging stays in the single release lane.
- This command must not push to remotes or create anything outside the configured Linear team.
- If `LINEAR_API_KEY` is missing or the team can't be resolved, stop and tell the user — do not
  fall back to guessing.
