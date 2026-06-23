#!/usr/bin/env bash
# =============================================================================
# config.sh — easim Docker 环境统一配置
# 其他脚本通过 source "$(dirname "$0")/config.sh" 引入
# =============================================================================

# ---------- 路径配置 ----------
# easim 代码在宿主机上的绝对路径（必须修改为当前机器的实际路径）
EASIM_HOST_PATH=""

# Isaac Teleop Web Client 工程路径（deps/cloudxr/webxr_client 子目录的绝对路径）
ISAAC_TELEOP_PATH=""

# ---------- Docker 配置 ----------
CONTAINER_NAME="kxq_easim_container"
IMAGE_NAME="easim:v0.3"
DOCKERFILE="docker/Dockerfile.easimnew"
SHM_SIZE="16g"
ROS_DOMAIN_ID=0

# ---------- X11 / 显示配置 ----------
# GDM Xauthority 路径（多用户机器可改为对应 UID）
GDM_XAUTH="/run/user/1001/gdm/Xauthority"
DOCKER_XAUTH="/tmp/.docker.xauth"

# ---------- CloudXR 配置 ----------
CLOUDXR_ENV_CONFIG="$HOME/.cloudxr/hand_tracking_ab.env"

# ---------- 运行环境 ----------
# docker：命令通过 isaaclab.sh -p 执行，并在容器内运行
# native：命令直接用 python 执行（conda 环境）
# 留空则每次启动时菜单询问
DEFAULT_RUN_ENV=""   # 可设为 "docker" 或 "native"

# ---------- conda 环境名 ----------
TELEOP_CONDA_ENV="isaac_teleop_web_server_pico_env"
