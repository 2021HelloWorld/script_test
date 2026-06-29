# easim Docker 环境脚本使用说明

## 脚本放置位置

这套部署脚本是宿主机侧的辅助脚本，不是 easim 仿真项目源码的一部分。可以把 `scripts/` 放在其他宿主机目录中使用，只要按实际位置执行脚本，并确保 `config.sh` 中的 `EASIM_HOST_PATH` 指向 easim 仿真项目根目录即可。容器启动时会把 `EASIM_HOST_PATH` 挂载为 `/easim`，把当前脚本目录挂载为 `/deploy_scripts`。

> 不建议把这套部署脚本放进 `.../easim/scripts/`。该路径通常属于 easim 仓库自己的脚本目录，和容器内的 `/deploy_scripts/` 不是同一用途，混放容易造成误解。


## 前置条件

每台机器首次部署按以下顺序执行，只需做一次。

### 1. NVIDIA 显卡驱动（580.159.03）

通过系统「软件和更新 → 附加驱动」安装，或使用 `ubuntu-drivers` 命令：

```bash
sudo ubuntu-drivers install nvidia:580
sudo reboot
# 验证
nvidia-smi
```

### 2. CUDA 12.8

```bash
bash scripts/00_install_cuda.sh
# 验证
nvcc --version
```

> 驱动版本必须为 580.159.03，脚本会强制校验，不匹配则报错退出。  
> 驱动和 CUDA 版本强绑定，不要随意升级其中一个。

### 3. Docker 29.1.3 + tmux

```bash
bash scripts/01_install_host_deps.sh
# 验证
docker --version
tmux -V
```

> 安装完成后脚本会自动将当前用户加入 docker 组，执行 `newgrp docker` 或重新登录后生效。

### 4. easim 代码仓库

```bash
git clone https://gitlab.senseauto.com/kaiwu/simulation/utils/easim.git
cd easim
git checkout origin/feature/nav2-integration-dev-20260410 # 根据实际开发版本选择
```

> 以上 4 步完成后，再继续使用本目录下的脚本。

---

## 推荐入口

日常使用优先从统一入口进入：

```bash
bash scripts/easim.sh
```

常用快捷命令：

```bash
bash scripts/easim.sh check    # 环境预检，只报告状态
bash scripts/easim.sh deploy   # 首次部署
bash scripts/easim.sh restart  # 重启/恢复环境
bash scripts/easim.sh teleop   # 启动遥操
bash scripts/easim.sh process  # 数据处理
bash scripts/easim.sh status   # 状态查看
```

入口菜单只保留首次部署、重启/恢复环境、启动遥操、数据处理、状态查看这几个日常场景。`check` 只做环境预检，不安装、不修改环境；`setup`、`init`、`cuda`、`host-deps`、`cdi`、`build` 等维护命令仍可通过命令行单独执行。

底层的 `00_install_cuda.sh` 到 `07_process_dataset.sh` 仍然保留，排查问题或单独执行某一步时可以继续直接调用。

## 目录结构

```
scripts/
├── easim.sh                # 统一入口菜单和快捷命令
├── setup.sh                # 交互式配置向导，生成 config.sh
├── config.sh               # 统一配置变量（由 setup.sh 生成）
├── 00_install_cuda.sh      # 安装 CUDA Toolkit 12.8（宿主机）
├── 01_install_host_deps.sh # 安装 Docker 29.1.3 + tmux（宿主机）
├── 02_setup_cdi.sh         # 安装 nvidia-ctk + 生成 CDI 规格
├── 03_build_image.sh       # 检查/生成 Dockerfile，构建 Docker 镜像
├── 04_start_container.sh   # 刷新 Xauth + 启动容器
├── 05_init_docker_env.sh   # 容器内初始化 Isaac Lab/easim 环境
├── 06_teleop_pico.sh       # 一键启动遥操（tmux 三窗口）
├── 07_process_dataset.sh   # replay 检查、异常 trial 剔除、初始化帧裁剪、整理 sim_data
├── hdf5_dataset_tools.py   # 07 脚本使用的 HDF5 检查/合并/重编号辅助工具
└── README.md               # 本文档
```

