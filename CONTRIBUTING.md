# Contributing

Thanks for improving Symphony + Claude Lane.

## What Fits

Good contributions usually improve one of these areas:

- safer Claude worker launch patterns
- clearer Linear routing and closeout guidance
- better tests for tmux, environment isolation, sentinel handling, or MCP selection
- documentation that helps adopters configure their own repos
- examples for long-horizon multi-agent orchestration

Keep shared guidance portable. Repo-specific paths, private queue names, local tokens, and company-specific process should live in the adopter repo, not in this skill.

## Development

Run the same checks as CI:

```bash
bash -n \
  env.sh \
  bin/claude-doctor \
  bin/claude-version \
  bin/claude-tmux-finalize \
  bin/release-manager \
  bin/release-manager-doctor \
  bin/release-status \
  bin/routing-feedback \
  tests/test_mcp_runpod_optin.sh \
  tests/test_tmux_sentinel_malformed.sh \
  tests/test_env_isolation.sh \
  tests/test_release_manager.sh \
  tests/test_release_status.sh \
  tests/test_routing_feedback.sh \
  tests/test_release_manager_doctor.sh \
  tests/test_launcher_recovery.sh \
  skills/symphony-claude-lane/assets/claude-worker.reference.sh

find . -path './.git' -prune -o \( -name '*.json' -o -name 'marketplace.json' \) -type f -print \
  | sort \
  | xargs -n1 jq empty

bash tests/test_tmux_sentinel_malformed.sh
bash tests/test_mcp_runpod_optin.sh
bash tests/test_env_isolation.sh
bash tests/test_release_manager.sh
bash tests/test_release_status.sh
bash tests/test_routing_feedback.sh
bash tests/test_release_manager_doctor.sh
bash tests/test_launcher_recovery.sh
```

## Security Hygiene

Never commit real API keys, Linear issue payloads, customer data, screenshots with sensitive content, private repo names, or local absolute paths. Runtime artifacts under `workspaces/`, `runs/`, and `logs/` are ignored for this reason.

## Pull Requests

Small, focused PRs are easiest to review. Include:

- what changed
- why it matters
- which checks you ran
- any remaining risks or environment assumptions
