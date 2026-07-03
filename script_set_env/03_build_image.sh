#!/usr/bin/env bash
# =============================================================================
# 03_build_image.sh — 检查并构建 easim Docker 镜像
# 运行位置：宿主机
# 运行时机：首次部署，或需要重新构建镜像时
# 前置条件：01_install_host_deps.sh、02_setup_cdi.sh 已执行
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ---------- 颜色输出 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

DOCKERFILE_PATH="${EASIM_HOST_PATH}/${DOCKERFILE}"
DEFAULT_BASE_IMAGE="nvidia/cuda:12.8.0-devel-ubuntu22.04"
DEFAULT_PYTORCH_INDEX_URL="https://download.pytorch.org/whl/cu128"
LEGACY_BASE_IMAGE="nvidia/cuda:13.0.0-devel-ubuntu22.04"
LEGACY_PYTORCH_INDEX_URL="https://download.pytorch.org/whl/cu130"

# ---------- 检查 easim 路径 ----------
if [ ! -d "$EASIM_HOST_PATH" ]; then
    error "EASIM_HOST_PATH 不存在：$EASIM_HOST_PATH\n  请先运行 setup.sh 填写正确路径"
fi

# ---------- 检查 Dockerfile ----------
if [ -f "$DOCKERFILE_PATH" ]; then
    info "Dockerfile 已存在：$DOCKERFILE_PATH"
    if grep -q "$LEGACY_BASE_IMAGE" "$DOCKERFILE_PATH" || grep -q "$LEGACY_PYTORCH_INDEX_URL" "$DOCKERFILE_PATH"; then
        warn "检测到旧 CUDA/PyTorch 默认源，自动更新为 CUDA 12.8 / cu128..."
        sed -i \
            -e "s|ARG BASE_IMAGE=${LEGACY_BASE_IMAGE}|ARG BASE_IMAGE=${DEFAULT_BASE_IMAGE}|g" \
            -e "s|ARG PYTORCH_INDEX_URL=${LEGACY_PYTORCH_INDEX_URL}|ARG PYTORCH_INDEX_URL=${DEFAULT_PYTORCH_INDEX_URL}|g" \
            "$DOCKERFILE_PATH"
        info "Dockerfile 默认镜像/源已更新 ✓"
    fi
else
    error "Dockerfile 不存在：$DOCKERFILE_PATH"
fi

# ---------- 检查镜像是否已存在 ----------
if docker image inspect "$IMAGE_NAME" &>/dev/null; then
    info "镜像 ${IMAGE_NAME} 已存在，跳过构建"
    info "如需重新构建，请先执行：docker rmi ${IMAGE_NAME}"
    exit 0
fi

# ---------- 构建镜像 ----------
info "开始构建镜像 ${IMAGE_NAME}（时间较长，请耐心等待）..."
info "构建上下文：${EASIM_HOST_PATH}"
info "Dockerfile：${DOCKERFILE_PATH}"

docker build \
    -f "$DOCKERFILE_PATH" \
    -t "$IMAGE_NAME" \
    "$EASIM_HOST_PATH"

info "镜像 ${IMAGE_NAME} 构建完成 ✓"
info "===== 03_build_image.sh 执行完成 ====="
info "下一步：运行 04_start_container.sh"
