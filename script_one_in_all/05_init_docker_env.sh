#!/usr/bin/env bash
# =============================================================================
# 05_init_docker_env.sh — 容器内首次初始化 Isaac Lab / easim 环境
# 运行位置：Docker 容器内（/root 或 /easim 下）
# 运行时机：首次进入新容器后执行一次
# =============================================================================
set -euo pipefail

# ---------- 颜色输出 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

ISAACLAB_SH="/easim/isaac_workspace/IsaacLab/isaaclab.sh"
ISAACSIM_PYTHON="/easim/isaac_workspace/IsaacLab/_isaac_sim/python.sh"

# ---------- 确认在容器内 ----------
if [ ! -f "/.dockerenv" ]; then
    error "该脚本必须在 Docker 容器内运行"
fi

# ---------- 确认 /easim 已挂载 ----------
if [ ! -d "/easim" ]; then
    error "/easim 目录不存在，请确认容器启动时挂载了 easim 目录"
fi

# ---------- Step 1: 配置 .bashrc 环境变量 ----------
info "[1/8] 配置 .bashrc 环境变量..."

# 获取宿主机 DISPLAY 编号（默认 :0）
HOST_DISPLAY="${DISPLAY:-:0}"
# 取 :N 的 N
DISP_NUM=$(echo "$HOST_DISPLAY" | grep -oP ':\d+' | head -1 || echo ":0")

grep -q 'export DISPLAY=' /root/.bashrc || \
    echo "export DISPLAY=${DISP_NUM}" >> /root/.bashrc
grep -q 'export OMNI_KIT_ALLOW_ROOT=' /root/.bashrc || \
    echo 'export OMNI_KIT_ALLOW_ROOT=1' >> /root/.bashrc

info "DISPLAY=${DISP_NUM}, OMNI_KIT_ALLOW_ROOT=1 已写入 .bashrc ✓"

# ---------- Step 2: 创建 isaac_workspace 软链接 ----------
info "[2/8] 创建 /easim/isaac_workspace 软链接..."
if [ -L "/easim/isaac_workspace" ]; then
    warn "软链接已存在，跳过"
elif [ -d "/easim/isaac_workspace" ]; then
    warn "/easim/isaac_workspace 已是真实目录，跳过"
else
    ln -s /data/isaac_workspace /easim/isaac_workspace
    info "软链接创建完成 ✓"
fi

# ---------- 验证 isaaclab.sh 存在 ----------
if [ ! -f "$ISAACLAB_SH" ]; then
    error "找不到 $ISAACLAB_SH，请确认 /data/isaac_workspace 挂载正确"
fi

# ---------- Step 3: 安装 Isaac Lab 依赖 ----------
info "[3/8] 安装 Isaac Lab 依赖（isaaclab.sh --install）..."
cd /easim/isaac_workspace/IsaacLab
./isaaclab.sh --install
info "Isaac Lab 安装完成 ✓"

# ---------- Step 4: 将 easim 装入 Isaac Sim bundled Python ----------
info "[4/8] 将 easim 安装到 Isaac Sim Python（pip install -e）..."
"$ISAACSIM_PYTHON" -m pip install -e /easim
info "easim 安装完成 ✓"

# ---------- Step 5: 安装 isaacteleop ----------
info "[5/8] 安装 isaacteleop（CloudXR 遥操 Python 包）..."
"$ISAACSIM_PYTHON" -m pip install \
    'isaacteleop[cloudxr]==1.3.43rc1' \
    --extra-index-url https://pypi.nvidia.com
info "isaacteleop 安装完成 ✓"

info "配置 CloudXR 环境文件（hand_tracking_ab.env）..."
mkdir -p /root/.cloudxr
cat > /root/.cloudxr/hand_tracking_ab.env <<'CLOUDXR_EOF'
NV_CXR_ENABLE_PUSH_DEVICES=false
NV_CXR_ENABLE_TENSOR_DATA=true
NV_CXR_FILE_LOGGING=true
NV_DEVICE_PROFILE=auto-webrtc
CLOUDXR_EOF
info "CloudXR 配置完成 ✓"

# ---------- Step 5: 安装可选工具 ----------
info "[6/8] 安装 ffmpeg（h264 → mp4 转换工具）..."
apt update -qq && apt install -y ffmpeg
info "ffmpeg 安装完成 ✓"

info "[7/8] 安装 pyarrow（fastwam_robotwin2.0 数据验证）..."
"$ISAACLAB_SH" -p -m pip install pyarrow

info "[8/8] 安装遥操 pink IK 依赖及回放环境修复包..."
"$ISAACLAB_SH" -p -m pip install "numpy>=1.26.0,<2.0"
"$ISAACLAB_SH" -p -m pip install --no-deps "osqp>=1.0.0,<2.0.0"
"$ISAACSIM_PYTHON" -m pip install "scipy==1.15.3" "warp-lang==1.12.1"
"$ISAACSIM_PYTHON" -m pip install "onnxruntime==1.26.0"

# ---------- 检查 .bashrc 可加载 ----------
# 这里不能在 set -u 下直接 source /root/.bashrc；如果 .bashrc 里引用了未定义变量，
# bash 会直接退出当前脚本，导致前面安装都成功但初始化被误判失败。
if [ -f /root/.bashrc ]; then
    if ! ( set +u; source /root/.bashrc ) >/dev/null 2>&1; then
        warn "/root/.bashrc 加载检查未通过，已忽略；重新进入容器后请手动确认环境变量"
    fi
fi

info ""
info "===== 初始化完成 ====="
info "验证环境（scene_preview）："
info "  cd /easim"
info "  ./isaac_workspace/IsaacLab/isaaclab.sh -p source/easim/cli/run_unified.py \\"
info "      --task pick_place_skill --mode scene_preview"
info ""
info "查看 Isaac Sim 版本："
info "  ./isaac_workspace/IsaacLab/isaaclab.sh -s"
