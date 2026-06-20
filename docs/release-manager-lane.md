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

Use `--no-linear` for GitHub-only setups or private GitHub tests where tracker
state should not change.

## Strategy Modes

| Strategy | Behavior |
|---|---|
| `queue` / `auto` | `gh pr merge --auto --squash --delete-branch`; with GitHub Merge Queue enabled, GitHub handles ordering and final validation. |
| `squash` | Immediate squash merge. Use only with branch protection and a trusted repo. |
| `merge` | Immediate merge commit. |
| `rebase` | Immediate rebase merge. |

For busy branches, prefer GitHub Merge Queue plus required status checks.

## Labels

| Label | Purpose |
|---|---|
| `release:ready` | Worker says PR is ready for the release manager. |
| `release:queued` | Release manager claimed the PR and requested merge/queue. |
| `release:merged` | Merge evidence was observed; never set from queue intent alone. |
| `release:failed` | Merge or deploy failed and needs follow-up. |

Defaults are configurable with `RELEASE_MANAGER_*` env vars in `env.sh`.

## Safety Invariants

- Dry-run is default.
- `--apply` is required for mutation.
- Apply mode takes a per `(repo, base branch, ready label)` lock.
- Workers do not mutate `main`.
- Release manager serializes `main`.
- Deployment waits poll a workflow run for the merge SHA.
- Linear/tracker closeout is evidence-based, not just "worker said done."

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
