# Tmux Backend — Lessons Learned

Bug-by-bug postmortems from the build of the tmux-backed Claude worker lane. These are the kinds of footguns you'll hit if you adapt the reference launcher to your environment.

## During build

### 1. Workspace-scoped Linear labels are invisible to `team.labels.nodes`

**Symptom:** Test exited with curl rc=56 trying to create the `lane:claude` label, even though `lane:claude` already existed.

**Root cause:** In our Linear workspace, `lane:claude` is workspace-scoped (`team: null`). Querying `teams.nodes[].labels.nodes` only returns team-scoped labels. The workspace label was invisible.

**Fix:** When looking up an existing label, try both scopes:

```graphql
query($n: String!) {
  issueLabels(filter: {name: {eq: $n}}, first: 5) {
    nodes { id name team { id key } }
  }
}
```

Fall back to team-scoped creation only if not found at either scope.

**Generalizable:** Any tooling that creates Linear issues with labels should accept workspace-scoped labels too.

### 2. `set -e` + `local` outside a function = silent script death

**Symptom:** Test ran 7 assertions then went silent and exited 1 (no summary printed). Cleanup trap fired correctly so no residue, but no diagnostic.

**Root cause:** Extension to `claude-status` introduced `local _session_alive=false` inside a `for` loop. The `local` keyword is only valid inside functions. Bash with `set -e` treats this as a fatal error and terminates immediately. No stderr because we redirected `2>/dev/null` on the calling `status_json=...` line.

**Fix:** Use plain variables. Underscore-prefix avoids collision with the loop's iteration vars.

**Generalizable lessons:**
- When extending an existing script, grep for `local` to see where the script's function boundaries are before adding it elsewhere.
- Don't redirect stderr to `/dev/null` on the very call you're trying to capture — it hides the actual failure mode.
- A trap-based cleanup should ideally log "early exit triggered by trap" so silent `set -e` deaths surface in the test output.

### 3. `tmux send-keys` is unreliable for long prompts; `load-buffer`/`paste-buffer` is the right primitive

Validated mechanically. A 7KB rendered prompt pasted cleanly via `load-buffer`/`paste-buffer`; the same prompt via raw `send-keys` would race the TUI input handler at the front and drop characters.

### 4. `tmux ls` exits 1 when no sessions exist

This bit the test harness on the "no leftover sessions" assertion in an early iteration. Wrapping with `2>/dev/null` or `|| true` is essential when checking for absence.

### 5. Linear auto-transition Backlog→In Progress matters operationally

Without it, dispatched tickets sit in Backlog with no visible signal that work has started. The dispatcher adds this transition at the start of dispatch (the smoke test verified the transition fires for `type=backlog` and `type=unstarted` states).

## During the v0.6.1 iteration (model + reconcile + env allowlist)

### 6. `declare -A foo=([BARE_KEY]=...)` evaluates the subscript arithmetically under `set -u`

**Symptom:** Dispatcher died at the env-prefix build with `CLAUDE_TMUX_SENTINEL_PATH: unbound variable`. Confusing because the variable IS a literal key in the associative-array literal, not a reference.

**Root cause:** When bash parses `[CLAUDE_TMUX_SENTINEL_PATH]=...` inside a `declare -A` literal, it treats the unquoted subscript as a (degenerate) arithmetic expression. With `set -u`, bare names that aren't defined as numeric vars error out as unbound. The fix is either `["CLAUDE_TMUX_SENTINEL_PATH"]=...` (quote the key) or sidestep the array entirely.

**Fix used:** Ditched the associative array. Built the env prefix from a flat for-loop over `"NAME=value"` strings:

```bash
for extra in "CLAUDE_TMUX_SENTINEL_PATH=$sentinel_path" ...; do
  extra_name="${extra%%=*}"
  extra_value="${extra#*=}"
  ...
done
```

**Generalizable:** When `set -u` is on, associative-array subscripts are a sharp edge. Quote keys or avoid the literal-init form.

### 7. Linear `IssueLabelPayload.label` → `issueLabel` (API name change)

**Symptom:** Complex test's label-creation mutation errored with "Cannot query field 'label' on type 'IssueLabelPayload'."

**Root cause:** Linear renamed the field at some point. The payload now exposes `issueLabel`, not `label`. The earlier success/scenarios tests didn't hit this because the `lane:claude` label already existed at workspace scope, so the create path never ran.

**Fix:** Use `issueLabel{ id name }` in the mutation result selector.

**Generalizable:** Any GraphQL mutation that returns a payload should be defensive about field renames — Linear ships schema changes regularly. Adding an introspection probe to a smoke test is overkill but worth considering if you depend on many mutations.

## During the real-claude smoke

### 8. `--permission-mode bypassPermissions` does NOT skip the trust dialog OR the bypass-mode warning

**Symptom:** First real-haiku dispatch (issue `XXX-NNN`) timed out at 300s. Transcript showed claude sitting on TWO interactive modal dialogs:
1. "Is this a project you created or one you trust?" (workspace trust)
2. "Bypass Permissions mode warning… By proceeding, you accept all responsibility…"

