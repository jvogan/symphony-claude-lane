# tests/

Three fully-isolated regression tests for the v0.8.2 hardening that landed in v3.0.0.

These tests do **not** create real Linear tickets or invoke the Claude CLI. They are pure-bash predicate checks that exercise the safety guards introduced in the tmux backend port. They are safe to run on any host with `bash`, `jq`, and a sourced `env.sh`.

## Tests

| Test | What it verifies |
|---|---|
| `test_tmux_sentinel_malformed.sh` | The `jq -e 'type == "object"'` predicate the reference launcher uses to validate the sentinel JSON file. Also greps the reference launcher to confirm the guard and the `sentinel_malformed` exit_reason are still wired in. |
| `test_mcp_runpod_optin.sh` | The 9 branches of `env.sh`'s `CLAUDE_WORKER_ENABLE_RUNPOD` toggle: which MCP config gets selected, which secrets join the worker env allowlist, and how re-sourcing after the toggle preserves operator overrides. |
| `test_env_isolation.sh` | Replicates the reference launcher's `env -i $allowlist=value …` build loop and verifies that allowlisted vars (e.g. `LINEAR_API_KEY`) survive the execve boundary while unlisted secrets (`SECRET_UNLISTED`, default-mode `RUNPOD_API_KEY`) do NOT. Guards against the broken-by-design `tmux new-session -e VAR=value` pattern silently regressing in. |

## Run

```bash
bash tests/test_tmux_sentinel_malformed.sh
bash tests/test_mcp_runpod_optin.sh
bash tests/test_env_isolation.sh
```

Each test prints `PASS`/`FAIL` lines, then a summary. Non-zero exit = at least one assertion failed.

## What these tests do NOT cover

Tests that depend on real Linear writes, the full dispatcher, or a live `claude` CLI are not part of this repo. They live in the operator's adapted launcher implementation. The two tests here are deliberately scoped to the patterns the reference assets demonstrate — sentinel JSON validation and the MCP opt-in surface — so any adopter can verify their copy of the skill assets is intact.

If you adapt the reference launcher and want fuller coverage, you'll typically want additional tests on top of these: an end-to-end test that drives a real `claude` invocation against a sandbox issue, a TOCTOU race test over the dispatch lock acquire/pid-write window, and a target-spec test that grep-guards the `bin/` and `tests/` trees for bare `tmux -t name` references (the exact-match `=name:` convention is documented in `docs/architecture.md`). Those depend on your local launcher shape and are intentionally not bundled.
