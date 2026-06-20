# GitHub-only quickstart (no Linear, no Symphony)

You have **only Claude Code and/or Codex + a GitHub account** and you want the
high-volume workflow: many parallel agents finish work, and instead of each one
racing to merge into `main` (the rebase storm where the 5th–8th agent takes an
hour), they hand off and a single owner lands everything safely.

You can do that today with just GitHub. Linear and Symphony make it nicer at
scale (see the last section), but neither is required.

> **The one idea that fixes it:** workers never merge. Each worker opens a PR,
> gets CI green, adds the GitHub label `release:ready`, and **stops**. One
> `bin/release-manager` process is the *only* thing that ever merges into `main`,
> and it merges serially. Fifteen agents can't collide if only one writer exists.

## The rebase storm is actually two problems

They have different fixes, and only one of them needs anything fancy:

| Problem | Fixed by | Needs |
|---|---|---|
| **Chaos** — 15 agents racing to merge, each invalidating the others (the "5th agent takes 1hr+") | the single-writer release-manager lane | nothing — works on any repo |
| **Latency** — even orderly serial merges cost one CI cycle per PR | GitHub **Merge Queue** (parallel speculative CI) | an **org-owned** repo |

So on a plain personal repo you **fix the chaos completely** and accept serial
latency. For 5–8 PRs at ~2 min CI that is ~10–15 minutes orderly — not the 1 hr+
chaos failure. If you later want the latency fix too, see "Scaling up" below.

## One-time GitHub setup

```bash
# 1. Authenticate gh AND wire git's credential helper. Workers push over HTTPS;
#    a GH_TOKEN alone does NOT let `git push` authenticate — setup-git fixes that.
gh auth login          # then: gh auth status
gh auth setup-git      # so each worker's `git push` authenticates

# 2. Create the handoff labels (the entire state machine in this mode).
export GH_REPO=owner/name           # <-- set to YOUR repo, e.g. octocat/widgets
for L in release:ready release:queued release:merged release:failed; do
  gh label create "$L" -R "$GH_REPO" 2>/dev/null || true
done

# 3. Clone THIS skill, then source its env and run the GitHub-only preflight.
#    (The release-manager tooling lives at the repo ROOT — `npx skills add`
#    installs only the skill folder, NOT bin/ or env.sh, so git clone is required.)
git clone https://github.com/jvogan/symphony-claude-lane.git
source symphony-claude-lane/env.sh
bin/release-manager-doctor --repo /path/to/your/repo --strategy squash
```

`release-manager-doctor` (not `claude-doctor` — that one expects Linear) is your
GitHub-only preflight. It treats Linear as optional and tells you exactly what
your repo can and can't do for serialized merges — including whether Merge Queue
is even available to you and whether a strict "require up-to-date" check would
re-create the storm.

**Pick your merge strategy** based on what the doctor reports:

- **Personal repo (most new users): use `--strategy squash`.** The release
  manager merges ready PRs one at a time with `gh pr merge --squash`. No repo
  settings required. This is the simplest correct path.
- **`--strategy queue` (the default) needs more:** it runs `gh pr merge --auto`,
  which GitHub rejects unless you enable **Settings → General → Allow
  auto-merge** *and* there is a required status check (or a merge queue) for it
  to wait on. Without those it either fails every PR or merges instantly with no
  serialization. The doctor warns when this is misconfigured.

## The worker contract

Give this to every worker — Claude *or* Codex. It is the whole trick:

> Work on your own branch (`claude/<slug>` or `codex/<slug>`), never `main`.
> Finish the task, open a PR, make CI green, and run the repo's validation.
> Put a short summary in the PR description. Then add the GitHub label
> `release:ready` and **stop**.
>
> Do **not** merge, rebase onto main, push to `main`, or deploy — *even if I say
> "deploy."* "Deploy" means "hand off": add `release:ready` and stop. Only the
> release manager merges.

That last clause is what kills the storm: "deploy" stops meaning "you merge."

## Fanning out the workers

You do **not** need Symphony for this. Two options:

**a) Drive them yourself (simplest).** Open N Claude Code / Codex sessions, give
each one task plus the contract above. For isolation, give each its own worktree:

```bash
git worktree add ../wt-fix-nav -b claude/fix-nav main
```

**b) Use the bundled launcher in GitHub-only mode.** The reference launcher runs
a tmux-backed **Claude** worker that takes its task from a GitHub issue or a file
(no Linear) and closes out by opening a PR + adding `release:ready`. (It is
**Claude-only** — there is no Codex launcher in this repo; run Codex workers via
option (a), or via Symphony for managed fleets.)

```bash
# Task from a GitHub issue (its lane:claude label, if set, is honored as the routing guard):
skills/symphony-claude-lane/assets/claude-worker.reference.sh \
  gh-42 /path/to/your/repo --no-linear --github-issue 42

# …or task from a file (operator-authored = auto-routed):
skills/symphony-claude-lane/assets/claude-worker.reference.sh \
  fix-nav /path/to/your/repo --no-linear --task-file task.md
```

