#!/usr/bin/env bash
# =============================================================================
# setup.sh — 交互式配置向导，生成 config.sh
# 运行位置：宿主机
# 运行时机：首次使用前，或需要修改配置时
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.sh"

# ---------- 颜色输出 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }

# ---------- 读取带默认值的输入 ----------
# 用法: prompt_input "提示文字" "默认值" -> 结果存入 REPLY_VAL
prompt_input() {
    local prompt="$1"
    local default="$2"
    if [ -n "$default" ]; then
        echo -e "${YELLOW}${prompt}${NC}"
        echo -e "  当前值：${CYAN}${default}${NC}"
        read -rp "  直接回车保留，或输入新值：" val
        REPLY_VAL="${val:-$default}"
    else
        echo -e "${YELLOW}${prompt}${NC}"
        read -rp "  > " val
        REPLY_VAL="$val"
    fi
}

# ---------- 读取当前配置（若已存在）----------
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    warn "检测到已有配置，直接回车可保留当前值"
else
    warn "未检测到配置文件，将创建新的 config.sh"
fi

echo ""
echo -e "${CYAN}"
echo "╔══════════════════════════════════════════╗"
echo "║         easim 环境配置向导               ║"
echo "╚══════════════════════════════════════════╝"
echo -e "${NC}"

# ==========================================================================
# 1. 路径配置
# ==========================================================================
echo -e "${GREEN}── 路径配置 ──────────────────────────────────${NC}"

prompt_input "easim 代码在宿主机上的绝对路径" "${EASIM_HOST_PATH:-}"
NEW_EASIM_HOST_PATH="$REPLY_VAL"
if [ -n "$NEW_EASIM_HOST_PATH" ] && [ ! -d "$NEW_EASIM_HOST_PATH" ]; then
    warn "路径不存在：$NEW_EASIM_HOST_PATH（请确认后续会创建或挂载）"
fi

prompt_input "Isaac Teleop Web Client 路径（IsaacTeleop/deps/cloudxr/webxr_client）" "${ISAAC_TELEOP_PATH:-}"
NEW_ISAAC_TELEOP_PATH="$REPLY_VAL"

# ==========================================================================
# 2. Docker 配置
# ==========================================================================
echo ""
echo -e "${GREEN}── Docker 配置 ───────────────────────────────${NC}"

prompt_input "容器名" "${CONTAINER_NAME:-kxq_easim_container}"
NEW_CONTAINER_NAME="$REPLY_VAL"

prompt_input "镜像名" "${IMAGE_NAME:-easim:v0.3}"
NEW_IMAGE_NAME="$REPLY_VAL"

prompt_input "shared memory 大小" "${SHM_SIZE:-16g}"
NEW_SHM_SIZE="$REPLY_VAL"

prompt_input "ROS_DOMAIN_ID" "${ROS_DOMAIN_ID:-0}"
NEW_ROS_DOMAIN_ID="$REPLY_VAL"

# ==========================================================================
# 3. X11 配置
# ==========================================================================
echo ""
echo -e "${GREEN}── X11 / 显示配置 ────────────────────────────${NC}"

# 自动检测当前用户 UID
DETECTED_UID=$(id -u)
DEFAULT_GDM="/run/user/${DETECTED_UID}/gdm/Xauthority"
prompt_input "GDM Xauthority 路径（当前用户 UID=${DETECTED_UID}）" "${GDM_XAUTH:-$DEFAULT_GDM}"
NEW_GDM_XAUTH="$REPLY_VAL"

# ==========================================================================
# 4. 运行环境默认值
# ==========================================================================
echo ""
echo -e "${GREEN}── 运行环境默认值 ────────────────────────────${NC}"
echo -e "${YELLOW}默认运行环境（留空则每次启动时菜单询问）：${NC}"
echo "  1) 留空（每次询问）"
echo "  2) docker"
echo "  3) native（本机 conda）"
CURRENT_ENV_LABEL="留空（每次询问）"
if [ "${DEFAULT_RUN_ENV:-}" = "docker" ]; then CURRENT_ENV_LABEL="docker"; fi
if [ "${DEFAULT_RUN_ENV:-}" = "native" ]; then CURRENT_ENV_LABEL="native"; fi
echo -e "  当前值：${CYAN}${CURRENT_ENV_LABEL}${NC}"
read -rp "  输入序号 [1-3]，直接回车保留：" ENV_CHOICE
case "$ENV_CHOICE" in
    1) NEW_DEFAULT_RUN_ENV="" ;;
    2) NEW_DEFAULT_RUN_ENV="docker" ;;
    3) NEW_DEFAULT_RUN_ENV="native" ;;
    "") NEW_DEFAULT_RUN_ENV="${DEFAULT_RUN_ENV:-}" ;;
    *) warn "无效输入，保留原值"; NEW_DEFAULT_RUN_ENV="${DEFAULT_RUN_ENV:-}" ;;
