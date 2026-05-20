# Security Policy

## Supported Versions

Security and correctness fixes target the latest public release candidate or release. The tmux backend is the maintained default for v3 and later.

## Reporting a Vulnerability

Please report security issues privately through GitHub's security advisory flow when available, or by opening a minimal issue that does not include exploit details, secrets, customer data, or private infrastructure names.

Useful reports include:

- affected file or workflow
- expected versus observed behavior
- whether the issue can expose credentials, Linear payloads, local paths, or worker artifacts
- a minimal reproduction that uses fake credentials and synthetic issue data

## Security Model

This repository is a portable blueprint and reference implementation. Operators are responsible for adapting it to their environment and preserving the safety properties:

- explicit routing before launching a full-access worker
- isolated git worktrees per issue
- allowlisted worker environment via `env -i`
- RunPod tools and credentials jointly opt-in
- prompt-injection boundary around Linear issue bodies
- machine-readable worker outcomes
- closeout verification against Linear
- cleanup that preserves artifacts when integration or tracker state is uncertain

Do not treat the reference launcher as a substitute for your own operational review.