In `--no-linear` mode the launcher requires `gh` (not `LINEAR_API_KEY`), uses a
Linear-free prompt + MCP config, and the worker's closeout is "open PR + add
`release:ready`." Everything else (worktree isolation, the allowlisted `env -i`
jail, the completion sentinel, `--dry-run` safety) is identical to the Linear
path. Add `--dry-run` to preview without creating anything.

## The single release-manager command

One process, the only writer to `main`. Dry-run is the default — nothing mutates
until `--apply`.

```bash
source /path/to/symphony-claude-lane/env.sh

# Preview what WOULD be merged (no mutation):
bin/release-manager --repo /path/to/your/repo --no-linear --strategy squash --dry-run

# Drain the queue, looping as new release:ready PRs land:
bin/release-manager --repo /path/to/your/repo --no-linear --strategy squash \
  --apply --loop --interval 15 --max 10
```

- **`--no-linear`** is the GitHub-only flag: GitHub labels are the entire state
  machine (`release:ready` → `release:queued` → `release:merged` / `release:failed`).
- **`--strategy squash`** for a personal repo (immediate, serialized). Switch to
  `--strategy queue` only once you've enabled auto-merge or a merge queue.
- **Do not add `--wait-merge`** for high volume — it re-serializes the very work
  a merge queue would batch. Leave it off and let the loop drain.
- **No CI on the repo?** Every PR is skipped (`checks=none`) and the loop merges
  *nothing*. Add `--allow-no-checks` to merge on the label alone — only on repos
  where every label-adder is trusted. (`release-manager-doctor` warns when it
  finds no PR-triggered CI.)

> **`--loop` is a foreground heartbeat, not a daemon.** It is a plain
> poll-and-sleep inside one process: if that process dies, merging silently
> stops and nothing restarts it. Use it for attended sessions. For durable,
> hands-off operation, either run the **one-shot** form (drop `--loop`) on a
> schedule — cron, `launchd`, or a systemd timer — or adopt the event-driven
> GitHub Action template at
> [`docs/examples/release-on-ready.yml`](examples/release-on-ready.yml), which
> merges ready + CI-green PRs automatically and serially with no machine to
> keep running. Run **one** driver — a local `--loop` *or* the Action, not both
> (they don't share a lock across machines).

Monitor anytime (read-only, never takes the lock):

```bash
bin/release-status --repo /path/to/your/repo
```

**The trust boundary: label + green CI.** The release manager merges a PR only
when it *both* carries `release:ready` **and** has green CI — a red, pending, or
check-less PR is skipped, never merged. So what actually guards `main` is *who
(or what) can add the `release:ready` label* plus *your CI being required*. Keep
at least one required check and restrict label-add permission to trusted actors.
(On a repo with no CI at all, passing `--allow-no-checks` makes the label alone
the merge trigger — only do that where every label-adder is trusted.)

## Conflicts are manual in this mode

Automatic closed-loop conflict recovery (`--on-conflict redispatch`) needs Linear
to bound retries, so in `--no-linear` mode it is **off**: a PR that can't merge
cleanly (`mergeStateStatus=DIRTY`) is detected, **skipped, and reported** — never
silently merged. Resolve it yourself (or send the owning agent back):

```bash
git checkout claude/<slug> && git fetch origin && git rebase origin/main
# …resolve conflicts, then RE-RUN full validation (a rebase can break a green PR)…
git push --force-with-lease
gh pr edit <pr> --add-label release:ready     # re-enter the queue
```

To avoid conflicts in the first place: keep PRs small and stagger work that
touches the same files.

## Scaling up: what Linear and Symphony add

Nothing above changes when you adopt these — you just gain capabilities:

- **GitHub Merge Queue** (the *latency* fix) — requires an **organization-owned**
  repo (public on any org plan; private only on GitHub Enterprise Cloud). It runs
  CI once per speculative *group* of PRs and lands them together, so a burst
  drains in roughly one CI cycle instead of N. Personal repos can't enable it —
  the cheapest unlock is moving the repo under a free GitHub org and making it
  public. Then switch to `--strategy queue`.
- **Linear** — a durable cross-session backlog + audit trail, task-characteristic
  auto-routing, and **automatic** closed-loop conflict recovery (the release
  manager re-triggers the producing worker to rebase itself, bounded and
  fail-closed) instead of manual rebases. See [release-manager-lane.md](release-manager-lane.md).
- **Symphony** — the autonomous fleet manager: it turns N tracker issues into N
  isolated workers, self-advances waves as slots free up, throttles concurrency,
  skips file-overlapping work, and supervises/heals stuck workers — so you stop
  hand-launching sessions. The release-manager lane is itself just a Symphony
  lane pinned to one writer.

When you're ready: install [symphony-linear-starter](https://github.com/jvogan/symphony-linear-starter),
create the `lane:claude` + `model:*` labels ([linear-setup.md](linear-setup.md)),
drop `--no-linear`, and your worker contract and release loop stay the same.
