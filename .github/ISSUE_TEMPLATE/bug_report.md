---
name: Bug report
about: Report a problem with the skill, docs, tests, or reference launcher
title: "[bug] "
labels: bug
assignees: ""
---

## What happened?

Describe the behavior and what you expected instead.

## Where?

- File or doc:
- Command or workflow:
- Backend: tmux / `claude -p` adaptation / other

## Reproduction

Use fake credentials and synthetic issue data. Do not paste real Linear payloads, API keys, screenshots with sensitive content, or private repo names.

```bash
# minimal command sequence
```

## Environment

- OS:
- Shell:
- Claude Code version:
- tmux version:
- jq version:

## Checks run

- [ ] `bash tests/test_tmux_sentinel_malformed.sh`
- [ ] `bash tests/test_mcp_runpod_optin.sh`
- [ ] `bash tests/test_env_isolation.sh`
- [ ] Other:
