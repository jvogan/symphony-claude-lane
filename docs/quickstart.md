# Quickstart

This guide gets the public skill installed and verified. It does not create a production queue by itself; the reference launcher is meant to be adapted to your operator environment.

## 1. Clone and verify

```bash
git clone https://github.com/jvogan/symphony-claude-lane.git
cd symphony-claude-lane
export LINEAR_API_KEY="<linear-api-key>"
source ./env.sh
bin/claude-doctor
```

`claude-doctor` checks shell defaults, dependencies, MCP config, Linear connectivity, the required routing label, and runtime directory writability. If you are only reviewing the repo without Linear access, the local tests still run without `LINEAR_API_KEY`.

## 2. Install the skill

```bash
npx skills add jvogan/symphony-claude-lane
```

Or install manually:

```bash
mkdir -p "${CODEX_HOME:-$HOME/.codex}/skills"
cp -R skills/symphony-claude-lane "${CODEX_HOME:-$HOME/.codex}/skills/"
```

Restart your agent so the skill is discoverable.

## 3. Prepare Linear

Create a workspace-scoped label:

```text
lane:claude
```

Optional model labels:

```text
model:opus
model:sonnet
model:haiku
```

See `docs/linear-setup.md` for routing guards, model selection, and Linear auth conventions.

## 4. Ask your agent to configure the target repo

```text
Use $symphony-claude-lane to set up long-horizon multi-agent routing for this
Symphony + Linear repo. Use tmux-backed Claude workers by default, preserve
Codex/Symphony for bounded parallel work, and document closeout and cleanup.
```

The skill should produce or update:

- `.orchestration/claude-lane.yaml`
- repo orchestration docs such as `AGENTS.md`
- a launcher adapted from `skills/symphony-claude-lane/assets/claude-worker.reference.sh`
- worker prompt and closeout guidance
- cleanup and retention policy for worktrees and run artifacts

## 5. Choose a backend deliberately

The recommended default is tmux-backed interactive Claude Code:

- attachable via `tmux attach`
- subscription-billed
- matches attended Claude Code behavior
- uses JSON sentinel closeout

If your team wants API-priced, headless execution, adapt the launcher to `claude -p` using `docs/backend-options.md`. Keep the same routing, prompt safety, outcome, closeout, and cleanup contracts.

## 6. Dry-run before dispatch

Before launching a real worker, run your adapted launcher in dry-run mode. A good dry-run should:

- fetch the Linear issue
- verify routing guards
- render the prompt to a temporary file
- confirm the `<issue_body>` trust boundary exists
- print the planned worktree, branch, model, closeout state, and tmux session
- create no worktree, run directory, prompt artifact, or tmux session

Only dispatch real workers after the dry-run is side-effect free and understandable.
