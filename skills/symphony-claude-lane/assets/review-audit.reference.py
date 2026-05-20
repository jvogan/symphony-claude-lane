#!/usr/bin/env python3
"""Reference parser for Claude-lane outcome comments.

This parser is intentionally small and network-free. Adopters can wire it into
their own Linear/GitHub fetch layer, then use the classification result to decide
whether a ticket is eligible for operator review or auto-promotion.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

CURRENT_OUTCOME_RE = re.compile(
    r"<!--\s*symphony-outcome\b(?P<body>.*?)-->",
    re.IGNORECASE | re.DOTALL,
)
CURRENT_STATUS_RE = re.compile(
    r"(?:^|\n)\s*status\s*:\s*(success|failed|blocked)\b",
    re.IGNORECASE,
)
LEGACY_PASS_RE = re.compile(
    r"<!--\s*symphony:outcome\b[^>]*?\bverdict\s*=\s*(pass|verified|ok)\b",
    re.IGNORECASE | re.DOTALL,
)
TEXT_FAIL_RE = re.compile(
    r"(?:^|\n)\s*(?:verdict|outcome|status)\s*[:=]\s*(fail|failed|blocked|reject)\b",
    re.IGNORECASE,
)


def classify_outcome(text: str) -> dict[str, str | None]:
    """Classify a comment body as pass, fail, or unknown."""
    current_blocks = list(CURRENT_OUTCOME_RE.finditer(text))
    current_success = None
    for block in reversed(current_blocks):
        body = block.group("body")
        status_match = CURRENT_STATUS_RE.search(body)
        if not status_match:
            continue
        status = status_match.group(1).lower()
        if status == "success":
            current_success = block
            continue
        return evidence("fail", "current", block.group(0))

    if current_success is not None:
        return evidence("pass", "current", current_success.group(0))

    fail_match = TEXT_FAIL_RE.search(text)
    if fail_match:
        return evidence("fail", "text", fail_match.group(0))

    legacy_match = LEGACY_PASS_RE.search(text)
    if legacy_match:
        return evidence("pass", "legacy", legacy_match.group(0))

    return {"classification": "unknown", "format": None, "evidence": None}


def evidence(classification: str, fmt: str, snippet: str) -> dict[str, str]:
    compact = " ".join(snippet.split())
    if len(compact) > 200:
        compact = compact[:197] + "..."
    return {"classification": classification, "format": fmt, "evidence": compact}


def self_test() -> None:
    cases = [
        ("<!-- symphony-outcome\nstatus: success\n-->", "pass"),
        ("<!-- symphony-outcome\nstatus: failed\n-->", "fail"),
        ("<!-- symphony-outcome\nstatus: blocked\n-->", "fail"),
        ("<!-- symphony-outcome\nstatus: success\n-->\n<!-- symphony-outcome\nstatus: failed\n-->", "fail"),
        ("<!-- symphony:outcome verdict=pass -->", "pass"),
        ("outcome: failed", "fail"),
        ("ordinary comment", "unknown"),
    ]
    for text, expected in cases:
        result = classify_outcome(text)
        actual = result["classification"]
        if actual != expected:
            raise AssertionError(f"expected {expected}, got {actual}: {text!r}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*", help="Comment text files. Reads stdin when omitted.")
    parser.add_argument("--self-test", action="store_true", help="Run parser self-tests.")
    args = parser.parse_args(argv)

    if args.self_test:
        self_test()
        return 0

    if not args.paths:
        print(json.dumps(classify_outcome(sys.stdin.read()), indent=2, sort_keys=True))
        return 0

    results = []
    for raw_path in args.paths:
        path = Path(raw_path)
        results.append({"path": raw_path, **classify_outcome(path.read_text())})
    print(json.dumps(results, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
