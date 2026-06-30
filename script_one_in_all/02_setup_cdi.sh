#!/usr/bin/env bash
# =============================================================================
# 02_setup_cdi.sh — 安装 nvidia-container-toolkit 并生成 CDI 规格文件
# 运行位置：宿主机
# 运行时机：首次部署 / 重装驱动后
# =============================================================================
set -euo pipefail

# ---------- 颜色输出 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---------- 检查 docker 版本 ≥ 25.0（CDI 支持要求）----------
info "检查 Docker 版本..."
docker --version || error "Docker 未安装，请先安装 Docker（版本 ≥ 25.0）"
DOCKER_VER=$(docker --version | grep -oP '\d+\.\d+' | head -1)
DOCKER_MAJOR=$(echo "$DOCKER_VER" | cut -d. -f1)
if [ "$DOCKER_MAJOR" -lt 25 ]; then
    error "Docker 版本 $DOCKER_VER 不满足要求，CDI 需要 Docker ≥ 25.0，请升级"
fi
info "Docker 版本 $DOCKER_VER ✓"

# ---------- 安装 nvidia-container-toolkit ----------
if command -v nvidia-ctk &>/dev/null; then
    info "nvidia-ctk 已安装（$(nvidia-ctk --version 2>&1 | head -1)），跳过安装"
else
    warn "nvidia-ctk 未找到，开始安装 nvidia-container-toolkit..."

    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

    sudo apt update
    sudo apt install -y nvidia-container-toolkit
    info "nvidia-container-toolkit 安装完成 ✓"
fi

# ---------- 生成 CDI 规格文件 ----------
info "生成 CDI 规格文件到 /etc/cdi/nvidia.yaml ..."
sudo mkdir -p /etc/cdi
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
info "CDI 规格文件生成完成 ✓"

# ---------- 验证 ----------
info "验证 CDI 规格文件..."
ls -lh /etc/cdi/nvidia.yaml

MATCH_COUNT=$(grep -cE 'nvidia_icd|libGLX_nvidia|libnvidia-glcore|libEGL_nvidia|libnvidia-vulkan' /etc/cdi/nvidia.yaml || true)
info "关键库匹配数量：$MATCH_COUNT"

info "CDI 设备列表："
sudo nvidia-ctk cdi list

info "Docker CDI 信息："
docker info 2>/dev/null | grep -iE 'runtime|cdi' || warn "未在 docker info 中找到 CDI 相关信息，可能需要重启 Docker daemon"

info "===== 02_setup_cdi.sh 执行完成 ====="
