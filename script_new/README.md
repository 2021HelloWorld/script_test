# easim Docker 环境搭建脚本说明

## 脚本放置位置

这套部署脚本是宿主机侧的辅助脚本，不是 easim 仿真项目源码的一部分。可以把 `script_new/` 放在宿主机任意目录中使用，只要确保 `config.sh` 中的 `EASIM_HOST_PATH` 指向 easim 仿真项目根目录即可。

容器启动时会挂载：

| 宿主机路径 | 容器内路径 | 说明 |
|------------|------------|------|
| `EASIM_HOST_PATH` | `/easim` | easim 代码仓库 |
| `script_new/` | `/deploy_scripts` | 本目录下的部署脚本 |

> 不建议把这套部署脚本放进 `.../easim/scripts/`。该路径通常属于 easim 仓库自己的脚本目录，和容器内的 `/deploy_scripts/` 不是同一用途，混放容易造成误解。

---

## 目录结构

```text
script_new/
├── easim.sh                # 统一入口菜单和快捷命令
├── setup.sh                # 交互式配置向导，生成 config.sh
├── config.sh               # 统一配置变量
├── 00_install_cuda.sh      # 安装 CUDA Toolkit 12.8（宿主机）
├── 01_install_host_deps.sh # 安装 Docker 29.1.3（宿主机）
├── 02_setup_cdi.sh         # 安装 nvidia-ctk + 生成 CDI 规格
├── 03_build_image.sh       # 检查/生成 Dockerfile，构建 Docker 镜像
├── 04_start_container.sh   # 刷新 Xauth + 启动容器
├── 05_init_docker_env.sh   # 容器内初始化 Isaac Lab/easim 环境
└── README.md               # 本文档
```

---

## 全新机器搭建流程

每台机器首次部署按以下顺序执行。

### 1. 安装 NVIDIA 显卡驱动

要求版本：`580.159.03`

可以通过系统「软件和更新 -> 附加驱动」安装，或使用命令安装：

```bash
sudo ubuntu-drivers install nvidia:580
sudo reboot
```

重启后验证：

```bash
nvidia-smi
```

### 2. 安装 CUDA 12.8

```bash
bash script_new/00_install_cuda.sh
```

验证：

```bash
nvcc --version
```

> 驱动版本必须为 `580.159.03`，脚本会强制校验，不匹配则报错退出。驱动和 CUDA 版本强绑定，不要随意升级其中一个。

### 3. 安装 Docker 29.1.3

```bash
bash script_new/01_install_host_deps.sh
```

验证：

```bash
docker --version
```

> 安装完成后脚本会自动将当前用户加入 docker 组，执行 `newgrp docker` 或重新登录后生效。

### 4. 准备 easim 代码仓库

```bash
git clone https://gitlab.senseauto.com/kaiwu/simulation/utils/easim.git
cd easim
git checkout origin/feature/nav2-integration-dev-20260410
```

分支按实际开发版本选择。完成后记下 easim 仓库的绝对路径，后面配置时会用到。

### 5. 配置部署参数

```bash
bash script_new/easim.sh setup
```

重点确认：

| 配置项 | 说明 |
|--------|------|
| `EASIM_HOST_PATH` | easim 仓库在宿主机上的绝对路径 |
| `CONTAINER_NAME` | 容器名，默认 `kxq_easim_container` |
| `IMAGE_NAME` | 镜像名，默认 `easim:v0.3` |
| `SHM_SIZE` | Docker shared memory 大小，默认 `16g` |
| `ROS_DOMAIN_ID` | ROS domain ID，默认 `0` |
| `GDM_XAUTH` | 当前桌面会话的 Xauthority 路径 |

### 6. 环境预检

```bash
bash script_new/easim.sh check
```

预检只报告状态，不安装、不修改环境。检查项包括：

1. `config.sh` 和关键路径
2. NVIDIA 驱动版本
3. CUDA Toolkit
4. Docker 和 Docker daemon 权限

### 7. 首次部署 Docker 环境

```bash
bash script_new/easim.sh deploy
```

`deploy` 会依次执行：

1. `02_setup_cdi.sh`：配置 NVIDIA CDI
2. `03_build_image.sh`：构建 easim Docker 镜像
3. `04_start_container.sh`：启动容器
4. 可选执行容器初始化

新容器通常需要初始化一次。部署过程中看到：

```text
是否现在初始化容器环境？新容器通常需要执行一次。
```

建议选择 `yes`。

---

## 已有 CUDA/Docker 的机器

如果机器上已经安装好 NVIDIA 驱动、CUDA 和 Docker，可以从配置和部署开始：

```bash
bash script_new/easim.sh setup
bash script_new/easim.sh check
bash script_new/easim.sh deploy
```

如果预检提示 CUDA 或 Docker 不符合要求，再单独执行：

```bash
bash script_new/00_install_cuda.sh
bash script_new/01_install_host_deps.sh
```

---

## 宿主机重启后

宿主机重启，或退出桌面会话后重新登录，需要重新刷新 Xauthority 并恢复容器：

```bash
bash script_new/easim.sh restart
```

该命令实际执行的是：

```bash
bash script_new/04_start_container.sh
```

---

## 常用命令

```bash
bash script_new/easim.sh setup      # 首次配置或修改 config.sh
bash script_new/easim.sh check      # 环境预检
bash script_new/easim.sh deploy     # 首次部署 Docker 环境
bash script_new/easim.sh restart    # 重启/恢复容器环境
bash script_new/easim.sh init       # 初始化容器内 easim/Isaac Lab 环境
bash script_new/easim.sh status     # 查看配置、镜像、容器状态
```

