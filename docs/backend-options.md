# Backend Options

The skill is a routing and worker-lifecycle blueprint. The bundled reference launcher uses tmux-backed interactive Claude Code because that is the recommended default for long-horizon work, but adopters can intentionally adapt the launch backend.

## Option A: tmux-backed interactive Claude Code

Use this when you want:

- subscription-billed Claude Code sessions
- attachable live workers (`tmux attach -t =cw-<issue>`)
- behavior that matches an attended Claude Code session
- human observability during long-running work
- JSON sentinel closeout through `bin/claude-tmux-finalize`

Trade-offs:

- no subprocess exit code
- requires tmux
- needs dialog handling for first-launch trust and bypass prompts
- workers must write a sentinel before teardown

This is the maintained default in `skills/symphony-claude-lane/assets/claude-worker.reference.sh`.

## Option B: `claude -p` headless subprocess

Use this when you intentionally prefer:

- API-priced / Agent SDK-style billing
- non-interactive subprocess execution
- stdout / JSONL capture instead of live tmux attach
- simpler process supervision by PID and exit code

Trade-offs:

- no live TUI to attach to
- billing and throttling differ from subscription-backed interactive use
- resume and closeout semantics differ
- prompt and output can be easier to mishandle if user issue bodies enter argv or logs

If you adapt the reference launcher back to `claude -p`, preserve these contracts:

- route fail-closed before launching a full-access worker
- create one isolated git worktree per issue
- build the worker environment with `env -i`
- pass issue bodies through stdin or files, never shell arguments
- keep the `<issue_body>` trust boundary
- write `meta.env` atomically
- record model, branch, closeout state, status, and validation summary
- parse `output.jsonl` defensively and treat missing or malformed result events as failures
- post a machine-readable `symphony-outcome` comment
- verify Linear closeout state before cleanup
- preserve artifacts when tracker state or integration state is uncertain

## Option C: hybrid

Some teams may use tmux for long-horizon design, debugging, visual verification, and review work, while using `claude -p` for short headless tasks where API pricing and subprocess supervision are preferred.

If you run a hybrid, make the backend part of the routing profile:

```yaml
backend_selection:
  default: tmux
  use_claude_p_when:
    - headless_batch_task
    - no_browser_or_tui_needed
    - api_pricing_preferred
  use_tmux_when:
    - long_horizon_task
    - visual_verification
    - operator_may_need_to_attach
    - complex_debugging
```

Expose the backend in run metadata:

```sh
backend='tmux'      # or claude-p
```

Status, cleanup, and closeout tooling must branch on that field instead of guessing from process shape.