---


## 典型使用流程

### 场景一：全新机器部署

```bash
bash scripts/easim.sh
# 选择 1) 首次部署
```

首次部署会先执行环境预检，检查 NVIDIA 驱动、CUDA Toolkit、Docker、tmux 和关键路径。预检只报告状态，不安装、不修改环境；存在失败项时会停止部署并返回主菜单。预检通过后会配置 CDI、构建镜像、启动容器，并询问是否初始化容器环境。新容器通常需要初始化一次，初始化完成后即可启动遥操。

### 场景二：宿主机重启后

```bash
bash scripts/easim.sh
# 选择 2) 重启/恢复环境
```

> 注意：退出桌面会话（注销/重新登录）也需要重新执行此步骤。

### 场景三：日常遥操

```bash
bash scripts/easim.sh
# 选择 3) 启动遥操
```

启动后按菜单依次选择：运行环境 → 场景 → 设备 → 数据集，确认后自动创建 tmux 三窗口。关闭 Isaac Sim 窗口或遥操主进程退出后，本次 `easim_teleop` session 会自动关闭并返回入口菜单。

### 场景四：遥操数据处理

```bash
bash scripts/easim.sh
# 选择 4) 数据处理
```

支持单个 hdf5 处理，也支持多个 hdf5 先合并再统一 replay、人工检查、剔除异常 trial、裁剪初始化不稳定帧。脚本会先检查 hdf5 是否存在、大小是否异常、能否正常打开、是否包含 `/data/demo_*`；检查失败会返回“单个/多个合并”的选择界面，方便重新选择文件。最终成品统一输出到 easim 根目录下的 `datasets/sim_data/<数据名>_processed_<时间>/`，摘要报告会记录采集成功率。

---

## 各脚本详细说明

### setup.sh

**运行位置：** 宿主机  
**运行时机：** 首次使用前，或需要修改配置时


向导会逐项询问配置，直接回车保留当前值，确认后自动写入 `config.sh`，需要修改配置时重新运行即可(GDM Xauth 路径会自动检测当前用户 UID)。
配置项说明：

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `EASIM_HOST_PATH` | 宿主机 easim 绝对路径 | 需手动填写 |
| `ISAAC_TELEOP_PATH` | IsaacTeleop webxr_client 路径 | 需手动填写 |
| `CONTAINER_NAME` | 容器名 | `kxq_easim_container` |
| `IMAGE_NAME` | 镜像名 | `easim:v0.3` |
| `SHM_SIZE` | 共享内存大小 | `16g` |
| `ROS_DOMAIN_ID` | ROS domain ID | `0` |
| `GDM_XAUTH` | GDM Xauth 路径（自动检测当前用户 UID） | `/run/user/<UID>/gdm/Xauthority` |
| `DEFAULT_RUN_ENV` | 默认运行环境，`docker` / `native` / 留空每次询问 | `""` |
| `TELEOP_CONDA_ENV` | Web Server conda 环境名 | `isaac_teleop_web_server_pico_env` |


---

### config.sh

由 `setup.sh` 生成，所有脚本通过 `source config.sh` 引入。直接编辑或重新运行 `setup.sh` 均可修改。

---

### 00_install_cuda.sh

**运行位置：** 宿主机  
**运行时机：** 首次部署，在安装 NVIDIA 驱动（580.159.03）之后、执行 `01_install_host_deps.sh` 之前

执行内容：
1. 检查 `nvidia-smi` 是否存在，驱动版本是否精确匹配 580.159.03
2. 检测已有 CUDA 包，若有冲突则列出并询问是否继续
3. 下载 CUDA 12.8 本地安装包（支持断点续传，默认缓存到 `~/.cache/easim/`）
4. 配置 apt pin 文件，安装 `cuda-toolkit-12-8`
5. 幂等写入 `~/.bashrc` 的 `PATH` / `LD_LIBRARY_PATH`
6. 就地验证 `nvcc --version`

