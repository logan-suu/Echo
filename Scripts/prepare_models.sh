#!/usr/bin/env bash
# ==========================================
# Echo · 回响 — 模型准备脚本 (v5.1)
#
# 用途：下载、转换并安装 Echo 所需的三个端侧模型到
#       Echo/Resources/Models/ 目录。
#
# 模型清单（v5.1 刷新，2026-07-04）：
#   1. MobileCLIP2-S4 (Image + Text)  — Core ML, ~540MB INT8
#   2. Qwen3-Embedding-0.6B           — Core ML, ~400MB INT4
#   3. SenseVoice Small               — GGUF, ~129MB Q4_K
#
# 总计约 ~1,000MB（原 v4.6 方案 ~1,600MB，-37%）。
#
# 前置依赖：
#   - Python 3.10+ with coremltools>=8.3
#   - huggingface_hub (pip install huggingface_hub)
#   - git-lfs (for HuggingFace model downloads)
#
# 用法：
#   bash Scripts/prepare_models.sh [--skip-download] [--skip-convert] [--model {all|vision|embed|asr}]
#
# 对应规格：docs/02-architecture/技术选型文档.md v5.1 §1~3
# 任务：1.5 - 模型打包到 Bundle
# ==========================================

set -euo pipefail

# ==========================================
# Configuration
# ==========================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MODELS_DIR="$PROJECT_ROOT/Echo/Resources/Models"

SKIP_DOWNLOAD=false
SKIP_CONVERT=false
TARGET_MODEL="all"

# ==========================================
# Model Sources (HuggingFace)
# ==========================================

# MobileCLIP2-S4: Apple's official model
# Paper: https://arxiv.org/abs/2508.20691
# GitHub: https://github.com/apple/ml-mobileclip
MOBILECLIP2_HF="apple/mobileclip2-s4"                # Official PyTorch weights
# Community Core ML exports (verified):
# - coreyward/MobileCLIP2-S4-CoreML (FP16: 614MB+236MB)
# Convert with: coremltools 8.3+, remeber reparameterize_model()

# Qwen3-Embedding-0.6B: Alibaba's embedding model
# Blog: https://qwenlm.github.io/blog/qwen3-embedding/
MOBILECLIP2_HF="Qwen/Qwen3-Embedding-0.6B"           # Official PyTorch weights
# Community Core ML exports:
# - tooktang/Qwen3-Embedding-0.6B-CoreML (2.2GB bundle)
# - mlboydaisuke/Qwen3-Embedding-0.6B-CoreAI (~1.1GB fp16)

# SenseVoice Small: Alibaba FunASR
# GitHub: https://github.com/FunAudioLLM/SenseVoice
# GGUF runtime: https://github.com/lovemefan/SenseVoice.cpp
SENSEVOICE_GGUF_URL="https://huggingface.co/lovemefan/SenseVoice-small-onnx/resolve/main/sensevoice-small-q4_k.gguf"

# ==========================================
# Color output
# ==========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ==========================================
# Parse arguments
# ==========================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-download) SKIP_DOWNLOAD=true; shift ;;
        --skip-convert)  SKIP_CONVERT=true; shift ;;
        --model)         TARGET_MODEL="$2"; shift 2 ;;
        *)               log_error "Unknown argument: $1"; exit 1 ;;
    esac
done

# ==========================================
# Pre-flight checks
# ==========================================
preflight() {
    log_info "Echo v5.1 Model Preparation Script"
    log_info "=================================="
    log_info "Project root: $PROJECT_ROOT"
    log_info "Models dir:   $MODELS_DIR"
    log_info "Target:       $TARGET_MODEL"
    echo ""

    mkdir -p "$MODELS_DIR"

    if [ "$SKIP_DOWNLOAD" = false ]; then
        if ! command -v python3 &> /dev/null; then
            log_error "Python 3 is required but not found."
            exit 1
        fi
        log_info "Python 3: $(python3 --version)"

        if ! python3 -c "import huggingface_hub" 2>/dev/null; then
            log_warn "huggingface_hub not installed. Install with: pip install huggingface_hub"
            log_warn "Some models may fail to download."
        fi
    fi
}

