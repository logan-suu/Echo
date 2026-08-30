#!/usr/bin/env python3
"""
SigLIP2-B/32-256 Core ML Conversion Script (3F.3a)
====================================================
Converts Google siglip2-base-patch32-256 PyTorch checkpoint to Core ML
.mlpackage via coremltools, then compiles to .mlmodelc for Xcode bundling.

Architecture: patch_size=32, image_size=256, 64 patches, 768-dim, 12 layers, 12 heads.

Requirements:
    pip install torch coremltools safetensors numpy pillow

Usage:
    python3 Scripts/convert_siglip2.py \
        --source Echo/Resources/Models/siglip2-base-patch32-256/model.safetensors \
        --output Echo/Resources/Models/SigLIP2BasePatch32.mlpackage

License: MIT (this script); Apache-2.0 (SigLIP2 model)
Revision: 3F.3a — corrected architecture constants from safetensors inspection
"""

import argparse
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F
from safetensors.torch import load_file
from torch import nn

# ---- Architecture Constants (verified from safetensors) ----
IMAGE_SIZE = 256
PATCH_SIZE = 32
NUM_PATCHES = (IMAGE_SIZE // PATCH_SIZE) ** 2  # 64
EMBED_DIM = 768
NUM_HEADS = 12
NUM_LAYERS = 12
INTERMEDIATE_SIZE = 3072
NUM_CHANNELS = 3

# Normalization (SigLIP2 standard)
MEAN = [0.5, 0.5, 0.5]
STD = [0.5, 0.5, 0.5]


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(8192):
            h.update(chunk)
    return h.hexdigest()


def sha256_dir(path: str) -> str:
    h = hashlib.sha256()
    for root, dirs, files in os.walk(path):
        dirs.sort()
        for fname in sorted(files):
            fp = os.path.join(root, fname)
            h.update(fname.encode())
            with open(fp, "rb") as f:
                while chunk := f.read(8192):
                    h.update(chunk)
    return h.hexdigest()


# ---------------------------------------------------------------------------
# Vision Transformer (SigLIP2 vision encoder)
# ---------------------------------------------------------------------------

# ---- Pinned identity constants (handover plan WP2 steps 3c-3f) ----
PINNED_VOCAB = 256_000
PINNED_TEXT_PARAMS = 282_303_744
TEXT_HIDDEN = 768
TEXT_LAYERS = 12
TEXT_HEADS = 12
TEXT_INTERMEDIATE = 3072
TEXT_SEQ = 64
TEXT_PAD_ID = 0
# fp16-safe additive mask sentinel: finfo(float32).min overflows during
# compute_precision=FLOAT16 conversion (observed cosine collapse on
# all-real-token inputs); a finite -1e4 keeps masked softmax weights ~0
# without any overflow path.
TEXT_MASK_SENTINEL = -1e4


def validate_text_tower_preflight(state_dict: dict, expected_total_params=None) -> int:
    """Fail-closed identity checks on text-tower weights (WP2 steps 3c/3e).

    Rejects wrong vocabulary size and (optionally) wrong total parameter count
    BEFORE any conversion work happens.
    """
    emb = state_dict.get("text_model.embeddings.token_embedding.weight")
    if emb is None:
        emb = state_dict.get("text_model.embeddings.token_embedding")
    if emb is None:
        raise ValueError("text tower preflight: missing token embedding weights")
    vocab = int(emb.shape[0])
    if vocab != PINNED_VOCAB:
        raise ValueError(f"pinned vocabulary must be {PINNED_VOCAB}, got {vocab}")
    # 只统计文本塔键——源文件同时携带 vision/text 双塔权重（WP2 步骤 3b 实测）
    total = 0
    for key, t in state_dict.items():
        if not key.startswith("text_model."):
            continue
        numel = getattr(t, "numel", None)
        if callable(numel):
            total += int(numel())
    if expected_total_params is not None and total != expected_total_params:
        raise ValueError(
            f"text tower parameter count mismatch: {total} != {expected_total_params}"
        )
    return total


class SigLIP2VisionEncoder(nn.Module):
    """SigLIP2-B/32-256 vision encoder.

    Architecture (verified against safetensors):
      - Patch embedding: Conv2d(3→768, kernel=32, stride=32)
      - Position embedding: learnable [64, 768] (no CLS token)
      - 12 × Transformer encoder layers (pre-norm, q/k/v/out proj)
      - Post layer-norm
      - Head: attention(in_proj) + MLP → probe [1, 1, 768] output
    """

    def __init__(self, state_dict: dict):
        super().__init__()

        # -- Patch embedding --
        pw = state_dict["vision_model.embeddings.patch_embedding.weight"]
        pb = state_dict["vision_model.embeddings.patch_embedding.bias"]
        self.patch_embed = nn.Conv2d(
            NUM_CHANNELS, EMBED_DIM, kernel_size=PATCH_SIZE,
            stride=PATCH_SIZE, padding=0, bias=True,
        )
        self.patch_embed.weight = nn.Parameter(pw)
        self.patch_embed.bias = nn.Parameter(pb)

        # -- Position embedding (64 patches, 2D → add batch dim at runtime) --
        self.register_buffer(
            "pos_embed",
            state_dict["vision_model.embeddings.position_embedding.weight"]
        )  # [64, 768]

        # -- Transformer encoder layers --
        self.layers = nn.ModuleList()
        for i in range(NUM_LAYERS):
            self.layers.append(_EncoderLayer(state_dict, i))

        # -- Post layer-norm --
        self.post_ln = nn.LayerNorm(EMBED_DIM, eps=1e-6)
        self.post_ln.weight = nn.Parameter(
            state_dict["vision_model.post_layernorm.weight"]
        )
        self.post_ln.bias = nn.Parameter(
            state_dict["vision_model.post_layernorm.bias"]
        )

        # -- Head --
        self.head_attn_in = nn.Linear(EMBED_DIM, 3 * EMBED_DIM, bias=True)
        self.head_attn_in.weight = nn.Parameter(
            state_dict["vision_model.head.attention.in_proj_weight"]
        )
        self.head_attn_in.bias = nn.Parameter(
            state_dict["vision_model.head.attention.in_proj_bias"]
        )
        self.head_attn_out = nn.Linear(EMBED_DIM, EMBED_DIM, bias=True)
        self.head_attn_out.weight = nn.Parameter(
            state_dict["vision_model.head.attention.out_proj.weight"]
        )
        self.head_attn_out.bias = nn.Parameter(
            state_dict["vision_model.head.attention.out_proj.bias"]
        )
        self.head_ln = nn.LayerNorm(EMBED_DIM, eps=1e-6)
        self.head_ln.weight = nn.Parameter(
            state_dict["vision_model.head.layernorm.weight"]
        )
        self.head_ln.bias = nn.Parameter(
            state_dict["vision_model.head.layernorm.bias"]
        )
        self.head_mlp_fc1 = nn.Linear(EMBED_DIM, INTERMEDIATE_SIZE, bias=True)
        self.head_mlp_fc1.weight = nn.Parameter(
            state_dict["vision_model.head.mlp.fc1.weight"]
        )
        self.head_mlp_fc1.bias = nn.Parameter(
            state_dict["vision_model.head.mlp.fc1.bias"]
        )
        self.head_mlp_fc2 = nn.Linear(INTERMEDIATE_SIZE, EMBED_DIM, bias=True)
        self.head_mlp_fc2.weight = nn.Parameter(
            state_dict["vision_model.head.mlp.fc2.weight"]
        )
        self.head_mlp_fc2.bias = nn.Parameter(
            state_dict["vision_model.head.mlp.fc2.bias"]
        )
        self.register_buffer(
            "probe",
            state_dict["vision_model.head.probe"]
        )  # [1, 1, 768]

    def forward(self, pixel_values: torch.Tensor) -> torch.Tensor:
        """Forward pass: [B, 3, 256, 256] → [B, 768]."""
        B = pixel_values.shape[0]

        # Patch embedding: [B, 3, 256, 256] → [B, 768, 8, 8] → [B, 64, 768]
        x = self.patch_embed(pixel_values)       # [B, 768, 8, 8]
        x = x.flatten(2).transpose(1, 2)          # [B, 64, 768]

        # Add position embedding
        x = x + self.pos_embed.unsqueeze(0)       # [B, 64, 768]

        # Transformer layers
        for layer in self.layers:
            x = layer(x)

        # Post layer-norm
        x = self.post_ln(x)                        # [B, 64, 768]

        # Head: multi-head attention pooling with learned probe token (SiglipMultiheadAttentionPoolingHead)
        # Upstream HF semantics: probe is the sole query, patch tokens x provide keys/values
        # (cross-attention), NOT combined self-attention. CR-13 fix -- the two are not
        # mathematically equivalent; combined self-attention changes the attention pattern.
        probe = self.probe.expand(B, -1, -1)       # [B, 1, 768]
        qkv_probe = self.head_attn_in(probe)        # [B, 1, 2304]
        qkv_x = self.head_attn_in(x)                # [B, 64, 2304]
        q = qkv_probe[:, :, :EMBED_DIM].reshape(B, 1, NUM_HEADS, EMBED_DIM // NUM_HEADS).transpose(1, 2)
        k = qkv_x[:, :, EMBED_DIM:2 * EMBED_DIM].reshape(B, 64, NUM_HEADS, EMBED_DIM // NUM_HEADS).transpose(1, 2)
        v = qkv_x[:, :, 2 * EMBED_DIM:].reshape(B, 64, NUM_HEADS, EMBED_DIM // NUM_HEADS).transpose(1, 2)

        attn_weights = (q @ k.transpose(-2, -1)) * (EMBED_DIM // NUM_HEADS) ** -0.5
        attn_weights = F.softmax(attn_weights, dim=-1)
        attn = attn_weights @ v                      # [B, 12, 1, 64]
        attn = attn.transpose(1, 2).reshape(B, 1, EMBED_DIM)
        probe_out = self.head_attn_out(attn)         # [B, 1, 768]

        # Official pinned chain (HF SiglipMultiheadAttentionPoolingHead):
        # h = LN(A); out = A + MLP(h) -- no extra probe residual (WP2 step 1b)
        h = self.head_ln(probe_out)
        mlp_out = self.head_mlp_fc2(
            F.gelu(self.head_mlp_fc1(h), approximate="tanh")   # checkpoint tanh GELU (WP2 step 1d)
        )
        probe_out = probe_out + mlp_out             # [B, 1, 768]

        # L2 normalize
        probe_out = F.normalize(probe_out, p=2, dim=-1)

        return probe_out.squeeze(1)                 # [B, 768]


# ---- Paired text tower (WP2 steps 3a-3b) ----
class _TextSelfAttention(nn.Module):
    """Multi-head attention matching HF SiglipText self_attn (q/k/v/out_proj)."""

    def __init__(self, sd: dict, prefix: str):
        super().__init__()
        self.q_proj = nn.Linear(TEXT_HIDDEN, TEXT_HIDDEN)
        self.k_proj = nn.Linear(TEXT_HIDDEN, TEXT_HIDDEN)
        self.v_proj = nn.Linear(TEXT_HIDDEN, TEXT_HIDDEN)
        self.out_proj = nn.Linear(TEXT_HIDDEN, TEXT_HIDDEN)
        for name in ("q_proj", "k_proj", "v_proj", "out_proj"):
            lin = getattr(self, name)
            lin.weight = nn.Parameter(sd[prefix + name + ".weight"])
            lin.bias = nn.Parameter(sd[prefix + name + ".bias"])
        self.head_dim = TEXT_HIDDEN // TEXT_HEADS
        self.scale = self.head_dim ** -0.5

    def forward(self, x, bias=None):
        B, S, _H = x.shape
        hd = self.head_dim
        q = self.q_proj(x).view(B, S, TEXT_HEADS, hd).transpose(1, 2)
        k = self.k_proj(x).view(B, S, TEXT_HEADS, hd).transpose(1, 2)
        v = self.v_proj(x).view(B, S, TEXT_HEADS, hd).transpose(1, 2)
        scores = (q @ k.transpose(-2, -1)) * self.scale
        if bias is not None:
            scores = scores + bias
        attn = F.softmax(scores, dim=-1) @ v
        attn = attn.transpose(1, 2).reshape(B, S, TEXT_HIDDEN)
        return self.out_proj(attn)


class _TextMLP(nn.Module):
    def __init__(self, sd: dict, prefix: str):
        super().__init__()
        self.fc1 = nn.Linear(TEXT_HIDDEN, TEXT_INTERMEDIATE)
        self.fc2 = nn.Linear(TEXT_INTERMEDIATE, TEXT_HIDDEN)
        self.fc1.weight = nn.Parameter(sd[prefix + "fc1.weight"])
        self.fc1.bias = nn.Parameter(sd[prefix + "fc1.bias"])
        self.fc2.weight = nn.Parameter(sd[prefix + "fc2.weight"])
        self.fc2.bias = nn.Parameter(sd[prefix + "fc2.bias"])

    def forward(self, x):
        return self.fc2(F.gelu(self.fc1(x), approximate="tanh"))


class _TextLayer(nn.Module):
    def __init__(self, sd: dict, idx: int):
        super().__init__()
        p = f"text_model.encoder.layers.{idx}."
        self.ln1 = nn.LayerNorm(TEXT_HIDDEN, eps=1e-6)
        self.ln1.weight = nn.Parameter(sd[p + "layer_norm1.weight"])
        self.ln1.bias = nn.Parameter(sd[p + "layer_norm1.bias"])
        self.attn = _TextSelfAttention(sd, p + "self_attn.")
        self.ln2 = nn.LayerNorm(TEXT_HIDDEN, eps=1e-6)
        self.ln2.weight = nn.Parameter(sd[p + "layer_norm2.weight"])
        self.ln2.bias = nn.Parameter(sd[p + "layer_norm2.bias"])
        self.mlp = _TextMLP(sd, p + "mlp.")

    def forward(self, x, bias=None):
        x = x + self.attn(self.ln1(x), bias)
        x = x + self.mlp(self.ln2(x))
        return x


class SigLIP2TextEncoder(nn.Module):
    """Paired text tower replicating HF SiglipTextTransformer semantics.

    Bidirectional attention (NO causal mask, unlike CLIP). Official SigLIP2
    inference applies NO attention mask (the HF tokenizer returns none), so
    pad positions participate unmasked; final LayerNorm then LAST-position
    pooling (documented HF behavior: may be a padding position) then head
    projection.
    """

    def __init__(self, sd: dict):
        super().__init__()
        self.token_embedding = nn.Embedding(PINNED_VOCAB, TEXT_HIDDEN)
        self.token_embedding.weight = nn.Parameter(
            sd["text_model.embeddings.token_embedding.weight"]
        )
        self.position_embedding = nn.Embedding(TEXT_SEQ, TEXT_HIDDEN)
        self.position_embedding.weight = nn.Parameter(
            sd["text_model.embeddings.position_embedding.weight"]
        )
        self.layers = nn.ModuleList([_TextLayer(sd, i) for i in range(TEXT_LAYERS)])
        self.final_layer_norm = nn.LayerNorm(TEXT_HIDDEN, eps=1e-6)
        self.final_layer_norm.weight = nn.Parameter(sd["text_model.final_layer_norm.weight"])
        self.final_layer_norm.bias = nn.Parameter(sd["text_model.final_layer_norm.bias"])
        self.head = nn.Linear(TEXT_HIDDEN, TEXT_HIDDEN)
        self.head.weight = nn.Parameter(sd["text_model.head.weight"])
        self.head.bias = nn.Parameter(sd["text_model.head.bias"])

    def forward(self, input_ids):
        ids = input_ids.to(torch.long)
        # Official SigLIP2 inference passes NO attention mask (the HF tokenizer
        # returns none). Masking pad keys here collapses text embeddings to
        # noise: masked -> flat cos band ~0.03 vs image tower, unmasked ->
        # real semantic discrimination (empirically verified vs HF).
        x = self.token_embedding(ids) + self.position_embedding.weight[: ids.shape[1]][None]
        for layer in self.layers:
            x = layer(x)
        x = self.final_layer_norm(x)
        pooled = x[:, -1, :]
        # Shared normalization contract with the image tower: Core ML output
        # is a unit vector (handover plan §6 acceptance).
        return F.normalize(self.head(pooled), p=2, dim=-1)


class _DualTower(nn.Module):
    """WP2 步骤 5：双塔联合图——单次推理产出 image/text embeddings 对。"""

    def __init__(self, vision: nn.Module, text: nn.Module):
        super().__init__()
        self.vision = vision
        self.text = text

    def forward(self, pixel_values, input_ids):
        return self.vision(pixel_values), self.text(input_ids)


def _apply_weight_compression(path: Path, quantization: str) -> None:
    """WP2 步骤 5：对已保存的 .mlpackage 施加候选量化（fp16 为基线不处理）。"""
    if quantization == "fp16":
        return
    import coremltools as ct
    from coremltools.optimize.coreml import (
        OpLinearQuantizerConfig,
        OpPalettizerConfig,
        OptimizationConfig,
        linear_quantize_weights,
        palettize_weights,
    )

    model = ct.models.MLModel(str(path))
    if quantization == "int8":
        config = OptimizationConfig(
            global_config=OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8")
        )
        compressed = linear_quantize_weights(model, config=config)
    elif quantization == "6bit":
        config = OptimizationConfig(global_config=OpPalettizerConfig(nbits=6))
        compressed = palettize_weights(model, config=config)
    elif quantization == "4bit":
        config = OptimizationConfig(global_config=OpPalettizerConfig(nbits=4))
        compressed = palettize_weights(model, config=config)
    else:
        raise ValueError(f"unsupported quantization: {quantization}")
    compressed.save(str(path))
    print(f"[quantize] {quantization} applied -> {path}")


def convert_text_to_coreml(model: nn.Module, output_path: str) -> str:
    """Trace-export the text tower with a fixed int32[1,64] input contract."""
    import coremltools as ct
    import numpy as np

    model.eval()
    example_ids = torch.zeros((1, TEXT_SEQ), dtype=torch.int32)
    traced = torch.jit.trace(model, example_ids)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input_ids", shape=(1, TEXT_SEQ), dtype=np.int32)],
        outputs=[ct.TensorType(name="text_embeddings")],
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16,
    )
    os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)
    mlmodel.save(output_path)
    print(f"[convert] Saved: {output_path}")
    return output_path


class _EncoderLayer(nn.Module):
    """Single SigLIP2 transformer encoder layer (pre-norm).

    Uses separate Q/K/V projections (not combined in_proj).
    """

    def __init__(self, state_dict: dict, layer_idx: int):
        super().__init__()
        p = f"vision_model.encoder.layers.{layer_idx}."

        self.ln1 = nn.LayerNorm(EMBED_DIM, eps=1e-6)
        self.ln1.weight = nn.Parameter(state_dict[p + "layer_norm1.weight"])
        self.ln1.bias = nn.Parameter(state_dict[p + "layer_norm1.bias"])

        # Attention: separate q/k/v projections
        self.q_proj = nn.Linear(EMBED_DIM, EMBED_DIM, bias=True)
        self.q_proj.weight = nn.Parameter(state_dict[p + "self_attn.q_proj.weight"])
        self.q_proj.bias = nn.Parameter(state_dict[p + "self_attn.q_proj.bias"])
        self.k_proj = nn.Linear(EMBED_DIM, EMBED_DIM, bias=True)
        self.k_proj.weight = nn.Parameter(state_dict[p + "self_attn.k_proj.weight"])
        self.k_proj.bias = nn.Parameter(state_dict[p + "self_attn.k_proj.bias"])
        self.v_proj = nn.Linear(EMBED_DIM, EMBED_DIM, bias=True)
        self.v_proj.weight = nn.Parameter(state_dict[p + "self_attn.v_proj.weight"])
        self.v_proj.bias = nn.Parameter(state_dict[p + "self_attn.v_proj.bias"])
        self.out_proj = nn.Linear(EMBED_DIM, EMBED_DIM, bias=True)
        self.out_proj.weight = nn.Parameter(state_dict[p + "self_attn.out_proj.weight"])
        self.out_proj.bias = nn.Parameter(state_dict[p + "self_attn.out_proj.bias"])

        self.ln2 = nn.LayerNorm(EMBED_DIM, eps=1e-6)
        self.ln2.weight = nn.Parameter(state_dict[p + "layer_norm2.weight"])
        self.ln2.bias = nn.Parameter(state_dict[p + "layer_norm2.bias"])

        self.mlp_fc1 = nn.Linear(EMBED_DIM, INTERMEDIATE_SIZE, bias=True)
        self.mlp_fc1.weight = nn.Parameter(state_dict[p + "mlp.fc1.weight"])
        self.mlp_fc1.bias = nn.Parameter(state_dict[p + "mlp.fc1.bias"])
        self.mlp_fc2 = nn.Linear(INTERMEDIATE_SIZE, EMBED_DIM, bias=True)
        self.mlp_fc2.weight = nn.Parameter(state_dict[p + "mlp.fc2.weight"])
        self.mlp_fc2.bias = nn.Parameter(state_dict[p + "mlp.fc2.bias"])

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        # Pre-norm attention
        residual = x
        x = self.ln1(x)
        B, N, D = x.shape
        q = self.q_proj(x).view(B, N, NUM_HEADS, D // NUM_HEADS).transpose(1, 2)
        k = self.k_proj(x).view(B, N, NUM_HEADS, D // NUM_HEADS).transpose(1, 2)
        v = self.v_proj(x).view(B, N, NUM_HEADS, D // NUM_HEADS).transpose(1, 2)
        attn_weights = (q @ k.transpose(-2, -1)) * (EMBED_DIM // NUM_HEADS) ** -0.5
        attn_weights = F.softmax(attn_weights, dim=-1)
        attn = attn_weights @ v
        attn = attn.transpose(1, 2).reshape(B, N, D)
        x = residual + self.out_proj(attn)

        # Pre-norm MLP
        residual = x
        x = self.ln2(x)
        x = residual + self.mlp_fc2(F.gelu(self.mlp_fc1(x)))
        return x


# ---------------------------------------------------------------------------
# Reference vectors
# ---------------------------------------------------------------------------

def make_solid_image(r: int, g: int, b: int) -> torch.Tensor:
    """Create a solid-color 256×256 image tensor normalized to [-1, 1]."""
    img = torch.zeros(3, IMAGE_SIZE, IMAGE_SIZE, dtype=torch.float32)
    img[0] = ((r / 255.0) - MEAN[0]) / STD[0]
    img[1] = ((g / 255.0) - MEAN[1]) / STD[1]
    img[2] = ((b / 255.0) - MEAN[2]) / STD[2]
    return img


def cosine_sim(a, b):
    a = np.asarray(a, dtype=np.float64)
    b = np.asarray(b, dtype=np.float64)
    return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b)))


def generate_reference_vectors(model: nn.Module) -> dict:
    """Generate deterministic reference vectors from 5 solid-color images."""
    model.eval()
    colors = {
        "solid_red_256": (255, 0, 0),
        "solid_green_256": (0, 255, 0),
        "solid_blue_256": (0, 0, 255),
        "solid_white_256": (255, 255, 255),
        "solid_black_256": (0, 0, 0),
    }

    samples = []
    with torch.no_grad():
        for label, (r, g, b) in colors.items():
            img = make_solid_image(r, g, b).unsqueeze(0)  # [1, 3, 256, 256]
            output = model(img)                             # [1, 768]
            vec = output.squeeze(0).tolist()
            samples.append({
                "label": label,
                "description": f"Solid {label.split('_')[1]} image (R={r},G={g},B={b}), 256×256.",
                "embedding": [round(v, 8) for v in vec],
            })
            print(f"  [reference] {label}: dim={len(vec)}, norm={np.linalg.norm(vec):.6f}")

    return {
        "schemaVersion": "1.0.0",
        "modelId": "siglip2-base-patch32-256-v1",
        "dimension": EMBED_DIM,
        "revision": "main",
        "description": (
            "SigLIP2-B/32-256 reference output vectors for conversion consistency "
            "verification (US-SRC-011 model semantics). Generated by "
            "Scripts/convert_siglip2.py from 5 solid-color 256×256 images. "
            "Compare Core ML runtime output for >0.995 cosine similarity."
        ),
        "status": "pending-evaluation",
        "samples": samples,
    }


# ---------------------------------------------------------------------------
# Core ML conversion
# ---------------------------------------------------------------------------

def convert_to_coreml(model: nn.Module, output_path: str) -> str:
    """Trace and export SigLIP2 vision encoder as Core ML .mlpackage."""
    import coremltools as ct

    model.eval()

    # Trace with JIT (explicit attention for compatibility)
    example = make_solid_image(128, 128, 128).unsqueeze(0)
    traced = torch.jit.trace(model, example)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="pixel_values", shape=(1, 3, IMAGE_SIZE, IMAGE_SIZE))],
        outputs=[ct.TensorType(name="embeddings")],
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16,
    )

    os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)
    mlmodel.save(output_path)
    print(f"[convert] Saved: {output_path}")
    return output_path


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="SigLIP2-B/32-256 Core ML Converter (3F.3a)"
    )
    parser.add_argument(
        "--source", type=str,
        help="Path to model.safetensors"
    )
    parser.add_argument(
        "--output", type=str,
        default="Resources/Models/SigLIP2BasePatch32.mlpackage",
        help="Output .mlpackage path"
    )
    parser.add_argument(
        "--no-compile", action="store_true",
        help="Skip xcrun coremlcompiler compilation"
    )
    parser.add_argument(
        "--checksum-only", action="store_true",
        help="Only compute SHA-256 of existing model directory"
    )
    parser.add_argument(
        "--model-dir", type=str,
        help="Path to .mlmodelc directory for checksum computation"
    )
    parser.add_argument(
        "--reference-vectors", type=str,
        default="Echo/Resources/Models/siglip2-reference-vectors.json",
        help="Output path for reference vectors JSON"
    )
    parser.add_argument(
        "--tower", choices=["vision", "text", "dual"], default="vision",
        help="Which tower(s) to export (WP2: text + dual candidates)"
    )
    parser.add_argument(
        "--revision", type=str, default="",
        help="Pinned source revision recorded into conversion log"
    )
    parser.add_argument(
        "--quantization", choices=["fp16", "int8", "6bit", "4bit"], default="fp16",
        help="Candidate quantization (WP2 step 5)"
    )
    args = parser.parse_args()

    print("=" * 60)
    print("Echo SigLIP2-B/32-256 Core ML Converter (3F.3a)")
    print(f"  image_size={IMAGE_SIZE}  patch_size={PATCH_SIZE}")
    print(f"  num_patches={NUM_PATCHES}  embed_dim={EMBED_DIM}")
    print(f"  num_layers={NUM_LAYERS}  num_heads={NUM_HEADS}")
    print("=" * 60)

    # Checksum-only mode
    if args.checksum_only:
        if not args.model_dir or not os.path.exists(args.model_dir):
            print(f"ERROR: --model-dir '{args.model_dir}' does not exist", file=sys.stderr)
            sys.exit(1)
        sha256 = sha256_dir(args.model_dir)
        name = os.path.basename(args.model_dir)
        print(f"\nSHA-256: {sha256}  {name}")
        print("\nAdd this to Scripts/model_checksums.sha256:")
        print(f"{sha256}  {name}")
        return

    # Conversion mode
    if not args.source or not os.path.exists(args.source):
        print(f"ERROR: --source '{args.source}' does not exist", file=sys.stderr)
        sys.exit(1)

    source_sha256 = sha256_file(args.source)
    print(f"\n[source]  SHA-256: {source_sha256}")

    # Step 1: Load model
    print("\n[load] Loading SigLIP2-B/32-256 from safetensors...")
    state_dict = load_file(args.source)
    # Strip torch dtype metadata — safetensors returns named tensors sometimes
    state_dict = {k: v.float() if hasattr(v, 'float') else v
                  for k, v in state_dict.items()}
    # WP2 step 5: dual-tower candidate export (single graph, two inputs/two outputs)
    if args.tower == "dual":
        import coremltools as ct
        import numpy as np

        validate_text_tower_preflight(state_dict, expected_total_params=PINNED_TEXT_PARAMS)
        print("[preflight] vocab/param identity OK (pinned)")
        vmodel = SigLIP2VisionEncoder(state_dict).eval()
        tmodel = SigLIP2TextEncoder(state_dict).eval()
        dual = _DualTower(vmodel, tmodel).eval()
        rev = args.revision or "unspecified"
        px_example = torch.zeros((1, 3, IMAGE_SIZE, IMAGE_SIZE), dtype=torch.float32)
        ids_example = torch.zeros((1, TEXT_SEQ), dtype=torch.int32)
        traced = torch.jit.trace(dual, (px_example, ids_example))
        mlmodel = ct.convert(
            traced,
            inputs=[
                ct.TensorType(name="pixel_values", shape=(1, 3, IMAGE_SIZE, IMAGE_SIZE), dtype=np.float32),
                ct.TensorType(name="input_ids", shape=(1, TEXT_SEQ), dtype=np.int32),
            ],
            outputs=[
                ct.TensorType(name="image_embeddings"),
                ct.TensorType(name="text_embeddings"),
            ],
            minimum_deployment_target=ct.target.iOS17,
            compute_precision=ct.precision.FLOAT16,
        )
        out_dir = os.path.dirname(args.output) or "."
        os.makedirs(out_dir, exist_ok=True)
        mlmodel.save(args.output)
        print(f"[convert] Saved dual-tower: {args.output}")
        if args.quantization != "fp16":
            from pathlib import Path as _P

            _apply_weight_compression(_P(args.output), args.quantization)
        print(f"[dual] export complete  quantization={args.quantization}  revision={rev}")
        return

    # WP2 step 3b: paired text tower export path (fail-closed preflight first)
    if args.tower == "text":
        validate_text_tower_preflight(state_dict, expected_total_params=PINNED_TEXT_PARAMS)
        print("[preflight] vocab/param identity OK (pinned)")
        model = SigLIP2TextEncoder(state_dict)
        model.eval()
        n_params = sum(p.numel() for p in model.parameters())
        rev = args.revision or "unspecified"
        print(f"[load]   Text tower loaded ({n_params:,} params)  revision={rev}")
        convert_text_to_coreml(model, args.output)
        print("\n[text] Text tower export complete.")
        return

    model = SigLIP2VisionEncoder(state_dict)
    model.eval()
    print(f"[load]   Model loaded ({sum(p.numel() for p in model.parameters()):,} params)")

    # Step 2: Quick smoke test
    print("\n[verify] Running PyTorch forward pass...")
    with torch.no_grad():
        test_input = make_solid_image(128, 128, 128).unsqueeze(0)
        test_output = model(test_input)
        print(f"[verify]  Output shape: {test_output.shape}")
        print(f"[verify]  Output norm: {test_output.norm().item():.6f}")

    # Step 3: Generate reference vectors
    print("\n[reference] Generating reference vectors...")
    ref_vectors = generate_reference_vectors(model)
    ref_path = args.reference_vectors
    os.makedirs(os.path.dirname(ref_path) or ".", exist_ok=True)
    with open(ref_path, "w") as f:
        json.dump(ref_vectors, f, indent=2)
    print(f"[reference] Written to: {ref_path}")

    # Step 4: Convert to Core ML
    print("\n[convert] Converting to Core ML .mlpackage...")
    mlpackage_path = convert_to_coreml(model, args.output)

    # Step 5: Compile to .mlmodelc
    mlmodelc_path = None
    if not args.no_compile:
        print("\n[compile] Compiling .mlmodelc via xcrun coremlcompiler...")
        output_dir = os.path.dirname(mlpackage_path) or "."
        result = subprocess.run(
            ["xcrun", "coremlcompiler", "compile", mlpackage_path, output_dir],
            capture_output=True, text=True, check=False,
        )
        if result.returncode != 0:
            print(f"  WARNING: coremlcompiler failed:\n{result.stderr}", file=sys.stderr)
            print(f"  Compile manually: xcrun coremlcompiler compile {mlpackage_path} {output_dir}")
        else:
            compiled_name = os.path.splitext(os.path.basename(mlpackage_path))[0] + ".mlmodelc"
            mlmodelc_path = os.path.join(output_dir, compiled_name)
            if os.path.exists(mlmodelc_path):
                print(f"[compile]  Compiled to: {mlmodelc_path}")
                sha256 = sha256_dir(mlmodelc_path)
                print(f"[compile]  SHA-256: {sha256}")
                print("\n  Add this to Scripts/model_checksums.sha256:")
                print(f"  {sha256}  {compiled_name}")
            else:
                print(f"  WARNING: Expected {compiled_name} not found", file=sys.stderr)

    # Summary
    print("\n" + "=" * 60)
    print("Conversion Complete")
    print("=" * 60)
    print(f"Source:     {args.source}")
    print(f"SHA-256:    {source_sha256}")
    print(f"Output:     {args.output}")
    if mlmodelc_path:
        print(f"Compiled:   {mlmodelc_path}")
    print(f"References: {ref_path}")
    print("=" * 60)


if __name__ == "__main__":
    main()