```bash
bash scripts/00_install_cuda.sh
```

安装包缓存会在安装前后做完整性校验；如果检测到残缺 `.deb`，脚本会删除坏缓存并重新下载。也可以通过 `EASIM_CUDA_CACHE_DIR=/path/to/cache` 指定缓存目录。

**重置方法（回到干净状态）：**
```bash
sudo apt remove --purge cuda-toolkit-12-8
sudo rm -f /etc/apt/preferences.d/cuda-repository-pin-600
```

---

### 01_install_host_deps.sh

**运行位置：** 宿主机  
**运行时机：** 首次部署，在安装 CUDA 之后、执行 `02_setup_cdi.sh` 之前

执行内容：
1. 检测已安装的 Docker 版本；若版本不符则询问是否卸载重装
2. 安装系统依赖、导入 Docker 官方 GPG Key、配置 apt 仓库
3. 确认目标版本 29.1.3 在 apt 源中可用
4. 安装 `docker-ce`、`docker-ce-cli`、`containerd.io`、`docker-buildx-plugin`、`docker-compose-plugin`
5. 启动 Docker 服务并设置开机自启
6. 将当前用户加入 docker 组

```bash
bash scripts/01_install_host_deps.sh
```

**重置方法（回到干净状态）：**
```bash
sudo apt remove --purge docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
sudo rm -f /etc/apt/keyrings/docker.gpg /etc/apt/sources.list.d/docker.list
```

---

### 02_setup_cdi.sh

**运行位置：** 宿主机  
**运行时机：** 首次部署，或重装 NVIDIA 驱动后

执行内容：
1. 检查 Docker 版本是否 ≥ 25.0（CDI 依赖）
2. 若未安装 `nvidia-ctk`，自动安装 `nvidia-container-toolkit`
3. 生成 `/etc/cdi/nvidia.yaml` CDI 规格文件
4. 验证规格文件内容并列出 CDI 设备

```bash
bash scripts/02_setup_cdi.sh
```

**重置方法（回到干净状态）：**
```bash
sudo rm -f /etc/cdi/nvidia.yaml
```

---

### 03_build_image.sh

**运行位置：** 宿主机  
**运行时机：** 首次部署，或需要重新构建镜像时

执行内容：
1. 检查 `EASIM_HOST_PATH` 是否存在
2. 检查 `Dockerfile.easimnew` 是否存在，不存在则自动生成
3. 检查目标镜像是否已构建，已存在则跳过
4. 执行 `docker build` 构建镜像（时间较长）

```bash
bash scripts/03_build_image.sh
```

**重新构建镜像：**
```bash
docker rmi easim:v0.3
bash scripts/03_build_image.sh
```

---

### 04_start_container.sh

**运行位置：** 宿主机  
**运行时机：** 每次宿主机重启后，或退出桌面会话重新登入后

执行内容：
1. 检查 `EASIM_HOST_PATH` 是否存在
2. 执行 `xhost +local:docker` 允许 Docker 访问 X11
3. 复制 GDM Xauthority cookie 到 `/tmp/.docker.xauth`
4. 检测旧容器状态，交互式询问操作方式
5. 以 CDI GPU 直通方式启动容器，同时挂载两个目录：
   - `EASIM_HOST_PATH → /easim`（easim 代码）
   - `scripts/ → /deploy_scripts`（本目录下的部署脚本）

检测到旧容器时会出现选项：

```
请选择操作：
  1) 保留容器数据，直接启动/复用（推荐）
  2) 删除旧容器，从镜像重新创建（pip 安装的包将丢失）
```

选 2 重建后需重新运行 `05_init_docker_env.sh` 初始化环境。

```bash
bash scripts/04_start_container.sh
```

**手动进入容器：**
```bash
docker exec -it kxq_easim_container /bin/bash
```

> 容器内 `/deploy_scripts/` 对应宿主机的 `scripts/` 目录，`/easim/scripts/` 仍为 easim 仓库原有脚本，互不干扰。

---

### 05_init_docker_env.sh