# ==========================================
# Step 1: MobileCLIP2-S4
# ==========================================
prepare_mobileclip2_s4() {
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Step 1/3: MobileCLIP2-S4 (Vision Encoder)"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local image_model="$MODELS_DIR/MobileCLIP2-S4-Image.mlmodelc"
    local text_model="$MODELS_DIR/MobileCLIP2-S4-Text.mlmodelc"

    if [ -d "$image_model" ] && [ -d "$text_model" ]; then
        log_info "✓ MobileCLIP2-S4 模型已存在，跳过。"
        log_info "  Image: $(du -sh "$image_model" | cut -f1)"
        log_info "  Text:  $(du -sh "$text_model" | cut -f1)"
        return 0
    fi

    if [ "$SKIP_DOWNLOAD" = true ]; then
        log_warn "跳过下载（--skip-download）。"
        return 0
    fi

    log_info "下载 MobileCLIP2-S4 官方 PyTorch 权重..."
    log_warn "PyTorch 权重需转换为 Core ML 格式。"
    log_warn ""
    log_warn "手动转换步骤："
    log_warn "  1. git clone https://github.com/apple/ml-mobileclip"
    log_warn "  2. cd ml-mobileclip && pip install -e ."
    log_warn "  3. python Scripts/convert_mobileclip2_to_coreml.py"
    log_warn ""
    log_warn "社区 Core ML 导出参考："
    log_warn "  https://huggingface.co/coreyward/MobileCLIP2-S4-CoreML"
    log_warn ""

    # Attempt to download community Core ML export
    if python3 -c "import huggingface_hub" 2>/dev/null; then
        log_info "尝试从 HuggingFace 下载社区 Core ML 导出..."
        python3 -c "
from huggingface_hub import snapshot_download
import shutil, os

target = '$MODELS_DIR'
try:
    path = snapshot_download(
        'coreyward/MobileCLIP2-S4-CoreML',
        local_dir=os.path.join(target, '_mobileclip2_download'),
        local_dir_use_symlinks=False,
    )
    print(f'下载完成: {path}')
    # Move .mlpackage files to Models/
    for f in os.listdir(path):
        if f.endswith('.mlpackage'):
            src = os.path.join(path, f)
            dst = os.path.join(target, f)
            if not os.path.exists(dst):
                shutil.move(src, dst)
                print(f'  → {f}')
    # Cleanup
    shutil.rmtree(os.path.join(target, '_mobileclip2_download'), ignore_errors=True)
except Exception as e:
    print(f'下载失败: {e}')
    print('请手动转换或下载。')
" 2>&1 || log_warn "社区 Core ML 下载失败，需手动处理。"
    fi
}

# ==========================================
# Step 2: Qwen3-Embedding-0.6B
# ==========================================
prepare_qwen3_embedding() {
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Step 2/3: Qwen3-Embedding-0.6B (Text Embedding)"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local embed_model="$MODELS_DIR/Qwen3-Embedding-0.6B.mlmodelc"

    if [ -d "$embed_model" ]; then
        log_info "✓ Qwen3-Embedding-0.6B 模型已存在，跳过。"
        log_info "  Size: $(du -sh "$embed_model" | cut -f1)"
        return 0
    fi

    if [ "$SKIP_DOWNLOAD" = true ]; then
        log_warn "跳过下载（--skip-download）。"
        return 0
    fi

    log_info "Qwen3-Embedding-0.6B 社区 Core ML 导出:"
    log_info "  https://huggingface.co/tooktang/Qwen3-Embedding-0.6B-CoreML"
    log_info ""

    # Attempt to download community Core ML export
    if python3 -c "import huggingface_hub" 2>/dev/null; then
        log_info "尝试从 HuggingFace 下载社区 Core ML 导出..."
        python3 -c "
from huggingface_hub import snapshot_download
import shutil, os

target = '$MODELS_DIR'
try:
    path = snapshot_download(
        'tooktang/Qwen3-Embedding-0.6B-CoreML',
        local_dir=os.path.join(target, '_qwen3_download'),
        local_dir_use_symlinks=False,
    )
    print(f'下载完成: {path}')
    for f in os.listdir(path):
        if f.endswith('.mlpackage'):
            src = os.path.join(path, f)
            dst = os.path.join(target, 'Qwen3-Embedding-0.6B.mlpackage')
            if not os.path.exists(dst):
                shutil.move(src, dst)
                print(f'  → Qwen3-Embedding-0.6B.mlpackage')
    shutil.rmtree(os.path.join(target, '_qwen3_download'), ignore_errors=True)
except Exception as e:
    print(f'下载失败: {e}')
" 2>&1 || log_warn "社区 Core ML 下载失败，需手动处理。"
    fi
}

