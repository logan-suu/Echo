#!/usr/bin/env bash
# ==========================================
# Echo — Model Preparation Script (v6.0)
#
# Purpose: download Echo's on-device models into Echo/Resources/Models/,
#          with pinned revisions + SHA256 verification for reproducible
#          delivery (R-4.1/R-4.2).
#
# Model manifest (v6.0, route per research report decisions 1-4, 2026-08-01):
#   1. multilingual-e5-small           — Core ML, 224MB  (text embedding, engineering tentative)
#   2. Whisper tiny GGUF (Q5_1)        — GGUF, ~39MB     (ASR, R-5.4 approved; small = challenger)
#   3. SigLIP2-B/32 checkpoint         — PyTorch, ~1.5GB (vision, replaces MobileCLIP, conversion source)
#
# Removed (license blocked / conservative exclusion):
#   - MobileCLIP-B LT  — public weights prohibit commercial use (decision 4 retired)
#   - SenseVoice Small — FunASR custom terms, conservative shortlist exclusion
#
# Dependency: huggingface_hub (pip install huggingface_hub)
#
# Usage:
#   bash Scripts/prepare_models.sh                       # download + verify
#   bash Scripts/prepare_models.sh --generate-checksums  # download + generate checksum manifest
#   bash Scripts/prepare_models.sh --verify-only         # verify existing files only
#
# References:
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

# R-4.1: fail-fast — propagate non-zero (replaces the old silent `|| log_error`)
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
# SHA256 verification utilities (R-4.2)
# ==========================================

# Compute a file's SHA256 (cross-platform: shasum / sha256sum)
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

# Escape regex metacharacters so a filename matches literally in grep -E (#2).
escape_regex() {
    printf '%s' "$1" | sed 's/[.[\*^$()+?{|\\]/\\&/g'
}

# Read the expected SHA256 from the manifest (format: <sha256>  <filename>)
expected_sha256() {
    local filename="$1"
    [ -f "$CHECKSUMS_FILE" ] || return 1
    local escaped
    escaped="$(escape_regex "$filename")"
    grep -E "^[a-f0-9]{64}[[:space:]]+$escaped\$" "$CHECKSUMS_FILE" | cut -d' ' -f1 | head -1
}