**Root cause:** `--permission-mode bypassPermissions` only suppresses per-tool permission prompts. It does NOT suppress:

- The workspace trust dialog (per `claude --help`: "skipped when Claude is run in non-interactive mode (via -p, or when stdout is not a TTY)" — interactive mode always asks)
- The bypass-mode confirmation dialog itself

Result: real claude blocked forever waiting for keyboard input that wasn't coming.

**Fix (two-pronged):**

a. **Swap the flag**: `--permission-mode bypassPermissions` → `--dangerously-skip-permissions` in the dispatcher's launch command. The legacy aggressive flag suppresses the trust dialog and most pre-prompt dialogs.

b. **Belt-and-suspenders dialog navigation**: even with the legacy flag, the bypass-mode warning still appeared empirically on Claude Code 2.1.143. Added `dismiss_first_launch_dialogs` to the dispatcher: after TUI bootstrap, capture-pane and check for known dialog text, send the right keystrokes, then proceed with the prompt paste.

**Generalizable:** When driving interactive Claude Code from outside, ANY pre-prompt modal will block forever (no human to respond). Defense pattern:

- Use the most aggressive permission flag available
- After bootstrap, ALWAYS capture-pane and inspect for known dialogs before sending the actual work prompt
- Add new dialog-text patterns to the helper as future Claude Code releases introduce them

## During real-claude × 2 parallel smoke

### 9. `poller_pid` in meta.env is intentionally cleared by the monitor's final write

**Symptom:** Wrote a parallel-smoke validation that asserted `poller_pid` was non-empty in meta.env after a `--background` run. Assertion failed for both runs.

**Root cause:** Not a bug. The parent dispatcher records `poller_pid` in meta.env when it forks the monitor subshell. The monitor then runs to completion and writes a FRESH atomic meta.env at the very end with `poller_pid=''` — because the monitor itself is about to exit. Recording a dead PID would be misleading.

**Correct durable witness** that `--background` mode actually ran is `monitor.log` — that's where the detached subshell's stdout/stderr go. If it exists and is non-empty, the monitor lifecycle worked.

**Generalizable:** Don't assert on a transient PID field after the holder process exits. Look for filesystem evidence the process actually did its work.

### 10. Trust dialog appears non-deterministically per worktree

**Symptom:** In the parallel smoke, dispatcher A's trust-dialog helper fired ("trust dialog visible — sending Enter to accept default (option 1)"). Dispatcher B's didn't. Both worktrees were brand-new directories.

**Hypothesis:** Either (a) claude has a brief race window where the dialog renders after the helper's capture-pane window closes, or (b) `--dangerously-skip-permissions` skips the trust dialog most of the time but not always (perhaps depending on prior session state).

**Why it didn't break B:** The trust default is "1. Yes, I trust this folder". If the dialog DID appear and the helper didn't catch it, the actual prompt-paste sends text + Enter — and Enter would dismiss the trust dialog with the default acceptance. The text would then go to the actual claude prompt. Lucky outcome.

**Mitigation if this becomes flaky:** Add a longer wait + a second capture-pane pass to the helper. Or send a single Enter unconditionally as a "dismiss any potential dialog default" before the prompt-paste — risky if it interferes with normal prompts, but for first-launch-only would be safe.

## To watch for in production

### A. `--dangerously-skip-permissions` flag stability

Claude Code's permission flag has changed names across releases. Lock-in the flag name when validating against real claude. If it changes, both the dispatcher launch line and `settings/claude-settings.tmux.json` need updating in lockstep.

### B. TUI bootstrap timing

8s default for `TUI_BOOTSTRAP_SLEEP` in the reference launcher is generous on most systems but may be too aggressive on slow ones or first launches. The dispatcher logs a WARNING if no pane content appeared in that window but proceeds anyway. If real claude drops the first characters of the prompt, bump this env var.

### C. Stale sentinel from killed-9 dispatcher

A SIGKILL of the dispatcher mid-run leaves the tmux session AND any partial work AND any sentinel the worker may have written. Pre-dispatch guard refuses to start a new session over the corpse:

```
die "Stale sentinel exists at $sentinel_path — refusing to dispatch."
```

Operator should manually move the worktree aside, delete the sentinel, and re-dispatch.

### D. Concurrent same-issue dispatch

`tmux new-session -d -s cw-<issue>` will fail if a session by that name already exists. The dispatcher's pre-check turns this into an explicit error with remediation hints instead of a confusing tmux error.

### E. Rate limit shared with interactive use

Once tmux workers and your interactive Claude Code session both bill against the same subscription bucket, parallel workers can crowd out interactive work. Watch the daily/weekly limits — Anthropic's UI reports usage but there's no programmatic limit query.

### F. Linear `issue` query by identifier vs by team+number

The dispatcher uses `issues(filter:{team:{key:{eq:$tk}},number:{eq:$n}})` which is the most portable. Linear also accepts `issue(id: "TEAM-123")` directly (coerces identifier strings). If we ever consolidate, the team/number split lets us avoid string parsing on the API side.
