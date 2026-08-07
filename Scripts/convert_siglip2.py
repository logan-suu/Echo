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
import torch.nn as nn
import torch.nn.functional as F
from safetensors.torch import load_file

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

        # Residual + LayerNorm + MLP (upstream chain)
        probe_out = probe_out + probe               # residual
        probe_out = self.head_ln(probe_out)
        mlp_out = self.head_mlp_fc2(
            F.gelu(self.head_mlp_fc1(probe_out))
        )
        probe_out = probe_out + mlp_out             # [B, 1, 768]

        # L2 normalize
        probe_out = F.normalize(probe_out, p=2, dim=-1)

        return probe_out.squeeze(1)                 # [B, 768]


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
            capture_output=True, text=True,
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
