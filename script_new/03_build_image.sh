#!/usr/bin/env bash
# =============================================================================
# 03_build_image.sh — 检查并构建 easim Docker 镜像
# 运行位置：宿主机
# 运行时机：首次部署，或需要重新构建镜像时
# 前置条件：01_install_host_deps.sh、02_setup_cdi.sh 已执行
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ---------- 颜色输出 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

DOCKERFILE_PATH="${EASIM_HOST_PATH}/${DOCKERFILE}"
DEFAULT_BASE_IMAGE="nvidia/cuda:12.8.0-devel-ubuntu22.04"
DEFAULT_PYTORCH_INDEX_URL="https://download.pytorch.org/whl/cu128"
LEGACY_BASE_IMAGE="nvidia/cuda:13.0.0-devel-ubuntu22.04"
LEGACY_PYTORCH_INDEX_URL="https://download.pytorch.org/whl/cu130"

# ---------- 检查 easim 路径 ----------
if [ ! -d "$EASIM_HOST_PATH" ]; then
    error "EASIM_HOST_PATH 不存在：$EASIM_HOST_PATH\n  请先运行 setup.sh 填写正确路径"
fi

# ---------- 检查 / 自动生成 Dockerfile ----------
if [ -f "$DOCKERFILE_PATH" ]; then
    info "Dockerfile 已存在：$DOCKERFILE_PATH"
    if grep -q "$LEGACY_BASE_IMAGE" "$DOCKERFILE_PATH" || grep -q "$LEGACY_PYTORCH_INDEX_URL" "$DOCKERFILE_PATH"; then
        warn "检测到旧 CUDA/PyTorch 默认源，自动更新为 CUDA 12.8 / cu128..."
        sed -i \
            -e "s|ARG BASE_IMAGE=${LEGACY_BASE_IMAGE}|ARG BASE_IMAGE=${DEFAULT_BASE_IMAGE}|g" \
            -e "s|ARG PYTORCH_INDEX_URL=${LEGACY_PYTORCH_INDEX_URL}|ARG PYTORCH_INDEX_URL=${DEFAULT_PYTORCH_INDEX_URL}|g" \
            "$DOCKERFILE_PATH"
        info "Dockerfile 默认镜像/源已更新 ✓"
    fi
else
    warn "未找到 $DOCKERFILE_PATH，自动生成..."
    mkdir -p "$(dirname "$DOCKERFILE_PATH")"
    cat > "$DOCKERFILE_PATH" << 'DOCKERFILE_CONTENT'
# 1. 基础镜像
ARG BASE_IMAGE=nvidia/cuda:12.8.0-devel-ubuntu22.04
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive
ARG UBUNTU_MIRROR=https://mirrors.tuna.tsinghua.edu.cn
ARG ROS2_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/ros2/ubuntu
ENV BUILD_DIR=/opt/unitree-setup
ENV WORK_DIR=/data

RUN sed -i "s|http://archive.ubuntu.com/ubuntu|${UBUNTU_MIRROR}/ubuntu|g" /etc/apt/sources.list && \
    sed -i "s|http://security.ubuntu.com/ubuntu|${UBUNTU_MIRROR}/ubuntu|g" /etc/apt/sources.list && \
    printf 'Acquire::ForceIPv4 "true";\nAcquire::Retries "5";\n' > /etc/apt/apt.conf.d/99easim-apt

