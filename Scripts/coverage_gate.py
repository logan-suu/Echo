#!/usr/bin/env python3
# ==========================================
# 文件: Scripts/coverage_gate.py
# 对应规格: AGENTS.md §9.3 (CI 门禁清单)
# 用途: Compute Echo.app line coverage excluding SwiftUI Views
#       and Fixture Loaders. Views are declarative layout code tested
#       via Live Simulator Review, not unit tests.
# 排除规则 (2026-08-03 refactor/ui-feature-dirs): UI 层改为功能域目录
#       (Echo/UI/{AppShell,Home,Search,Detail,...}), 不再有 Echo/UI/Views/。
#       按文件名后缀排除: *View.swift (声明式视图) + *FixtureLoader.swift
#       (确定性测试/Preview 数据注入器) — 与旧目录前缀行为等价。
# 用法: python3 Scripts/coverage_gate.py <xcresult_path> [threshold]
# 生成时间: 2026-08-02
# ==========================================

import json
import sys
import os

DEFAULT_THRESHOLD = 65


def is_excluded(path: str) -> bool:
    """True if the file is declarative SwiftUI view or a fixture loader.

    Previously excluded the whole Echo/UI/Views/ directory; after the
    feature-directory refactor the same file classes are matched by suffix.
    """
    base = os.path.basename(path)
    return base.endswith("View.swift") or base.endswith("FixtureLoader.swift")


def compute_coverage(xcresult_path: str, exclude_fn) -> tuple[float, int, int, int]:
    """Returns (coverage_pct, total_exec_lines, covered_lines, excluded_file_count)."""
    import subprocess

    result = subprocess.run(
        [
            "xcrun", "xccov", "view", "--report", "--json",
            xcresult_path,
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(f"::error::xccov failed: {result.stderr}", file=sys.stderr)
        sys.exit(1)

    data = json.loads(result.stdout)
    target = next(
        (x for x in data.get("targets", []) if x.get("name") == "Echo.app"), None
    )
    if target is None:
        print("::error::Echo.app target not found in coverage report", file=sys.stderr)
        sys.exit(1)

    total_exec = 0
    total_cov = 0
    excluded_count = 0
    included_count = 0

    for f in target.get("files", []):
        path = f.get("path", "")
        if exclude_fn(path):
            excluded_count += 1
            continue
        included_count += 1
        total_exec += f.get("executableLines", 0)
        total_cov += f.get("coveredLines", 0)

    if total_exec == 0:
        pct = 0.0
    else:
        pct = total_cov / total_exec * 100.0

    print(
        f"Files included: {included_count}, excluded: {excluded_count}, "
        f"executable lines: {total_exec}, covered: {total_cov}",
        file=sys.stderr,
    )
    return pct, total_exec, total_cov, excluded_count


def get_full_target_coverage(xcresult_path: str) -> float:
    """Returns the full Echo.app target lineCoverage (including Views)."""
    import subprocess

    result = subprocess.run(
        ["xcrun", "xccov", "view", "--report", "--json", xcresult_path],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return 0.0
    data = json.loads(result.stdout)
    target = next(
        (x for x in data.get("targets", []) if x.get("name") == "Echo.app"), None
    )
    if target is None:
        return 0.0
    return target.get("lineCoverage", 0.0) * 100.0


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <xcresult_path> [threshold]", file=sys.stderr)
        sys.exit(1)

    xcresult_path = sys.argv[1]
    threshold = int(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_THRESHOLD

    if not os.path.isdir(xcresult_path):
        print(f"::error::{xcresult_path} not found", file=sys.stderr)
        sys.exit(1)

    coverage_pct, total_exec, total_cov, excluded = compute_coverage(
        xcresult_path, is_excluded
    )
    coverage_int = int(coverage_pct)

    full_cov = get_full_target_coverage(xcresult_path)
    full_cov_int = int(full_cov)

    print(f"Echo.app coverage (excl. Views): {coverage_int}%")
    print(f"Echo.app coverage (full target): {full_cov_int}%")

    if coverage_int < threshold:
        print(
            f"::error::Echo.app coverage (excl. Views) {coverage_int}% "
            f"below threshold {threshold}%"
        )
        sys.exit(1)

    print(f"✅ Echo.app coverage (excl. Views) {coverage_int}% ≥ {threshold}%")


if __name__ == "__main__":
    main()
