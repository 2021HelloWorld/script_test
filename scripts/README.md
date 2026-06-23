# easim Docker 环境脚本使用说明

## 前置条件

以下环境需在使用脚本前**手工完成安装**，每台机器只需做一次。详细步骤参考 `../easim环境搭建-基础环境安装.md`。

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
# 详细步骤见 easim环境搭建-基础环境安装.md
# 验证
nvcc --version
```

> 驱动和 CUDA 版本强绑定，不要随意升级其中一个。

### 3. Docker 29.1.3

```bash
# 详细步骤见 easim环境搭建-基础环境安装.md
# 验证（版本必须 ≥ 25.0，CDI 功能依赖）
docker --version

# 将当前用户加入 docker 组（装完后需重新登录生效）
sudo usermod -aG docker $USER
newgrp docker
```

### 4. easim 代码仓库

```bash
git clone https://gitlab.senseauto.com/kaiwu/simulation/utils/easim.git
cd easim
git checkout origin/feature/nav2-integration-dev-20260410 # 根据实际开发版本选择
```

克隆完成后，将 `config.sh` 中的 `EASIM_HOST_PATH` 改为该目录的绝对路径。

### 5. tmux

`04_teleop_pico.sh` 依赖 tmux 管理多窗口：

```bash
sudo apt install tmux
# 验证
tmux -V
```

### 6. 构建 Docker 镜像（easim:v0.3）

```bash
cd /path/to/easim
docker build -f docker/Dockerfile.easimnew -t easim:v0.3 .
```

> 以上 5 步完成后，再继续使用本目录下的脚本。

---

## 目录结构

```
scripts/
├── setup.sh                # 交互式配置向导，生成 config.sh
├── config.sh               # 统一配置变量（由 setup.sh 生成）
├── 01_setup_cdi.sh         # 安装 nvidia-ctk + 生成 CDI 规格
├── 02_start_container.sh   # 刷新 Xauth + 启动容器
├── 03_init_docker_env.sh   # 容器内初始化 Isaac Lab/easim 环境
├── 04_teleop_pico.sh       # 一键启动遥操（tmux 三窗口）
└── README.md               # 本文档
```

---

## 第一步：运行配置向导

```bash
bash scripts/setup.sh
```

向导会逐项询问配置，直接回车保留当前值，确认后自动写入 `config.sh`。需要修改配置时重新运行即可。

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

## 典型使用流程

### 场景一：全新机器部署

```bash
# 1. 运行配置向导
bash scripts/setup.sh

# 2. 安装 nvidia-container-toolkit，生成 CDI 规格
bash scripts/01_setup_cdi.sh

# 3. 构建 Docker 镜像（在 easim 目录下执行）
cd /path/to/easim
docker build -f docker/Dockerfile.easimnew -t easim:v0.3 .

# 4. 启动容器
bash scripts/02_start_container.sh

# 5. 进入容器，初始化环境（只需执行一次）
docker exec -it kxq_easim_container bash
bash /easim/scripts/03_init_docker_env.sh
```

### 场景二：宿主机重启后

```bash
# Xauth cookie 已失效，需要重新启动容器
bash scripts/02_start_container.sh
```

> 注意：退出桌面会话（注销/重新登录）也需要重新执行此步骤。

### 场景三：日常遥操

```bash
bash scripts/04_teleop_pico.sh
```

启动后按菜单依次选择：运行环境 → 场景 → 设备 → 数据集，确认后自动创建 tmux 三窗口。

---

## 各脚本详细说明

### setup.sh

**运行位置：** 宿主机  
**运行时机：** 首次使用前，或需要修改配置时

交互式向导，逐项询问配置项，确认后写入 `config.sh`。已有配置时直接回车可保留当前值，GDM Xauth 路径会自动检测当前用户 UID。

```bash
bash scripts/setup.sh
```

---

### config.sh

由 `setup.sh` 生成，所有脚本通过 `source config.sh` 引入。直接编辑或重新运行 `setup.sh` 均可修改。

---

### 01_setup_cdi.sh

**运行位置：** 宿主机  
**运行时机：** 首次部署，或重装 NVIDIA 驱动后

执行内容：
1. 检查 Docker 版本是否 ≥ 25.0（CDI 依赖）
2. 若未安装 `nvidia-ctk`，自动安装 `nvidia-container-toolkit`
3. 生成 `/etc/cdi/nvidia.yaml` CDI 规格文件
4. 验证规格文件内容并列出 CDI 设备

```bash
bash scripts/01_setup_cdi.sh
```

**重置方法（回到干净状态）：**
```bash
sudo rm -f /etc/cdi/nvidia.yaml
```

---

### 02_start_container.sh

**运行位置：** 宿主机  
**运行时机：** 每次宿主机重启后，或退出桌面会话重新登入后

执行内容：
1. 检查 `EASIM_HOST_PATH` 是否存在
2. 执行 `xhost +local:docker` 允许 Docker 访问 X11
3. 复制 GDM Xauthority cookie 到 `/tmp/.docker.xauth`
4. 检测旧容器状态，交互式询问操作方式
5. 以 CDI GPU 直通方式启动容器

检测到旧容器时会出现选项：

```
请选择操作：
  1) 保留容器数据，直接启动/复用（推荐）
  2) 删除旧容器，从镜像重新创建（pip 安装的包将丢失）
```

选 2 重建后需重新运行 `03_init_docker_env.sh` 初始化环境。

```bash
bash scripts/02_start_container.sh
```

**手动进入容器：**
```bash
docker exec -it kxq_easim_container /bin/bash
```

---

### 03_init_docker_env.sh

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
bash /easim/scripts/03_init_docker_env.sh
```

**验证环境：**
```bash
cd /easim
./isaac_workspace/IsaacLab/isaaclab.sh -p source/easim/cli/run_unified.py \
    --task pick_place_skill --mode scene_preview
```

---

### 04_teleop_pico.sh

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
bash scripts/04_teleop_pico.sh
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
| `Ctrl+B D` | 退出 tmux（保留后台运行） |
| `tmux attach -t easim_teleop` | 重新附加到 session |
| `tmux kill-session -t easim_teleop` | 关闭 session 并停止所有服务 |

**Pico 连接步骤（启动后）：**
1. 等待 Terminal 1、2 服务就绪
2. easim 完全启动后，在 Isaac Sim GUI 点击 **AR → Start**
3. 戴上 Pico，浏览器输入 `https://<宿主机局域网IP>:8080`
4. 点击 **Certificate Accept**（首次需要）→ **Connect** → **Play**
5. 倒计时结束后开始遥操；**Reset** 重置场景；**Disconnect** 退出

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
# 重新从 01_setup_cdi.sh 开始
```

**Q: 容器内 `pip install -e .` 方式使用 easim**  
```bash
docker exec -it kxq_easim_container bash
cd /easim && pip install -e .
```
