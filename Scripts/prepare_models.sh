#!/usr/bin/env bash
# ==========================================
# Echo · 回响 — 模型准备脚本 (v6.0)
#
# 用途：下载 Echo 所需的端侧模型到 Echo/Resources/Models/，
#       固定 revision + SHA256 校验，确保可复现交付（R-4.1/R-4.2）。
#
# 模型清单（v6.0，调研报告决策 1~4 后路线，2026-08-01）：
#   1. multilingual-e5-small           — Core ML, 224MB  (文本嵌入，工程暂定)
#   2. Whisper small GGUF (Q4_K)       — GGUF, ~244MB    (ASR，替代 SenseVoice)
#   3. SigLIP2-B/32 checkpoint         — PyTorch, ~1.5GB (视觉，替代 MobileCLIP，转换源)
#
# 已移除（许可阻断/保守排除）：
#   - MobileCLIP-B LT  — 公共权重禁止商业使用（调研报告决策 4 淘汰）
#   - SenseVoice Small — FunASR 自定义条款，保守短名单排除
#
# 依赖：huggingface_hub（pip install huggingface_hub）
#
# 用法：
#   bash Scripts/prepare_models.sh                  # 下载 + 校验
#   bash Scripts/prepare_models.sh --generate-checksums  # 下载 + 生成校验清单
#   bash Scripts/prepare_models.sh --verify-only    # 仅校验已存在文件
#
# 参考：
#   docs/02-architecture/技术选型文档.md
#   docs/decisions/ADR-004-model-migration-2025.md
#   Echo dev-1.0 缺陷修复计划.md Phase R-4
# ==========================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MODELS_DIR="$PROJECT_ROOT/Echo/Resources/Models"
CHECKSUMS_FILE="$SCRIPT_DIR/model_checksums.sha256"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# R-4.1: 失败即返回非零（替代旧的 `|| log_error` 静默吞错）
die() { log_error "$*"; return 1; }

MODE="download"
case "${1:-}" in
    --generate-checksums) MODE="generate" ;;
    --verify-only)        MODE="verify" ;;
    "")                   MODE="download" ;;
    *) die "Unknown option: $1 (use --generate-checksums or --verify-only)"; exit 1 ;;
esac

mkdir -p "$MODELS_DIR"

# ==========================================
# SHA256 校验工具（R-4.2）
# ==========================================

# 计算文件的 SHA256（跨平台：shasum / sha256sum）
compute_sha256() {
    local file="$1"
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | cut -d' ' -f1
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | cut -d' ' -f1
    else
        die "No SHA256 tool available (need shasum or sha256sum)"
        return 1
    fi
}

# 从校验清单读取期望的 SHA256（格式：<sha256>  <filename>）
expected_sha256() {
    local filename="$1"
    [ -f "$CHECKSUMS_FILE" ] || return 1
    grep -E "^[a-f0-9]{64}[[:space:]]+$filename\$" "$CHECKSUMS_FILE" | cut -d' ' -f1 | head -1
}

# 校验文件 SHA256。generate 模式写入清单，download/verify 模式比对。
verify_or_record() {
    local file="$1"
    local filename
    filename="$(basename "$file")"

    [ -e "$file" ] || { log_error "Missing: $file"; return 1; }

    local actual
    actual="$(compute_sha256 "$file")" || return 1

    if [ "$MODE" = "generate" ]; then
        # 写入/更新清单（移除旧条目后追加）
        if [ -f "$CHECKSUMS_FILE" ]; then
            grep -vE "[[:space:]]$filename\$" "$CHECKSUMS_FILE" > "$CHECKSUMS_FILE.tmp" || true
            mv "$CHECKSUMS_FILE.tmp" "$CHECKSUMS_FILE"
        fi
        echo "$actual  $filename" >> "$CHECKSUMS_FILE"
        log_info "  Recorded checksum: $actual  $filename"
        return 0
    fi

    # download / verify 模式：比对期望值
    local expected
    expected="$(expected_sha256 "$filename")" || true
    if [ -z "$expected" ]; then
        log_error "No checksum entry for $filename in $CHECKSUMS_FILE"
        log_error "Run with --generate-checksums to populate the manifest."
        return 1
    fi
    if [ "$actual" != "$expected" ]; then
        log_error "SHA256 MISMATCH for $filename"
        log_error "  expected: $expected"
        log_error "  actual:   $actual"
        return 1
    fi
    log_info "  Checksum OK: $filename"
    return 0
}

# ==========================================
# 1. multilingual-e5-small (Text Embedding)
# Source: tamikisg/multilingual-e5-small-coreml
# 384-dim, 100+ languages. 工程暂定（法律待审）。
# ==========================================
E5_REPO="tamikisg/multilingual-e5-small-coreml"
E5_REVISION="main"  # TODO (R-4.2): pin to immutable commit hash for reproducibility

