#!/usr/bin/env bash
# =============================================================================
# easim.sh - easim 环境统一入口脚本
# 运行位置：宿主机
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

EXPECTED_NVIDIA_DRIVER="580.159.03"
EXPECTED_CUDA_VERSION="12.8"
EXPECTED_CUDA_NVCC="/usr/local/cuda-${EXPECTED_CUDA_VERSION}/bin/nvcc"
EXPECTED_DOCKER_VERSION="29.1.3"
MIN_DOCKER_MAJOR=25

print_header() {
    echo -e "${CYAN}"
    echo "=========================================="
    echo "          easim 工具入口"
    echo "=========================================="
    echo -e "${NC}"
}

usage() {
    cat <<EOF
用法:
  bash script_new/easim.sh [command]

常用命令:
  deploy      首次部署：配置 -> CDI -> 构建镜像 -> 启动容器 -> 可选初始化
  restart     重启/恢复环境
  status      查看当前配置、镜像、容器状态

维护命令:
  check       环境预检，只报告状态，不安装/不修改环境
  setup       首次配置或修改 config.sh
  init        初始化容器内 easim/Isaac Lab 环境
  cuda        安装 CUDA Toolkit
  host-deps   安装 Docker 等宿主机依赖
  cdi         配置 NVIDIA CDI
  build       构建 Docker 镜像

不带 command 时进入交互菜单。
EOF
}

pause() {
    echo ""
    read -rp "按回车返回菜单..." _
}

run_menu_action() {
    local action="$1"
    if ( "$action" ); then
        echo ""
        info "操作已结束，返回主菜单。"
    else
        local status=$?
        echo ""
        warn "操作已中断或失败（退出码：$status），返回主菜单。"
    fi
    pause
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-yes}"
    local answer suffix

    if [ "$default" = "yes" ]; then
        suffix="[Y/n]"
    else
        suffix="[y/N]"
    fi

    read -rp "$prompt $suffix " answer
    answer="${answer:-}"
    if [ -z "$answer" ]; then
        [ "$default" = "yes" ]
        return
    fi
    [[ "$answer" =~ ^[Yy]$ ]]
}

run_script() {
    local script_name="$1"
    local script_path="$SCRIPT_DIR/$script_name"
    [ -f "$script_path" ] || error "找不到脚本：$script_path"
    bash "$script_path"
}

load_config() {
    [ -f "$CONFIG_FILE" ] || error "未找到 config.sh，请先运行：bash script_new/easim.sh setup"
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
}

ensure_config_or_setup() {
    if [ ! -f "$CONFIG_FILE" ]; then
        warn "未找到 config.sh，将先运行配置向导。"
        run_script "setup.sh"
    fi
}

setup_config() {
    run_script "setup.sh"
}

check_pass() {
    echo -e "${GREEN}[PASS]${NC} $*"
}

check_warn() {
    CHECK_WARNINGS=$((CHECK_WARNINGS + 1))
    echo -e "${YELLOW}[WARN]${NC} $*"
}

check_fail() {
    CHECK_FAILS=$((CHECK_FAILS + 1))
    echo -e "${RED}[FAIL]${NC} $*"
}

check_hint() {
    echo "       $*"
}

