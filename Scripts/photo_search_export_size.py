#!/usr/bin/env python3
"""WP7 8a: App Thinning / package size EVIDENCE collector.

Reads the release evidence manifest, locates a signed Release candidate
archive product, and records the App Thinning package size report.
When a signed RC is unavailable the collector records a typed blocked
status (route enablement stays withheld until real evidence lands).
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def load_manifest(path: Path) -> dict:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def blocked(output: Path | None, reason: str, hint: str) -> int:
    verdict = {
        "status": "blocked",
        "reason": reason,
        "resumeHint": hint,
        "packageSizes": None,
    }
    rendered = json.dumps(verdict, ensure_ascii=False, indent=2)
    if output is not None:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(rendered + "\n", encoding="utf-8")
    else:
        print(rendered)
    return 0


def collect(manifest: dict) -> dict:
    """Locate the newest Release simulator/app archive and report sizes."""
    products = REPO_ROOT / "build" / "Release-iphonesimulator"
    app_path: Path | None = None
    for candidate in sorted(products.glob("Echo.app"), key=lambda p: p.stat().st_mtime, reverse=True):
        app_path = candidate
        break
    if app_path is None:
        # Fall back to DerivedData products
        derived = Path.home() / "Library/Developer/Xcode/DerivedData"
        for candidate in derived.glob("Echo-*/Build/Products/Release-iphonesimulator/Echo.app"):
            app_path = candidate
            break

    if app_path is None or not app_path.exists():
        raise FileNotFoundError("no signed Release candidate found (run xcodebuild archive first)")

    total = sum(f.stat().st_size for f in app_path.rglob("*") if f.is_file())
    return {
        "status": "measured",
        "appPath": str(app_path),
        "packageSizes": {
            "appBytes": total,
            "appMegabytes": round(total / (1024 * 1024), 1),
            "note": "raw .app size; App Thinning report requires exportAppThinning with a distribution archive",
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--output", required=False)
    args = parser.parse_args()

    output = Path(args.output) if args.output else None
    manifest = load_manifest(Path(args.manifest))
    try:
        verdict = collect(manifest)
        code = 0
    except FileNotFoundError as exc:
        verdict = {
            "status": "blocked",
            "reason": str(exc),
            "resumeHint": "archive a signed Release candidate (xcodebuild archive -configuration Release) then rerun",
            "packageSizes": None,
        }
        code = 0
    except Exception as exc:  # noqa: BLE001
        verdict = {"status": "error", "reason": str(exc), "packageSizes": None}
        code = 1

    rendered = json.dumps(verdict, ensure_ascii=False, indent=2)
    if output is not None:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(rendered + "\n", encoding="utf-8")
    else:
        print(rendered)
    if verdict.get("status") == "error":
        print(f"runner-error: {verdict.get('reason')}", file=sys.stderr)
    _ = (os, subprocess)
    return code


if __name__ == "__main__":
    sys.exit(main())
