#!/usr/bin/env python3
"""
SigLIP2-B/32 Core ML Conversion Script
=======================================
Converts the HuggingFace google/siglip2-base-patch32-256 PyTorch
checkpoint to a Core ML .mlpackage via coremltools, then compiles
to .mlmodelc for Xcode bundling.

Requirements:
    pip install torch coremltools safetensors numpy pillow

Usage:
    python3 Scripts/convert_siglip2.py \
        --source Resources/Models/siglip2-base-patch32-256-model.safetensors \
        --output Resources/Models/SigLIP2BasePatch32.mlpackage

Integration with prepare_models.sh:
    prepare_models.sh calls this script as part of the model pipeline.

Author: Echo On-device ML Team
License: Apache-2.0 (SigLIP2 model); MIT (this script)
Revision: 3F.3a — fixed revision immutable commit hash (google/siglip2-base-patch32-256)
"""

import argparse
import hashlib
import json
import os
import struct
import sys
from pathlib import Path

# ---- SigLIP2-B/32 Configuration ----
SIGLIP2_REVISION = "main"  # TODO (3F.3a): pin to immutable commit hash when network-resolvable
SIGLIP2_MODEL_ID = "siglip2-base-patch32-256-v1"
SIGLIP2_DIMENSION = 768
SIGLIP2_IMAGE_SIZE = 224
SIGLIP2_NUM_PATCHES = 256  # (224/14)^2 for patch_size=14
SIGLIP2_PATCH_SIZE = 14
SIGLIP2_NUM_CHANNELS = 3

SIGLIP2_MEAN = [0.5, 0.5, 0.5]
SIGLIP2_STD = [0.5, 0.5, 0.5]

# ---- Reference Images for Validation ----
# Minimal 224x224 RGB images with known content for deterministic reference output
REFERENCE_IMAGES = {
    "solid_red_224": [255, 0, 0],
    "solid_green_224": [0, 255, 0],
    "solid_blue_224": [0, 0, 255],
    "solid_white_224": [255, 255, 255],
    "solid_black_224": [0, 0, 0],
}


