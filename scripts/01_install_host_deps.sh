#!/usr/bin/env bash
# =============================================================================
# 01_install_host_deps.sh — 安装宿主机依赖（Docker 29.1.3 + tmux）
# 运行位置：宿主机
# 运行时机：首次部署，在安装 CUDA 之后、执行 02_setup_cdi.sh 之前
# =============================================================================
set -euo pipefail

# ---------- 颜色输出 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---------- 常量 ----------
REQUIRED_VERSION="29.1.3"
VERSION_STRING="5:${REQUIRED_VERSION}-1~ubuntu.22.04~jammy"

# ---------- 检查是否已安装 ----------
if command -v docker &>/dev/null; then
    INSTALLED=$(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1)
    if [ "$INSTALLED" = "$REQUIRED_VERSION" ]; then
        info "Docker ${INSTALLED} 已安装，跳过安装"
        _add_user_to_group
        exit 0
    else
        warn "检测到 Docker ${INSTALLED}，需要版本 ${REQUIRED_VERSION}"
        read -r -p "是否卸载当前版本并安装 ${REQUIRED_VERSION}？[y/N] " CONFIRM
        [[ "$CONFIRM" =~ ^[Yy]$ ]] || { info "已取消"; exit 0; }
        sudo apt remove --purge -y docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
        info "旧版本已卸载 ✓"
    fi
fi

# ---------- 安装系统依赖 ----------
info "安装依赖..."
# 忽略无关源的 GPG 错误（如 Chrome），只要不影响 Docker 源即可
sudo apt update 2>&1 | grep -v "^W:" || true
sudo apt install -y ca-certificates curl gnupg lsb-release

# ---------- 添加 Docker 官方 GPG Key ----------
info "导入 Docker GPG Key..."
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
info "GPG Key 导入完成 ✓"

# ---------- 添加 Docker apt 仓库 ----------
info "配置 Docker apt 仓库..."
echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# 只更新 Docker 源，跳过其他源（避免 Chrome 等 GPG 错误干扰）
info "更新 Docker apt 源..."
sudo apt update -o Dir::Etc::sourcelist="sources.list.d/docker.list" \
                -o Dir::Etc::sourceparts="-" \
                -o APT::Get::List-Cleanup="0"

# ---------- 确认目标版本存在 ----------
info "确认版本 ${REQUIRED_VERSION} 可用..."
MADISON_OUT=$(apt-cache madison docker-ce 2>/dev/null || true)
if echo "$MADISON_OUT" | grep -q "$REQUIRED_VERSION"; then
    info "版本 ${REQUIRED_VERSION} 可用 ✓"
else
    warn "apt-cache madison 输出："
    echo "$MADISON_OUT" | head -5 || echo "  （无输出）"
    error "apt 源中找不到 Docker ${REQUIRED_VERSION}。可能原因：\n  1. 网络无法访问 download.docker.com\n  2. Docker GPG Key 导入失败\n  请检查网络后重试"
fi

# ---------- 安装 Docker ----------
info "安装 Docker ${REQUIRED_VERSION}..."
sudo apt install -y \
    docker-ce="${VERSION_STRING}" \
    docker-ce-cli="${VERSION_STRING}" \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin
info "Docker 安装完成 ✓"

# ---------- 启动并设置开机自启 ----------
info "启动 Docker 服务..."
sudo systemctl enable docker
sudo systemctl start docker
info "Docker 服务已启动 ✓"

# ---------- 将当前用户加入 docker 组 ----------
_add_user_to_group() {
    if groups "$USER" | grep -qw docker; then
        info "用户 $USER 已在 docker 组，跳过"
    else
        sudo usermod -aG docker "$USER"
        info "已将 $USER 加入 docker 组 ✓"
        warn "需要重新登录（或执行 newgrp docker）使 docker 组权限生效"
    fi
}

_add_user_to_group

# ---------- 安装 tmux ----------
info "检查 tmux..."
if command -v tmux &>/dev/null; then
    info "tmux 已安装（$(tmux -V)），跳过"
else
    info "安装 tmux..."
    sudo apt install -y tmux
    info "tmux 安装完成（$(tmux -V)） ✓"
fi

# ---------- 验证 Docker ----------
info "验证安装..."
INSTALLED=$(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1)
if [ "$INSTALLED" = "$REQUIRED_VERSION" ]; then
    info "Docker ${INSTALLED} 安装验证通过 ✓"
else
    error "版本不符：期望 ${REQUIRED_VERSION}，实际 ${INSTALLED}"
fi

info "===== 01_install_host_deps.sh 执行完成 ====="
info "如需立即使用 docker 命令（无需 sudo），执行：newgrp docker"
info "下一步：运行 02_setup_cdi.sh"