# Verify a file's SHA256. generate mode writes the manifest; download/verify mode compares.
verify_or_record() {
    local file="$1"
    local filename
    filename="$(basename "$file")"

    [ -e "$file" ] || { log_error "Missing: $file"; return 1; }

    local actual
    actual="$(compute_sha256 "$file")" || return 1

    if [ "$MODE" = "generate" ]; then
        # Write/update the manifest (drop any stale entry, then append)
        local escaped
        escaped="$(escape_regex "$filename")"
        if [ -f "$CHECKSUMS_FILE" ]; then
            grep -vE "[[:space:]]$escaped\$" "$CHECKSUMS_FILE" > "$CHECKSUMS_FILE.tmp" || true
            mv "$CHECKSUMS_FILE.tmp" "$CHECKSUMS_FILE"
        fi
        echo "$actual  $filename" >> "$CHECKSUMS_FILE"
        log_info "  Recorded checksum: $actual  $filename"
        return 0
    fi

    # download / verify mode: compare against the expected value
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
# 384-dim, 100+ languages. Engineering tentative (legal review pending).
# ==========================================
E5_REPO="tamikisg/multilingual-e5-small-coreml"
E5_REVISION="main"  # TODO (R-4.2): pin to immutable commit hash for reproducibility

download_e5() {
    log_info "Step 1/3: multilingual-e5-small (Text Embedding, 224MB)"

    local emb="$MODELS_DIR/MultilingualE5Small.mlpackage"
    if [ -d "$emb" ] && [ "$MODE" != "generate" ]; then
        log_info "  Already present — verifying checksum"
        verify_or_record "$emb/Manifest.json" || return 1
        verify_or_record "$MODELS_DIR/tokenizer.json" || { log_error "gate-reason: missing-tokenizer"; return 1; }
        return 0
    fi

    [ "$MODE" = "verify" ] && { log_error "Missing: $emb"; log_error "gate-reason: missing-e5"; return 1; }

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
    if item == 'tokenizer.json':
        dst = os.path.join(target, 'tokenizer.json')
        shutil.copyfile(os.path.join(path, item), dst)
        print(f'  tokenizer.json')
        found = True
shutil.rmtree(os.path.join(target, '_tmp'), ignore_errors=True)
sys.exit(0 if found else 1)
" 2>&1 || { log_error "E5 download failed"; return 1; }

    verify_or_record "$emb/Manifest.json" || return 1
    verify_or_record "$MODELS_DIR/tokenizer.json" || return 1
}

# ==========================================
# 2. Whisper tiny GGUF (ASR, R-5.4)
# Source: ggml-org/whisper.cpp (whisper GGUF models)
# Replaces SenseVoice (conservative shortlist exclusion).
# Legal status: each artifact in the chain requires separate review.
# ==========================================
# R-5.4 (2026-08-01): whisper tiny approved (~39MB GGUF). small stays as
# challenger for later evaluation. Model artifact must match the decision.
WHISPER_GGUF_URL="https://hf-mirror.com/ggml-org/whisper.cpp/resolve/main/ggml-tiny-q5_1.bin"
WHISPER_GGUF_FILE="whisper-tiny-q5_1.gguf"

download_whisper() {
    log_info "Step 2/3: Whisper tiny GGUF Q5_1 (ASR, ~39MB)"

    local gguf="$MODELS_DIR/$WHISPER_GGUF_FILE"
    if [ -f "$gguf" ] && [ "$MODE" != "generate" ]; then
        log_info "  Already present — verifying checksum"
        verify_or_record "$gguf" || return 1
        return 0
    fi

    [ "$MODE" = "verify" ] && { log_error "Missing: $gguf"; return 1; }

    log_info "  Downloading Whisper tiny GGUF Q5_1 ..."
    # R-4.1: curl -f makes HTTP errors exit non-zero (fail-fast)
    curl -fsSL -o "$gguf" "$WHISPER_GGUF_URL" \
        -H "User-Agent: curl/8.0.0" || { log_error "Whisper GGUF download failed"; return 1; }

    verify_or_record "$gguf" || return 1
}

# ==========================================
# 3. SigLIP2-B/32 checkpoint (Vision, conversion source)
# Source: google/siglip2-base-patch32-256 (Apache-2.0)
# Replaces MobileCLIP (license blocked). Requires Core ML self-conversion (R-3.2).
# ==========================================
SIGLIP2_REPO="google/siglip2-base-patch32-256"
SIGLIP2_REVISION="94dffa8cb1179de3e03f091dbc3917e5d5a9ae84"  # pinned immutable commit (DEF-35-001 closed; handover plan §2.3)

download_siglip2() {
    log_info "Step 3/3: SigLIP2-B/32 checkpoint (Vision, ~1.5GB, conversion source)"

    local ckpt="$MODELS_DIR/siglip2-base-patch32-256"
    if [ -d "$ckpt" ] && [ "$MODE" != "generate" ]; then
        log_info "  Already present — verifying checksum"
        verify_or_record "$ckpt/model.safetensors" || return 1
        return 0
    fi

    [ "$MODE" = "verify" ] && { log_error "Missing: $ckpt"; log_error "gate-reason: missing-vision"; return 1; }

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
# Main — R-4.1: && chaining, abort on any failure
# ==========================================
main() {
    echo ""
    log_info "Echo v6.0 Model Preparation (mode: $MODE)"
    log_info "======================================"
    log_info "Target: $MODELS_DIR"
    echo ""

    # R-4.1: && chaining — abort with non-zero exit on any download/verify failure
    if ! { download_e5 && echo "" && download_whisper && echo "" && download_siglip2; }; then
        log_error "Model preparation failed (mode: $MODE)"
        exit 1
    fi

    # WP7 9g/9h: license notice gate——verify 模式下检查许可声明文件存在
    if [ "$MODE" = "verify" ]; then
        NOTICE_FILE="$PROJECT_ROOT/Echo/Resources/Models/LICENSE-NOTICE.md"
        if [ ! -f "$NOTICE_FILE" ]; then
            log_error "gate-reason: missing-notice"
            log_error "Missing license notice: $NOTICE_FILE"
            exit 1
        fi
        log_info "  License notice OK: $NOTICE_FILE"
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
