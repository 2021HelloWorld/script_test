#!/usr/bin/env bash
# =============================================================================
# 04_teleop_pico.sh — 一键启动 Pico 遥操（3 个 tmux pane）
# 运行位置：宿主机
# 运行时机：日常遥操使用
#
# 布局：
#   ┌──────────────────────────┬──────────────────────────┐
#   │  pane 0                  │  pane 2                  │
#   │  Isaac Teleop Web Server │  easim + 遥操命令        │
#   ├──────────────────────────┤                          │
#   │  pane 1                  │                          │
#   │  CloudXR 服务            │                          │
#   └──────────────────────────┴──────────────────────────┘
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ---------- 颜色输出 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

SESSION="easim_teleop"

# ==========================================================================
# 场景选择菜单
# ==========================================================================

# 场景定义：每项格式为 "显示名|task|默认dataset文件名"
SCENES=(
    "抓三个水果        |pick_fruits_skill              |pick_fruit_pico_hand_dex11.hdf5"
    "抓纸团果皮        |pick_paper_balls_skill         |pick_paper_balls_test_260615_1935.hdf5"
    "水果+纸团综合场景 |pick_fruits_and_paper_balls    |pick_fruits_and_paper_balls_test_260615_1935.hdf5"
)

# 遥操设备选择
DEVICES=(
    "Pico 4 Ultra  |pico_handtracking"
    "Vision Pro    |handtracking"
)

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════╗"
echo "║         easim 遥操启动器                 ║"
echo "╚══════════════════════════════════════════╝"
echo -e "${NC}"

# ---------- 选择运行环境 ----------
RUN_ENV="${DEFAULT_RUN_ENV:-}"
if [ -z "$RUN_ENV" ]; then
    echo -e "${YELLOW}请选择运行环境：${NC}"
    echo "  1) Docker 容器"
    echo "  2) 本机（conda 环境）"
    echo ""
    read -rp "输入序号 [1-2]: " ENV_IDX
    case "$ENV_IDX" in
        1) RUN_ENV="docker" ;;
        2) RUN_ENV="native" ;;
        *) error "无效输入：$ENV_IDX" ;;
    esac
fi

if [ "$RUN_ENV" = "docker" ]; then
    PYTHON_CMD="./isaac_workspace/IsaacLab/isaaclab.sh -p"
    ENV_LABEL="Docker 容器"
else
    PYTHON_CMD="python"
    ENV_LABEL="本机（conda）"
fi

# ---------- 选择场景 ----------
echo -e "${YELLOW}请选择遥操场景：${NC}"
for i in "${!SCENES[@]}"; do
    NAME=$(echo "${SCENES[$i]}" | cut -d'|' -f1)
    echo "  $((i+1))) $NAME"
done
echo ""
read -rp "输入序号 [1-${#SCENES[@]}]: " SCENE_IDX

if ! [[ "$SCENE_IDX" =~ ^[0-9]+$ ]] || \
   [ "$SCENE_IDX" -lt 1 ] || [ "$SCENE_IDX" -gt "${#SCENES[@]}" ]; then
    error "无效输入：$SCENE_IDX"
fi

SELECTED_SCENE="${SCENES[$((SCENE_IDX-1))]}"
TASK=$(echo "$SELECTED_SCENE"       | cut -d'|' -f2 | xargs)
DEFAULT_DS=$(echo "$SELECTED_SCENE" | cut -d'|' -f3 | xargs)
SCENE_NAME=$(echo "$SELECTED_SCENE" | cut -d'|' -f1 | xargs)

# ---------- 选择设备 ----------
echo ""
echo -e "${YELLOW}请选择遥操设备：${NC}"
for i in "${!DEVICES[@]}"; do
    DEV_NAME=$(echo "${DEVICES[$i]}" | cut -d'|' -f1)
    echo "  $((i+1))) $DEV_NAME"
done
echo ""
read -rp "输入序号 [1-${#DEVICES[@]}]: " DEV_IDX

if ! [[ "$DEV_IDX" =~ ^[0-9]+$ ]] || \
   [ "$DEV_IDX" -lt 1 ] || [ "$DEV_IDX" -gt "${#DEVICES[@]}" ]; then
    error "无效输入：$DEV_IDX"
fi

TELEOP_DEVICE=$(echo "${DEVICES[$((DEV_IDX-1))]}" | cut -d'|' -f2 | xargs)

