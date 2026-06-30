#!/usr/bin/env bash
# =============================================================================
# 04_start_container.sh — 刷新 Xauthority 并启动 easim Docker 容器
# 运行位置：宿主机
# 运行时机：每次宿主机重启后，或退出桌面会话重新登入后
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ---------- 颜色输出 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---------- 检查 easim 路径 ----------
if [ ! -d "$EASIM_HOST_PATH" ]; then
    error "easim 路径不存在：$EASIM_HOST_PATH
请修改 config.sh 中的 EASIM_HOST_PATH 变量"
fi
info "easim 路径：$EASIM_HOST_PATH ✓"

# ---------- 允许 Docker 访问 X11 ----------
info "配置 X11 访问权限..."
xhost +local:docker

# ---------- 刷新 Xauthority ----------
info "复制 Xauthority cookie..."
if [ ! -f "$GDM_XAUTH" ]; then
    error "找不到 GDM Xauth 文件：$GDM_XAUTH
如果你的 UID 不是 1001，请修改 config.sh 中的 GDM_XAUTH 路径
（使用 'id -u' 查看当前 UID）"
fi

if [ -d "$DOCKER_XAUTH" ] || [ "$(basename "$DOCKER_XAUTH")" != "Xauthority" ]; then
    DOCKER_XAUTH_DIR="$DOCKER_XAUTH"
    DOCKER_XAUTH_FILE="$DOCKER_XAUTH_DIR/Xauthority"
else
    DOCKER_XAUTH_FILE="$DOCKER_XAUTH"
    DOCKER_XAUTH_DIR="$(dirname "$DOCKER_XAUTH_FILE")"
fi

if [ -e "$DOCKER_XAUTH_DIR" ] && [ ! -d "$DOCKER_XAUTH_DIR" ]; then
    error "Xauthority 缓存路径不是目录：$DOCKER_XAUTH_DIR"
fi

if ! mkdir -p "$DOCKER_XAUTH_DIR" 2>/dev/null; then
    warn "无法创建 Xauthority 缓存目录，尝试使用 sudo 修复：$DOCKER_XAUTH_DIR"
    sudo mkdir -p "$DOCKER_XAUTH_DIR" || error "创建 Xauthority 缓存目录失败：$DOCKER_XAUTH_DIR"
fi

if [ ! -w "$DOCKER_XAUTH_DIR" ] || [ ! -x "$DOCKER_XAUTH_DIR" ]; then
    warn "Xauthority 缓存目录不可写，尝试修复权限：$DOCKER_XAUTH_DIR"
    sudo chown "$USER:$(id -gn)" "$DOCKER_XAUTH_DIR" || error "修复 Xauthority 缓存目录属主失败：$DOCKER_XAUTH_DIR"
    chmod 700 "$DOCKER_XAUTH_DIR" || error "修复 Xauthority 缓存目录权限失败：$DOCKER_XAUTH_DIR"
fi

if [ -e "$DOCKER_XAUTH_FILE" ] && [ ! -w "$DOCKER_XAUTH_FILE" ]; then
    warn "Xauthority 缓存文件不可写，尝试修复权限：$DOCKER_XAUTH_FILE"
    sudo chown "$USER:$(id -gn)" "$DOCKER_XAUTH_FILE" || error "修复 Xauthority 缓存文件属主失败：$DOCKER_XAUTH_FILE"
fi

cp "$GDM_XAUTH" "$DOCKER_XAUTH_FILE"
chmod 644 "$DOCKER_XAUTH_FILE"
DOCKER_XAUTH="$DOCKER_XAUTH_FILE"
info "Xauthority 已复制到 $DOCKER_XAUTH ✓"

# ---------- 检查镜像是否存在 ----------
if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
    error "镜像 $IMAGE_NAME 不存在，请先在 easim 目录下执行：
  cd $EASIM_HOST_PATH
  docker build -f $DOCKERFILE -t $IMAGE_NAME ."
fi

# ---------- 处理旧容器 ----------
FORCE_RECREATE=false
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        STATUS="running"
    else
        STATUS="stopped"
    fi

    echo ""
    if [ "$STATUS" = "running" ]; then
        warn "容器 $CONTAINER_NAME 正在运行"
    else
        warn "容器 $CONTAINER_NAME 已停止"
    fi
    echo -e "请选择操作："
    echo "  1) 保留容器数据，直接启动/复用（推荐）"
    echo "  2) 删除旧容器，从镜像重新创建（pip 安装的包将丢失）"
    echo ""
    read -rp "输入序号 [1-2]: " ACTION
    case "$ACTION" in
        1)
            if [ "$STATUS" = "running" ]; then
                info "复用运行中的容器，Xauthority 已刷新 ✓"
            else
                info "重启已停止的容器..."
                docker start "$CONTAINER_NAME"
                info "容器重启成功 ✓"
            fi
            info ""
            info "进入容器：docker exec -it $CONTAINER_NAME /bin/bash"
            info "===== 04_start_container.sh 执行完成 ====="
            exit 0
            ;;
        2)
            warn "删除旧容器 $CONTAINER_NAME ..."
            docker rm -f "$CONTAINER_NAME"
            FORCE_RECREATE=true
            ;;
        *)
            error "无效输入：$ACTION"
            ;;
    esac
fi

# ---------- 创建容器（首次 或 选择重建）----------
if [ "$FORCE_RECREATE" = true ]; then
    info "重新创建容器 $CONTAINER_NAME ..."
else
    info "首次创建容器 $CONTAINER_NAME ..."
fi
docker run -itd \
    --name "$CONTAINER_NAME" \
    --network host \
    --device nvidia.com/gpu=all \
    -e NVIDIA_DRIVER_CAPABILITIES=all \
    -e NVIDIA_VISIBLE_DEVICES=all \
    -e DISPLAY="$DISPLAY" \
    -e XAUTHORITY="$DOCKER_XAUTH" \
    -e OMNI_KIT_ALLOW_ROOT=1 \
    -e QT_X11_NO_MITSHM=1 \
    -v /tmp/.X11-unix:/tmp/.X11-unix \
    -v "$DOCKER_XAUTH:$DOCKER_XAUTH" \
    --ipc=host \
    --shm-size="$SHM_SIZE" \
    -e ROS_DOMAIN_ID="$ROS_DOMAIN_ID" \
    -v "$EASIM_HOST_PATH:/easim" \
    -v "$SCRIPT_DIR:/deploy_scripts" \
    "$IMAGE_NAME"

# ---------- 验证 ----------
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    info "容器启动成功 ✓"
    info ""
    info "进入容器：docker exec -it $CONTAINER_NAME /bin/bash"
    info ""
    if [ "$FORCE_RECREATE" = true ]; then
        info "容器已重建，请重新初始化环境："
        info "  bash /deploy_scripts/05_init_docker_env.sh"
    else
        info "如果是首次进入容器，请运行："
        info "  bash /deploy_scripts/05_init_docker_env.sh"
    fi
else
    error "容器启动失败，请检查上方输出"
fi

info "===== 04_start_container.sh 执行完成 ====="
