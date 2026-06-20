# Goal layer

The release-manager lane *executes and merges* a backlog. It does not decide **what the
next wave of work should be**. The goal layer is that missing piece: it holds a durable
**goal** — a north star plus acceptance criteria and a budget — and drives ephemeral
**planner** passes that mint the next wave of work tickets, until the acceptance criteria
are met (or a guard stops it).

This is what turns "merge whatever is ready" into "work toward *this outcome* for hours,
unattended."

```
            ┌─────────────────────────── goal layer (this doc) ───────────────────────────┐
            │                                                                              │
  /goal ───▶│  goal-manager init        durable GOAL state in a Linear PROJECT             │
            │     • north star          (base64 block: status, acceptance, budget)         │
            │     • acceptance          + first planner ticket (label goal:planner)        │
            │                                                                              │
            │  ┌─ heartbeat ─ goal-manager tick --loop ──────────────────────────────────┐ │
            │  │  every interval:                                                         │ │
            │  │   1. run the release lane (merge ready PRs)  ───────────┐                │ │
            │  │   2. backlog low & no planner pending? mint next planner│                │ │
            │  └─────────────────────────────────────────────────────────┼──────────────┘ │
            │                                                             │                │
            │  planner ticket dispatched (Symphony / launcher / you) ─────┘                │
            │     → planner AGENT reads `status`, then:                                    │
            │        • acceptance met → goal-manager complete  (goal → done, loop stops)   │
            │        • else → add-tasks (next wave) + next-planner (or guard → halted)     │
            └──────────────────────────────────────────────────────────────────────────────┘
                          │ work tickets (label lane:claude)        ▲ merged PRs move issues to Done
                          ▼                                         │
            ┌──────── existing lane (unchanged) ──────────────────────────────────────────┐
            │  workers implement a ticket → open PR → mark release:ready → STOP            │
            │  release-manager: single writer, merges ready+green PRs serially into main   │
            └──────────────────────────────────────────────────────────────────────────────┘
```

## The principle: durable state, ephemeral agents

The goal layer copies the release lane's design one level up. The release lane never keeps a
long-running "merge brain"; it keeps **state on GitHub** (PR labels) and runs an idempotent
pass that re-derives what to do. The goal layer keeps **state in Linear** (a project) and runs
ephemeral planner passes that re-derive the plan each time.

There is deliberately **no long-lived planning context** that drifts, forgets, or dies. Every
planner pass is a fresh agent that reads the durable state, acts once, and exits. If it crashes,
the next heartbeat just mints another one. This is the same reason the merge lane is a stateless
loop rather than one daemon holding everything in memory.

## The pieces

| Piece | What it is | Role |
|---|---|---|
| `bin/goal-manager` | A bash engine (sibling of `release-manager`) | All durable-state I/O and **all guard logic** (dedup, budget, termination). Dry-run by default; mutations need `--apply`. |
| `commands/goal.md` (`/goal`) | A slash command | Bootstraps a goal: frames north star + acceptance, runs `init`, wires the loop. |
| `assets/goal-planner-prompt.template.md` | A worker prompt | The prompt a **planner agent** runs. Its output is tickets, not a PR. |
| heartbeat | `goal-manager tick --loop` | Merges via the release lane, then mints the next planner when the backlog runs low. |

The planner needs judgement ("is acceptance met? what is the next wave?"), so it is an LLM agent.
Everything mechanical and safety-critical (counting progress, dedup, enforcing the budget,
deciding to halt) lives in `goal-manager`, never in the agent's head — exactly as merge-gate logic
lives in `release-manager`, not in the worker.

## State machine (all in Linear)

- **Goal** = a Linear **project**. Its description carries a machine-readable block:
  ```
  <!-- goal-state -->
  <base64 of {"status":"active","north_star":...,"acceptance":...,"budget_tasks":N,"budget_passes":K,"no_new_work_halt":S,...}>
  <!-- /goal-state -->
  ```
  `status` is `active` → `done` (acceptance met) or `halted` (a guard tripped or an operator stop).
  The values are base64-encoded JSON so arbitrary goal text can never corrupt the block.
- **Work tickets** = issues in the project labelled with the lane's `task_label` (default
  `lane:claude`). Workers pick these up and run the normal worker → `release:ready` → merge flow.
- **Planner tickets** = issues labelled `goal:planner`. A pending one (Todo/In Progress) means a
  planning pass is owed. When a pass runs, `goal-manager` closes the ticket and tags it
  `goal:planned` (it added work) or `goal:nowork` (it added nothing).

Progress is **derived** from one Linear query each pass — counts by state *type*
(unstarted/started/completed/canceled, which are stable across workspaces), planner passes, and the
trailing no-work streak. Nothing mutable is cached, so the math cannot drift out of sync with Linear.

## Termination — the guards that make it safe to leave alone

Autonomy for hours is only safe if it is guaranteed to **stop**. Every guard is fail-closed: if
Linear is unreadable, `goal-manager` skips the pass rather than guessing, and never mutates on a bad
read. A goal ends when any of these fire:

