Use a machine-readable outcome block in the final issue comment so the mixed lane can be monitored consistently.

## Success

```text
<!-- symphony-outcome
outcome_version: 1
lane: claude
branch: claude/example-ticket
status: success
files_touched: src/ui/OnboardingModal.tsx, src/styles/theme.css
tests_added: 0
validation_summary: npm test and npm run build passed; desktop and mobile Playwright checks completed
suggested_action: none
-->
```

## Failure

```text
<!-- symphony-outcome
outcome_version: 1
lane: claude
branch: claude/example-ticket
status: failed
reason: exhausted_turn_budget
progress_pct: 70
remaining: closeout copy is finished; mobile layout still needs verification and one dark-theme regression remains
files_touched: src/ui/OnboardingModal.tsx, src/styles/theme.css
tests_added: 0
validation_summary: unit tests passed; browser verification incomplete
suggested_action: split_ticket
-->
```
