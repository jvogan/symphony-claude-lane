# Examples

Use these examples to understand how task characteristics drive routing decisions.

## Route to Claude: UI redesign with browser verification

**Summary:** Redesign the onboarding modal so the hero, feature list, and primary action feel clearer and more premium.

**Why Claude:** Visual judgment, hierarchy decisions, browser verification needed. Not sandbox-compatible.

**Task characteristics:** requires_browser_verification, requires_visual_judgment

**Acceptance criteria:**

- onboarding modal hierarchy is clearer on desktop and mobile
- primary and secondary actions remain obvious in both themes
- browser verification covers desktop and mobile
- validation commands pass

## Route to Claude: security review of auth flow

**Summary:** Review the new OAuth2 implementation for token handling vulnerabilities, scope escalation risks, and session management issues.

**Why Claude:** Deep reasoning about trust boundaries, security-sensitive analysis, needs to read and reason across multiple files.

**Task characteristics:** involves_security_review, requires_deep_reasoning

## Route to Claude: complex debugging

**Summary:** Users report intermittent 500s on the checkout endpoint. Stack traces point to a race condition in the payment reconciliation service. Reproduce, diagnose, and fix.

**Why Claude:** Subtle bug requiring deep reasoning across multiple services. Needs external tool access (database queries, API calls) to reproduce. Not bounded enough for sandbox execution.

**Task characteristics:** requires_deep_reasoning, requires_external_tools

## Route to Claude: documentation architecture

**Summary:** Restructure the API reference docs to match the new module layout. Add migration guides for the v2 → v3 breaking changes.

**Why Claude:** Technical writing quality matters. Needs to understand the full API surface and make judgment calls about organization.

**Task characteristics:** involves_documentation, requires_deep_reasoning

## Route to Claude: E2E test suite

**Summary:** Add Playwright E2E tests for the new dashboard. Cover login, data loading, chart interactions, and export flow.

**Why Claude:** E2E tests require browser automation and network access. Breaks in Codex sandbox.

**Task characteristics:** breaks_in_sandbox, requires_browser_verification, requires_external_tools

## Route to Codex: bounded implementation

**Summary:** Add a `lastModified` timestamp field to the User model, migration, and all CRUD endpoints.

**Why Codex:** Well-scoped, mechanical, sandbox-compatible. Clear acceptance criteria. Fast parallel execution if batched with similar tasks.

**Task characteristics:** bounded_implementation, sandbox_compatible, config_or_schema_changes

## Route to Codex: test infrastructure

**Summary:** Add unit tests for the validation utilities. Target 90% branch coverage. Mock external dependencies.

**Why Codex:** Test writing is bounded, sandbox-compatible, and benefits from fast parallel execution.

**Task characteristics:** test_infrastructure, bounded_implementation, sandbox_compatible

## Route to Codex: refactor bundle

**Summary:** Extract the shared form validation logic into a `validation/` module. Update all 12 consumers. Remove the deprecated helpers.

**Why Codex:** Mechanical restructuring with a well-defined transformation. No judgment calls about design.

**Task characteristics:** mechanical_refactor, bounded_implementation, parallelizable_batch

## Ambiguous: could go either way

**Summary:** Refactor the notification system to support email, SMS, and push channels with a unified provider interface.

**Analysis:** This is a refactor (Codex-leaning) but requires architectural judgment about the interface design (Claude-leaning). If the interface shape is already decided in the ticket, route to Codex. If the worker needs to design the interface, route to Claude.

**Resolution:** If `ask_on_ambiguous_tickets` is true, ask the operator. Otherwise, prefer Claude (the safer choice when judgment is required).

## Example routing questions to ask the adopter

- Should the orchestrator analyze task characteristics automatically, or use label-only routing?
- What types of work appear most often in this repo? (helps calibrate the default routing)
- Is this a mixed-model setup or Claude-only?
- Which labels should always route to Claude? To Codex?
- Should all frontend tickets require Playwright verification?
- Do you want tickets to stop in `In Review`, or can some self-close to `Done`?

## Example fallback when the user does not answer

If the user is unavailable or does not want to decide yet:

- use task-characteristic routing with the default `prefer_claude_when` and `prefer_codex_when` lists
- keep `ask_on_ambiguous_tickets: true`
- require `In Review` before `Done`
- write those assumptions into `.orchestration/claude-lane.yaml` and the repo guidance so they are easy to revise later
