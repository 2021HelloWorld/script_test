#!/usr/bin/env bash
# =============================================================================
# 00_install_cuda.sh — 安装 CUDA Toolkit 12.8（宿主机）
# 运行位置：宿主机
# 运行时机：首次部署，在安装 NVIDIA 驱动之后、执行 02_setup_cdi.sh 之前
# 前置条件：NVIDIA 驱动 580.159.03 已安装
# =============================================================================
set -euo pipefail

# ---------- 颜色输出 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---------- 常量 ----------
CUDA_VERSION="12.8"
CUDA_PKG="cuda-toolkit-12-8"
CUDA_DEB="cuda-repo-ubuntu2204-12-8-local_12.8.0-570.86.10-1_amd64.deb"
CUDA_URL="https://developer.download.nvidia.com/compute/cuda/12.8.0/local_installers/${CUDA_DEB}"
CUDA_PIN_URL="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-ubuntu2204.pin"
CUDA_KEYRING_SRC="/var/cuda-repo-ubuntu2204-12-8-local/cuda-485B8195-keyring.gpg"
CUDA_INSTALL_PATH="/usr/local/cuda-${CUDA_VERSION}"

# ---------- 前置检查：驱动 ----------
info "检查 NVIDIA 驱动..."
if ! command -v nvidia-smi &>/dev/null; then
    error "未检测到 nvidia-smi，请先安装 NVIDIA 驱动（推荐 580.159.03），再运行本脚本"
fi
REQUIRED_DRIVER="580.159.03"
DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
info "检测到驱动版本：$DRIVER_VER"
if [ "$DRIVER_VER" != "$REQUIRED_DRIVER" ]; then
    error "驱动版本不匹配（当前：$DRIVER_VER，要求：$REQUIRED_DRIVER），请安装指定版本后重试"
fi
info "驱动版本 $DRIVER_VER ✓"

# ---------- 检查是否已安装 ----------
if [ -f "${CUDA_INSTALL_PATH}/bin/nvcc" ]; then
    INSTALLED_VER=$("${CUDA_INSTALL_PATH}/bin/nvcc" --version | grep -oP 'release \K[\d.]+')
    info "CUDA ${INSTALLED_VER} 已安装于 ${CUDA_INSTALL_PATH}，跳过安装"
    # 仍需确保环境变量已写入 .bashrc
    _setup_env
    exit 0
fi

# ---------- 检查是否有旧版 CUDA 冲突 ----------
info "检查已安装的 CUDA 版本..."
EXISTING=$(dpkg -l | grep -E '^ii\s+cuda' | awk '{print $2}' || true)
if [ -n "$EXISTING" ]; then
    warn "检测到以下已安装的 CUDA 相关包："
    echo "$EXISTING"
    warn "若上述版本与 12.8 冲突，请手动卸载后重试（避免自动删除影响现有环境）"
    warn "可使用：sudo apt remove --purge <包名>"
    read -r -p "是否仍然继续安装 CUDA 12.8？[y/N] " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { info "已取消"; exit 0; }
fi

# ---------- 下载 .deb 包（带本地缓存检查）----------
TMPDIR="${TMPDIR:-/tmp}"
DEB_PATH="${TMPDIR}/${CUDA_DEB}"

if [ -f "$DEB_PATH" ]; then
    info "检测到本地缓存：${DEB_PATH}，跳过下载"
else
    info "下载 CUDA 12.8 安装包（约 3 GB，请耐心等待）..."
    wget -c -O "$DEB_PATH" "$CUDA_URL" || error "下载失败，请检查网络或手动下载到 ${DEB_PATH}"
    info "下载完成 ✓"
fi

# ---------- 配置 apt pin ----------
info "配置 apt pin 文件..."
wget -q -O /tmp/cuda-ubuntu2204.pin "$CUDA_PIN_URL" \
    || warn "pin 文件下载失败，继续安装（非致命）"
[ -f /tmp/cuda-ubuntu2204.pin ] && sudo mv /tmp/cuda-ubuntu2204.pin /etc/apt/preferences.d/cuda-repository-pin-600

# ---------- 安装 .deb 包并导入 GPG Key ----------
info "安装 CUDA 本地仓库包..."
sudo dpkg -i "$DEB_PATH"

if [ -f "${CUDA_KEYRING_SRC}" ]; then
    sudo cp "${CUDA_KEYRING_SRC}" /usr/share/keyrings/
    info "GPG 密钥已导入 ✓"
else
    warn "未找到预期的 GPG 密钥文件 ${CUDA_KEYRING_SRC}，apt update 时可能报错"
fi

sudo apt update

# ---------- 安装 CUDA Toolkit ----------
info "安装 ${CUDA_PKG}..."
sudo apt install -y "${CUDA_PKG}"
info "${CUDA_PKG} 安装完成 ✓"

# ---------- 配置环境变量 ----------
_setup_env() {
    local BASHRC="$HOME/.bashrc"
    local PATH_LINE="export PATH=${CUDA_INSTALL_PATH}/bin:\$PATH"
    local LD_LINE="export LD_LIBRARY_PATH=${CUDA_INSTALL_PATH}/lib64:\$LD_LIBRARY_PATH"

    if grep -qF "${CUDA_INSTALL_PATH}/bin" "$BASHRC"; then
        info "PATH 已包含 CUDA 路径，跳过写入"
    else
        echo "$PATH_LINE" >> "$BASHRC"
        info "已写入 PATH → ${BASHRC}"
    fi

    if grep -qF "${CUDA_INSTALL_PATH}/lib64" "$BASHRC"; then
        info "LD_LIBRARY_PATH 已包含 CUDA 路径，跳过写入"
    else
        echo "$LD_LINE" >> "$BASHRC"
        info "已写入 LD_LIBRARY_PATH → ${BASHRC}"
    fi
}

_setup_env

# ---------- 验证 ----------
info "验证安装..."
export PATH="${CUDA_INSTALL_PATH}/bin:$PATH"
if "${CUDA_INSTALL_PATH}/bin/nvcc" --version; then
    info "CUDA ${CUDA_VERSION} 安装验证通过 ✓"
else
    warn "nvcc 验证失败，请重新打开终端（source ~/.bashrc）后手动执行 nvcc --version"
fi

info "===== 00_install_cuda.sh 执行完成 ====="
info "请执行 'source ~/.bashrc' 或重新打开终端使环境变量生效"
info "下一步：运行 02_setup_cdi.sh"
