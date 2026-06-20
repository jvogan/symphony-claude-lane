# Conflict-Aware Dispatch (design / roadmap)

> **Status: design, not shipped.** This document describes a *preventive* layer for
> high-volume multi-agent work. The release lane already solves the merge problem
> *reactively* (single-owner serialization, GitHub Merge Queue, and closed-loop
> rebase recovery — see [`release-manager-lane.md`](release-manager-lane.md)).
> Conflict-aware dispatch attacks the same problem one step earlier, at the moment
> work is handed out. It is documented here as a deliberate, well-scoped bet rather
> than shipped as an unproven heuristic in the dispatch path.

## The problem it prevents

When many workers run at once, the expensive failures don't come from "pushing to
main" — they come from **two workers editing overlapping code at the same time**.
Worker A and Worker B both branch off `main`, both finish, both open PRs. The first
merges cleanly; the second is now behind and conflicting, so it must rebase, re-run
CI (~minutes), and — if `main` moved again meanwhile — rebase a second time. With
5–8 concurrent finishers this becomes a rebase storm: the last few PRs can take an
hour to land even though each individual CI run is short.

GitHub Merge Queue and the [release manager](release-manager-lane.md) make that
*recoverable and bounded*. Closed-loop recovery makes it *autonomous*. But every
rebase cycle still burns wall-clock and worker tokens. The cheapest conflict is the
one that never happens.

**Insight:** conflicts are a function of *file overlap between concurrently
in-flight issues*. If the dispatcher knew, at hand-out time, that issue X and issue
Y are both going to touch `src/auth/*`, it could stagger them — run X now, hold Y
until X's PR is in `release:ready` — while still fanning out the dozen issues that
touch disjoint areas. Throughput stays high; the contention that causes rebase
storms is removed at the source.

## Where this sits

Defense in depth, not a replacement:

```
Dispatch time          →  Conflict-aware dispatch   (prevent overlap)   ← this doc
PR ready → main         →  GitHub Merge Queue        (serialize + batch)
Merge hit a conflict    →  Closed-loop recovery      (auto-rebase)       ← shipped
```

Prevent what you can predict; serialize what you can't; recover from the rest.

## Approach

The dispatcher computes, for a candidate wave of issues, a **predicted touch-set**
per issue, builds an **overlap graph**, and emits a **dispatch plan**: groups of
mutually-disjoint issues that are safe to run fully in parallel, plus a serialized
order within each overlapping cluster.

### 1. Predicting an issue's touch-set

Three signals, cheapest first, combined with falling confidence:

1. **Label → path map.** Most repos already route by area labels (`kind:ui`,
   `kind:infra`, …). A small map — colocated with the routing profile — associates
   each label with the directories it tends to touch:

   ```yaml
   # .orchestration/claude-lane.yaml  (proposed addition; schema_version bump)
   conflict_zones:
     kind:auth:      [src/auth/, src/middleware/session.ts]
     kind:billing:   [src/billing/, migrations/]
     kind:ui:        [app/, components/]
     shared_hot:     [package.json, src/types/, schema.prisma]   # always treat as overlapping
   ```

   Zero model cost, fully deterministic, and operator-auditable. This alone catches
   the common case (two `kind:billing` issues, or anything touching `shared_hot`).

2. **Historical touch-sets.** The lane already records what each finished issue
   actually changed: the worker outcome block carries `files_touched`, and the
   completion sentinel / `meta.env` corpus preserves it per issue (see
   [`architecture.md`](architecture.md)). Aggregating `files_touched` by label over
   past waves turns the static map above into a *learned* one — the same corpus
   [`bin/routing-feedback`](release-manager-lane.md) reads for model performance.

3. **Planning pass (optional, highest cost).** For issues with no useful labels, a
   single cheap model call ("which files/dirs will this issue most likely touch?")
   produces a predicted set. Bounded to one call per unlabeled issue; skipped when
   the label map already covers the issue.

Every prediction is **advisory and conservative**: unknown → treat as potentially
overlapping with the `shared_hot` set, never as guaranteed-disjoint. False negatives
(a missed overlap) cost one rebase cycle, which the recovery loop already handles —
so the system degrades to today's behavior, never worse.

### 2. Overlap graph → dispatch plan

- Nodes are candidate issues; an edge connects two issues whose predicted touch-sets
  intersect (path-prefix match; any `shared_hot` member forces an edge).
- Connected components are **clusters**: within a cluster, dispatch is serialized
  (one in flight until its PR reaches `release:ready`); across clusters, dispatch is
  fully parallel.
- Within a cluster, order by issue priority, then by smallest predicted touch-set
  first (land the small, surgical changes before the sprawling ones).

The output is a plan the orchestrator consults — it does not seize control of
dispatch:

```
$ dispatch-plan --wave LIN-101,LIN-102,...,LIN-115
parallel now (disjoint):  LIN-101 LIN-103 LIN-104 LIN-107 LIN-110 ...
hold (overlap cluster A, src/billing/): LIN-102 → then LIN-109
hold (overlap cluster B, shared_hot):   LIN-105 → then LIN-112
note: LIN-114 unlabeled, predicted touch-set unknown — treated as shared_hot
```

## Why it's a roadmap item, not shipped today

Honest constraints that must be resolved before this belongs in the dispatch path:

- **Prediction is heuristic.** A label map is only as good as the repo's labeling
  discipline; a planning pass can be wrong. The cost of a wrong *hold* is lost
  parallelism (slower, not incorrect); the cost of a wrong *parallel* is one rebase
  cycle. Both are survivable, but the tuning (how aggressively to hold) needs real
  wave data to set well.
- **It needs the corpus.** Signal (2) is only useful after the lane has run enough
  waves to learn per-label touch-sets. Signal (1) works on day one but needs the
  operator to fill in `conflict_zones`.
- **Schema change.** `conflict_zones` is a new routing-profile block and a
  `schema_version` bump; it should land with `routing-feedback` learning to populate
  it, not before.
- **It must never block correctness.** The plan is advisory. If the predictor is
  unavailable or the operator opts out, dispatch falls back to today's fan-out and
  the release lane absorbs the conflicts as it does now.

## Suggested build order (when prioritized)

1. **Static `conflict_zones`** in the routing profile + a `dispatch-plan` advisory
   that reads it and prints parallel/hold groups. Deterministic, no model cost,
   immediately useful for repos with area labels.
2. **Learned touch-sets** — extend `routing-feedback` to aggregate `files_touched`
   by label from the `meta.env` corpus and *propose* `conflict_zones` entries
   (human-approved, same as its routing suggestions).
3. **Planning-pass fallback** for unlabeled issues, bounded to one call each.
4. **Orchestrator integration** — have the dispatch loop consume the plan, holding
   clustered issues until the predecessor reaches `release:ready`.

Until then, the shipped path — Merge Queue + single-owner release manager + closed-
loop rebase recovery — handles high-volume merging correctly; conflict-aware
dispatch is the optimization that makes it *cheaper*, not the thing that makes it
*work*.
