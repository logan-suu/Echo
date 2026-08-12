#!/usr/bin/env python3
"""Static ban gate for task 3F.10 (AGENTS.md R-001/R-005/R-007, §11.4).

Scans Echo/ production sources for prohibited constructs:
  - import Combine                      (R-007)
  - @unchecked Sendable                 (R-007)
  - nonisolated(unsafe)                 (R-007)
  - Task.detached                       (§11.4)
  - print( / NSLog(                     (§11.4 — unified logging only)
  - URLSession dataTask / NSURLSession  (R-001/R-005 — no network)

Test targets are excluded (test fakes may use patterns production forbids).
Exit code 0 = clean; 1 = violations found.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Echo"

BANS = [
    (re.compile(r"^\s*import\s+Combine\b", re.MULTILINE), "import Combine (R-007)"),
    (re.compile(r"@unchecked\s+Sendable"), "@unchecked Sendable (R-007)"),
    (re.compile(r"nonisolated\(unsafe\)"), "nonisolated(unsafe) (R-007)"),
    (re.compile(r"Task\.detached"), "Task.detached (§11.4)"),
    (re.compile(r"\bNSLog\s*\("), "NSLog (§11.4)"),
    (re.compile(r"URLSession\.shared\.dataTask|NSURLSession"), "network data task (R-001/R-005)"),
]

PRINT = re.compile(r"(?<![.\w])print\s*\(")


def strip_comments_and_strings(text):
    """Remove Swift line/block comments and string literals so ban patterns only
    match executable code (header comments reference the banned constructs)."""
    out = []
    i = 0
    n = len(text)
    while i < n:
        two = text[i:i + 2]
        if two == "//":
            j = text.find("\n", i)
            i = n if j < 0 else j + 1
            out.append("\n")
            continue
        if two == "/*":
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2
            out.append(" ")
            continue
        if text[i] == '"':
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == '"':
                    j += 1
                    break
                j += 1
            out.append(" ")
            i = j
            continue
        out.append(text[i])
        i += 1
    return "".join(out)


def main():
    violations = []
    for swift in sorted(SOURCE.rglob("*.swift")):
        raw = swift.read_text(encoding="utf-8")
        text = strip_comments_and_strings(raw)
        for pattern, label in BANS:
            for match in pattern.finditer(text):
                line = raw.count("\n", 0, match.start()) + 1
                violations.append(f"{swift.relative_to(ROOT)}:{line}: {label}")
        for match in PRINT.finditer(text):
            line = raw.count("\n", 0, match.start()) + 1
            violations.append(f"{swift.relative_to(ROOT)}:{line}: print() (§11.4)")

    if violations:
        print(f"FAIL: {len(violations)} static ban violation(s)")
        for violation in violations[:50]:
            print(f"  - {violation}")
        return 1
    print("OK: no banned constructs in Echo/ production sources")
    return 0


if __name__ == "__main__":
    sys.exit(main())
