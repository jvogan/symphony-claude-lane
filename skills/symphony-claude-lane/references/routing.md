# Routing

Use this reference to decide what belongs in the Claude lane and how to persist those decisions.

## Default lane stance

Start with **UI-first + extensible**.

Default Claude ownership:

- UI implementation where visual judgment matters
- UX polish and interaction refinement
- browser-verified frontend work
- product copy, onboarding text, and marketing-style writing
- skeptical review of worker output

Default Codex ownership:

- pure implementation
- refactors
- test infrastructure
- CI or release plumbing
- types, schemas, migrations, and config-heavy work

## Questions to ask the adopter

Before broadening the lane, ask:

1. Should Claude stay UI-focused, or also own docs, review, research, or E2E work?
2. Which labels should always route to Claude?
3. Which labels should never route to Claude?
4. Should visual verification be mandatory for all UI tickets, or only a subset?
5. Is operator review required before `Done`, or can some Claude tickets self-close?

Do not guess these when the repo has no prior guidance. Persist the answers.

If the user does not answer, use this fallback:

- keep Claude UI-first
- leave optional Claude-owned areas empty
- keep `ask_on_ambiguous_tickets: true`
- default closeout to `in-review`
- note the assumption in the repo-local guidance so future operators can revisit it

## Persisting the answers

Create or update a repo-local routing profile, typically:

```text
.orchestration/claude-lane.yaml
```

Use `assets/claude-lane-profile.example.yaml` as the source template.

The profile should become the durable contract for:

- default lane mode
- Claude focus areas
- optional Claude-owned areas
- labels that always or never route to Claude
- visual verification expectations
- preferred models
- closeout behavior
- whether ambiguous tickets should trigger a user question

## Recommended first version

- Keep Claude narrow at first
- Add extra responsibilities only when the repo shows repeated success
- Expand by work category, not by vague confidence

Good expansions:

- docs
- review
- release notes
- E2E verification

Bad expansions:

- "whatever feels hard"
- "anything creative"
- "all product work"
