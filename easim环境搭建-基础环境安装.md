# easim环境搭建\-基础环境安装

1. 工作站基础环境构建

    1. nvidia\-smi显卡驱动安装580\.159\.03

    2. cuda12\.8安装

        ```Plain Text
        wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-ubuntu2204.pin
        sudo mv cuda-ubuntu2204.pin /etc/apt/preferences.d/cuda-repository-pin-600
        
        #下载安装包
        wget https://developer.download.nvidia.com/compute/cuda/12.8.0/local_installers/cuda-repo-ubuntu2204-12-8-local_12.8.0-570.86.10-1_amd64.deb
        
        #安装
        sudo dpkg -i cuda-repo-ubuntu2204-12-8-local_12.8.0-570.86.10-1_amd64.deb
        sudo cp /var/cuda-repo-ubuntu2204-12-8-local/cuda-485B8195-keyring.gpg /usr/share/keyrings/
        
        sudo apt update
        
        #安装 CUDA Toolkit 12.8
        sudo apt install cuda-toolkit-12-8
        
        #配置环境变量
        echo 'export PATH=/usr/local/cuda-12.8/bin:$PATH' >> ~/.bashrc
        echo 'export LD_LIBRARY_PATH=/usr/local/cuda-12.8/lib64:$LD_LIBRARY_PATH' >> ~/.bashrc
        source ~/.bashrc
        
        #验证
        nvcc --version
        ```

        1. 参考文档

            1. https://developer\.nvidia\.com/cuda\-downloads?target\_os=Linux\&target\_arch=x86\_64\&Distribution=Ubuntu\&target\_version=22\.04\&target\_type=deb\_local

    3. 安装docker 29\.1\.3

        ```Plain Text
        #更新系统并安装依赖
        sudo apt update
        sudo apt install -y \
            ca-certificates \
            curl \
            gnupg \
            lsb-release
        
        添加 Docker 官方 GPG Key
        sudo install -m 0755 -d /etc/apt/keyrings
        
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        
        sudo chmod a+r /etc/apt/keyrings/docker.gpg
        
        #添加 Docker 仓库
        echo \
          "deb [arch=$(dpkg --print-architecture) \
          signed-by=/etc/apt/keyrings/docker.gpg] \
          https://download.docker.com/linux/ubuntu \
          $(. /etc/os-release && echo $VERSION_CODENAME) stable" | \
          sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        #更新软件源
        sudo apt update
        
        #查看可安装版本
        apt-cache madison docker-ce
        
        #确认版本号
        apt-cache madison docker-ce | grep 29.1.3
        
        #安装
        VERSION_STRING="5:29.1.3-1~ubuntu.22.04~jammy"
        sudo apt install -y \
            docker-ce=$VERSION_STRING \
            docker-ce-cli=$VERSION_STRING \
            containerd.io \
            docker-buildx-plugin \
            docker-compose-plugin
            
        #启动 Docker
        sudo systemctl enable docker
        sudo systemctl start docker
        
        sudo systemctl status docker
        
        #验证安装
        docker --version
        
        #将当前用户加入 docker 组：
        sudo usermod -aG docker $USER
        newgrp docker
        
        #验证
        newgrp docker
        ```

