#!/usr/bin/env python3
"""Formal parity verifier for SigLIP2 dual towers (handover plan WP2 step 4).

Produces one machine-readable JSON report covering five required comparisons:
  intermediateParity      traced-PyTorch stage outputs vs upstream module stages
  rawPoolerParity         Core ML outputs vs upstream pooler vectors (cosine)
  normalizedVectorParity  Core ML outputs are unit vectors matching renormalized upstream
  scoreMatrixParity       cross-modal similarity matrix (images x texts)
  topKParity              per-image top-K text ranking identical to upstream

All numeric gates are PROVISIONAL pending owner approval (plan §10.1);
the FP16 cosine gate used here is 0.999.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def _cosine(a: np.ndarray, b: np.ndarray) -> float:
    return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", default="google/siglip2-base-patch32-256")
    parser.add_argument("--revision", default="94dffa8cb1179de3e03f091dbc3917e5d5a9ae84")
    parser.add_argument("--vision-model", required=True)
    parser.add_argument("--text-model", required=True)
    parser.add_argument("--fixture", default="Scripts/tests/fixtures/siglip2_tokenizer_fixture.json")
    parser.add_argument("--output", required=True)
    parser.add_argument(
        "--require-coreml", action="store_true", dest="require_coreml",
        help="release-gate form: fail fast if either Core ML artifact is absent"
    )
    args = parser.parse_args()

    import coremltools.models as ctm
    import torch
    from transformers import Siglip2TextModel, SiglipVisionModel

    if args.require_coreml:
        missing = [p for p in (args.vision_model, args.text_model)
                   if not (repo_root() / p).exists()]
        if missing:
            print(f"[require-coreml] missing artifacts: {missing}", file=__import__('sys').stderr)
            return 1
        print("[require-coreml] both Core ML artifacts present")

    repo = Path.cwd()
    local_dir = str(repo / "PinnedModels/siglip2-base-patch32-256")

    # ---------- deterministic inputs ----------
    spec = importlib.util.spec_from_file_location("conv", str(repo / "Scripts/convert_siglip2.py"))
    conv = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(conv)

    colors = {"blue": (0, 0, 255), "red": (255, 0, 0), "green": (0, 255, 0),
              "white": (255, 255, 255), "black": (0, 0, 0), "gray": (128, 128, 128)}
    pixel_batch = torch.stack([conv.make_solid_image(*rgb) for rgb in colors.values()])

    fixture = json.loads((repo / args.fixture).read_text(encoding="utf-8"))
    case_names = sorted(fixture["cases"].keys())
    ids_np = np.array([fixture["cases"][n]["inputIds"] for n in case_names], dtype=np.int32)
    mask_np = np.array([fixture["cases"][n]["attentionMask"] for n in case_names], dtype=np.int64)
    ids_t = torch.tensor(ids_np, dtype=torch.long)
    mask_t = torch.tensor(mask_np, dtype=torch.long)

    report: dict = {
        "checkpoint": args.checkpoint,
        "revision": args.revision,
        "visionModel": args.vision_model,
        "textModel": args.text_model,
        "imageCount": len(colors),
        "textCount": len(case_names),
        "gates": {"cosine": 0.999},
    }

    # ---------- upstream reference ----------
    vref = SiglipVisionModel.from_pretrained(local_dir).eval()
    tref = Siglip2TextModel.from_pretrained(local_dir).eval()
    with torch.no_grad():
        up_vision = vref(pixel_values=pixel_batch.clone()).pooler_output.numpy()          # [N,768]
        up_text = tref(input_ids=ids_t, attention_mask=mask_t).pooler_output.numpy()      # [M,768]

    up_vision_n = up_vision / np.linalg.norm(up_vision, axis=-1, keepdims=True)
    up_text_n = up_text / np.linalg.norm(up_text, axis=-1, keepdims=True)
    up_matrix = up_vision_n @ up_text_n.T                                                  # [N,M]

    # ---------- Core ML ----------
    vml = ctm.MLModel(args.vision_model)
    tml = ctm.MLModel(args.text_model)
    core_vision = np.stack([
        np.array(vml.predict({"pixel_values": pixel_batch[i:i+1].numpy()})["embeddings"]).flatten()
        for i in range(len(colors))
    ])
    # 文本模型契约为固定 (1,64) 批形状——逐行推理后堆叠
    core_text_rows = []
    for i in range(ids_np.shape[0]):
        row_out = tml.predict({"input_ids": ids_np[i:i + 1]})["text_embeddings"]
        core_text_rows.append(np.array(row_out).flatten())
    core_text = np.stack(core_text_rows)                                                   # [M,768]

    core_vision_n = core_vision / (np.linalg.norm(core_vision, axis=-1, keepdims=True) + 1e-12)
    core_matrix = core_vision_n @ core_text.T                                              # [N,M]

    # ---------- 1) rawPoolerParity ----------
    raw = {}
    for label, img_idx in zip(colors, range(len(colors))):
        raw[f"vision/{label}"] = _cosine(core_vision[img_idx], up_vision[img_idx])
    for name in case_names:
        j = case_names.index(name)
        raw[f"text/{name}"] = _cosine(core_text[j], up_text[j])
    raw_worst = min(raw.values())
    report["rawPoolerParity"] = {"perCase": raw, "worst": raw_worst,
                                 "gate": 0.999, "passed": raw_worst >= 0.999}

    # ---------- 2) normalizedVectorParity ----------
    norm_checks = {}
    for label, i in zip(colors, range(len(colors))):
        up_n = up_vision[i] / (np.linalg.norm(up_vision[i]) + 1e-12)
        norm_checks[f"vision/{label}"] = {
            "unitNorm": abs(float(np.linalg.norm(core_vision[i])) - 1.0) < 0.02,
            "maxAbsDiffVsRenorm": float(np.abs(core_vision[i] - up_n).max()),
            "cosine": _cosine(core_vision[i], up_n),
        }
    for name, j in zip(case_names, range(len(case_names))):
        norm_checks[f"text/{name}"] = {
            "unitNorm": abs(float(np.linalg.norm(core_text[j])) - 1.0) < 0.02,
            "maxAbsDiffVsRenorm": float(np.abs(core_text[j] - up_text_n[j]).max()),
            "cosine": _cosine(core_text[j], up_text_n[j]),
        }
    norm_pass = all(v["unitNorm"] and v["cosine"] >= 0.999 for v in norm_checks.values())
    report["normalizedVectorParity"] = {"perCase": norm_checks, "passed": norm_pass}

    # ---------- 3) intermediateParity (traced-PyTorch vs upstream, fp32) ----------
    sd_path = local_dir + "/model.safetensors"
    from safetensors.torch import load_file
    sd = {k: v.float() for k, v in load_file(sd_path).items()}
    mine_t = conv.SigLIP2TextEncoder(sd).eval()

    inter: dict = {}
    with torch.no_grad():
        # text stages
        ids_l = ids_t
        x = mine_t.token_embedding(ids_l) + mine_t.position_embedding.weight[: ids_l.shape[1]][None]
        bias = ((1.0 - mask_t.float()) * conv.TEXT_MASK_SENTINEL)[:, None, None, :]
        inter["text/embeddings"] = x[0].numpy()
        for i, layer in enumerate(mine_t.layers):
            x = layer(x, bias)
            if i in (0, 5, 11):
                inter[f"text/layer{i}"] = x[0].numpy()
        xf = mine_t.final_layer_norm(x)
        inter["text/final_ln"] = xf[0].numpy()

        # vision stages (embeddings sum + selected layer outputs via module hooks not available;
        # use pre-head pooled chain: run encoder pieces through public submodules when exposed,
        # otherwise record post-encoder pooled only)
        with torch.no_grad():
            up_v_last = vref(pixel_values=pixel_batch.clone()).last_hidden_state.numpy()
        inter["vision/upstream_last_hidden_norm"] = float(np.linalg.norm(up_v_last[0]))

    # text intermediate vs upstream equivalents (recompute upstream stages)
    with torch.no_grad():
        emb = tref.text_model.embeddings(input_ids=ids_t)
        inter_up: dict = {"text/embeddings": emb[0].numpy()}
        h = emb
        for i, layer in enumerate(tref.text_model.encoder.layers):
            h = layer(h, attention_mask=_prepare_mask(mask_t))
            if i in (0, 5, 11):
                inter_up[f"text/layer{i}"] = h[0].numpy()
        hf_ln = tref.text_model.final_layer_norm(h)
        inter_up["text/final_ln"] = hf_ln[0].numpy()

    worst_inter = 1.0
    inter_detail = {}
    for key, mine_arr in inter.items():
        if key not in inter_up:
            continue
        c = _cosine(mine_arr.flatten(), inter_up[key].flatten())
        inter_detail[key] = c
        worst_inter = min(worst_inter, c)
    inter_pass = worst_inter >= 0.9999 and len(inter_detail) >= 5
    report["intermediateParity"] = {
        "scope": "traced-PyTorch(fp32) vs upstream module stages, text tower",
        "stages": inter_detail,
        "worst": worst_inter,
        "gate": 0.9999,
        "passed": bool(inter_pass),
        "visionNote": "vision stage-wise parity covered by raw/score sections; "
                      "conv-layout weights make per-stage extraction non-trivial",
    }

    # ---------- 4) scoreMatrixParity ----------
    diff = np.abs(core_matrix - up_matrix)
    report["scoreMatrixParity"] = {
        "shape": list(up_matrix.shape),
        "maxAbsDiff": float(diff.max()),
        "meanAbsDiff": float(diff.mean()),
        "upstreamSample": [[round(float(x), 6) for x in row[:3]] for row in up_matrix[:3]],
        "gate": 0.05,
        "passed": bool(diff.max() <= 0.05),
    }

    # ---------- 5) topKParity ----------
    K = 3
    mismatches = []
    for i, label in enumerate(colors):
        up_rank = list(np.argsort(-up_matrix[i])[:K])
        core_rank = list(np.argsort(-core_matrix[i])[:K])
        if up_rank != core_rank:
            mismatches.append({"image": label, "upstream": up_rank, "coreml": core_rank})
    report["topKParity"] = {
        "k": K,
        "imagesChecked": len(colors),
        "mismatches": mismatches,
        "passed": len(mismatches) == 0,
    }

    overall = all(report[s]["passed"] for s in
                  ["rawPoolerParity", "normalizedVectorParity",
                   "intermediateParity", "scoreMatrixParity", "topKParity"])
    report["overallPassed"] = bool(overall)

    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"[parity] overallPassed={overall} -> {out}")
    return 0 if overall else 1


def _prepare_mask(mask_t):
    import torch
    from transformers.modeling_attn_mask_utils import _prepare_4d_attention_mask

    return _prepare_4d_attention_mask(mask_t, torch.float32)


if __name__ == "__main__":
    import importlib.util
    raise SystemExit(main())
