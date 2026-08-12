#!/usr/bin/env python3
"""UIAutomation contract gate for task 3F.10 (US-DIS-004, §4.6.10).

Scope: this gate owns the `degradation-banner` surface (per phase3f-execution-plan
§3F.10 Files — UIAutomation Modify/Create lists). Strict contract resolution is
enforced for gated surfaces; all other instances only need to parse as JSON.

Checks (gated surfaces):
  1. The surface contract carries a version marker (contractVersion or version).
  2. Every surface-declared state resolves to exactly ONE state contract
     file (<surface>-state-<stateId>.json).
  3. Every declared action resolves to exactly ONE action contract file
     (<surface>-action-<shortId>.json, shortId = actionId suffix after '.').
  4. Gated journeys reference only declared states and existing action files.
  5. The surface declares accessibility expectations (an `accessibility`
     block, or state expectedSemantics carrying accessibility entries).

Exit code 0 = all gates pass; 1 = violations found.
"""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INSTANCES = ROOT / "UIAutomation" / "Contracts" / "instances"

# Surfaces whose contracts this task owns and must fully resolve.
GATED_SURFACES = {"degradation-banner"}


def load(path):
    with path.open(encoding="utf-8") as fh:
        return json.load(fh)


def action_short_id(action_id):
    return action_id.split(".", 1)[1] if "." in action_id else action_id


def state_ids(data):
    result = set()
    for state in data.get("states", []):
        if isinstance(state, dict) and state.get("stateId"):
            result.add(state["stateId"])
        elif isinstance(state, str):
            result.add(state)
    return result


def main():
    errors = []
    files = sorted(INSTANCES.glob("*.json"))
    if not files:
        print("FAIL: no contract instances found")
        return 1

    surfaces = {}
    journeys = []
    for path in files:
        try:
            data = load(path)
        except (json.JSONDecodeError, OSError) as exc:
            errors.append(f"{path.name}: invalid JSON ({exc})")
            continue
        if not isinstance(data, dict):
            errors.append(f"{path.name}: contract root must be an object")
            continue
        name = path.name
        surface = data.get("surfaceId")
        if surface in GATED_SURFACES or name.endswith("-surface.json"):
            if surface is None:
                surface = name[: -len("-surface.json")]
            if surface in GATED_SURFACES:
                surfaces[surface] = (path, data)
        elif "-journey-" in name and data.get("surfaceId") in GATED_SURFACES:
            journeys.append((path, data))

    for surface, (path, data) in surfaces.items():
        if not data.get("contractVersion") and not data.get("version"):
            errors.append(f"{path.name}: missing contractVersion/version")
        states = state_ids(data)
        for state_id in sorted(states):
            if not (INSTANCES / f"{surface}-state-{state_id}.json").exists():
                errors.append(f"{surface}: state '{state_id}' has no state contract file")
        for action in data.get("actions", []) or []:
            if not isinstance(action, dict):
                continue
            action_id = action.get("actionId")
            if not action_id:
                continue
            if not (INSTANCES / f"{surface}-action-{action_short_id(action_id)}.json").exists():
                errors.append(f"{surface}: action '{action_id}' has no action contract file")
        has_accessibility = bool(data.get("accessibility"))
        if not has_accessibility:
            for state_id in states:
                state_path = INSTANCES / f"{surface}-state-{state_id}.json"
                if state_path.exists():
                    semantics = json.dumps(load(state_path).get("expectedSemantics", {}))
                    if "accessibility" in semantics:
                        has_accessibility = True
                        break
        if not has_accessibility:
            errors.append(f"{path.name}: no accessibility expectations declared")

    for path, data in journeys:
        default_surface = data.get("surfaceId") or path.name.split("-journey-")[0]
        for step in data.get("steps", []):
            if not isinstance(step, dict):
                continue
            step_surface = step.get("surfaceId", default_surface)
            state_id = step.get("stateId")
            action_id = step.get("actionId")
            if state_id and state_id not in state_ids(surfaces.get(step_surface, (None, {}))[1]):
                errors.append(f"{path.name}: step references undeclared state '{state_id}' on '{step_surface}'")
            if action_id:
                action_file = INSTANCES / f"{step_surface}-action-{action_short_id(action_id)}.json"
                if not action_file.exists():
                    errors.append(f"{path.name}: step references missing action contract '{action_id}'")

    if errors:
        print(f"FAIL: {len(errors)} contract violation(s)")
        for err in errors[:50]:
            print(f"  - {err}")
        return 1
    print(f"OK: {len(files)} contracts valid, {len(surfaces)} gated surface(s) resolve deterministically")
    return 0


if __name__ == "__main__":
    sys.exit(main())