**运行位置：** Docker 容器内  
**运行时机：** 首次进入新容器后执行一次

执行内容：
1. 写入 `.bashrc` 环境变量（`DISPLAY`、`OMNI_KIT_ALLOW_ROOT=1`）
2. 创建 `/easim/isaac_workspace → /data/isaac_workspace` 软链接
3. 执行 `isaaclab.sh --install` 安装 Isaac Lab 依赖
4. 将 easim 安装到 Isaac Sim bundled Python（`pip install -e /easim`）
5. 安装可选工具：ffmpeg、pyarrow、pink IK 依赖、回放环境修复包

```bash
# 进入容器后执行
bash /deploy_scripts/05_init_docker_env.sh
```

**验证环境：**
```bash
cd /easim
./isaac_workspace/IsaacLab/isaaclab.sh -p source/easim/cli/run_unified.py \
    --task pick_place_skill --mode scene_preview
```

---

### 06_teleop_pico.sh

**运行位置：** 宿主机  
**运行时机：** 日常遥操

使用 tmux 自动创建三个 pane，分别对应遥操所需的三个 terminal：

```
┌─────────────────────────┬──────────────────────────┐
│  Terminal 1             │  Terminal 3              │
│  Isaac Teleop           │  easim 遥操命令提示      │
│  Web Server             │                          │
├─────────────────────────┤                          │
│  Terminal 2             │                          │
│  CloudXR 服务           │                          │
└─────────────────────────┴──────────────────────────┘
```

启动后会依次出现交互菜单，按提示输入序号选择：

```
1. 运行环境   Docker 容器 / 本机（conda）
2. 遥操场景   抓三个水果 / 抓纸团果皮 / 水果+纸团综合场景
3. 遥操设备   Pico 4 Ultra / Vision Pro
4. 文件后缀   自定义后缀，直接回车则不添加
5. 确认摘要   确认后启动 tmux
```

数据集文件名格式为 `<场景>_<时间YYmmdd_HHMM>_<后缀>.hdf5`，例如：

```
datasets/imit_learning/pick_fruits_skill_260623_1630_kxq_test1.hdf5
```

不填后缀时：

```
datasets/imit_learning/pick_fruits_skill_260623_1630.hdf5
```

```bash
bash scripts/06_teleop_pico.sh
```

运行环境决定了 CloudXR 和遥操命令的调用方式：

| 环境 | CloudXR 启动方式 | 遥操命令前缀 |
|------|-----------------|-------------|
| Docker | `docker exec` 进容器执行 `isaaclab.sh -p -m isaacteleop.cloudxr` | `./isaac_workspace/IsaacLab/isaaclab.sh -p` |
| 本机 | 直接 `python -m isaacteleop.cloudxr` | `python` |

如果某台机器固定使用某种环境，在 `config.sh` 中设置 `DEFAULT_RUN_ENV="docker"` 或 `DEFAULT_RUN_ENV="native"`，启动时将跳过该步选择。

**tmux 常用操作：**

| 按键 | 功能 |
|------|------|
| `Ctrl+B` 再按方向键 | 切换 pane |
| `Ctrl+B D` | 临时脱离 tmux（后台保留） |
| `tmux attach -t easim_teleop` | 重新附加到 session |
| `tmux kill-session -t easim_teleop` | 关闭 session 并停止所有服务 |

关闭 Isaac Sim 窗口或遥操主进程退出后，Terminal 3 会执行自动收尾脚本，3 秒后关闭本次 `easim_teleop` session，并返回入口菜单。该逻辑只对重新创建的新 session 生效；如果当前仍在旧 session 中，请先执行 `tmux kill-session -t easim_teleop` 后重新启动遥操。

**Pico 连接步骤（启动后）：**
1. 等待 Terminal 1、2 服务就绪
2. easim 完全启动后，在 Isaac Sim GUI 点击 **AR → Start**
3. 戴上 Pico，浏览器输入 `https://<宿主机局域网IP>:8080`
4. 点击 **Certificate Accept**（首次需要）→ **Connect** → **Play**
5. 倒计时结束后开始遥操；**Reset** 重置场景；**Disconnect** 退出