# ==========================================
# Step 3: SenseVoice Small
# ==========================================
prepare_sensevoice() {
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Step 3/3: SenseVoice Small (ASR Engine)"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local asr_model="$MODELS_DIR/sensevoice-small-q4_k.gguf"

    if [ -f "$asr_model" ]; then
        local size=$(du -sh "$asr_model" | cut -f1)
        log_info "✓ SenseVoice Small 模型已存在 ($size)，跳过。"
        return 0
    fi

    if [ "$SKIP_DOWNLOAD" = true ]; then
        log_warn "跳过下载（--skip-download）。"
        return 0
    fi

    log_info "下载 SenseVoice Small Q4_K GGUF (~129MB)..."
    log_info "来源: $SENSEVOICE_GGUF_URL"
    log_info "GGUF 运行时: https://github.com/lovemefan/SenseVoice.cpp"

    if command -v curl &> /dev/null; then
        curl -L -o "$asr_model" "$SENSEVOICE_GGUF_URL" --progress-bar && \
            log_info "✓ 下载完成: $(du -sh "$asr_model" | cut -f1)" || \
            log_error "下载失败，请手动下载。"
    elif command -v wget &> /dev/null; then
        wget -O "$asr_model" "$SENSEVOICE_GGUF_URL" && \
            log_info "✓ 下载完成: $(du -sh "$asr_model" | cut -f1)" || \
            log_error "下载失败，请手动下载。"
    else
        log_error "curl 或 wget 未安装，无法下载。"
    fi
}

# ==========================================
# Summary
# ==========================================
summary() {
    echo ""
    log_info "========================================="
    log_info "Model Preparation Complete"
    log_info "========================================="

    local total_size=0
    for model in "$MODELS_DIR"/*; do
        if [ -e "$model" ] && [ "$(basename "$model")" != ".gitkeep" ]; then
            local size=$(du -sh "$model" | cut -f1)
            echo "  $(basename "$model")  $size"
        fi
    done

    echo ""
    if [ -d "$MODELS_DIR/MobileCLIP2-S4-Image.mlmodelc" ] && \
       [ -d "$MODELS_DIR/Qwen3-Embedding-0.6B.mlmodelc" ] && \
       [ -f "$MODELS_DIR/sensevoice-small-q4_k.gguf" ]; then
        log_info "✅ 所有模型已就绪。运行 swift test --filter ModelBundleTests 验证。"
    else
        log_warn "⚠️  部分模型缺失。请检查上述输出中的错误。"
        log_warn "模型文件不入 Git — CI 环境需运行此脚本。"
    fi
}

# ==========================================
# Main
# ==========================================
main() {
    preflight

    case "$TARGET_MODEL" in
        all|vision) prepare_mobileclip2_s4 ;;&
        all|embed)  prepare_qwen3_embedding ;;&
        all|asr)    prepare_sensevoice ;;&
    esac

    summary
}

main
