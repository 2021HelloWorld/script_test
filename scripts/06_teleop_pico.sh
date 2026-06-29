#!/usr/bin/env bash
# =============================================================================
# 06_teleop_pico.sh — 一键启动 Pico 遥操（3 个 tmux pane）
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
        bash "$SCRIPT_DIR/04_start_container.sh" || error "容器启动失败"
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
# 生成遥操运行脚本（挂载为容器内 /deploy_scripts/.teleop_run.sh）
# ==========================================================================
TELEOP_SCRIPT="$SCRIPT_DIR/.teleop_run.sh"
CLOUDXR_SCRIPT="$SCRIPT_DIR/.cloudxr_run.sh"
TELEOP_PANE_SCRIPT="$SCRIPT_DIR/.teleop_pane_run.sh"
if [ "$RUN_ENV" = "docker" ]; then
    cat > "$TELEOP_SCRIPT" <<TELEOP_EOF
#!/usr/bin/env bash
source /root/.bashrc 2>/dev/null || true
cd /easim
source /root/.cloudxr/run/cloudxr.env
export XDG_RUNTIME_DIR=\$HOME/.cloudxr/run
export XR_RUNTIME_JSON=\$HOME/.cloudxr/openxr_cloudxr.json
exec ./isaac_workspace/IsaacLab/isaaclab.sh -p source/easim/cli/run_unified.py \\
  --task $TASK --mode teleop_record \\
  --teleop_device $TELEOP_DEVICE --enable_pinocchio \\
  --num_success_steps 20 --no-vr-teleop-debug \\
  --dataset_file $DATASET_FILE
TELEOP_EOF
    chmod +x "$TELEOP_SCRIPT"
    info "遥操脚本已生成：$TELEOP_SCRIPT ✓"

    cat > "$CLOUDXR_SCRIPT" <<CLOUDXR_EOF
#!/usr/bin/env bash
source /root/.bashrc 2>/dev/null || true
echo '[INFO] Starting CloudXR service in foreground; this pane should stay occupied.'
# 清理残留的 CloudXR 进程，释放端口（兼容没有 fuser 的容器）
pkill -f 'isaacteleop.cloudxr' 2>/dev/null || true
sleep 2
for port in 49100 48322; do
    pid=\$(ss -tlnp 2>/dev/null | grep ":\${port} " | grep -oP 'pid=\K[0-9]+' | head -1)
    [ -n "\$pid" ] && kill -9 "\$pid" 2>/dev/null || true
done
cd /easim
echo '[INFO] Launching isaacteleop.cloudxr. If the last line is "Using python from:", wait 1-3 minutes, then start Terminal 3.'
export PYTHONUNBUFFERED=1
exec ./isaac_workspace/IsaacLab/isaaclab.sh -p -m isaacteleop.cloudxr --accept-eula \\
    --cloudxr-env-config \$HOME/.cloudxr/hand_tracking_ab.env
CLOUDXR_EOF
    chmod +x "$CLOUDXR_SCRIPT"
    info "CloudXR 脚本已生成：$CLOUDXR_SCRIPT ✓"
fi

cat > "$TELEOP_PANE_SCRIPT" <<TELEOP_PANE_EOF
#!/usr/bin/env bash
set +e

echo -e '\\033[0;36m[Terminal 3] easim 遥操 — $ENV_LABEL\\033[0m'
echo -e '\\033[1;32m场景：$SCENE_NAME | 设备：$TELEOP_DEVICE\\033[0m'
echo -e '\\033[1;32m数据集：$DATASET_FILE\\033[0m'
echo ''
echo -e '\\033[1;32m[Pico 连接地址] https://$HOST_IP:8080\\033[0m'
echo '  easim 启动后：Isaac Sim GUI → AR → Start'
echo '  Pico 浏览器输入上方地址 → Accept → Connect → Play'
echo ''

read -rp '等待 Terminal 1、2 服务就绪后，按 Enter 启动遥操... '
if [ \$? -ne 0 ]; then
    TELEOP_STATUS=130
else
TELEOP_PANE_EOF

if [ "$RUN_ENV" = "docker" ]; then
    cat >> "$TELEOP_PANE_SCRIPT" <<TELEOP_PANE_EOF
    docker exec -it $CONTAINER_NAME bash /deploy_scripts/.teleop_run.sh
    TELEOP_STATUS=\$?
