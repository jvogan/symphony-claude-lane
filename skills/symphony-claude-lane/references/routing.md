# Routing

Use this reference to decide how tasks get routed between Claude and Codex, and how to persist those decisions.

## Routing strategy

The routing profile supports two strategies:

- **task-characteristic** (recommended): The orchestrator analyzes each issue and picks the best model based on what the task requires. Labels serve as overrides.
- **label-only**: Routing is determined entirely by Linear labels. Simpler but less adaptive.

Both strategies use the same routing profile format. The difference is whether the orchestrator actively analyzes tasks or passively reads labels.

## When to prefer Claude

Route to Claude when the task has characteristics that benefit from Claude's strengths:

- **Requires browser verification** — the task changes rendered output and needs visual confirmation via Playwright
- **Requires visual judgment** — layout, spacing, color, typography, interaction design decisions
- **Requires deep reasoning** — architecture decisions, complex multi-file refactors where intent matters, subtle debugging
- **Requires external tools** — MCP servers, APIs, network access, database queries, anything that breaks in a sandbox
- **Involves security review** — reviewing code for vulnerabilities, auditing auth flows, analyzing trust boundaries
- **Involves documentation** — API docs, architecture docs, onboarding guides, technical writing where quality matters
- **Involves code review** — skeptical diff review, issue shaping, quality assessment of worker output
- **Breaks in Codex sandbox** — E2E tests, integration tests, tasks needing system access
- **Involves product copy** — user-facing text where tone, clarity, and branding matter

## When to prefer Codex

Route to Codex when the task is a good fit for fast, bounded, sandboxed execution:

- **Bounded implementation** — a well-scoped code change with clear acceptance criteria
- **Sandbox-compatible** — no network, database, or browser access needed
- **Parallelizable** — several similar-shaped tasks that benefit from running 3+ workers at once
- **Config and schema changes** — types, migrations, CI config, package updates
- **Test infrastructure** — unit tests, test fixtures, mocking infrastructure
- **Refactors** — mechanical restructuring where the transformation is well-defined

## When either works

Some tasks could go either way. In these cases:

- If the routing profile has a label override, follow it
- If the task is bounded and sandbox-compatible, prefer Codex (faster)
- If the task has any ambiguity about scope or requires judgment calls, prefer Claude
- If `ask_on_ambiguous_tickets` is true, ask the operator

## Questions to ask the adopter

Before configuring routing, ask:

1. Should the orchestrator analyze task characteristics automatically, or use label-only routing?
2. What types of work appear most often in this repo's backlog? (UI, backend, infra, docs, etc.)
3. Is this a mixed-model setup (Claude + Codex) or Claude-only?
4. Which labels should always route to Claude regardless of analysis?
5. Which labels should never route to Claude?
6. Should visual verification be mandatory for all frontend tickets, or only a subset?
7. Is operator review required before `Done`, or can some tickets self-close?
8. Should the routing stay in the same Linear project with label filters, or use a separate project?
9. Should Claude workers use the default tmux backend, headless `claude -p`, or a hybrid split?

Do not guess these when the repo has no prior guidance. Persist the answers.

If the user does not answer, use this fallback:

- use task-characteristic routing
- prefer Claude for browser-verified, visual, complex reasoning, review, and documentation work
- prefer Codex for bounded implementation, config, tests, and refactors
- keep `ask_on_ambiguous_tickets: true`
- default closeout to `in-review`
- default Claude backend to tmux
- note the assumptions in the repo-local guidance so future operators can revisit them

## Persisting the answers

Create or update a repo-local routing profile, typically:

```text
.orchestration/claude-lane.yaml
```

Use `assets/claude-lane-profile.example.yaml` as the source template.

The profile should become the durable contract for:

- routing strategy (task-characteristic or label-only)
- model selection criteria (prefer_claude_when, prefer_codex_when)
- label overrides (always_route, never_route)
- backend selection (tmux, `claude -p`, or hybrid)
- visual verification expectations
- preferred models
- inherited base guardrails
- privacy and redaction rules
- closeout behavior
- cleanup and retention policy
- whether ambiguous tickets should trigger a user question

## Expanding over time

Start with the default routing and tighten or expand based on evidence:

- Track which model produces better output for which task types
- Move task categories between models based on results, not assumptions
- Expand Claude's scope when the routing proves stable
- Narrow Codex's scope if sandbox limitations cause repeated failures

Good expansions for Claude:

- complex refactors (when intent matters more than speed)
- release notes and changelogs
- E2E and integration tests (sandbox-incompatible)
- cross-cutting architectural work

Bad expansions for either model:

- "whatever feels hard" (not a task characteristic)
- "anything creative" (too vague to route on)
- "all product work" (too broad, loses routing signal)