| Guard | Set by | Stops the goal when… |
|---|---|---|
| **Acceptance met** | the planner agent | the planner judges the criteria satisfied → `complete` → `done`. |
| **Task budget** | `--budget-tasks` | total work tickets reach the cap → `add-tasks` refuses to create more. |
| **Pass budget** | `--budget-passes` | planner passes reach the cap → `next-planner` halts. |
| **No-new-work** | `--no-new-work-halt` | N consecutive planner passes add nothing → `next-planner` halts. |
| **Pending-planner** | (always on) | a planner is already pending → no second planner is minted (no fan-out, no spin). |
| **Title dedup** | (always on) | a wave repeats an existing ticket title → that ticket is dropped. |
| **Single-writer lock** | (always on) | a second `goal-manager` for the same goal is blocked (one writer, like the merge lane). |

The no-work streak + the pass budget together guarantee forward progress *or* a halt: a planner that
keeps finding nothing to do drives the streak to the halt threshold; a planner that keeps finding work
eventually hits the task or pass budget. There is no configuration in which it mints forever.

The pending-planner guard is **lag-proof**: each mint first reserves a slot in the durable state block
(`planners_minted`, which is read-your-writes consistent) before creating the ticket, so a second mint
is blocked even in the window where Linear's issue *list* has not yet surfaced the just-created planner.
That closes the double-mint race between the heartbeat and a planner agent.

> The full issue set is paginated, so the counts that drive every guard are exact regardless of size
> (up to a hard 5000-issue safety cap, past which `goal-manager` refuses to operate rather than trust a
> truncated count). Still, keep budgets modest — a goal is meant to span tens of tickets; split very large
> efforts into several goals.

## Quickstart (standalone — no Symphony required)

```bash
source ./env.sh                      # goal-manager + release-manager on PATH; defaults loaded
export LINEAR_API_KEY=...            # never commit this
```

1. **Create the goal** (dry-run first to preview the state, then `--apply`):
   ```bash
   goal-manager init --team ENG --name "Dark mode" \
     --north-star "The web app supports a polished dark theme users can toggle and that persists." \
     --acceptance "Toggle in settings; theme persists across reloads; all primary screens themed; visual check passes." \
     --budget-tasks 12 --budget-passes 6 --no-new-work-halt 2
   # prints the new goal/project id, e.g. proj_abc123, and mints the first planner ticket
   ```

2. **Dispatch.** Something must launch agents against the open tickets:
   - a **`goal:planner`** ticket → launch a planner with `assets/goal-planner-prompt.template.md`
     (its output is the next wave of tickets);
   - **work** tickets → launch ordinary workers (they open PRs and mark them `release:ready`).

   With Symphony, point it at the project and it dispatches both. Standalone, use the worker launcher
   (`assets/claude-worker.reference.sh`) — wire it to select the planner prompt when a ticket carries
   `goal:planner`. Or, in a Claude session, dispatch them yourself.

3. **Run the heartbeat** (merges ready PRs and replenishes the backlog):
   ```bash
   goal-manager tick --goal proj_abc123 --with-release-manager --repo "$PWD" --apply --loop --interval 120
   ```
   It stops on its own when the goal reaches `done` or `halted`.

`/goal "<your goal>"` automates steps 1–3 with confirmation prompts.

### wave.json shape

`add-tasks` (and `init --tasks-file`) read a JSON array; each item becomes one work ticket:

```json
[
  {
    "title": "Add a theme toggle to the settings page",
    "description": "## Summary\n...\n\n## Acceptance Criteria\n- [ ] ...\n\n## Validation Commands\n- `npm test`\n\n## Touched Areas\n- src/settings/"
  }
]
```

## Running modes

- **Symphony** — Symphony dispatches and heals; the heartbeat (or a cron) runs `tick`. Fully hands-off.
- **Standalone launcher** — the worker launcher dispatches planner + work tickets; the heartbeat replenishes.
- **Your own Claude session** — `/goal` frames the goal, you let the heartbeat run, and you launch agents
  for open tickets between ticks. Good for a supervised first run.

In every mode `goal-manager` is the same: it owns durable state and the guards. Only *who launches the
agents* differs — and `goal-manager` never launches them, it only mints the tickets, exactly as
`release-manager` never creates worker PRs.

## Operational notes

- **Dispatch is external.** `goal-manager` mints a `goal:planner` ticket; it does not run the planner.
  If nothing dispatches planner tickets, the goal stalls (safely) with a pending planner and the
  heartbeat logging "planner pending dispatch". Wire dispatch (Symphony / launcher / operator) for
  autonomy.
- **Linear is eventually consistent.** A just-created ticket may not appear in the next query for a few
  seconds (like the `gh` label lag the release lane absorbs). The single-writer lock plus the
  pending-planner check keep this from double-minting in the common case; keep `--interval` at tens of
  seconds, not sub-second.
- **One writer per goal.** Run a single heartbeat per goal. The lock blocks a second `goal-manager`, but
  don't rely on it to coordinate two operators racing the same project.
- **Budgets are durable.** They are stored in the goal state at `init`, not re-read from flags each pass —
  raising a cap means editing the goal, which is intentional friction against "just let it keep going".

## Safety

- The planner only creates tickets. It never merges, pushes, or moves work to Done — merging stays in the
  single release lane, gated by CI.
- Goal text and ticket titles are **untrusted data** to the planner (see the trust boundary in the prompt
  template); they cannot redirect it to change scope, budget, or to declare the goal complete.
- Don't raise the budgets or disable the no-new-work halt mid-run to keep an unattended goal going. Those
  caps are the whole reason it is safe to walk away.
