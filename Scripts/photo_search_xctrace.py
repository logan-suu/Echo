#!/usr/bin/env python3
"""WP7 8c: xctrace deep-attribution EVIDENCE collector.

Wraps the xctrace CLI to record a Time Profiler trace of the instrumented
app on a physical device and persists a trace index JSON. Prior empirical
evidence (xctrace-meta.json) documents five CLI failure modes on this
workstation — the collector records a typed blocked status when the CLI
channel is unavailable so evidence gathering can resume with Instruments GUI.
"""
from __future__ import annotations

import argparse
import json
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
        "traceIndex": None,
    }
    rendered = json.dumps(verdict, ensure_ascii=False, indent=2)
    if output is not None:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(rendered + "\n", encoding="utf-8")
    else:
        print(rendered)
    return 0


def collect(manifest: dict, output_dir: Path) -> dict:
    dest = manifest.get("simulatorDestination", "")
    device_name = "Logan\u2019s phone"
    trace_path = output_dir / "device-time-profiler.trace"
    proc = subprocess.run(
        [
            "xcrun", "xctrace", "record",
            "--template", "Time Profiler",
            "--device", device_name,
            "--all-processes",
            "--time-limit", "12s",
            "--output", str(trace_path),
        ],
        capture_output=True, text=True, check=False,
    )
    index = {
        "template": "Time Profiler",
        "device": device_name,
        "simulatorDestination": dest,
        "tracePath": str(trace_path),
        "exitCode": proc.returncode,
        "durationSeconds": 12,
    }
    if proc.returncode != 0:
        return {
            "status": "cli-unavailable",
            "reason": "xctrace CLI recording failed (see xctrace-meta.json for the five documented failure modes); use Instruments GUI",
            "traceIndex": index,
        }
    return {"status": "recorded", "traceIndex": index}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--output", required=False)
    args = parser.parse_args()

    output = Path(args.output) if args.output else None
    manifest = load_manifest(Path(args.manifest))
    output_dir = output.parent if output is not None else REPO_ROOT / ".omo/evidence/photo-text-search/wp7"

    try:
        verdict = collect(manifest, output_dir)
        code = 0
    except Exception as exc:  # noqa: BLE001
        verdict = {
            "status": "error",
            "reason": str(exc),
            "resumeHint": "use Instruments GUI manually (see xctrace-meta.json)",
        }
        code = 1

    rendered = json.dumps(verdict, ensure_ascii=False, indent=2)
    if output is not None:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(rendered + "\n", encoding="utf-8")
    else:
        print(rendered)
    if verdict.get("status") == "error":
        print(f"runner-error: {verdict.get('reason')}", file=sys.stderr)
    return code


if __name__ == "__main__":
    sys.exit(main())