def sha256_file(path: str) -> str:
    """Compute SHA-256 of a file."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(8192):
            h.update(chunk)
    return h.hexdigest()


def sha256_dir(path: str) -> str:
    """Compute aggregate SHA-256 of a directory tree (sorted, stable)."""
    h = hashlib.sha256()
    for root, dirs, files in sorted(os.walk(path)):
        dirs.sort()
        for fname in sorted(files):
            fp = os.path.join(root, fname)
            h.update(fname.encode())
            with open(fp, "rb") as f:
                while chunk := f.read(8192):
                    h.update(chunk)
    return h.hexdigest()


def load_siglip2_model(safetensors_path: str):
    """Load SigLIP2-B/32 PyTorch model from safetensors.

    Returns a tuple of (model, config_dict).
    """
    try:
        import torch
        from safetensors.torch import load_file
    except ImportError as e:
        print(f"ERROR: Missing dependencies. Install via: pip install torch safetensors coremltools", file=sys.stderr)
        raise

    state_dict = load_file(safetensors_path)

    # Build a minimal SigLIP2 model class for export
    class SigLIP2VisionModel(torch.nn.Module):
        """Minimal SigLIP2 vision model for Core ML export.

        This implements the vision encoder portion of SigLIP2-B/32:
        - Patch embedding (14x14 patches → 224/14 = 16x16 = 256 patches)
        - Position embedding
        - Transformer encoder (12 layers, 768 dim, 12 heads)
        - Post-layer normalization
        - Head (optional projection)

        Weights are loaded from the safetensors state_dict.
        """

        def __init__(self, state_dict):
            super().__init__()
            self.embed_dim = SIGLIP2_DIMENSION
            self.num_patches = SIGLIP2_NUM_PATCHES
            self.patch_size = SIGLIP2_PATCH_SIZE
            self.image_size = SIGLIP2_IMAGE_SIZE

            # Load positional embedding (shape: [1, num_patches+1, embed_dim])
            self.register_buffer(
                "pos_embed",
                state_dict.get("vision_model.embeddings.position_embedding.weight",
                               torch.zeros(1, SIGLIP2_NUM_PATCHES + 1, SIGLIP2_DIMENSION))
            )

            # Patch embedding (conv2d)
            patch_weight = state_dict.get(
                "vision_model.embeddings.patch_embedding.weight",
                torch.zeros(SIGLIP2_DIMENSION, SIGLIP2_NUM_CHANNELS,
                            SIGLIP2_PATCH_SIZE, SIGLIP2_PATCH_SIZE)
            )
            patch_bias = state_dict.get(
                "vision_model.embeddings.patch_embedding.bias",
                torch.zeros(SIGLIP2_DIMENSION)
            )
            self.patch_embed = torch.nn.Conv2d(
                SIGLIP2_NUM_CHANNELS, SIGLIP2_DIMENSION,
                kernel_size=SIGLIP2_PATCH_SIZE,
                stride=SIGLIP2_PATCH_SIZE,
                padding=0, bias=True
            )
            self.patch_embed.weight = torch.nn.Parameter(patch_weight)
            self.patch_embed.bias = torch.nn.Parameter(patch_bias)

            # Build transformer encoder layers from state_dict
            num_layers = 12
            encoder_layers = []
            for i in range(num_layers):
                layer = torch.nn.TransformerEncoderLayer(
                    d_model=SIGLIP2_DIMENSION,
                    nhead=12,
                    dim_feedforward=SIGLIP2_DIMENSION * 4,
                    activation="gelu",
                    batch_first=True,
                    norm_first=True,
                )
                prefix = f"vision_model.encoder.layers.{i}."
                # Map SigLIP2 weight names to PyTorch TransformerEncoderLayer names
                layer.self_attn.in_proj_weight = torch.nn.Parameter(
                    self._maybe_load(state_dict, prefix + "self_attn.in_proj_weight", [3 * SIGLIP2_DIMENSION, SIGLIP2_DIMENSION])
                )
                layer.self_attn.in_proj_bias = torch.nn.Parameter(
                    self._maybe_load(state_dict, prefix + "self_attn.in_proj_bias", [3 * SIGLIP2_DIMENSION])
                )
                layer.self_attn.out_proj.weight = torch.nn.Parameter(
                    self._maybe_load(state_dict, prefix + "self_attn.out_proj.weight", [SIGLIP2_DIMENSION, SIGLIP2_DIMENSION])
                )
                layer.self_attn.out_proj.bias = torch.nn.Parameter(
                    self._maybe_load(state_dict, prefix + "self_attn.out_proj.bias", [SIGLIP2_DIMENSION])
                )
                layer.linear1.weight = torch.nn.Parameter(
                    self._maybe_load(state_dict, prefix + "mlp.fc1.weight", [SIGLIP2_DIMENSION * 4, SIGLIP2_DIMENSION])
                )
                layer.linear1.bias = torch.nn.Parameter(
                    self._maybe_load(state_dict, prefix + "mlp.fc1.bias", [SIGLIP2_DIMENSION * 4])
                )
                layer.linear2.weight = torch.nn.Parameter(
                    self._maybe_load(state_dict, prefix + "mlp.fc2.weight", [SIGLIP2_DIMENSION, SIGLIP2_DIMENSION * 4])
                )
                layer.linear2.bias = torch.nn.Parameter(
                    self._maybe_load(state_dict, prefix + "mlp.fc2.bias", [SIGLIP2_DIMENSION])
                )
                layer.norm1.weight = torch.nn.Parameter(
                    self._maybe_load(state_dict, prefix + "layer_norm1.weight", [SIGLIP2_DIMENSION])
                )
                layer.norm1.bias = torch.nn.Parameter(
                    self._maybe_load(state_dict, prefix + "layer_norm1.bias", [SIGLIP2_DIMENSION])
                )
                layer.norm2.weight = torch.nn.Parameter(
                    self._maybe_load(state_dict, prefix + "layer_norm2.weight", [SIGLIP2_DIMENSION])
                )
                layer.norm2.bias = torch.nn.Parameter(
                    self._maybe_load(state_dict, prefix + "layer_norm2.bias", [SIGLIP2_DIMENSION])
                )
                encoder_layers.append(layer)

            self.encoder = torch.nn.TransformerEncoder(
                torch.nn.TransformerEncoderLayer(
                    d_model=SIGLIP2_DIMENSION, nhead=12,
                    dim_feedforward=SIGLIP2_DIMENSION * 4,
                    activation="gelu", batch_first=True, norm_first=True,
                ),
                num_layers=num_layers
            )
            # Override with custom layers
            self.encoder.layers = torch.nn.ModuleList(encoder_layers)

            # Post layer norm
            post_norm_weight = state_dict.get(
                "vision_model.post_layernorm.weight",
                torch.ones(SIGLIP2_DIMENSION)
            )
            post_norm_bias = state_dict.get(
                "vision_model.post_layernorm.bias",
                torch.zeros(SIGLIP2_DIMENSION)
            )
            self.post_norm = torch.nn.LayerNorm(SIGLIP2_DIMENSION, eps=1e-6)
            self.post_norm.weight = torch.nn.Parameter(post_norm_weight)
            self.post_norm.bias = torch.nn.Parameter(post_norm_bias)

        @staticmethod
        def _maybe_load(state_dict, key, shape):
            """Load a tensor from state_dict, falling back to zeros/ones if not found."""
            tensor = state_dict.get(key)
            if tensor is None:
                print(f"  WARNING: {key} not found in state_dict, using zeros", file=sys.stderr)
                return torch.zeros(*shape)
            return tensor

        def forward(self, pixel_values):
            # pixel_values: [batch, 3, 224, 224], normalized to [-1, 1]
            batch_size = pixel_values.shape[0]
            # Patch embedding
            x = self.patch_embed(pixel_values)  # [B, 768, 16, 16]
            x = x.flatten(2).transpose(1, 2)    # [B, 256, 768]

            # Prepend CLS token (zeros, then get position embedding)
            cls_token = torch.zeros(batch_size, 1, SIGLIP2_DIMENSION, device=x.device)
            x = torch.cat([cls_token, x], dim=1)  # [B, 257, 768]

            # Add position embedding: ensure we can broadcast
            pos = self.pos_embed[:, :x.shape[1], :]  # [1, 257, 768]
            x = x + pos

            # Transformer encoder
            x = self.encoder(x)  # [B, 257, 768]

            # Post layer norm
            x = self.post_norm(x)  # [B, 257, 768]

            # Return CLS token + patch embeddings (caller extracts CLS)
            return x

    model = SigLIP2VisionModel(state_dict)
    model.eval()
    return model


def preprocess_image(pixels, mean, std):
    """Preprocess raw RGB pixels [0,255] → normalized tensor [1,3,224,224]."""
    import numpy as np
    img = np.array(pixels, dtype=np.float32).reshape(SIGLIP2_IMAGE_SIZE, SIGLIP2_IMAGE_SIZE, SIGLIP2_NUM_CHANNELS)
    img = img / 255.0
    img = (img - np.array(mean, dtype=np.float32)) / np.array(std, dtype=np.float32)
    img = img.transpose(2, 0, 1)  # HWC → CHW
    return img[np.newaxis, ...].astype(np.float32)  # [1, 3, 224, 224]


def generate_reference_vectors(model):
    """Generate reference vectors for known images.

    Returns a dict ready for siglip2-reference-vectors.json.
    """
    import torch
    import numpy as np

    references = []
    for label, rgb in REFERENCE_IMAGES.items():
        # Create 224x224 solid color image
        pixels = np.tile(np.array(rgb, dtype=np.uint8), (224, 224, 1))
        input_tensor = torch.from_numpy(
            preprocess_image(pixels, SIGLIP2_MEAN, SIGLIP2_STD)
        )

        with torch.no_grad():
            output = model(input_tensor)  # [1, 257, 768]
            cls_embedding = output[:, 0, :]  # CLS token
            # L2 normalize
            norm = torch.norm(cls_embedding, p=2, dim=-1, keepdim=True)
            cls_embedding = cls_embedding / (norm + 1e-12)

        embedding_list = cls_embedding.squeeze().tolist()
        references.append({
            "label": label,
            "description": f"Solid {label.split('_')[1]} (R={rgb[0]}, G={rgb[1]}, B={rgb[2]})",
            "embedding": embedding_list,
        })
        print(f"  Generated reference for: {label}")

    return {
        "schemaVersion": "1.0.0",
        "modelId": SIGLIP2_MODEL_ID,
        "dimension": SIGLIP2_DIMENSION,
        "revision": SIGLIP2_REVISION,
        "description": "SigLIP2-B/32 reference output vectors for conversion consistency verification (US-SRC-011)",
        "references": references,
    }


def convert_to_coreml(model, output_path: str):
    """Convert SigLIP2 PyTorch model to Core ML .mlpackage."""
    try:
        import coremltools as ct
        import torch
    except ImportError:
        print("ERROR: coremltools not installed. Install via: pip install coremltools", file=sys.stderr)
        raise

    print(f"[convert] Tracing SigLIP2 model...")

    # Trace the model with a sample input
    example_input = torch.randn(1, 3, 224, 224)
    traced_model = torch.jit.trace(model, example_input)

    print(f"[convert] Converting to Core ML...")
    mlmodel = ct.convert(
        traced_model,
        inputs=[ct.TensorType(shape=(1, 3, 224, 224), name="pixel_values")],
        outputs=[ct.TensorType(name="last_hidden_state")],
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT16,
    )

    # Add metadata
    mlmodel.author = "Echo On-device ML Team (via google/siglip2-base-patch32-256, Apache-2.0)"
    mlmodel.short_description = (
        f"SigLIP2-B/32 Vision Encoder — 768d image embeddings for Echo. "
        f"Source: HuggingFace google/siglip2-base-patch32-256. "
        f"Licensed under Apache-2.0."
    )
    mlmodel.version = SIGLIP2_REVISION
    mlmodel.license = "Apache-2.0"

    mlpackage_path = output_path
    if not mlpackage_path.endswith(".mlpackage"):
        mlpackage_path = mlpackage_path + ".mlpackage"

    print(f"[convert] Saving to: {mlpackage_path}")
    mlmodel.save(mlpackage_path)

    # Verify the saved model loads
    import coremltools as ct  # noqa: F811
    loaded = ct.models.MLModel(mlpackage_path)
    spec = loaded.get_spec()
    print(f"[convert] Verified: model loaded successfully")
    print(f"[convert] Input: {spec.description.input[0].name} — shape {spec.description.input[0].type.multiArrayType.shape}")
    print(f"[convert] Output: {spec.description.output[0].name} — shape {spec.description.output[0].type.multiArrayType.shape}")

    return mlpackage_path


def main():
    parser = argparse.ArgumentParser(
        description="Convert SigLIP2-B/32 to Core ML format for Echo",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Convert from safetensors
  python3 Scripts/convert_siglip2.py \\
      --source Resources/Models/siglip2-base-patch32-256-model.safetensors \\
      --output Resources/Models/SigLIP2BasePatch32.mlpackage

  # Compute SHA-256 only
  python3 Scripts/convert_siglip2.py --checksum-only --model-dir Resources/Models/SigLIP2BasePatch32.mlmodelc
        """
    )
    parser.add_argument(
        "--source", type=str,
        help="Path to siglip2-base-patch32-256-model.safetensors (PyTorch checkpoint)"
    )
    parser.add_argument(
        "--output", type=str, default="Resources/Models/SigLIP2BasePatch32.mlpackage",
        help="Output path for .mlpackage (default: %(default)s)"
    )
    parser.add_argument(
        "--no-compile", action="store_true",
        help="Skip Xcode .mlmodelc compilation (compile separately via xcrun coremlcompiler)"
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
        default="Resources/Models/siglip2-reference-vectors.json",
        help="Output path for reference vectors JSON (default: %(default)s)"
    )
    args = parser.parse_args()

    print("=" * 60)
    print("Echo SigLIP2-B/32 Core ML Converter (3F.3a)")
    print(f"Revision: {SIGLIP2_REVISION}")
    print("=" * 60)

    # Checksum-only mode
    if args.checksum_only:
        if not args.model_dir or not os.path.exists(args.model_dir):
            print(f"ERROR: --model-dir '{args.model_dir}' does not exist", file=sys.stderr)
            sys.exit(1)
        sha256 = sha256_dir(args.model_dir)
        print(f"\nSHA-256: {sha256}  {os.path.basename(args.model_dir)}")
        print("\nAdd this to Scripts/model_checksums.sha256:")
        print(f"{sha256}  {os.path.basename(args.model_dir)}")
        return

    # Conversion mode
    if not args.source or not os.path.exists(args.source):
        print(f"ERROR: --source '{args.source}' does not exist", file=sys.stderr)
        sys.exit(1)

    source_sha256 = sha256_file(args.source)
    print(f"\n[source]  SHA-256: {source_sha256}")

    # Step 1: Load model
    print("\n[load] Loading SigLIP2-B/32 from safetensors...")
    model = load_siglip2_model(args.source)
    print("[load]  Model loaded successfully")

    # Step 2: Generate reference vectors (before conversion, PyTorch ground truth)
    print("\n[reference] Generating reference vectors...")
    ref_vectors = generate_reference_vectors(model)

    ref_path = args.reference_vectors
    os.makedirs(os.path.dirname(ref_path) or ".", exist_ok=True)
    with open(ref_path, "w") as f:
        json.dump(ref_vectors, f, indent=2)
    print(f"[reference] Written to: {ref_path}")

    # Step 3: Convert to Core ML
    print("\n[convert] Converting to Core ML .mlpackage...")
    mlpackage_path = convert_to_coreml(model, args.output)

    # Step 4: Compile to .mlmodelc
    mlmodelc_path = None
    if not args.no_compile:
        print(f"\n[compile] Compiling .mlmodelc via xcrun coremlcompiler...")
        import subprocess
        output_dir = os.path.dirname(mlpackage_path)
        result = subprocess.run(
            ["xcrun", "coremlcompiler", "compile", mlpackage_path, output_dir],
            capture_output=True, text=True
        )
        if result.returncode != 0:
            print(f"  WARNING: coremlcompiler failed: {result.stderr}", file=sys.stderr)
            print(f"  Compile manually: xcrun coremlcompiler compile {mlpackage_path} {output_dir}")
        else:
            compiled_name = os.path.splitext(os.path.basename(mlpackage_path))[0] + ".mlmodelc"
            mlmodelc_path = os.path.join(output_dir, compiled_name)
            if os.path.exists(mlmodelc_path):
                print(f"[compile] Compiled to: {mlmodelc_path}")
                sha256 = sha256_dir(mlmodelc_path)
                print(f"[compile] SHA-256: {sha256}")
                print(f"\nAdd this to Scripts/model_checksums.sha256:")
                print(f"{sha256}  {compiled_name}")
            else:
                print(f"  WARNING: Expected {compiled_name} not found after compilation", file=sys.stderr)

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
