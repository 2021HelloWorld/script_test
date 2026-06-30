#!/usr/bin/env bash
# =============================================================================
# config.sh — easim Docker 环境统一配置
# 其他脚本通过 source "$(dirname "$0")/config.sh" 引入
# 修改配置请运行 setup.sh
# 上次配置时间：2026-06-30 11:56:06
# =============================================================================

# ---------- 路径配置 ----------
EASIM_HOST_PATH="/media/sensetime/68bb4571-f355-45f0-a282-3c97df8fc0061/kongxiaoqiang/easim/easim"
ISAAC_TELEOP_PATH="/media/sensetime/68bb4571-f355-45f0-a282-3c97df8fc0061/kongxiaoqiang/easim/IsaacTeleop/deps/cloudxr/webxr_client"

# ---------- Docker 配置 ----------
CONTAINER_NAME="kxq_easim_container"
IMAGE_NAME="easim:v0.3"
DOCKERFILE="docker/Dockerfile.easimnew"
SHM_SIZE="16g"
ROS_DOMAIN_ID=0

# ---------- X11 / 显示配置 ----------
GDM_XAUTH="/run/user/1001/gdm/Xauthority"
DOCKER_XAUTH="/tmp/.docker.xauth/Xauthority"

# ---------- CloudXR 配置 ----------
CLOUDXR_ENV_CONFIG="$HOME/.cloudxr/hand_tracking_ab.env"

# ---------- 运行环境 ----------
# docker：命令通过 isaaclab.sh -p 执行，并在容器内运行
# native：命令直接用 python 执行（conda 环境）
# 留空则每次启动时菜单询问
DEFAULT_RUN_ENV="docker"

# ---------- conda 环境名 ----------
TELEOP_CONDA_ENV="isaac_teleop_web_server_pico_env"