维护命令：

```bash
bash script_new/easim.sh cuda       # 执行 00_install_cuda.sh
bash script_new/easim.sh host-deps  # 执行 01_install_host_deps.sh
bash script_new/easim.sh cdi        # 执行 02_setup_cdi.sh
bash script_new/easim.sh build      # 执行 03_build_image.sh
```

## 各脚本说明

### setup.sh

运行位置：宿主机

运行时机：首次使用前，或需要修改配置时

作用：交互式生成或更新 `config.sh`。

```bash
bash script_new/setup.sh
```

### config.sh

运行位置：宿主机

作用：保存统一配置变量，供其他脚本 `source` 使用。

一般不需要手动改，推荐通过下面命令修改：

```bash
bash script_new/easim.sh setup
```

### 00_install_cuda.sh

运行位置：宿主机

运行时机：首次部署，在安装 NVIDIA 驱动之后、安装 Docker 之前

作用：

1. 检查 `nvidia-smi` 是否存在
2. 检查驱动版本是否为 `580.159.03`
3. 下载并安装 CUDA Toolkit 12.8
4. 写入 `PATH` / `LD_LIBRARY_PATH`
5. 验证 `nvcc --version`

```bash
bash script_new/00_install_cuda.sh
```

### 01_install_host_deps.sh

运行位置：宿主机

运行时机：首次部署，在安装 CUDA 之后

作用：

1. 安装 Docker 29.1.3
2. 安装 Docker buildx / compose 插件
3. 启动 Docker 服务并设置开机自启
4. 将当前用户加入 docker 组

```bash
bash script_new/01_install_host_deps.sh
```

### 02_setup_cdi.sh

运行位置：宿主机

运行时机：首次部署，或重装 NVIDIA 驱动后

作用：

1. 检查 Docker 版本是否支持 CDI
2. 安装 `nvidia-container-toolkit`
3. 生成 `/etc/cdi/nvidia.yaml`
4. 验证 CDI 设备

```bash
bash script_new/02_setup_cdi.sh
```

### 03_build_image.sh

运行位置：宿主机

运行时机：首次部署，或需要重新构建镜像时

作用：

1. 检查 `EASIM_HOST_PATH`
2. 检查或生成 `docker/Dockerfile.easimnew`
3. 构建 Docker 镜像

```bash
bash script_new/03_build_image.sh
```

如果镜像已存在，脚本会跳过构建。如需重新构建，先删除旧镜像：

```bash
docker rmi easim:v0.3
bash script_new/03_build_image.sh
```

### 04_start_container.sh

运行位置：宿主机

运行时机：首次部署、宿主机重启后、桌面会话重新登录后

作用：

1. 检查 easim 路径
2. 配置 X11 访问权限
3. 复制 Xauthority cookie 到 `/tmp/.docker.xauth`
4. 启动或复用 Docker 容器
5. 挂载 easim 代码和部署脚本目录

```bash
bash script_new/04_start_container.sh
```

手动进入容器：

```bash
docker exec -it kxq_easim_container /bin/bash
```

### 05_init_docker_env.sh

运行位置：Docker 容器内

运行时机：首次进入新容器后执行一次；如果重建容器，也需要重新执行

作用：

1. 写入容器内 `.bashrc` 环境变量
2. 创建 `/easim/isaac_workspace -> /data/isaac_workspace` 软链接
3. 执行 `isaaclab.sh --install`
4. 将 easim 安装到 Isaac Sim bundled Python
5. 安装 ffmpeg、pyarrow、pink IK 依赖、回放环境修复包

推荐从宿主机执行统一入口：

```bash
bash script_new/easim.sh init
```

也可以进入容器后手动执行：

```bash
docker exec -it kxq_easim_container /bin/bash
bash /deploy_scripts/05_init_docker_env.sh
```

---

## 环境验证

容器初始化完成后，可以进入容器验证：

```bash
docker exec -it kxq_easim_container /bin/bash
cd /easim
./isaac_workspace/IsaacLab/isaaclab.sh -p source/easim/cli/run_unified.py \
    --task pick_place_skill --mode scene_preview
```

查看 Isaac Sim 版本：

```bash
cd /easim
./isaac_workspace/IsaacLab/isaaclab.sh -s
```

---

## 常见问题

### `GDM Xauth 文件不存在`

检查当前用户 UID：

```bash
id -u
```

然后重新运行配置向导，确认 `GDM_XAUTH` 路径：

```bash
bash script_new/easim.sh setup
```

### Docker daemon 当前用户不可访问

安装 Docker 后，当前用户加入 docker 组需要重新登录或执行：

```bash
newgrp docker
```

再验证：

```bash
docker info
```

### 想完全重置容器环境

```bash
docker rm -f kxq_easim_container
sudo rm -f /etc/cdi/nvidia.yaml
bash script_new/easim.sh deploy
```

### 容器内 `/deploy_scripts/05_init_docker_env.sh` 找不到

`/deploy_scripts` 是容器内路径，宿主机上不存在。先启动容器，再进入容器执行：

```bash
bash script_new/easim.sh restart
docker exec -it kxq_easim_container /bin/bash
bash /deploy_scripts/05_init_docker_env.sh
```

也可以直接从宿主机执行：

```bash
bash script_new/easim.sh init
```
