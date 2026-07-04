#!/usr/bin/env bash
# ==========================================
# Echo · 回响 — 模型准备脚本 (v5.1b)
#
# 用途：下载 Echo 所需的端侧模型到 Echo/Resources/Models/
#
# 模型清单（v5.1b 最终可用方案，2026-07-04）：
#   1. MobileCLIP-B LT (image + text)  — Core ML, 286MB
#   2. multilingual-e5-small           — Core ML, 224MB
#   3. SenseVoice Small (CoreML + GGUF)— Core ML + GGUF, 373MB
#
# 总计：883MB
#
# 依赖：huggingface_hub（pip install huggingface_hub）
#
# 用法：
#   bash Scripts/prepare_models.sh
#
# 参考：
#   docs/02-architecture/技术选型文档.md v5.1b
#   docs/decisions/ADR-004-model-migration-2025.md
# ==========================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MODELS_DIR="$PROJECT_ROOT/Echo/Resources/Models"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

mkdir -p "$MODELS_DIR"

# ==========================================
# 1. MobileCLIP-B LT (Vision Encoder)
# Source: Apple official — apple/coreml-mobileclip
# Variant: B-LT (Best Latency/Throughput)
# ==========================================
download_mobileclip() {
    log_info "Step 1/3: MobileCLIP-B LT (Vision Encoder, 286MB)"

    local img="$MODELS_DIR/MobileCLIP-B-lt_image.mlpackage"
    local txt="$MODELS_DIR/MobileCLIP-B-lt_text.mlpackage"

    if [ -d "$img" ] && [ -d "$txt" ]; then
        log_info "  Already present"
        return 0
    fi

    log_info "  Downloading from apple/coreml-mobileclip ..."
    HF_ENDPOINT=https://hf-mirror.com MODELS_DIR="$MODELS_DIR" python3 -c "
import os, shutil
from huggingface_hub import snapshot_download
target = os.environ['MODELS_DIR']
path = snapshot_download('apple/coreml-mobileclip', local_dir=os.path.join(target, '_tmp'), resume_download=True)
for item in os.listdir(path):
    if 'mobileclip_blt' in item and item.endswith('.mlpackage'):
        new_name = item.replace('mobileclip_blt', 'MobileCLIP-B-lt')
        dst = os.path.join(target, new_name)
        if not os.path.exists(dst):
            shutil.copytree(os.path.join(path, item), dst)
            print(f'  {new_name}')
shutil.rmtree(os.path.join(target, '_tmp'), ignore_errors=True)
" 2>&1 || log_error "Failed."
}

# ==========================================
# 2. multilingual-e5-small (Text Embedding)
# Source: tamikisg/multilingual-e5-small-coreml
# 384-dim, 100+ languages
# ==========================================
download_e5() {
    log_info "Step 2/3: multilingual-e5-small (Text Embedding, 224MB)"

    local emb="$MODELS_DIR/MultilingualE5Small.mlpackage"
    if [ -d "$emb" ]; then
        log_info "  Already present"
        return 0
    fi

    log_info "  Downloading from tamikisg/multilingual-e5-small-coreml ..."
    HF_ENDPOINT=https://hf-mirror.com MODELS_DIR="$MODELS_DIR" python3 -c "
import os, shutil
from huggingface_hub import snapshot_download
target = os.environ['MODELS_DIR']
path = snapshot_download('tamikisg/multilingual-e5-small-coreml', local_dir=os.path.join(target, '_tmp'), resume_download=True)
for item in os.listdir(path):
    if 'E5' in item and item.endswith('.mlpackage'):
        dst = os.path.join(target, 'MultilingualE5Small.mlpackage')
        if not os.path.exists(dst):
            shutil.copytree(os.path.join(path, item), dst)
            print(f'  MultilingualE5Small.mlpackage')
shutil.rmtree(os.path.join(target, '_tmp'), ignore_errors=True)
" 2>&1 || log_error "Failed."
}

# ==========================================
# 3. SenseVoice Small (ASR)
# Source: FluidInference/sensevoice-small-coreml (CoreML INT8)
#         cstr/sensevoice-small-GGUF (GGUF Q4_K)
# ==========================================
download_sensevoice() {
    log_info "Step 3/3: SenseVoice Small (ASR, ~373MB)"

    local cml="$MODELS_DIR/SenseVoiceSmall_int8.mlmodelc"
    local gguf="$MODELS_DIR/sensevoice-small-q4_k.gguf"

    if [ -d "$cml" ] && [ -f "$gguf" ]; then
        log_info "  Already present"
        return 0
    fi

    # CoreML
    if [ ! -d "$cml" ]; then
        log_info "  Downloading CoreML INT8 ..."
        HF_ENDPOINT=https://hf-mirror.com MODELS_DIR="$MODELS_DIR" python3 -c "
import os, shutil
from huggingface_hub import snapshot_download
target = os.environ['MODELS_DIR']
path = snapshot_download('FluidInference/sensevoice-small-coreml', local_dir=os.path.join(target, '_tmp'), resume_download=True)
for item in os.listdir(path):
    full = os.path.join(path, item)
    if item.endswith('.mlmodelc'):
        dst = os.path.join(target, item)
        if not os.path.exists(dst):
            shutil.copytree(full, dst)
            print(f'  {item}')
shutil.rmtree(os.path.join(target, '_tmp'), ignore_errors=True)
" 2>&1 || log_error "CoreML failed."
    fi

    # GGUF
    if [ ! -f "$gguf" ]; then
        log_info "  Downloading GGUF Q4_K (129MB) ..."
        curl -fsSL -o "$gguf" \
            "https://hf-mirror.com/cstr/sensevoice-small-GGUF/resolve/main/sensevoice-small-q4_k.gguf" \
            -H "User-Agent: curl/8.0.0" || log_error "GGUF failed."
    fi
}

# ==========================================
# Main
# ==========================================
main() {
    echo ""
    log_info "Echo v5.1b Model Preparation"
    log_info "=============================="
    log_info "Target: $MODELS_DIR"
    echo ""

    download_mobileclip && echo ""
    download_e5 && echo ""
    download_sensevoice

    echo ""
    log_info "=============================="
    log_info "Bundle: $(du -sh "$MODELS_DIR" | cut -f1)"
    log_info "Run: xcodebuild test -only-testing:EchoTests/ModelBundleTests"
    log_info "=============================="
}

main