1. 搭建easim docker环境

    ```Plain Text
    #代码仓库链接
    https://gitlab.senseauto.com/kaiwu/simulation/utils/easim/-/commits/feature%2Fnav2-integration-dev-20260410?ref_type=heads
    
    #切换到当前分支
    origin/feature/nav2-integration-dev-20260410
    ```

    1. Dockerfile

        1. 文件名

            1. Dockerfile\.easimnew

        2. 文件内容\(做过了部分修改\)

        ```Bash
        # 1. 基础镜像
        # 方案 B：与宿主机驱动 580 官方支持对齐，使用 CUDA 13.x 基础镜像，再安装 ROS2 Humble
        # 若拉取 docker.io 超时，可先在其他网络拉取镜像再 build，或使用：--build-arg BASE_IMAGE=镜像地址
        ARG BASE_IMAGE=nvidia/cuda:13.0.0-devel-ubuntu22.04
        FROM ${BASE_IMAGE}
        
        # 设置环境变量，避免交互式弹窗
        ENV DEBIAN_FRONTEND=noninteractive
        ARG UBUNTU_MIRROR=https://mirrors.tuna.tsinghua.edu.cn
        ARG ROS2_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/ros2/ubuntu
        # 修改点：将构建目录设在 /opt 下，避免与 runtime 的 /data 挂载冲突
        ENV BUILD_DIR=/opt/unitree-setup
        ENV WORK_DIR=/data
        
        # 使用国内镜像源，并提高 apt 在网络抖动时的稳定性
        RUN sed -i "s|http://archive.ubuntu.com/ubuntu|${UBUNTU_MIRROR}/ubuntu|g" /etc/apt/sources.list && \
            sed -i "s|http://security.ubuntu.com/ubuntu|${UBUNTU_MIRROR}/ubuntu|g" /etc/apt/sources.list && \
            printf 'Acquire::ForceIPv4 "true";\nAcquire::Retries "5";\n' > /etc/apt/apt.conf.d/99easim-apt
        
        # 1.1 安装 ROS2 Humble（在 CUDA 13.0 的 Ubuntu 22.04 上）
        RUN apt-get update && apt-get install -y \
            locales \
            curl \
            gnupg2 \
            lsb-release \
            software-properties-common \
            && rm -rf /var/lib/apt/lists/*
        
        RUN locale-gen en_US en_US.UTF-8 && \
            update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
        
        ENV LANG=en_US.UTF-8
        ENV LC_ALL=en_US.UTF-8
        
        RUN curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key -o /usr/share/keyrings/ros-archive-keyring.gpg && \
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] ${ROS2_MIRROR} $(. /etc/os-release && echo $UBUNTU_CODENAME) main" > /etc/apt/sources.list.d/ros2.list
        
        RUN apt-get update && apt-get install -y \
            ros-humble-ros-base \
            python3-colcon-common-extensions \
            && rm -rf /var/lib/apt/lists/*
        
        # 2. 初始基础工具安装
        RUN apt-get update && apt-get install -y \
            iproute2 \
            net-tools \
            pciutils \
            usbutils \
            vim \
            git \
            wget \
            git-lfs \
            unzip \
            openssh-client \
            python3-pip \
            build-essential \
            cmake \
            ninja-build \
            && rm -rf /var/lib/apt/lists/*
        
        # 3. 基础 Python 包升级
        RUN pip3 install --upgrade pip && pip3 install cmake --upgrade
        
        ###################################################
        # 安装 Conda（Miniconda）
        ###################################################
        # 检查 conda 是否已安装，如果没有则安装 Miniconda
        RUN which conda > /dev/null 2>&1 || \
            (echo "Installing Miniconda..." && \
            wget -q https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O /tmp/miniconda.sh && \
            bash /tmp/miniconda.sh -b -p /opt/miniconda3 && \
            rm /tmp/miniconda.sh && \
            /opt/miniconda3/bin/conda init bash && \
            /opt/miniconda3/bin/conda config --system --set auto_activate_base false && \
            /opt/miniconda3/bin/conda config --system --prepend channels conda-forge && \
            /opt/miniconda3/bin/conda config --system --set auto_update_conda false && \
            /opt/miniconda3/bin/conda clean -afy)
        
        # 添加 conda 到 PATH
        ENV PATH=/opt/miniconda3/bin:${PATH}
        
        # 接受 Conda Terms of Service, 避免后续执行conda命令出错
        RUN /opt/miniconda3/bin/conda config --set channel_priority flexible && \
            /opt/miniconda3/bin/conda config --system --set auto_activate_base false && \
            /opt/miniconda3/bin/conda config --system --add channels defaults && \
            echo "yes" | /opt/miniconda3/bin/conda tos accept 2>/dev/null || \
            (/opt/miniconda3/bin/conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main 2>/dev/null || true) && \
            (/opt/miniconda3/bin/conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r 2>/dev/null || true)
        
        # 6. 后置安装：ROS DDS 相关包和剩余依赖
        # CUDA 已由基础镜像安装完毕，移除 NVIDIA apt 源，避免镜像同步期间校验失败
        RUN rm -f /etc/apt/sources.list.d/cuda*.list /etc/apt/sources.list.d/nvidia-ml*.list
        RUN apt-get update && apt-get install -y \
            ros-humble-rmw-cyclonedds-cpp \
            ros-humble-rosidl-generator-dds-idl \
            libopencv-dev \
            ros-humble-rosbridge-server \
            libcurlpp-dev \
            libcurl4-openssl-dev \
            && rm -rf /var/lib/apt/lists/*
        
        # 10. 深度学习环境与工具（方案 B：CUDA 13.x 对齐）
        # 说明：不强行 pin 具体 torch 版本，避免 cu130 index 中无该版本导致构建失败；
        # 如需固定版本，可在 build 时传入 --build-arg TORCH_VERSION=...
        ARG PYTORCH_INDEX_URL=https://download.pytorch.org/whl/cu130
        ARG TORCH_VERSION=
        RUN if [ -n "${TORCH_VERSION}" ]; then \
              pip install --no-cache-dir --force-reinstall \
                "torch==${TORCH_VERSION}" "torchvision" "torchaudio" \
                --index-url "${PYTORCH_INDEX_URL}"; \
            else \
              pip install --no-cache-dir --force-reinstall \
                torch torchvision torchaudio \
                --index-url "${PYTORCH_INDEX_URL}"; \
            fi && \
            pip3 install --no-cache-dir pre-commit
        
        # 11. 补充第三方依赖（colcon build 所需，原镜像未包含）
        
        # 11.1 ROS2 PCL 相关包 + libc++ 运行时（Open3D 预编译包依赖 LLVM libc++）
        RUN apt-get update && apt-get install -y \
            ros-humble-pcl-ros \
            ros-humble-pcl-conversions \
            libc++1 \
            libc++abi1 \
            && rm -rf /var/lib/apt/lists/*
        
        # 13. 设置 CUDA 与环境路径
        ENV PATH=/usr/local/cuda/bin:$PATH
        ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH
        ENV CUDACXX=/usr/local/cuda/bin/nvcc
        # 设置关键的 DDS 环境变量指向 BUILD_DIR (即 /opt)
        # ENV CYCLONEDDS_HOME=${BUILD_DIR}/unitree_ros2/cyclonedds_ws/install/cyclonedds/
        # # 让 CMake 能 find_package(CycloneDDS/CycloneDDS-CXX)
        # ENV CMAKE_PREFIX_PATH=/opt/cyclonedds:/opt/cyclonedds-cxx:/opt/unitree_robotics
        
        # 自动 source 环境到 bashrc
        # 注意顺序：unitree cyclonedds 必须在 ros humble 之后 source，
        # 使其 bin/idlc 优先于 /opt/ros/humble/bin/idlc（后者 -l cxx 在本环境中会段错误）
        # RUN echo "source /opt/ros/humble/setup.bash" >> ~/.bashrc && \
        #     echo "source ${BUILD_DIR}/unitree_ros2/cyclonedds_ws/install/setup.bash" >> ~/.bashrc && \
        #     echo "source /opt/livox_ws/install/setup.bash" >> ~/.bashrc && \
        #     echo "export CYCLONEDDS_HOME=${CYCLONEDDS_HOME}" >> ~/.bashrc && \
        #     echo "export LD_LIBRARY_PATH=$LD_LIBRARY_PATH" >> ~/.bashrc
        
        # 13.1 Isaac Sim / Isaac Lab 安装参数
        ENV ISAACSIM_VERSION=v5.1.0 \
            ISAACLAB_VERSION=v2.3.0 \
            WORKSPACE=${WORK_DIR}/isaac_workspace \
            PYTHON_VERSION=3.11 \
            ENV_NAME=env_isaaclab_easim \
            ISAACSIM_PATH=${WORK_DIR}/isaac_workspace/IsaacSim \
            ISAACSIM_PYTHON_EXE=${WORK_DIR}/isaac_workspace/IsaacSim/python.sh
        
        # 13.2 创建工作目录并安装 Isaac Sim 预编译包
        RUN set -eux; \
            rm -rf "${WORKSPACE}"; \
            mkdir -p "${WORKSPACE}"; \
            cd "${WORKSPACE}"; \
            echo "[2/7] 下载并解压 Isaac Sim ${ISAACSIM_VERSION} 预编译版本..."; \
            wget http://10.151.5.18:30080/isaac_sim/isaac-sim-standalone-5.1.0-linux-x86_64.zip; \
            unzip isaac-sim-standalone-5.1.0-linux-x86_64.zip -d IsaacSim; \
            rm -f isaac-sim-standalone-5.1.0-linux-x86_64.zip
        
        # 13.3 验证 Isaac Sim Python 入口
        RUN set -eux; \
            echo "[4/7] 设置并验证 Isaac Sim 环境变量..."; \
            "${ISAACSIM_PYTHON_EXE}" -c "print('Isaac Sim configuration is now complete.')"
        
        # 13.4 克隆 Isaac Lab 并切换到指定版本
        RUN set -eux; \
            echo "[5/7] 克隆 Isaac Lab ${ISAACLAB_VERSION}..."; \
            cd "${WORKSPACE}"; \
            if [ ! -d IsaacLab ]; then \
                git clone https://github.com/isaac-sim/IsaacLab.git; \
            fi; \
            cd IsaacLab; \
            git fetch --tags; \
            git checkout "tags/${ISAACLAB_VERSION}" -b "${ISAACLAB_VERSION}"
        
        # 13.5 建立 Isaac Sim 符号链接
        RUN set -eux; \
            echo "[6/7] 建立 Isaac Sim 符号链接..."; \
            ln -sfn "${ISAACSIM_PATH}" "${WORKSPACE}/IsaacLab/_isaac_sim"
        
        # 13.6 使用 Conda 创建 Isaac Lab 虚拟环境
        RUN bash -lc 'set -exo pipefail; \
            echo "[7/7] 创建 Python 虚拟环境(Conda版)..."; \
            eval "$(conda shell.bash hook)"; \
            export TERM=xterm; \
            conda remove -n "${ENV_NAME}" --all -y || true; \
            cd "${WORKSPACE}/IsaacLab"; \
            ./isaaclab.sh -c "${ENV_NAME}"'
        
        # 13.7 安装 Isaac Lab 依赖
        RUN bash -lc 'set -exo pipefail; \
            echo "[7/7] 安装 Isaac Lab 依赖: 准备环境..."; \
            eval "$(conda shell.bash hook)"; \
            conda activate "${ENV_NAME}"; \
            conda remove -y packaging || true; \
            printf "setuptools<82\n" > /tmp/isaaclab-pip-constraint.txt'
        
        #modify by kxq
        RUN bash -lc 'set -exo pipefail; \
            echo "[7/7] 安装 Isaac Lab 依赖: 安装 pip 基础包..."; \
            eval "$(conda shell.bash hook)"; \
            conda activate "${ENV_NAME}"; \
            conda install -y pip; \
            python -m pip install -U pip wheel "setuptools<82"; \
            python -m pip install --ignore-installed --no-deps packaging==26.0; \
            if [ -x /usr/bin/cmake ]; then \
                export PATH="/usr/bin:/bin:${PATH}"; \
                echo "Using system cmake: $(/usr/bin/cmake --version | sed -n "1p")"; \
            fi'
        
        RUN bash -lc 'set -exo pipefail; \
            echo "[7/7] 安装 Isaac Lab 依赖: 检查激活环境..."; \
            eval "$(conda shell.bash hook)"; \
            export TERM=xterm; \
            conda activate "${ENV_NAME}"; \
            if [ -x /usr/bin/cmake ]; then \
                export PATH="/usr/bin:/bin:${PATH}"; \
            fi; \
            cd "${WORKSPACE}/IsaacLab"; \
            echo "CONDA_PREFIX=${CONDA_PREFIX}"; \
            which python; \
            python --version; \
            python -m pip --version; \
            test -f ./isaaclab.sh; \
            ls -ld _isaac_sim'
        
        RUN bash -lc 'set -exo pipefail; \
            echo "[7/7] 安装 Isaac Lab 依赖: 执行 isaaclab 安装..."; \
            eval "$(conda shell.bash hook)"; \
            export TERM=xterm; \
            conda activate "${ENV_NAME}"; \
            if [ -x /usr/bin/cmake ]; then \
                export PATH="/usr/bin:/bin:${PATH}"; \
            fi; \
            cd "${WORKSPACE}/IsaacLab"; \
            PIP_CONSTRAINT=/tmp/isaaclab-pip-constraint.txt ./isaaclab.sh --install; \
            rm -f /tmp/isaaclab-pip-constraint.txt; \
            echo "IsaacSim ${ISAACSIM_VERSION}, IsaacLab ${ISAACLAB_VERSION} 均已安装完成！"'
        
        RUN bash -lc 'set -exo pipefail; \
            eval "$(conda shell.bash hook)"; \
            conda activate "${ENV_NAME}"; \
            mkdir -p "${CONDA_PREFIX}/etc/conda/activate.d" "${CONDA_PREFIX}/etc/conda/deactivate.d"; \
            printf "%s\n" \
            "#!/usr/bin/env bash" \
            "export _OLD_LD_LIBRARY_PATH=\"\${LD_LIBRARY_PATH:-}\"" \
            "EXTRA_LD_PATHS=\"\${CONDA_PREFIX}/lib:${ISAACSIM_PATH}/exts/isaacsim.ros2.bridge/humble/lib\"" \
            "if [ -n \"\${LD_LIBRARY_PATH:-}\" ]; then" \
            "    export LD_LIBRARY_PATH=\"\${EXTRA_LD_PATHS}:\${LD_LIBRARY_PATH}\"" \
            "else" \
            "    export LD_LIBRARY_PATH=\"\${EXTRA_LD_PATHS}\"" \
            "fi" \
            > "${CONDA_PREFIX}/etc/conda/activate.d/isaaclab_ld_library_path.sh"; \
            printf "%s\n" \
            "#!/usr/bin/env bash" \
            "if [ -n \"\${_OLD_LD_LIBRARY_PATH+x}\" ]; then" \
            "    export LD_LIBRARY_PATH=\"\${_OLD_LD_LIBRARY_PATH}\"" \
            "    unset _OLD_LD_LIBRARY_PATH" \
            "else" \
            "    unset LD_LIBRARY_PATH" \
            "fi" \
            > "${CONDA_PREFIX}/etc/conda/deactivate.d/isaaclab_ld_library_path.sh"; \
            chmod +x "${CONDA_PREFIX}/etc/conda/activate.d/isaaclab_ld_library_path.sh" "${CONDA_PREFIX}/etc/conda/deactivate.d/isaaclab_ld_library_path.sh"'
        
        RUN printf '%s\n' \
            'export TERM=xterm' \
            'export DISPLAY=:1.0' \
            'export ROS_DISTRO=humble' \
            'export RMW_IMPLEMENTATION=rmw_fastrtps_cpp' \
            >> ~/.bashrc
        # 14. 最终工作目录 - 此时挂载宿主机代码到这里将是安全的
        WORKDIR ${WORK_DIR}
        
        # 默认保持 shell 开启
        CMD ["bash"]
        ```

    2. 参考文档

        1. [esim docker 使用](https://wcn31vzievmy.feishu.cn/wiki/CaAMwHujpiKja3k1DBPcrrITnLu)