TELEOP_PANE_EOF
else
    cat >> "$TELEOP_PANE_SCRIPT" <<TELEOP_PANE_EOF
    cd "$EASIM_HOST_PATH" && \\
    source "\$HOME/.cloudxr/run/cloudxr.env" && \\
    export XDG_RUNTIME_DIR="\$HOME/.cloudxr/run" && \\
    export XR_RUNTIME_JSON="\$HOME/.cloudxr/openxr_cloudxr.json" && \\
    $PYTHON_CMD source/easim/cli/run_unified.py \\
      --task $TASK --mode teleop_record \\
      --teleop_device $TELEOP_DEVICE --enable_pinocchio \\
      --num_success_steps 20 --no-vr-teleop-debug \\
      --dataset_file $DATASET_FILE
    TELEOP_STATUS=\$?
TELEOP_PANE_EOF
fi

cat >> "$TELEOP_PANE_SCRIPT" <<TELEOP_PANE_EOF
fi

echo ''
echo '[INFO] 遥操进程已退出，3 秒后关闭 tmux session 并返回入口菜单...'
sleep 3
tmux kill-session -t "$SESSION" 2>/dev/null
exit \$TELEOP_STATUS
TELEOP_PANE_EOF
chmod +x "$TELEOP_PANE_SCRIPT"
info "遥操 pane 脚本已生成：$TELEOP_PANE_SCRIPT ✓"

# ==========================================================================
# 创建 tmux session
# ==========================================================================
info "启动场景：$SCENE_NAME | 设备：$TELEOP_DEVICE | 环境：$ENV_LABEL"
info "创建 tmux session: $SESSION ..."

tmux new-session -d -s "$SESSION" -x 220 -y 50

# 布局：三列垂直分割
# pane 0 → Terminal 1（Web Server）
# pane 1 → Terminal 2（CloudXR）
# pane 2 → Terminal 3（遥操）
PANE_WEBSERVER="$SESSION:0.0"
PANE_CLOUDXR=$(tmux split-window -h -p 67 -t "$SESSION:0.0" -P -F "#{pane_id}")
PANE_TELEOP=$(tmux split-window -h -p 50 -t "$PANE_CLOUDXR" -P -F "#{pane_id}")

# Terminal 1（最左）：Isaac Teleop Web Server
tmux send-keys -t "$PANE_WEBSERVER" "
echo -e '\033[0;36m[Terminal 1] Isaac Teleop Web Server\033[0m'
cd '$ISAAC_TELEOP_PATH'
conda activate $TELEOP_CONDA_ENV
HOST=0.0.0.0 npm run dev-server:https
" ENTER

# CloudXR（左下，PANE_CLOUDXR）
if [ "$RUN_ENV" = "docker" ]; then
    tmux send-keys -t "$PANE_CLOUDXR" "
echo -e '\033[0;36m[Terminal 2] CloudXR 服务\033[0m'
echo 'CloudXR 是前台常驻服务；这个 pane 不会回到 shell。'
sleep 3
docker exec -it $CONTAINER_NAME bash /deploy_scripts/.cloudxr_run.sh
" ENTER
else
    tmux send-keys -t "$PANE_CLOUDXR" "
echo -e '\033[0;36m[Terminal 2] CloudXR 服务\033[0m'
echo 'CloudXR 是前台常驻服务；这个 pane 不会回到 shell。'
sleep 3
PYTHONUNBUFFERED=1 \\
python -m isaacteleop.cloudxr --accept-eula \\
  --cloudxr-env-config \"$CLOUDXR_ENV_CONFIG\"
" ENTER
fi

# 遥操（右侧，PANE_TELEOP）
tmux send-keys -t "$PANE_TELEOP" "bash '$TELEOP_PANE_SCRIPT'" ENTER

# ==========================================================================
# 完成
# ==========================================================================
info ""
info "===== tmux session '$SESSION' 已创建 ====="
info "  切换 pane  : Ctrl+B 再按方向键"
info "  临时脱离   : Ctrl+B D（后台保留）"
info "  重新附加   : tmux attach -t $SESSION"
info "  遥操结束   : 关闭 Isaac Sim 后自动关闭 session 并返回入口菜单"
info "  手动关闭   : tmux kill-session -t $SESSION"
info ""
info "Pico 浏览器连接地址：https://$HOST_IP:8080"
info ""

if [ -t 0 ]; then
    tmux attach -t "$SESSION"
fi