check_nvidia_driver() {
    local driver_output driver_version gpu_count gpu_output

    if ! command -v nvidia-smi &>/dev/null; then
        check_fail "NVIDIA 驱动：未找到 nvidia-smi"
        check_hint "请先安装 NVIDIA 驱动 ${EXPECTED_NVIDIA_DRIVER} 并重启。"
        return
    fi

    if ! driver_output="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null)"; then
        check_fail "NVIDIA 驱动：nvidia-smi 执行失败"
        check_hint "请确认驱动已正确加载，并执行 nvidia-smi 验证。"
        return
    fi

    driver_version="$(printf '%s\n' "$driver_output" | head -1 | tr -d '[:space:]')"
    if [ -z "$driver_version" ]; then
        check_fail "NVIDIA 驱动：nvidia-smi 可执行，但未能读取 GPU/驱动信息"
        check_hint "请确认驱动加载正常，并执行 nvidia-smi 验证。"
        return
    fi

    gpu_output="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || true)"
    gpu_count="$(printf '%s\n' "$gpu_output" | sed '/^[[:space:]]*$/d' | wc -l | tr -d '[:space:]')"
    if [ "$driver_version" = "$EXPECTED_NVIDIA_DRIVER" ]; then
        check_pass "NVIDIA 驱动：${driver_version}，GPU 数量：${gpu_count:-未知}"
    else
        check_fail "NVIDIA 驱动：当前 ${driver_version}，期望 ${EXPECTED_NVIDIA_DRIVER}"
        check_hint "驱动和 CUDA 版本强绑定，请先安装指定驱动并重启。"
    fi
}

check_cuda_toolkit() {
    local cuda_version

    if ! command -v nvcc &>/dev/null; then
        if [ -x "$EXPECTED_CUDA_NVCC" ]; then
            cuda_version="$("$EXPECTED_CUDA_NVCC" --version 2>/dev/null | sed -nE 's/.*release ([0-9]+\.[0-9]+).*/\1/p' | head -1 || true)"
            if [ "$cuda_version" = "$EXPECTED_CUDA_VERSION" ]; then
                check_warn "CUDA Toolkit：${EXPECTED_CUDA_NVCC} 存在，但 nvcc 不在 PATH 中"
                check_hint "请执行：source ~/.bashrc，或重新打开终端后再运行预检。"
                return
            fi

            check_fail "CUDA Toolkit：标准路径存在 nvcc，但版本为 ${cuda_version:-无法解析}，期望 ${EXPECTED_CUDA_VERSION}"
            check_hint "建议检查 ${EXPECTED_CUDA_NVCC}，必要时执行：bash script_new/easim.sh cuda"
            return
        else
            check_fail "CUDA Toolkit：未找到 nvcc"
            check_hint "建议执行：bash script_new/easim.sh cuda"
        fi
        return
    fi

    cuda_version="$(nvcc --version 2>/dev/null | sed -nE 's/.*release ([0-9]+\.[0-9]+).*/\1/p' | head -1 || true)"
    if [ "$cuda_version" = "$EXPECTED_CUDA_VERSION" ]; then
        check_pass "CUDA Toolkit：${cuda_version}"
    elif [ -n "$cuda_version" ]; then
        check_fail "CUDA Toolkit：当前 ${cuda_version}，期望 ${EXPECTED_CUDA_VERSION}"
        check_hint "建议执行：bash script_new/easim.sh cuda"
    else
        check_fail "CUDA Toolkit：无法解析 nvcc 版本"
        check_hint "请执行 nvcc --version 检查 CUDA 安装。"
    fi

    if [ ! -e /usr/local/cuda ]; then
        check_warn "CUDA 路径：/usr/local/cuda 不存在"
        check_hint "如果 nvcc 可用但该路径不存在，请确认 PATH/LD_LIBRARY_PATH 配置符合预期。"
    fi
}

