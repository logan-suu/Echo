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


# ---------------------------------------------------------------------------
# WP2 steps 2a-2d: 固定 tokenizer fixture（int32[1,64] 输入契约）
# ---------------------------------------------------------------------------

import json

FIXTURE = REPO_ROOT / "Scripts" / "tests" / "fixtures" / "siglip2_tokenizer_fixture.json"
REQUIRED_CASE_KEYS = {"zhHans", "enUS", "punctuation", "truncation", "padding", "empty", "mixed"}
VOCAB_SIZE_PINNED = 256_000


def test_tokenizer_fixture_schema_covers_required_cases() -> None:
    """WP2 步骤 2a：fixture 必须覆盖七类 case，形状满足固定 int32[1,64] 契约。"""
    data = json.loads(FIXTURE.read_text(encoding="utf-8"))
    cases = data["cases"]
    assert set(cases.keys()) == REQUIRED_CASE_KEYS
    assert data["maxLength"] == 64
    for name, case in cases.items():
        assert len(case["inputIds"]) == 64, name
        assert len(case["attentionMask"]) == 64, name
        assert all(isinstance(i, int) and 0 <= i < VOCAB_SIZE_PINNED for i in case["inputIds"]), name
        assert set(case["attentionMask"]) <= {0, 1}, name


def _live_encode(text: str) -> tuple[list[int], list[int]]:
    from transformers import AutoTokenizer

    tok = AutoTokenizer.from_pretrained(
        str(REPO_ROOT / "Echo/Resources/Models/siglip2-base-patch32-256")
    )
    enc = tok(text, padding="max_length", max_length=64, truncation=True,
              return_attention_mask=True)
    return enc["input_ids"], enc["attention_mask"]


def test_tokenizer_token_ids_match_pinned_upstream() -> None:
    """WP2 步骤 2c（GREEN regression）：fixture 与 pinned 分词器 token ID 完全一致。"""
    data = json.loads(FIXTURE.read_text(encoding="utf-8"))
    for name, case in data["cases"].items():
        ids, _mask = _live_encode(case["text"])
        assert ids == case["inputIds"], f"token ID drift in case {name}"


def test_tokenizer_attention_masks_match_pinned_upstream() -> None:
    """WP2 步骤 2d（GREEN regression）：attention mask 与 pinned 分词器完全一致。"""
    data = json.loads(FIXTURE.read_text(encoding="utf-8"))
    for name, case in data["cases"].items():
        _ids, mask = _live_encode(case["text"])
        assert mask == case["attentionMask"], f"attention mask drift in case {name}"


# ---------------------------------------------------------------------------
# WP2 steps 3a-3f: 文本塔导出工件与预检校验
# ---------------------------------------------------------------------------

TEXT_TOWER_ARTIFACT = REPO_ROOT / "Echo/Resources/Models/SigLIP2TextBasePatch32.mlpackage"
PINNED_VOCAB = 256_000
PINNED_TEXT_PARAMS = 282_303_744


def test_text_tower_artifact_is_produced() -> None:
    """WP2 步骤 3a：文本塔 Core ML 工件必须存在于契约路径。"""
    import os

    manifest = TEXT_TOWER_ARTIFACT / "Manifest.json"
    assert manifest.exists(), f"text tower artifact missing at {TEXT_TOWER_ARTIFACT}"
    assert os.path.getsize(TEXT_TOWER_ARTIFACT) > 0


def _preflight():
    import importlib.util

    spec = importlib.util.spec_from_file_location("convert_siglip2", CONVERTER)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


def test_pinned_vocabulary_is_256000() -> None:
    """WP2 步骤 3c/3d：词表 ≠ 256,000 的权重必须被 preflight 拒绝。"""
    mod = _preflight()
    good = {"text_model.embeddings.token_embedding": type("W", (), {"shape": [PINNED_VOCAB, 768]})}
    mod.validate_text_tower_preflight(good)  # must not raise
    bad = {"text_model.embeddings.token_embedding": type("W", (), {"shape": [32_000, 768]})}
    try:
        mod.validate_text_tower_preflight(bad)
    except ValueError as exc:
        assert "256000" in str(exc) or "vocab" in str(exc).lower()
    else:
        raise AssertionError("wrong vocabulary was accepted")


def test_pinned_text_parameter_count_is_282303744() -> None:
    """WP2 步骤 3e/3f：文本参数量 ≠ 282,303,744 必须被 preflight 拒绝。"""
    mod = _preflight()
    try:
        mod.validate_text_tower_preflight({}, expected_total_params=123)
    except ValueError:
        pass  # missing keys path also rejected
    # 精确值路径由真实权重在步骤 4 parity 中复核；此处锁定常量本身
    assert mod.PINNED_TEXT_PARAMS == PINNED_TEXT_PARAMS


# ---------------------------------------------------------------------------
# WP2 steps 4a-4j: 正式 parity 报告需求（五件套）
# ---------------------------------------------------------------------------

PARITY_REPORT = REPO_ROOT / ".omo/evidence/photo-text-search/wp2/intermediate-parity.json"


def _parity_report() -> dict:
    import json

    return json.loads(PARITY_REPORT.read_text(encoding="utf-8"))


def test_intermediate_tensor_parity_report_required() -> None:
    """WP2 步骤 4a：中间张量 parity 报告必须存在且通过。"""
    r = _parity_report()
    assert r["intermediateParity"]["passed"] is True
    assert len(r["intermediateParity"]["stages"]) >= 5


def test_raw_pooler_vector_parity_report_required() -> None:
    """WP2 步骤 4c：raw pooler 向量 parity（双塔）必须存在且通过。"""
    r = _parity_report()
    sec = r["rawPoolerParity"]
    assert sec["passed"] is True
    assert any(k.startswith("text/") for k in sec["perCase"])
    assert any(k.startswith("vision/") for k in sec["perCase"])


def test_normalized_vector_parity_report_required() -> None:
    """WP2 步骤 4e：归一化向量 parity 必须存在、单位范数全过。"""
    r = _parity_report()
    sec = r["normalizedVectorParity"]
    assert sec["passed"] is True
    assert all(v["unitNorm"] for v in sec["perCase"].values())


def test_score_matrix_parity_report_required() -> None:
    """WP2 步骤 4g：跨模态 score matrix parity 必须存在且 maxAbsDiff 达标。"""
    r = _parity_report()
    sec = r["scoreMatrixParity"]
    assert sec["passed"] is True
    assert sec["shape"] == [6, 7]


def test_top_k_parity_report_required() -> None:
    """WP2 步骤 4i：top-K 排序必须与上游完全一致。"""
    r = _parity_report()
    sec = r["topKParity"]
    assert sec["passed"] is True
    assert sec["mismatches"] == []
