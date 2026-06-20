# Release Manager Lane

The Claude lane makes workers autonomous. The release-manager lane makes
merge-to-main and deploy closeout autonomous without letting every worker fight
over the same branch.

## Core Rule

Workers are producers. The release manager is the single consumer that mutates
`main`.

Worker agents should:

1. Finish the task.
2. Open or update a PR.
3. Run the requested validation.
4. Add the GitHub label `release:ready`.
5. Post the PR URL and validation summary to the tracker.
6. Stop.

Worker agents must not merge, rebase, push to `main`, or trigger production
deployments.

## High-volume parallel merge (the 15-agents-at-once case)

Picture 15 agents finishing around the same time, each opening a PR and each
trying to merge into `main`. Every merge advances `main`, which puts every other
PR behind and forces a rebase. The agents fight over the same branch: PR 1 and 2
slip through, but by the 5th-7th PR the rebase-and-recheck cycle never converges.
That is the rebase storm, and it shows up as a single PR sitting in the queue for
an hour or more while `main` keeps moving underneath it. It is a livelock, not a
backlog — adding more agents makes it worse.

The fix is the producers/consumer split this lane already enforces, scaled up:

1. **Workers stay producers.** They open the PR, go green, add `release:ready`,
   post the tracker outcome, and stop. They never merge or rebase. The 15 agents
   never touch `main`; only the release manager does.
2. **Pick a serialization strategy for your repo.** Step 1 already fixes the
   *chaos* (only one writer touches `main`). What is left is *latency* — how fast
   the single writer can drain the queue:
   - **GitHub Merge Queue** is the throughput fix: it batches several
     `release:ready` PRs, rebases them against `main` once as a group, runs the
     merge-group checks once, and lands them together. **But Merge Queue is only
     available on organization-owned repos** (public on any org plan; private only
     on GitHub Enterprise Cloud). It does **not** exist on personal-account repos.
   - **No merge queue (e.g. a personal repo): use `--strategy squash`.** The
     release manager merges ready PRs one at a time. The chaos is still gone; you
     just pay ~one CI cycle per PR (N PRs ≈ N cycles).
   - **Watch out for strict "require branches up to date"** with no queue: that
     re-creates the storm even with a single writer (each landed PR invalidates
     the rest → re-update → re-run CI one-at-a-time). `bin/release-manager-doctor`
     detects this and warns. Either enable a queue, turn strict off, or accept the
     serial cost with `--strategy squash`.
   - `--strategy queue`/`auto` runs `gh pr merge --auto`, which GitHub rejects
     unless **Allow auto-merge** is enabled on the repo *and* there is something
     for it to wait on (a required check or a queue). Don't reach for it until the
     doctor says your repo is set up for it.
3. **Run one fire-and-forget release loop:**

   ```bash
   bin/release-manager \
     --repo /path/to/repo \
     --apply \
     --loop \
     --interval 15 \
     --strategy queue \
     --max 10
   ```

   Note what is *absent*: `--wait-merge`. With `--wait-merge` the loop blocks on
   each PR's full merge before it queues the next one, which serializes the exact
   work Merge Queue exists to batch — you get the storm back with extra latency.
   This is the `--wait-merge` serialization trap. For batched throughput, drop
   `--wait-merge` and let the loop queue PRs as fast as it finds them; GitHub does
   the ordering and the merge-group validation.
4. **Bump `--max`.** The default of 3 is tuned for low-traffic repos. For the
   15-agents case raise it (e.g. `--max 10`) so a single pass can hand the queue
   enough PRs to actually batch.
5. **Give production deploy a concurrency group** (see GitHub Workflow Notes) so
   the rapid succession of `main` pushes does not deploy concurrently.

Merge evidence and deploy evidence are not lost by dropping `--wait-merge`: the
loop still labels PRs `release:queued`, and a separate reconciler pass attaches
deploy evidence after the fact (see Decoupled deploy evidence below).

**Keep the loop alive — or make it event-driven.** `--loop` is a foreground
poll-and-sleep in a single process; if that process dies, merging silently stops
and nothing restarts it. For unattended operation, run the one-shot form (drop
`--loop`) under a supervisor (cron, `launchd`, a systemd timer, or a Symphony
lane), or use the event-driven GitHub Action template at
[`examples/release-on-ready.yml`](examples/release-on-ready.yml), which drains
ready + CI-green PRs on `labeled` / `check_suite: completed` / a cron backstop,
serialized by a `concurrency` group.