# ---------- 输入数据集路径 ----------
TIMESTAMP=$(date +%y%m%d_%H%M)
# 场景名转为小写下划线（去掉空格）
SCENE_SLUG=$(echo "$TASK" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')
DEFAULT_DS_NAME="${SCENE_SLUG}_${TIMESTAMP}"

echo ""
echo -e "${YELLOW}自定义文件名后缀（直接回车则不添加）：${NC}"
echo -e "  生成格式：${CYAN}datasets/imit_learning/${SCENE_SLUG}_${TIMESTAMP}_<后缀>.hdf5${NC}"
echo -e "  示例输入：${CYAN}kxq_test1${NC}"
read -rp "  > " USER_SUFFIX

if [ -z "$USER_SUFFIX" ]; then
    DATASET_FILE="datasets/imit_learning/${DEFAULT_DS_NAME}.hdf5"
else
    DATASET_FILE="datasets/imit_learning/${DEFAULT_DS_NAME}_${USER_SUFFIX}.hdf5"
fi

# ---------- 确认 ----------
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━���━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  环境：${CYAN}$ENV_LABEL${NC}"
echo -e "  场景：${CYAN}$SCENE_NAME${NC}"
echo -e "  设备：${CYAN}$TELEOP_DEVICE${NC}"
echo -e "  数据集：${CYAN}$DATASET_FILE${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
read -rp "确认启动？[Y/n] " CONFIRM
CONFIRM="${CONFIRM:-Y}"
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "已取消"
    exit 0
fi

# ==========================================================================
# 启动前检查
# ==========================================================================

command -v tmux &>/dev/null || error "未安装 tmux，请执行：sudo apt install tmux"

# docker 模式才需要检查容器
if [ "$RUN_ENV" = "docker" ]; then
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        warn "容器 $CONTAINER_NAME 未运行，正在启动..."
        bash "$SCRIPT_DIR/02_start_container.sh" || error "容器启动失败"
    fi
fi

if [ -z "$ISAAC_TELEOP_PATH" ]; then
    error "config.sh 中 ISAAC_TELEOP_PATH 未设置，请填写 IsaacTeleop webxr_client 的绝对路径"
fi
if [ ! -d "$ISAAC_TELEOP_PATH" ]; then
    error "Isaac Teleop Web Client 路径不存在：$ISAAC_TELEOP_PATH"
fi

if tmux has-session -t "$SESSION" 2>/dev/null; then
    warn "tmux session '$SESSION' 已存在，正在销毁重建..."
    tmux kill-session -t "$SESSION"
fi

HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}' || echo "<宿主机局域网IP>")

# ==========================================================================
# 创建 tmux session
# ==========================================================================
info "启动场景：$SCENE_NAME | 设备：$TELEOP_DEVICE | 环境：$ENV_LABEL"
info "创建 tmux session: $SESSION ..."

tmux new-session -d -s "$SESSION" -x 220 -y 50

# pane 0：Isaac Teleop Web Server
tmux send-keys -t "$SESSION:0.0" "
echo -e '\033[0;36m[Terminal 1] Isaac Teleop Web Server\033[0m'
cd '$ISAAC_TELEOP_PATH'
conda activate $TELEOP_CONDA_ENV
HOST=0.0.0.0 npm run dev-server:https
" ENTER

# pane 1：CloudXR（命令根据运行环境区分）
tmux split-window -v -t "$SESSION:0.0"
if [ "$RUN_ENV" = "docker" ]; then
    CLOUDXR_CMD="docker exec -it $CONTAINER_NAME bash -c \"
    source /root/.bashrc && cd /easim
    ./isaac_workspace/IsaacLab/isaaclab.sh -p -m isaacteleop.cloudxr --accept-eula \\
        --cloudxr-env-config \\\$HOME/.cloudxr/hand_tracking_ab.env\""
else
    CLOUDXR_CMD="python -m isaacteleop.cloudxr --accept-eula \\
  --cloudxr-env-config \"$CLOUDXR_ENV_CONFIG\""
fi
tmux send-keys -t "$SESSION:0.1" "
echo -e '\033[0;36m[Terminal 2] CloudXR 服务\033[0m'
sleep 3
$CLOUDXR_CMD
" ENTER

# pane 2：遥操命令提示（命令根据运行环境区分）
tmux split-window -h -t "$SESSION:0.0"
if [ "$RUN_ENV" = "docker" ]; then
    ENTER_HINT="# 2. 进入容器
echo 'docker exec -it $CONTAINER_NAME bash'
echo ''
echo '# 3. 容器内运行遥操（复制下方命令）：'"
    TELEOP_CMD="$PYTHON_CMD source/easim/cli/run_unified.py \\\\"
else
    ENTER_HINT="# 2. 运行遥操命令（复制下方）：
echo ''"
    TELEOP_CMD="$PYTHON_CMD source/easim/cli/run_unified.py \\\\"
fi

tmux send-keys -t "$SESSION:0.2" "
echo -e '\033[0;36m[Terminal 3] easim 遥操 — $ENV_LABEL\033[0m'
echo -e '\033[1;32m场景：$SCENE_NAME | 设备：$TELEOP_DEVICE\033[0m'
echo ''
echo -e '\033[1;33m[提示] 等待 Terminal 1、2 服务启动后，在此执行以下命令\033[0m'
echo ''
echo '# 1. 配置 CloudXR 环境变量'
echo 'source \$HOME/.cloudxr/run/cloudxr.env'
echo 'export XDG_RUNTIME_DIR=\$HOME/.cloudxr/run'
echo 'export XR_RUNTIME_JSON=\$HOME/.cloudxr/openxr_cloudxr.json'
echo ''
$ENTER_HINT
echo '---'
echo '$TELEOP_CMD'
echo '  --task $TASK --mode teleop_record \\'
echo '  --teleop_device $TELEOP_DEVICE --enable_pinocchio \\'
echo '  --num_success_steps 20 --no-vr-teleop-debug \\'
echo '  --dataset_file $DATASET_FILE'
echo '---'
echo ''
echo -e '\033[1;32m[Pico 连接地址] https://$HOST_IP:8080\033[0m'
echo '  easim 启动后：Isaac Sim GUI → AR → Start'
echo '  Pico 浏览器输入上方地址 → Accept → Connect → Play'
" ENTER

# ==========================================================================
# 完成
# ==========================================================================
info ""
info "===== tmux session '$SESSION' 已创建 ====="
info "  切换 pane  : Ctrl+B 再按方向键"
info "  退出保留   : Ctrl+B D"
info "  重新附加   : tmux attach -t $SESSION"
info "  关闭 session: tmux kill-session -t $SESSION"
info ""
info "Pico 浏览器连接地址：https://$HOST_IP:8080"
info ""

if [ -t 0 ]; then
    tmux attach -t "$SESSION"
fi