---

### 07_process_dataset.sh

**运行位置：** 宿主机  
**运行时机：** 遥操录制完成后，需要整理交付数据时

脚本处理的是 easim 项目根目录下的数据：

| 路径 | 说明 |
|------|------|
| `$EASIM_HOST_PATH/datasets/imit_learning/` | 原始遥操 hdf5 |
| `$EASIM_HOST_PATH/outputs/videos/replay_demo/` | replay 检查视频 |
| `$EASIM_HOST_PATH/datasets/sim_data/` | 最终处理好的 hdf5 + 视频 |

执行内容：
1. 选择运行环境、处理模式、场景和 hdf5 文件
2. 检查 hdf5 是否存在、是否过小、是否能打开、是否包含 `/data/demo_*`
3. 检查失败时返回处理模式选择界面，可重新选择单个或多个 hdf5
4. 检查通过后保留原始 hdf5，复制到处理工作区
5. 多文件模式下先合并 hdf5，并重排 trial 编号
6. 执行 replay，生成视频供人工检查
7. 输入异常 trial 编号，支持 `1 3 8` 或 `trial_1 trial_3`
8. 剔除异常 trial，并同步移动/重编号视频
9. 询问是否裁剪初始化不稳定帧，默认执行
10. 将最终 hdf5 和视频目录整理到 `datasets/sim_data/`

```bash
bash scripts/07_process_dataset.sh
```

最终输出结构：

```text
datasets/sim_data/
└── <name>_processed_<YYmmdd_HHMM>/
    ├── <name>_processed.hdf5
    ├── videos/
    │   ├── trial_0.mp4
    │   ├── trial_1.mp4
    │   └── ...
    ├── trial_mapping.csv
    ├── process_summary.txt
    └── _work/
```

其中 `_work/` 保留处理过程中的工作文件，方便回查；交付时主要使用 `<name>_processed.hdf5` 和 `videos/`。

`process_summary.txt` 会记录本次处理摘要，包括原始 hdf5、剔除的 trial、初始化裁剪参数和最终输出路径。采集成功率按“剔除异常 trial 后保留数量 / 原始 trial 数量”计算，例如：

```text
original_trial_count: 20
kept_trial_count_after_remove: 18
collection_success_rate: 18/20 (90.00%)
```

---

## 常见问题

**Q: `GDM Xauth 文件不存在` 报错**  
A: 检查当前用户 UID（`id -u`），修改 `config.sh` 中的 `GDM_XAUTH` 路径。

**Q: 端口 48322/49100 被占用**  
```bash
# 持久化预留端口，防止系统随机占用
sudo sysctl -w net.ipv4.ip_local_reserved_ports=48322,49100
echo 'net.ipv4.ip_local_reserved_ports=48322,49100' | \
    sudo tee /etc/sysctl.d/99-cloudxr-reserved.conf
```

**Q: 想完全重置容器环境**  
```bash
docker rm -f kxq_easim_container
sudo rm -f /etc/cdi/nvidia.yaml
# 重新从 02_setup_cdi.sh 开始
```

**Q: 容器内 `pip install -e .` 方式使用 easim**  
```bash
docker exec -it kxq_easim_container bash
cd /easim && pip install -e .
```

**Q: `docker exec` 报错 `container is not running`，容器退出码 127**  
A: `/tmp/.docker.xauth` 被错误地创建成了目录，导致 xauth 文件挂载失败、容器启动即退出。修复：
```bash
sudo rm -rf /tmp/.docker.xauth
bash scripts/04_start_container.sh  # 选 2 重建容器
```

**Q: 在宿主机执行 `bash /deploy_scripts/05_init_docker_env.sh` 报 `No such file or directory`**  
A: `/deploy_scripts` 是挂载在容器内的路径，宿主机上不存在。需先进入容器再执行：
```bash
docker exec -it kxq_easim_container bash
bash /deploy_scripts/05_init_docker_env.sh
```