## Closed-loop conflict recovery

Merge Queue handles PRs that *can* rebase cleanly. A PR whose branch has drifted
into a real conflict with `main` reports `mergeStateStatus=DIRTY`, and the queue
cannot land it. By default the release manager only logs `SKIP #N merge_state=DIRTY`
and moves on, leaving a human to rebase. Closed-loop conflict recovery turns that
dead end into an automatic redispatch: the release manager produces a signal, and
the dispatcher consumes it by sending the issue's own worker back to rebase its
branch.

Opt in with `--on-conflict`:

```bash
bin/release-manager \
  --repo /path/to/repo \
  --apply \
  --loop \
  --interval 15 \
  --strategy queue \
  --max 10 \
  --on-conflict redispatch
```

| `--on-conflict` | Behavior |
|---|---|
| `fail` (default) | A `DIRTY` PR is logged and `SKIP`ped. No tracker change. Byte-for-byte the current behavior. |
| `redispatch` | A `DIRTY` PR is signalled for rebase recovery (label + tracker comment + state move), so the dispatcher can re-run the worker against the conflict. |

Recovery is deliberately narrow. The release manager triggers a redispatch only
when **all** of these hold:

- The `pr_is_ready` reason is exactly `merge_state=DIRTY`. `DRAFT`, `BLOCKED`,
  `BEHIND`, and `UNKNOWN` merge states never redispatch — only a true conflict
  does.
- `--on-conflict redispatch` is set.
- The run is in apply mode (`--apply`). Dry-run never signals.
- Linear is usable: `LINEAR_API_KEY` is set **and** tracker updates are enabled
  (not `--no-linear`).

**Fail-closed when Linear is unavailable.** If Linear is not usable, the release
manager cannot read the prior attempt count, so it cannot know whether it is about
to loop forever. In that case it does **not** redispatch — it logs a warning and
falls through to the normal `SKIP`. This fail-closed rule is the primary guard
against an infinite rebase loop.

