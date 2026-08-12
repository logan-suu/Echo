#!/usr/bin/env python3
"""Localization gate for task 3F.10 (US-DIS-001/003, AGENTS.md §1.3).

Checks:
  1. Echo/Resources/Localizable.xcstrings parses and declares sourceLanguage en-US.
  2. Only zh-Hans and en-US localizations exist (AGENTS.md §1.3).
  3. 100% key parity: every key carries non-empty zh-Hans AND en-US values.
  4. No user-visible hardcoded English strings in SwiftUI View files: every
     Text/Label/Button/navigationTitle/Section literal must resolve to a
     catalog key (interpolations are normalized to printf specifiers).

Exit code 0 = all gates pass; 1 = violations found.
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Echo" / "Resources" / "Localizable.xcstrings"
UI_DIR = ROOT / "Echo" / "UI"

LITERAL_CALL = re.compile(
    r'(?<!accessibility)(?:Text|Label|Button|Toggle|navigationTitle|Section|Tab|alert|confirmationDialog)'
    r'\(\s*"((?:[^"\\]|\\.)*)"'
)
PROMPT_CALL = re.compile(r'prompt:\s*Text\("((?:[^"\\]|\\.)*)"')
INTERPOLATION = re.compile(r'\\\(([^)]*)\)')

ALLOWED_SUFFIXES = ("View.swift",)


def load_catalog():
    with CATALOG.open(encoding="utf-8") as fh:
        return json.load(fh)


def check_catalog(catalog):
    errors = []
    if catalog.get("sourceLanguage") != "en-US":
        errors.append("sourceLanguage must be en-US")
    strings = catalog.get("strings", {})
    if not strings:
        errors.append("catalog strings table is empty")
    for key, entry in strings.items():
        localizations = (entry or {}).get("localizations", {})
        for locale in localizations:
            if locale not in ("zh-Hans", "en-US"):
                errors.append(f"unsupported locale '{locale}' on key '{key}' (AGENTS.md §1.3)")
        for locale in ("zh-Hans", "en-US"):
            unit = (localizations.get(locale) or {}).get("stringUnit") or {}
            if not unit.get("value"):
                errors.append(f"missing/empty {locale} value for key '{key}'")
    return errors


def normalize_key(literal):
    """Convert a SwiftUI string literal with interpolations to its catalog key form."""
    def repl(match):
        expr = match.group(1).strip()
        if expr.startswith("Int(") or expr.endswith(".count"):
            return "%lld"
        return "%@"
    return INTERPOLATION.sub(repl, literal)


def is_dynamic_only(literal):
    """True when the literal is purely dynamic (no static words to localize)."""
    stripped = INTERPOLATION.sub("", literal)
    return not any(ch.isalpha() for ch in stripped)


def scan_views(catalog_keys):
    errors = []
    for swift in sorted(UI_DIR.rglob("*.swift")):
        if not swift.name.endswith(ALLOWED_SUFFIXES):
            continue
        text = swift.read_text(encoding="utf-8")
        for pattern in (LITERAL_CALL, PROMPT_CALL):
            for match in pattern.finditer(text):
                literal = match.group(1)
                if not literal.strip():
                    continue
                if is_dynamic_only(literal):
                    continue
                key = normalize_key(literal)
                if key not in catalog_keys:
                    line = text.count("\n", 0, match.start()) + 1
                    errors.append(f"{swift.relative_to(ROOT)}:{line}: hardcoded string not in catalog: {key!r}")
    return errors


def main():
    errors = []
    if not CATALOG.exists():
        print(f"FAIL: {CATALOG} missing")
        return 1
    catalog = load_catalog()
    errors += check_catalog(catalog)
    errors += scan_views(set(catalog.get("strings", {}).keys()))
    if errors:
        print(f"FAIL: {len(errors)} localization violation(s)")
        for err in errors[:50]:
            print(f"  - {err}")
        return 1
    print(f"OK: catalog parity 100% ({len(catalog.get('strings', {}))} keys), no hardcoded view strings")
    return 0


if __name__ == "__main__":
    sys.exit(main())
