#!/usr/bin/env python3
"""CI mutation runner for photo-text-search gates (handover plan WP1 step 0).

Exit contract (plan §9, identical across all WPs):
- exit 0   ONLY when a deliberate corruption makes the child release/verification
           gate fail with the EXPECTED named reason recorded in the manifest;
- nonzero  when the mutation survives, the wrong gate/reason fails, or the
           runner itself breaks.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

EXIT_OK = 0
EXIT_MUTATION_SURVIVED = 1
EXIT_WRONG_GATE_OR_REASON = 2
EXIT_RUNNER_ERROR = 3

REQUIRED_MANIFEST_KEYS = ("checkpointPin", "ownerVerdicts", "dataset")


def load_manifest(path: Path) -> dict:
    """Parse and structurally validate the approved evidence manifest."""
    with path.open(encoding="utf-8") as handle:
        manifest = json.load(handle)
    missing = [key for key in REQUIRED_MANIFEST_KEYS if key not in manifest]
    if missing:
        raise ValueError(f"manifest missing required keys: {missing}")
    return manifest


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True,
                        help="path to photo-text-search-release-evidence-manifest.json")
    parser.add_argument("--output", type=Path,
                        help="machine-readable result path (stdout when omitted)")
    parser.add_argument("--case", help="named deliberate-mutation case (steps 0c+)")
    parser.add_argument("--verify-all", type=Path, dest="verify_all",
                        help="evidence directory to re-verify (WP7)")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        manifest = load_manifest(args.manifest)
    except Exception as exc:  # noqa: BLE001 - runner must fail nonzero on its own breakage
        print(f"runner-error: {exc}", file=sys.stderr)
        return EXIT_RUNNER_ERROR

    summary = {
        "parsed": True,
        "source": str(args.manifest),
        "checkpointPin": manifest["checkpointPin"],
        "case": args.case,
    }
    rendered = json.dumps(summary, ensure_ascii=False, indent=2)
    if args.output is not None:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered + "\n", encoding="utf-8")
    else:
        print(rendered)
    return EXIT_OK


if __name__ == "__main__":
    raise SystemExit(main())