**GitHub-only (`--no-linear`):** automatic redispatch is therefore disabled —
there is no Linear to bound the retry count — so a `DIRTY` PR is detected,
skipped, and reported for a human (or a manually re-run worker) to rebase. The
manual recipe is in [github-only-quickstart.md](github-only-quickstart.md#conflicts-are-manual-in-this-mode).

**Attempt cap.** Before signalling, the release manager counts prior tracker
comments containing the marker `<!-- release-manager-rebase -->` on the issue and
sets `attempt = count + 1`. If `count` already meets or exceeds
`RELEASE_MANAGER_MAX_REBASE_ATTEMPTS` (default `2`), it stops trying to recover:
it relabels the PR `release:failed` (removing `release:ready`) and posts a failed
outcome with `detail=rebase_loop_exhausted attempts=<count>`, which moves the
issue to `RELEASE_MANAGER_LINEAR_FAILURE_STATE`. A repeatedly-unrebaseable PR ends
up parked for a human, not cycling forever.

**The redispatch signal** (apply mode), emitted in this order:

1. **GitHub label.** The PR gets `release:rebase`
   (`RELEASE_MANAGER_REBASE_PR_LABEL`) added and `release:ready` removed. Swapping
   the label takes the PR out of the consume set immediately, so the next pass does
   not pick it up again — that is the de-dup mechanism.
2. **Tracker comment.** A comment whose body starts with
   `<!-- release-manager-rebase -->`, followed by:

   ```
   status: rebase_requested
   pr: <url>
   base: <base>
   attempt: <N>
   detail: merge_state=DIRTY
   managed_by: release-manager
   ```

   This comment is also what the attempt counter reads on the next pass.
3. **Tracker state move.** The issue is moved to `RELEASE_MANAGER_REBASE_STATE`
   (default `Todo`) via its resolved state id.

**Dispatcher pickup contract.** The signal is consumed by the dispatcher/launcher,
not by the release manager. The operator (or a poller) watches for issues in
`RELEASE_MANAGER_REBASE_STATE` that carry a `<!-- release-manager-rebase -->`
comment, or equivalently a PR labelled `release:rebase`, and invokes the launcher
with `--rebase-recovery`. To avoid re-picking the same issue, the poller moves the
issue to `In Progress` at dispatch start. The launcher reuses the worker's existing
branch `claude/<issue-id-lower>` (it does not create a new branch): it fetches the
remote branch and adds a worktree tracking it, reusing the worktree if one already
exists. The worker then rebases its **own** branch onto `main`, resolves the
conflict, re-runs the full validation suite from scratch (a rebase can silently
break a previously green PR), pushes with `--force-with-lease` (never to `main`),
and re-adds `release:ready` while removing `release:rebase` — which puts the PR
back in the release manager's consume set for the next pass. If the conflict is
unsafe or semantic, the worker stops, finalizes as failed, and leaves
`release:rebase` in place so a human picks it up.

## AGENTS.md Snippet

Add this to adopter repos:

```md
## Deploy Protocol

When told "deploy", do not merge, rebase, push to main, or trigger production.

Instead:
- ensure your PR is green and not draft
- add GitHub label `release:ready`
- post a tracker outcome with PR URL, branch, validation summary, and risk notes
- stop

Only the Release Manager lane may queue, merge, deploy, or move the issue to
Done based on merge/deploy evidence.
```

## Commands

Dry-run is the default:

```bash
source ./env.sh
bin/release-manager-doctor --repo /path/to/repo
bin/release-manager --repo /path/to/repo --dry-run
```

Apply mode requires explicit opt-in:

```bash
bin/release-manager \
  --repo /path/to/repo \
  --apply \
  --strategy queue \
  --max 3 \
  --wait-merge
```

Loop mode keeps one release lane alive:

```bash
bin/release-manager \
  --repo /path/to/repo \
  --apply \
  --loop \
  --interval 30 \
  --strategy queue \
  --wait-merge \
  --wait-deploy-workflow deploy.yml
```

Use `--no-linear` for GitHub-only setups (no Linear at all) or private GitHub
tests where tracker state should not change. In `--no-linear` mode the GitHub
labels are the entire state machine and conflict recovery is manual — see the
full walkthrough in [github-only-quickstart.md](github-only-quickstart.md).

## Strategy Modes

| Strategy | Behavior |
|---|---|
| `queue` / `auto` | `gh pr merge --auto --squash --delete-branch`. Requires **Allow auto-merge** enabled on the repo (plus a required check or a merge queue for it to wait on); otherwise GitHub rejects every `--auto` request. With GitHub Merge Queue (organization-owned repos only) GitHub batches, orders, and runs final validation once per group. |
| `squash` | Immediate squash merge, one at a time. **The recommended no-queue / personal-repo strategy** — needs no repo settings; the single writer is the serialization. |
| `merge` | Immediate merge commit (one at a time). |
| `rebase` | Immediate rebase merge (one at a time). |

For an **organization** repo with heavy traffic, prefer GitHub Merge Queue plus
required status checks (the latency fix) — see High-volume parallel merge above:
keep `--strategy queue`, enable Merge Queue, drop `--wait-merge`. For a
**personal** repo (where Merge Queue does not exist), use `--strategy squash`:
the chaos is still gone, you just merge serially. Full GitHub-only walkthrough:
[github-only-quickstart.md](github-only-quickstart.md).

## Metrics

In apply mode the release manager appends one JSON line per processed PR to a
metrics file. Dry-run writes nothing — like every other side effect, metrics are
apply-only.

The file defaults to `$CLAUDE_RUNS_ROOT/release-metrics.jsonl` and is overridable
with `RELEASE_MANAGER_METRICS_FILE` or `--metrics-file PATH`. Each line carries:

| Field | Meaning |
|---|---|
| `ts` | Epoch seconds when the line was written. |
| `repo` | GitHub `OWNER/NAME`. |
| `number` | PR number. |
| `url` | PR URL. |
| `head` | Head branch. |
| `base` | Base branch. |
| `strategy` | Merge strategy used this pass. |
| `mode` | `apply` (metrics never emit in dry-run). |
| `conclusion` | One of `queued`, `merged`, `deployed`, `failed`, `rebase_requested`, `rebase_exhausted`. |
| `ready_observed` | Epoch seconds when the PR was first seen `READY`. |
| `queued` | Epoch seconds when merge/queue was requested, or `null`. |
| `merged` | Epoch seconds when merge evidence was observed, or `null`. |
| `time_to_main_s` | `merged - ready_observed` when merged, else `null`. |

`bin/release-status` reads this file to report time-to-main across recent PRs, so
the throughput loop produces its own latency telemetry as it runs.

## Decoupled deploy evidence (`--reconcile-deploys`)

The high-volume loop deliberately fires and forgets: it queues PRs without waiting
for the merge to land, so it never blocks on deploy evidence either. A separate
reconcile pass closes that gap. It finds lane-labelled merged PRs that have landed
but do not yet carry deploy evidence, polls the deploy workflow for each merge SHA,
and attaches the evidence — letting one fast loop drive throughput while a
reconciler trails behind recording what actually deployed.

```bash
bin/release-manager \
  --repo /path/to/repo \
  --apply \
  --reconcile-deploys \
  --wait-deploy-workflow deploy.yml
```

`--reconcile-deploys` requires `--wait-deploy-workflow`; without it the run dies
with an error, because there is no workflow to poll. The pass lists `--state
merged` PRs carrying only lane labels (`release:queued` or `release:merged`).
"Lacking deploy evidence" means: no `release-manager` comment containing `deploy=`
(when Linear is usable), or — for `--no-linear` runs — not yet carrying
`release:merged`. For each such PR it takes the merge commit SHA and polls the
deploy workflow:

- **Success** → relabel `release:merged` (removing `release:queued`) and post a
  `deployed` tracker outcome.
- **Failure** → relabel `release:failed` and post a `failed` outcome.

Like every mutating pass, this is dry-run by default and takes the release lock
only under `--apply`; it emits one metrics line per reconciled PR.

## Labels

| Label | Purpose |
|---|---|
| `release:ready` | Worker says PR is ready for the release manager. |
| `release:queued` | Release manager claimed the PR and requested merge/queue. |
| `release:merged` | Merge evidence was observed; never set from queue intent alone. |
| `release:failed` | Merge or deploy failed and needs follow-up. |
| `release:rebase` | Conflict recovery: replaces `release:ready` to ask the issue's worker to rebase. The PR leaves the consume set until the worker re-adds `release:ready`. |

Defaults are configurable with `RELEASE_MANAGER_*` env vars in `env.sh`.

## Safety Invariants

- Dry-run is default. Every flag below obeys it: `--on-conflict redispatch`,
  `--reconcile-deploys`, and `--metrics-file` are all no-ops without `--apply`.
- `--apply` is required for mutation.
- Apply mode takes a per `(repo, base branch, ready label)` lock. The reconcile
  pass takes the same lock and only under `--apply`.
- Workers do not mutate `main`.
- Release manager serializes `main`.
- Merge requires BOTH the `release:ready` label AND green CI: `pr_is_ready`
  independently checks `statusCheckRollup`, so a red, pending, or check-less PR
  is skipped (never merged) unless the operator explicitly passes
  `--allow-no-checks`. The trust boundary is label-add permission plus required
  checks.
- Deployment waits poll a workflow run for the merge SHA.
- Linear/tracker closeout is evidence-based, not just "worker said done."
- Metrics are apply-only: no JSONL line is written in dry-run.
- Conflict recovery is opt-in (`--on-conflict redispatch`) and fail-closed: it
  never redispatches when Linear is unavailable (the attempt count is unknowable),
  it only triggers on `merge_state=DIRTY`, and it stops after
  `RELEASE_MANAGER_MAX_REBASE_ATTEMPTS`.

## GitHub Workflow Notes

If GitHub Merge Queue is enabled, make sure required checks also run on the
`merge_group` event. Production deployment workflows should use a concurrency
group so multiple pushes to `main` do not deploy concurrently.

Example:

```yaml
concurrency:
  group: production-deploy
  cancel-in-progress: false
```

## Testing

The bundled tests use `RELEASE_MANAGER_GH_BIN` to point at a fake `gh` binary.
This verifies dry-run, apply command shape, deploy polling, and lock behavior
without touching real GitHub or Linear. Live mutation tests should use a private
GitHub repository and `--no-linear` unless the test is specifically about
tracker closeout.