RUN apt-get update && apt-get install -y \
    locales curl gnupg2 lsb-release software-properties-common \
    && rm -rf /var/lib/apt/lists/*

RUN locale-gen en_US en_US.UTF-8 && update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

RUN curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key -o /usr/share/keyrings/ros-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] ${ROS2_MIRROR} $(. /etc/os-release && echo $UBUNTU_CODENAME) main" > /etc/apt/sources.list.d/ros2.list

RUN apt-get update && apt-get install -y \
    ros-humble-ros-base python3-colcon-common-extensions \
    && rm -rf /var/lib/apt/lists/*

RUN apt-get update && apt-get install -y \
    iproute2 net-tools pciutils usbutils vim git wget git-lfs unzip \
    openssh-client python3-pip build-essential cmake ninja-build \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --upgrade pip && pip3 install cmake --upgrade

RUN which conda > /dev/null 2>&1 || \
    (wget -q https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O /tmp/miniconda.sh && \
    bash /tmp/miniconda.sh -b -p /opt/miniconda3 && rm /tmp/miniconda.sh && \
    /opt/miniconda3/bin/conda init bash && \
    /opt/miniconda3/bin/conda config --system --set auto_activate_base false && \
    /opt/miniconda3/bin/conda config --system --prepend channels conda-forge && \
    /opt/miniconda3/bin/conda config --system --set auto_update_conda false && \
    /opt/miniconda3/bin/conda clean -afy)

ENV PATH=/opt/miniconda3/bin:${PATH}

RUN /opt/miniconda3/bin/conda config --set channel_priority flexible && \
    /opt/miniconda3/bin/conda config --system --set auto_activate_base false && \
    /opt/miniconda3/bin/conda config --system --add channels defaults && \
    echo "yes" | /opt/miniconda3/bin/conda tos accept 2>/dev/null || \
    (/opt/miniconda3/bin/conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main 2>/dev/null || true) && \
    (/opt/miniconda3/bin/conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r 2>/dev/null || true)

RUN rm -f /etc/apt/sources.list.d/cuda*.list /etc/apt/sources.list.d/nvidia-ml*.list
RUN apt-get update && apt-get install -y \
    ros-humble-rmw-cyclonedds-cpp ros-humble-rosidl-generator-dds-idl \
    libopencv-dev ros-humble-rosbridge-server libcurlpp-dev libcurl4-openssl-dev \
    && rm -rf /var/lib/apt/lists/*

ARG PYTORCH_INDEX_URL=https://download.pytorch.org/whl/cu128
ARG TORCH_VERSION=
RUN if [ -n "${TORCH_VERSION}" ]; then \
      pip install --no-cache-dir --force-reinstall \
        "torch==${TORCH_VERSION}" "torchvision" "torchaudio" \
        --index-url "${PYTORCH_INDEX_URL}"; \
    else \
      pip install --no-cache-dir --force-reinstall \
        torch torchvision torchaudio --index-url "${PYTORCH_INDEX_URL}"; \
    fi && pip3 install --no-cache-dir pre-commit

RUN apt-get update && apt-get install -y \
    ros-humble-pcl-ros ros-humble-pcl-conversions libc++1 libc++abi1 \
    && rm -rf /var/lib/apt/lists/*

ENV PATH=/usr/local/cuda/bin:$PATH
ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH
ENV CUDACXX=/usr/local/cuda/bin/nvcc

ENV ISAACSIM_VERSION=v5.1.0 \
    ISAACLAB_VERSION=v2.3.0 \
    WORKSPACE=${WORK_DIR}/isaac_workspace \
    PYTHON_VERSION=3.11 \
    ENV_NAME=env_isaaclab_easim \
    ISAACSIM_PATH=${WORK_DIR}/isaac_workspace/IsaacSim \
    ISAACSIM_PYTHON_EXE=${WORK_DIR}/isaac_workspace/IsaacSim/python.sh

RUN set -eux; \
    rm -rf "${WORKSPACE}"; mkdir -p "${WORKSPACE}"; cd "${WORKSPACE}"; \
    wget http://10.151.5.18:30080/isaac_sim/isaac-sim-standalone-5.1.0-linux-x86_64.zip; \
    unzip isaac-sim-standalone-5.1.0-linux-x86_64.zip -d IsaacSim; \
    rm -f isaac-sim-standalone-5.1.0-linux-x86_64.zip

RUN set -eux; "${ISAACSIM_PYTHON_EXE}" -c "print('Isaac Sim configuration is now complete.')"

RUN set -eux; cd "${WORKSPACE}"; \
    if [ ! -d IsaacLab ]; then git clone https://github.com/isaac-sim/IsaacLab.git; fi; \
    cd IsaacLab; git fetch --tags; git checkout "tags/${ISAACLAB_VERSION}" -b "${ISAACLAB_VERSION}"

RUN set -eux; ln -sfn "${ISAACSIM_PATH}" "${WORKSPACE}/IsaacLab/_isaac_sim"

RUN bash -lc 'set -exo pipefail; eval "$(conda shell.bash hook)"; export TERM=xterm; \
    conda remove -n "${ENV_NAME}" --all -y || true; \
    cd "${WORKSPACE}/IsaacLab"; ./isaaclab.sh -c "${ENV_NAME}"'

RUN bash -lc 'set -exo pipefail; eval "$(conda shell.bash hook)"; \
    conda activate "${ENV_NAME}"; conda remove -y packaging || true; \
    printf "setuptools<82\n" > /tmp/isaaclab-pip-constraint.txt'

RUN bash -lc 'set -exo pipefail; eval "$(conda shell.bash hook)"; \
    conda activate "${ENV_NAME}"; conda install -y pip; \
    python -m pip install -U pip wheel "setuptools<82"; \
    python -m pip install --ignore-installed --no-deps packaging==26.0; \
    if [ -x /usr/bin/cmake ]; then export PATH="/usr/bin:/bin:${PATH}"; fi'

RUN bash -lc 'set -exo pipefail; eval "$(conda shell.bash hook)"; export TERM=xterm; \
    conda activate "${ENV_NAME}"; \
    if [ -x /usr/bin/cmake ]; then export PATH="/usr/bin:/bin:${PATH}"; fi; \
    cd "${WORKSPACE}/IsaacLab"; which python; python --version; test -f ./isaaclab.sh; ls -ld _isaac_sim'

RUN bash -lc 'set -exo pipefail; eval "$(conda shell.bash hook)"; export TERM=xterm; \
    conda activate "${ENV_NAME}"; \
    if [ -x /usr/bin/cmake ]; then export PATH="/usr/bin:/bin:${PATH}"; fi; \
    cd "${WORKSPACE}/IsaacLab"; \
    PIP_CONSTRAINT=/tmp/isaaclab-pip-constraint.txt ./isaaclab.sh --install; \
    rm -f /tmp/isaaclab-pip-constraint.txt'

RUN bash -lc 'set -exo pipefail; eval "$(conda shell.bash hook)"; \
    conda activate "${ENV_NAME}"; \
    mkdir -p "${CONDA_PREFIX}/etc/conda/activate.d" "${CONDA_PREFIX}/etc/conda/deactivate.d"; \
    printf "%s\n" "#!/usr/bin/env bash" \
    "export _OLD_LD_LIBRARY_PATH=\"\${LD_LIBRARY_PATH:-}\"" \
    "EXTRA_LD_PATHS=\"\${CONDA_PREFIX}/lib:${ISAACSIM_PATH}/exts/isaacsim.ros2.bridge/humble/lib\"" \
    "if [ -n \"\${LD_LIBRARY_PATH:-}\" ]; then export LD_LIBRARY_PATH=\"\${EXTRA_LD_PATHS}:\${LD_LIBRARY_PATH}\"" \
    "else export LD_LIBRARY_PATH=\"\${EXTRA_LD_PATHS}\"; fi" \
    > "${CONDA_PREFIX}/etc/conda/activate.d/isaaclab_ld_library_path.sh"; \
    printf "%s\n" "#!/usr/bin/env bash" \
    "if [ -n \"\${_OLD_LD_LIBRARY_PATH+x}\" ]; then export LD_LIBRARY_PATH=\"\${_OLD_LD_LIBRARY_PATH}\"; unset _OLD_LD_LIBRARY_PATH" \
    "else unset LD_LIBRARY_PATH; fi" \
    > "${CONDA_PREFIX}/etc/conda/deactivate.d/isaaclab_ld_library_path.sh"; \
    chmod +x "${CONDA_PREFIX}/etc/conda/activate.d/isaaclab_ld_library_path.sh" \
             "${CONDA_PREFIX}/etc/conda/deactivate.d/isaaclab_ld_library_path.sh"'

RUN printf '%s\n' 'export TERM=xterm' 'export DISPLAY=:1.0' \
    'export ROS_DISTRO=humble' 'export RMW_IMPLEMENTATION=rmw_fastrtps_cpp' >> ~/.bashrc

WORKDIR ${WORK_DIR}
CMD ["bash"]
DOCKERFILE_CONTENT
    info "Dockerfile 已自动生成：$DOCKERFILE_PATH ✓"
fi

# ---------- 检查镜像是否已存在 ----------
if docker image inspect "$IMAGE_NAME" &>/dev/null; then
    info "镜像 ${IMAGE_NAME} 已存在，跳过构建"
    info "如需重新构建，请先执行：docker rmi ${IMAGE_NAME}"
    exit 0
fi

# ---------- 构建镜像 ----------
info "开始构建镜像 ${IMAGE_NAME}（时间较长，请耐心等待）..."
info "构建上下文：${EASIM_HOST_PATH}"
info "Dockerfile：${DOCKERFILE_PATH}"

docker build \
    -f "$DOCKERFILE_PATH" \
    -t "$IMAGE_NAME" \
    "$EASIM_HOST_PATH"

info "镜像 ${IMAGE_NAME} 构建完成 ✓"
info "===== 03_build_image.sh 执行完成 ====="
info "下一步：运行 04_start_container.sh"