esac

# ==========================================================================
# 5. conda 环境名
# ==========================================================================
echo ""
echo -e "${GREEN}── conda 配置 ────────────────────────────────${NC}"

prompt_input "Isaac Teleop Web Server conda 环境名" "${TELEOP_CONDA_ENV:-isaac_teleop_web_server_pico_env}"
NEW_TELEOP_CONDA_ENV="$REPLY_VAL"

# ==========================================================================
# 确认
# ==========================================================================
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  EASIM_HOST_PATH    : ${CYAN}${NEW_EASIM_HOST_PATH:-（未填）}${NC}"
echo -e "  ISAAC_TELEOP_PATH  : ${CYAN}${NEW_ISAAC_TELEOP_PATH:-（未填）}${NC}"
echo -e "  CONTAINER_NAME     : ${CYAN}${NEW_CONTAINER_NAME}${NC}"
echo -e "  IMAGE_NAME         : ${CYAN}${NEW_IMAGE_NAME}${NC}"
echo -e "  SHM_SIZE           : ${CYAN}${NEW_SHM_SIZE}${NC}"
echo -e "  ROS_DOMAIN_ID      : ${CYAN}${NEW_ROS_DOMAIN_ID}${NC}"
echo -e "  GDM_XAUTH          : ${CYAN}${NEW_GDM_XAUTH}${NC}"
echo -e "  DEFAULT_RUN_ENV    : ${CYAN}${NEW_DEFAULT_RUN_ENV:-（每次询问）}${NC}"
echo -e "  TELEOP_CONDA_ENV   : ${CYAN}${NEW_TELEOP_CONDA_ENV}${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
read -rp "确认写入 config.sh？[Y/n] " CONFIRM
CONFIRM="${CONFIRM:-Y}"
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "已取消，config.sh 未修改"
    exit 0
fi

# ==========================================================================
# 写入 config.sh
# ==========================================================================
cat > "$CONFIG_FILE" << EOF
#!/usr/bin/env bash
# =============================================================================
# config.sh — easim Docker 环境统一配置
# 其他脚本通过 source "\$(dirname "\$0")/config.sh" 引入
# 修改配置请运行 setup.sh
# 上次配置时间：$(date '+%Y-%m-%d %H:%M:%S')
# =============================================================================

# ---------- 路径配置 ----------
EASIM_HOST_PATH="${NEW_EASIM_HOST_PATH}"
ISAAC_TELEOP_PATH="${NEW_ISAAC_TELEOP_PATH}"

# ---------- Docker 配置 ----------
CONTAINER_NAME="${NEW_CONTAINER_NAME}"
IMAGE_NAME="${NEW_IMAGE_NAME}"
DOCKERFILE="docker/Dockerfile.easimnew"
SHM_SIZE="${NEW_SHM_SIZE}"
ROS_DOMAIN_ID=${NEW_ROS_DOMAIN_ID}

# ---------- X11 / 显示配置 ----------
GDM_XAUTH="${NEW_GDM_XAUTH}"
DOCKER_XAUTH="/tmp/.docker.xauth/Xauthority"

# ---------- CloudXR 配置 ----------
CLOUDXR_ENV_CONFIG="\$HOME/.cloudxr/hand_tracking_ab.env"

# ---------- 运行环境 ----------
# docker：命令通过 isaaclab.sh -p 执行，并在容器内运行
# native：命令直接用 python 执行（conda 环境）
# 留空则每次启动时菜单询问
DEFAULT_RUN_ENV="${NEW_DEFAULT_RUN_ENV}"

# ---------- conda 环境名 ----------
TELEOP_CONDA_ENV="${NEW_TELEOP_CONDA_ENV}"
EOF

chmod +x "$CONFIG_FILE"
info "config.sh 已更新 ✓"
info "下一步：bash script_set_env/02_setup_cdi.sh"