check_docker_env() {
    local docker_version docker_major

    if ! command -v docker &>/dev/null; then
        check_fail "Docker：未找到 docker 命令"
        check_hint "建议执行：bash script_new/easim.sh host-deps"
        return
    fi

    docker_version="$(docker --version 2>/dev/null | sed -nE 's/^Docker version ([0-9]+(\.[0-9]+){0,2}).*/\1/p' || true)"
    docker_major="${docker_version%%.*}"
    if [ -z "$docker_version" ] || ! [[ "$docker_major" =~ ^[0-9]+$ ]]; then
        check_fail "Docker：无法解析版本"
        check_hint "请执行 docker --version 检查 Docker 安装。"
    elif [ "$docker_major" -lt "$MIN_DOCKER_MAJOR" ]; then
        check_fail "Docker：当前 ${docker_version}，要求 >= ${MIN_DOCKER_MAJOR}.0"
        check_hint "CDI 依赖 Docker >= ${MIN_DOCKER_MAJOR}.0，建议执行：bash script_new/easim.sh host-deps"
    elif [ "$docker_version" = "$EXPECTED_DOCKER_VERSION" ]; then
        check_pass "Docker：${docker_version}"
    else
        check_warn "Docker：当前 ${docker_version}，推荐 ${EXPECTED_DOCKER_VERSION}"
        check_hint "当前版本满足 CDI 最低要求，但与文档推荐版本不一致。"
    fi

    if docker info &>/dev/null; then
        check_pass "Docker daemon：当前用户可访问"
    else
        check_fail "Docker daemon：当前用户不可访问 /var/run/docker.sock"
        check_hint "请确认 Docker 服务已启动，并重新登录或执行 newgrp docker。"
    fi
}

check_config_paths() {
    if [ ! -f "$CONFIG_FILE" ]; then
        check_fail "配置文件：未找到 $CONFIG_FILE"
        check_hint "建议执行：bash script_new/easim.sh setup"
        return
    fi

    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    check_pass "配置文件：$CONFIG_FILE"

    if [ -n "${EASIM_HOST_PATH:-}" ] && [ -d "$EASIM_HOST_PATH" ]; then
        check_pass "easim 路径：$EASIM_HOST_PATH"
    else
        check_fail "easim 路径：不存在或未配置：${EASIM_HOST_PATH:-未设置}"
        check_hint "请执行：bash script_new/easim.sh setup"
    fi

    if [ -n "${ISAAC_TELEOP_PATH:-}" ] && [ -d "$ISAAC_TELEOP_PATH" ]; then
        check_pass "Isaac Teleop 路径：$ISAAC_TELEOP_PATH"
    else
        check_warn "Isaac Teleop 路径：不存在或未配置：${ISAAC_TELEOP_PATH:-未设置}"
        check_hint "该路径只影响遥操，不影响 Docker 环境搭建。"
    fi
}

check_env() {
    CHECK_FAILS=0
    CHECK_WARNINGS=0

    echo -e "${CYAN}环境预检（只检查状态，不安装、不修改环境）${NC}"
    echo ""

    check_config_paths
    check_nvidia_driver
    check_cuda_toolkit
    check_docker_env

    echo ""
    if [ "$CHECK_FAILS" -gt 0 ]; then
        echo -e "${RED}[FAIL]${NC} 预检结果：${CHECK_FAILS} 个失败项，${CHECK_WARNINGS} 个警告项"
        return 1
    fi

    if [ "$CHECK_WARNINGS" -gt 0 ]; then
        echo -e "${YELLOW}[WARN]${NC} 预检结果：无失败项，${CHECK_WARNINGS} 个警告项"
        return 0
    fi

    check_pass "预检结果：全部通过"
}

check_command() {
    print_header
    check_env
}

first_deploy() {
    print_header
    ensure_config_or_setup

    if ask_yes_no "是否检查/修改配置？" "no"; then
        run_script "setup.sh"
    fi

    echo ""
    if ! check_env; then
        error "环境预检未通过，已停止首次部署。"
    fi

    if [ "${CHECK_WARNINGS:-0}" -gt 0 ]; then
        echo ""
        if ! ask_yes_no "预检存在警告项，是否继续首次部署？" "no"; then
            error "已根据预检结果取消首次部署。"
        fi
    fi

    echo ""
    info "开始首次部署。"
    run_script "02_setup_cdi.sh"
    run_script "03_build_image.sh"
    run_script "04_start_container.sh"

    if ask_yes_no "是否现在初始化容器环境？新容器通常需要执行一次。" "yes"; then
        init_container_env
    else
        info "稍后可运行：bash script_new/easim.sh init"
    fi
}

start_container() {
    load_config
    run_script "04_start_container.sh"
}

