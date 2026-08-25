#!/usr/bin/env python3
"""CI mutation runner for photo-text-search gates (handover plan WP1).

Exit contract (plan §9, identical across all WPs):
- exit 0   ONLY when a deliberate corruption makes the child release/verification
           gate fail with the EXPECTED named reason recorded in the manifest;
- nonzero  when the mutation survives, the wrong gate/reason fails, or the
           runner itself breaks.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

EXIT_OK = 0
EXIT_MUTATION_SURVIVED = 1
EXIT_WRONG_GATE_OR_REASON = 2
EXIT_RUNNER_ERROR = 3

REQUIRED_MANIFEST_KEYS = (
    "checkpointPin",
    "ownerVerdicts",
    "dataset",
    "requiredArtifacts",
)

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
CHILD_CMD = ["bash", "Scripts/prepare_models.sh", "--verify-only"]

# Deliberate-mutation cases (WP1 steps 7a-8a). Corruption targets are resolved
# against manifest.requiredArtifacts so scripts never hardcode artifact paths.
CASE_SPECS: dict[str, dict] = {
    "missing-e5": {"hide": ["e5Dir"], "expected_reason": "missing-e5"},
    "missing-vision": {"hide": ["visionCkptDir"], "expected_reason": "missing-vision"},
    "preparation-failure": {"corrupt_checksums": True, "expect_no_named_reason": True},
}


def load_manifest(path: Path) -> dict:
    """Parse and structurally validate the approved evidence manifest."""
    with path.open(encoding="utf-8") as handle:
        manifest = json.load(handle)
    missing = [key for key in REQUIRED_MANIFEST_KEYS if key not in manifest]
    if missing:
        raise ValueError(f"manifest missing required keys: {missing}")
    return manifest


def decide_exit(child_returncode: int, child_output: str, expected_reason: str) -> int:
    """Map a single child-gate run onto the runner exit contract."""
    if child_returncode == 0:
        return EXIT_MUTATION_SURVIVED
    if expected_reason in child_output:
        return EXIT_OK
    return EXIT_WRONG_GATE_OR_REASON


def evaluate_case(child_rc: int, output: str, spec: dict) -> int:
    """Case-level evaluation; supports generic-failure expectations."""
    if spec.get("expect_no_named_reason"):
        detected = child_rc != 0 and "gate-reason:" not in output
        return EXIT_OK if detected else EXIT_WRONG_GATE_OR_REASON
    return decide_exit(child_rc, output, spec["expected_reason"])


def execute_case(name: str, artifacts: dict, output_path: Path | None) -> int:
    """Apply one deliberate corruption, run the child gate, judge, restore."""
    spec = CASE_SPECS.get(name)
    if spec is None:
        print(f"runner-error: unknown case '{name}'", file=sys.stderr)
        return EXIT_RUNNER_ERROR

    moved: list[tuple[Path, Path]] = []
    corrupted: tuple[Path, str] | None = None
    child_rc = -1
    combined = ""
    try:
        for key in spec.get("hide", []):
            target = REPO_ROOT / artifacts[key]
            if target.exists():
                hidden = target.with_name(target.name + ".mutation-hidden")
                os.rename(target, hidden)
                moved.append((target, hidden))
        if spec.get("corrupt_checksums"):
            cs_path = REPO_ROOT / artifacts["checksumsFile"]
            original = cs_path.read_text(encoding="utf-8")
            mutated = None
            for line in original.splitlines(keepends=True):
                stripped = line.strip()
                if stripped and not stripped.startswith("#"):
                    parts = stripped.split()
                    if len(parts) == 2:
                        digest = parts[0]
                        flipped = ("0" if digest[0] != "0" else "1") + digest[1:]
                        mutated = original.replace(digest, flipped, 1)
                        break
            if mutated is None:
                raise ValueError("no checksum entry available to corrupt")
            corrupted = (cs_path, original)
            cs_path.write_text(mutated, encoding="utf-8")

        proc = subprocess.run(
            CHILD_CMD, cwd=str(REPO_ROOT), capture_output=True, text=True, check=False
        )
        child_rc = proc.returncode
        combined = proc.stdout + proc.stderr
    except Exception as exc:  # noqa: BLE001 - runner failures must exit nonzero
        print(f"runner-error: {exc}", file=sys.stderr)
        return EXIT_RUNNER_ERROR
    finally:
        for src, hidden in reversed(moved):
            os.rename(hidden, src)
        if corrupted is not None:
            corrupted[0].write_text(corrupted[1], encoding="utf-8")

    code = evaluate_case(child_rc, combined, spec)
    tail = [ln for ln in combined.strip().splitlines()
            if "gate-reason" in ln or "[ERROR]" in ln][-6:]
    verdict = {
        "case": name,
        "childExitCode": child_rc,
        "mutationDetected": code == EXIT_OK,
        "expectedReason": spec.get("expected_reason"),
        "outputTail": tail,
    }
    rendered = json.dumps(verdict, ensure_ascii=False, indent=2)
    if output_path is not None:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(rendered + "\n", encoding="utf-8")
    else:
        print(rendered)
    return code


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True,
                        help="path to photo-text-search-release-evidence-manifest.json")
    parser.add_argument("--output", type=Path,
                        help="machine-readable result path (stdout when omitted)")
    parser.add_argument("--case", help="named deliberate-mutation case")
    parser.add_argument("--verify-all", type=Path, dest="verify_all",
                        help="evidence directory to re-verify (WP7)")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        manifest = load_manifest(args.manifest)
    except Exception as exc:  # noqa: BLE001 - runner failures must exit nonzero
        print(f"runner-error: {exc}", file=sys.stderr)
        return EXIT_RUNNER_ERROR

    if args.case is not None:
        return execute_case(args.case, manifest["requiredArtifacts"], args.output)

    summary = {
        "parsed": True,
        "source": str(args.manifest),
        "checkpointPin": manifest["checkpointPin"],
        "case": None,
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
