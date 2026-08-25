"""Contract tests for Scripts/photo_search_ci_mutation.py (handover plan WP1 step 0).

Exit contract (plan §9, identical across all WPs):
- exit 0   ONLY when deliberate corruption makes the child gate fail with the
           EXPECTED named reason recorded in the release evidence manifest;
- nonzero  when the mutation survives, the wrong gate/reason fails, or the
           runner itself breaks.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
RUNNER = REPO_ROOT / "Scripts" / "photo_search_ci_mutation.py"
MANIFEST = REPO_ROOT / "docs" / "05-planning" / "photo-text-search-release-evidence-manifest.json"

PINNED_REVISION = "94dffa8cb1179de3e03f091dbc3917e5d5a9ae84"


def _run_runner(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(RUNNER), *args],
        capture_output=True,
        check=False,
        text=True,
        cwd=str(REPO_ROOT),
    )


def test_mutation_runner_parses_approved_manifest(tmp_path: Path) -> None:
    """WP1 步骤 0a：runner 能解析 approved manifest 并输出机器可读摘要。"""
    output_path = tmp_path / "parsed-manifest.json"
    result = _run_runner("--manifest", str(MANIFEST), "--output", str(output_path))
    assert result.returncode == 0, result.stderr
    data = json.loads(output_path.read_text())
    assert data["checkpointPin"]["revision"] == PINNED_REVISION
