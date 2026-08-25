"""Parity contract tests for Scripts/convert_siglip2.py (handover plan WP2 steps 1a-1f).

Defect being fixed (plan §5): Echo's image-tower pooling deviated from the pinned
upstream SiglipMultiheadAttentionPoolingHead semantics in two ways:
  1. extra probe residual:  h = LN(A + probe); out = A + probe + MLP(h)
     official:              h = LN(A);        out = A + MLP(h)
  2. exact GELU instead of the checkpoint's tanh approximation.

Deep numeric parity against the pinned revision is proven separately by
Scripts/verify_siglip2_parity.py (step 4); these tests pin the structural
contract of the converter source itself.
"""

from __future__ import annotations

from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
CONVERTER = REPO_ROOT / "Scripts" / "convert_siglip2.py"


def _converter_source() -> str:
    return CONVERTER.read_text(encoding="utf-8")


def test_probe_residual_differs_from_pinned_upstream() -> None:
    """WP2 步骤 1a/1b：额外 probe residual 行必须从图像 pooling 中移除。

    修复前源码含 `probe_out = probe_out + probe`（与 pinned upstream 不一致的
    缺陷本体）；断言其不存在即为本测试的终态契约。
    """
    src = _converter_source()
    assert "probe_out = probe_out + probe" not in src


def test_gelu_approximation_matches_pinned_config() -> None:
    """WP2 步骤 1c/1d：pooling MLP 必须使用 checkpoint 的 tanh 近似 GELU。"""
    src = _converter_source()
    assert 'approximate="tanh"' in src
    # 旧精确 GELU 直接调用必须从 pooling 路径消失
    assert "F.gelu(self.head_mlp_fc1(probe_out))" not in src


def test_image_pooling_uses_official_chain() -> None:
    """WP2 步骤 1e/1f：输出链必须是官方语义 h = LN(A); out = A + MLP(h)。"""
    import re

    src = _converter_source()
    official = re.search(
        r"h = self\.head_ln\(probe_out\)\s*\n"
        r"\s*mlp_out = self\.head_mlp_fc2\(\s*"
        r'F\.gelu\(self\.head_mlp_fc1\(h\), approximate="tanh"\)',
        src,
    )
    assert official is not None, "official chain LN->MLP(tanh) ordering not found"
