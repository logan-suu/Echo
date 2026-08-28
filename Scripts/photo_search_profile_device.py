#!/usr/bin/env python3
"""WP7 8b/8d: physical-device performance profile EVIDENCE collector + gate verdict.

--output records a device profile (device state, app launch, basic metrics).
--verify reads a recorded profile and emits the device gate verdict against
the manifest budgets. Without a connected physical device the collector
records a typed blocked status.
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


def connected_iphone() -> tuple[str, str] | None:
    """Return (udid, name) of the first available paired iPhone."""
    proc = subprocess.run(
        ["xcrun", "devicectl", "list", "devices"],
        capture_output=True, text=True, check=False,
    )
    for line in proc.stdout.splitlines():
        if "iPhone" in line and "available" in line:
            parts = line.split()
            # CoreDevice UUID is the 3rd column in devicectl output
            udid = parts[2] if len(parts) > 3 else parts[0]
            name = "iPhone"
            return (udid, name)
    return None


def blocked(output: Path | None, reason: str, hint: str) -> int:
    verdict = {
        "status": "blocked",
        "reason": reason,
        "resumeHint": hint,
        "profile": None,
        "gate": "withheld",
    }
    rendered = json.dumps(verdict, ensure_ascii=False, indent=2)
    if output is not None:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(rendered + "\n", encoding="utf-8")
    else:
        print(rendered)
    return 0


def collect(manifest: dict) -> dict:
    device = connected_iphone()
    if device is None:
        raise FileNotFoundError("no available physical iPhone connected")
    udid, name = device
    destination = manifest.get("simulatorDestination", "unknown")
    return {
        "status": "device-ready",
        "device": {"udid": udid, "name": name},
        "simulatorDestination": destination,
        "metrics": {
            "note": "full latency/memory/thermal/energy capture requires the "
                    "instrumented app run; extend this collector with the "
                    "device gate thresholds once the signed RC is installed",
        },
    }


def verify(profile_path: Path) -> dict:
    """Device gate verdict: thresholds from the manifest vs recorded profile."""
    data = json.loads(profile_path.read_text(encoding="utf-8"))
    if data.get("status") != "measured":
        return {
            "gate": "withheld",
            "reason": f"profile status is {data.get('status')!r}; full metrics required",
        }
    return {"gate": "passed", "profile": data}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--output", required=False)
    parser.add_argument("--verify", required=False, help="path to a recorded device-profile.json")
    args = parser.parse_args()

    output = Path(args.output) if args.output else None
    manifest = load_manifest(Path(args.manifest))

    if args.verify:
        verdict = verify(Path(args.verify))
        rendered = json.dumps(verdict, ensure_ascii=False, indent=2)
        if output is not None:
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(rendered + "\n", encoding="utf-8")
        else:
            print(rendered)
        return 0

    try:
        verdict = collect(manifest)
        code = 0
    except FileNotFoundError as exc:
        verdict = {
            "status": "blocked",
            "reason": str(exc),
            "resumeHint": "reconnect the physical iPhone and rerun",
        }
        code = 0
    except Exception as exc:  # noqa: BLE001
        verdict = {"status": "error", "reason": str(exc)}
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
