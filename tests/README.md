# tests/

Nine fully-isolated regression tests for the v0.8.2 hardening that landed in v3.0.0, the release-manager lane, and the goal layer.

These tests do **not** create real Linear tickets, mutate GitHub, or invoke the Claude CLI. They are pure-bash checks with temporary repos and fake binaries where needed. They are safe to run on any host with `bash`, `jq`, `git`, and a sourced `env.sh`.

## Tests

| Test | What it verifies |
|---|---|
| `test_tmux_sentinel_malformed.sh` | The `jq -e 'type == "object"'` predicate the reference launcher uses to validate the sentinel JSON file. Also greps the reference launcher to confirm the guard and the `sentinel_malformed` exit_reason are still wired in. |
| `test_mcp_runpod_optin.sh` | The 9 branches of `env.sh`'s `CLAUDE_WORKER_ENABLE_RUNPOD` toggle: which MCP config gets selected, which secrets join the worker env allowlist, and how re-sourcing after the toggle preserves operator overrides. |
| `test_env_isolation.sh` | Replicates the reference launcher's `env -i $allowlist=value …` build loop and verifies that allowlisted vars (e.g. `LINEAR_API_KEY`) survive the execve boundary while unlisted secrets (`SECRET_UNLISTED`, default-mode `RUNPOD_API_KEY`) do NOT. Guards against the broken-by-design `tmux new-session -e VAR=value` pattern silently regressing in. |
| `test_release_manager.sh` | Uses a fake `gh` binary to verify release-manager dry-run safety, ready-PR filtering, apply command shape, no premature `release:merged` label without merge evidence, deploy workflow polling, live lock behavior, JSONL metrics (written on apply, never on dry-run), fail-closed conflict recovery (DIRTY PR not redispatched when Linear is unavailable), and `--reconcile-deploys` candidate selection. |
| `test_release_status.sh` | Verifies the read-only `bin/release-status` snapshot: per-label PR counts and oldest-age, time-to-main p50/p90 from the metrics JSONL, graceful degradation with no metrics, and that it makes no mutating `gh` call. |
| `test_routing_feedback.sh` | Verifies the read-only `bin/routing-feedback` analyzer: per-model/characteristic aggregation from `meta.env`, duration handling (incl. unparseable timestamps), the `schema_version != 2` advisory-only gate, attribution coverage, and that it never writes the profile or makes a network call. |
| `test_release_manager_doctor.sh` | Verifies `bin/release-manager-doctor` with a fake `gh`: the Merge Queue check (PASS when a `merge_queue` ruleset rule is present, WARN when absent, WARN-not-fail when the rulesets API errors), owner-type / merge-queue-availability detection, the auto-merge (`Allow auto-merge`) check, the strict "require up-to-date" rebase-storm warning, `release:*` label existence, the `CLAUDE_RUNS_ROOT` not-yet-created regression guard, and the Section-2 validation of the new `RELEASE_MANAGER_*` env vars. |
| `test_launcher_recovery.sh` | Drives the reference launcher's `--dry-run` render: rebase-recovery mode emits the rebase block (force-with-lease) with no leftover `{{…}}`, fresh mode omits it, free-text `--conflict-detail`/`--pr-url` with a newline or single quote is rejected, and a pre-existing sentinel is left untouched by dry-run. Also covers the `--no-linear` GitHub-only render: `--task-file` and `--github-issue` task sources, GitHub-native closeout (PR + `release:ready`), and fail-closed task-source validation. |
| `test_goal_manager.sh` | Uses a fake `curl` (Linear GraphQL) to verify the goal layer: `status` derives counts + the `terminal` flag from a base64 goal-state block, dry-run makes no mutation, `add-tasks` dedups (case/space-insensitive) and enforces the `budget_tasks` cap + `--max-per-wave`, planner passes are recorded and tickets closed (`goal:planned`/`goal:nowork`), `next-planner` mints or halts on the budget / no-new-work / pending-planner guards, `tick` mints when idle and waits when a planner is pending, unreadable Linear reads fail closed (no mutation), the live goal lock blocks a second writer, `--loop` exits promptly on SIGTERM, and the GraphQL-unused-variable lint. |

## Run

```bash
bash tests/test_tmux_sentinel_malformed.sh
bash tests/test_mcp_runpod_optin.sh
bash tests/test_env_isolation.sh
bash tests/test_release_manager.sh
bash tests/test_release_status.sh
bash tests/test_routing_feedback.sh
bash tests/test_release_manager_doctor.sh
bash tests/test_launcher_recovery.sh
bash tests/test_goal_manager.sh
```

Each test prints `PASS`/`FAIL` lines, then a summary. Non-zero exit = at least one assertion failed.

## What these tests do NOT cover

Tests that depend on real Linear writes, real GitHub PR mutation, the full dispatcher, or a live `claude` CLI are not part of this repo. They live in the operator's adapted launcher implementation. These tests are deliberately scoped to the patterns the reference assets demonstrate — sentinel JSON validation, MCP opt-in, environment isolation, and release-manager command semantics — so any adopter can verify their copy of the skill assets is intact.

If you adapt the reference launcher and want fuller coverage, you'll typically want additional tests on top of these: an end-to-end test that drives a real `claude` invocation against a sandbox issue, a TOCTOU race test over the dispatch lock acquire/pid-write window, and a target-spec test that grep-guards the `bin/` and `tests/` trees for bare `tmux -t name` references (the exact-match `=name:` convention is documented in `docs/architecture.md`). Those depend on your local launcher shape and are intentionally not bundled.