init_container_env() {
    load_config

    if ! command -v docker &>/dev/null; then
        error "未找到 docker 命令，请先安装 Docker。"
    fi

    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        warn "容器 $CONTAINER_NAME 未运行。"
        if ask_yes_no "是否先启动容器？" "yes"; then
            run_script "04_start_container.sh"
        else
            error "容器未运行，无法初始化。"
        fi
    fi

    info "在容器 $CONTAINER_NAME 内执行初始化脚本..."
    if [ -t 0 ] && [ -t 1 ]; then
        docker exec -it "$CONTAINER_NAME" bash /deploy_scripts/05_init_docker_env.sh
    else
        docker exec -i "$CONTAINER_NAME" bash /deploy_scripts/05_init_docker_env.sh
    fi
}

status_report() {
    print_header

    local docker_available=false

    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        info "配置文件：$CONFIG_FILE"
        if [ -n "${EASIM_HOST_PATH:-}" ] && [ -d "$EASIM_HOST_PATH" ]; then
            info "easim 路径：$EASIM_HOST_PATH"
        else
            warn "easim 路径不存在或未配置：${EASIM_HOST_PATH:-未设置}"
        fi
        info "镜像名：${IMAGE_NAME:-未设置}"
        info "容器名：${CONTAINER_NAME:-未设置}"
        info "默认运行环境：${DEFAULT_RUN_ENV:-每次询问}"
    else
        warn "未找到 config.sh"
    fi

    echo ""
    if command -v docker &>/dev/null; then
        info "Docker：$(docker --version 2>/dev/null || echo 未可用)"
        if docker info &>/dev/null; then
            docker_available=true
        else
            warn "Docker daemon 不可访问，请确认 Docker 服务已启动，且当前用户有权限访问 /var/run/docker.sock。"
        fi

        if [ "$docker_available" = true ] && [ -n "${IMAGE_NAME:-}" ]; then
            if docker image inspect "$IMAGE_NAME" &>/dev/null; then
                info "镜像状态：$IMAGE_NAME 已存在"
            else
                warn "镜像状态：$IMAGE_NAME 不存在"
            fi
        fi

        if [ "$docker_available" = true ] && [ -n "${CONTAINER_NAME:-}" ]; then
            if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
                local container_status
                container_status="$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo unknown)"
                info "容器状态：$CONTAINER_NAME ($container_status)"
            else
                warn "容器状态：$CONTAINER_NAME 不存在"
            fi
        fi
    else
        warn "Docker：未安装或不在 PATH 中"
    fi

    if [ -f /etc/cdi/nvidia.yaml ]; then
        info "CDI 规格：/etc/cdi/nvidia.yaml 已存在"
    else
        warn "CDI 规格：/etc/cdi/nvidia.yaml 不存在"
    fi

}

main_menu() {
    while true; do
        print_header
        echo "请选择功能："
        echo "  1) 首次部署"
        echo "  2) 重启/恢复环境"
        echo "  3) 状态查看"
        echo "  0) 退出"
        echo ""
        read -rp "输入序号 [0-3]: " choice

        case "$choice" in
            1) run_menu_action first_deploy ;;
            2) run_menu_action start_container ;;
            3) run_menu_action status_report ;;
            0) exit 0 ;;
            *) warn "无效输入：$choice"; pause ;;
        esac
    done
}

command="${1:-menu}"
case "$command" in
    menu) main_menu ;;
    help|-h|--help) usage ;;
    check) check_command ;;
    setup|config) setup_config ;;
    deploy) first_deploy ;;
    restart|start|container) start_container ;;
    init) init_container_env ;;
    status) status_report ;;
    cuda) run_script "00_install_cuda.sh" ;;
    host-deps|deps|docker) run_script "01_install_host_deps.sh" ;;
    cdi) run_script "02_setup_cdi.sh" ;;
    build|image) run_script "03_build_image.sh" ;;
    *)
        warn "未知命令：$command"
        echo ""
        usage
        exit 1
        ;;
esac