download_e5() {
    log_info "Step 1/3: multilingual-e5-small (Text Embedding, 224MB)"

    local emb="$MODELS_DIR/MultilingualE5Small.mlpackage"
    if [ -d "$emb" ] && [ "$MODE" != "generate" ]; then
        log_info "  Already present — verifying checksum"
        verify_or_record "$emb/Manifest.json" || return 1
        return 0
    fi

    [ "$MODE" = "verify" ] && { log_error "Missing: $emb"; return 1; }

    log_info "  Downloading from $E5_REPO @ $E5_REVISION ..."
    HF_ENDPOINT=https://hf-mirror.com MODELS_DIR="$MODELS_DIR" E5_REPO="$E5_REPO" E5_REVISION="$E5_REVISION" python3 -c "
import os, shutil, sys
from huggingface_hub import snapshot_download
target = os.environ['MODELS_DIR']
repo = os.environ['E5_REPO']
revision = os.environ['E5_REVISION']
path = snapshot_download(repo, revision=revision, local_dir=os.path.join(target, '_tmp'), resume_download=True)
found = False
for item in os.listdir(path):
    if item.endswith('.mlpackage'):
        dst = os.path.join(target, 'MultilingualE5Small.mlpackage')
        if os.path.exists(dst):
            shutil.rmtree(dst)
        shutil.copytree(os.path.join(path, item), dst)
        print(f'  MultilingualE5Small.mlpackage')
        found = True
shutil.rmtree(os.path.join(target, '_tmp'), ignore_errors=True)
sys.exit(0 if found else 1)
" 2>&1 || { log_error "E5 download failed"; return 1; }

    verify_or_record "$emb/Manifest.json" || return 1
}

# ==========================================
# 2. Whisper small GGUF (ASR)
# Source: ggml-org/whisper.cpp (whisper GGUF models)
# 替代 SenseVoice（保守短名单排除）。法律状态：工件链需分别审查。
# ==========================================
WHISPER_GGUF_URL="https://hf-mirror.com/ggml-org/whisper.cpp/resolve/main/ggml-small-q4_k.bin"
WHISPER_GGUF_FILE="whisper-small-q4_k.gguf"

download_whisper() {
    log_info "Step 2/3: Whisper small GGUF Q4_K (ASR, ~244MB)"

    local gguf="$MODELS_DIR/$WHISPER_GGUF_FILE"
    if [ -f "$gguf" ] && [ "$MODE" != "generate" ]; then
        log_info "  Already present — verifying checksum"
        verify_or_record "$gguf" || return 1
        return 0
    fi

    [ "$MODE" = "verify" ] && { log_error "Missing: $gguf"; return 1; }

    log_info "  Downloading Whisper GGUF Q4_K ..."
    # R-4.1: curl 失败即返回非零（-f 使 HTTP 错误退出非零）
    curl -fsSL -o "$gguf" "$WHISPER_GGUF_URL" \
        -H "User-Agent: curl/8.0.0" || { log_error "Whisper GGUF download failed"; return 1; }

    verify_or_record "$gguf" || return 1
}

# ==========================================
# 3. SigLIP2-B/32 checkpoint (Vision, conversion source)
# Source: google/siglip2-base-patch32-256 (Apache-2.0)
# 替代 MobileCLIP（许可阻断）。需自转换 Core ML（R-3.2）。
# ==========================================
SIGLIP2_REPO="google/siglip2-base-patch32-256"
SIGLIP2_REVISION="main"  # TODO (R-4.2): pin to immutable commit hash

download_siglip2() {
    log_info "Step 3/3: SigLIP2-B/32 checkpoint (Vision, ~1.5GB, conversion source)"

    local ckpt="$MODELS_DIR/siglip2-base-patch32-256"
    if [ -d "$ckpt" ] && [ "$MODE" != "generate" ]; then
        log_info "  Already present — verifying checksum"
        verify_or_record "$ckpt/model.safetensors" || return 1
        return 0
    fi

    [ "$MODE" = "verify" ] && { log_error "Missing: $ckpt"; return 1; }

    log_warn "  SigLIP2 is a conversion source (R-3.2). Core ML conversion required before production use."
    log_info "  Downloading from $SIGLIP2_REPO @ $SIGLIP2_REVISION ..."
    HF_ENDPOINT=https://hf-mirror.com MODELS_DIR="$MODELS_DIR" SIGLIP2_REPO="$SIGLIP2_REPO" SIGLIP2_REVISION="$SIGLIP2_REVISION" python3 -c "
import os, shutil, sys
from huggingface_hub import snapshot_download
target = os.environ['MODELS_DIR']
repo = os.environ['SIGLIP2_REPO']
revision = os.environ['SIGLIP2_REVISION']
dst = os.path.join(target, 'siglip2-base-patch32-256')
path = snapshot_download(repo, revision=revision, local_dir=dst, resume_download=True)
print(f'  siglip2-base-patch32-256')
sys.exit(0 if os.path.exists(os.path.join(dst, 'model.safetensors')) else 1)
" 2>&1 || { log_error "SigLIP2 download failed"; return 1; }

    verify_or_record "$ckpt/model.safetensors" || return 1
}

# ==========================================
# Main — R-4.1: && 链接，任一失败即中止
# ==========================================
main() {
    echo ""
    log_info "Echo v6.0 Model Preparation (mode: $MODE)"
    log_info "======================================"
    log_info "Target: $MODELS_DIR"
    echo ""

    # R-4.1: && 链接，任一下载/校验失败即中止并退出非零
    if ! { download_e5 && echo "" && download_whisper && echo "" && download_siglip2; }; then
        log_error "Model preparation failed (mode: $MODE)"
        exit 1
    fi

    echo ""
    log_info "======================================"
    log_info "Bundle: $(du -sh "$MODELS_DIR" | cut -f1)"
    if [ "$MODE" = "generate" ]; then
        log_info "Checksums written to: $CHECKSUMS_FILE"
    fi
    log_info "Verify: bash Scripts/prepare_models.sh --verify-only"
    log_info "======================================"
}

main
