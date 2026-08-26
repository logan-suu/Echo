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


# ---------------------------------------------------------------------------
# WP1 steps 0c-0j: four-state exit contract
# ---------------------------------------------------------------------------


def _import_runner():
    import importlib.util

    spec = importlib.util.spec_from_file_location("photo_search_ci_mutation", RUNNER)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def test_mutation_runner_returns_zero_only_for_expected_named_gate_failure() -> None:
    """WP1 步骤 0c：预期具名 child-gate failure -> runner exit 0。"""
    mod = _import_runner()
    verdict = mod.decide_exit(
        child_returncode=2,
        child_output="gate failed: required artifact missing-e5 absent",
        expected_reason="missing-e5",
    )
    assert verdict == mod.EXIT_OK


def test_mutation_runner_returns_nonzero_when_mutation_survives() -> None:
    """WP1 步骤 0e：mutation 存活（child gate 意外通过）-> 非零退出。"""
    mod = _import_runner()
    verdict = mod.decide_exit(
        child_returncode=0,
        child_output="gate passed unexpectedly",
        expected_reason="missing-e5",
    )
    assert verdict == mod.EXIT_MUTATION_SURVIVED
    assert verdict != 0


def test_mutation_runner_returns_nonzero_for_wrong_failure_reason() -> None:
    """WP1 步骤 0g：child gate 失败但原因不符 -> 非零退出。"""
    mod = _import_runner()
    verdict = mod.decide_exit(
        child_returncode=3,
        child_output="gate failed for some unrelated syntax error",
        expected_reason="missing-e5",
    )
    assert verdict == mod.EXIT_WRONG_GATE_OR_REASON
    assert verdict != 0


def test_mutation_runner_returns_nonzero_when_runner_breaks(tmp_path: Path) -> None:
    """WP1 步骤 0i：runner 自身异常（如 manifest 路径不存在）-> 非零退出。"""
    mod = _import_runner()
    code = mod.main(["--manifest", str(tmp_path / "does-not-exist.json")])
    assert code == mod.EXIT_RUNNER_ERROR
    assert code != 0
