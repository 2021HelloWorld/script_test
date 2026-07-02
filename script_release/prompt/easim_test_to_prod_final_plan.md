# EASIM 测试机到生产机发布与回退技术方案

## 1. 目标

测试机完成测试后，可以一键把当前验证通过的版本发布到多台生产机。

当生产环境需要回退时，可以在测试机选择历史稳定版本，并一键让所有生产机回退到该版本。

### 背景：现有工作流与本方案的定位

现有正常工作流中，**代码与资产是有意分离管理的**：

- 代码：通过 Git 拉取（`git pull`）。
- 资产：从数据库下载，不进 Git 仓库。

资产被 `.gitignore` 忽略是**刻意的设计**，因为它本就由数据库这条独立通道管理，不应进入代码仓库。

本方案不替代、也不否定现有工作流，而是**为生产发布补一条「版本锁定 + 整体一致」的通道**，解决现有流程下不易保证的两点：

- 代码 commit 与资产状态没有统一的版本绑定，发布时难以保证某台生产机的代码和资产正好是同一套测试通过的组合。
- 数据库下载面向开发；生产机需要的是已测试通过、可一键铺到多台、可精确回退的固定版本。

因此本方案把「某次测试通过的代码 commit + 当时的资产状态」冻结成不可变的稳定版本快照，从测试机统一推送和回退。**资产快照是这套版本机制的产物，不是要取代数据库下载。**

本方案适用于以下实际情况：

- 测试机和生产机都是 Ubuntu 系统。
- 场景代码通过 Git 管理，远程仓库为 `git@gitlab.senseauto.com:kaiwu/simulation/utils/easim.git`。
- 场景资产由数据库下载到 code 目录内，被 `.gitignore` 有意忽略，不进入 Git 仓库。
- 生产机通过 SSH 接收测试机指令。
- 资产通过 rsync 从测试机（稳定版本快照）同步到生产机。

### 本项目已确认的实际情况

- 测试机 code 目录：`/home/sensetime/Sensetime_ACE/kongxiaoqiang/easim/easim`。
- 当前发布基准 commit：`1f23a85c`，分支 `feature/modelzoo_refactor-20260603`。
  代码已推送到 gitlab 远程且不再产生新提交，生产机可通过 `git fetch` 拿到该 commit。
- 整个 `assets/` 目录共约 45G，但**实际使用并需要发布的只有一个房间**：
  `assets/environment/Office_10F_Room01/`，约 **12G**。
- 同级的 `Office_10F_Room01_*_bak_*` 等目录是本地历史备份，**不纳入发布**。
- `datasets/`、`outputs/` 等被忽略目录是运行数据/产物，**不纳入快照**。

## 2. 总体架构

```text
测试机 -> 多台生产机
```

测试机承担两个角色：

- 测试环境。
- 发布控制机和稳定版本备份库。

生产机只接收测试机指定的稳定版本，不自己决定更新到哪里。

## 3. 核心定义

一个稳定版本由三部分组成：

```text
稳定版本 = Git commit + ignored 资产快照 + sha256 校验文件
```

其中：

- `Git commit`：锁定 `yaml`、`py` 等由 Git 管理的代码。
- `ignored 资产快照`：锁定被 `.gitignore` 忽略的资产。本项目即 `assets/environment/Office_10F_Room01/`。
- `sha256 校验文件`：用于确认生产机上的资产和测试机备份的资产完全一致。

## 4. 测试机目录结构

> ### 路径与配置约定（保证脚本通用、可移植）
>
> 脚本逻辑中**不硬编码任何机器相关路径**，全部集中到 `scripts/config.sh`，并按三级优先级解析：
>
> ```text
> 命令行参数  >  环境变量  >  config.sh 默认值
> ```
>
> | 配置项 | 含义 | 默认值 / 解析方式 |
> |--------|------|-------------------|
> | `CODE_DIR` | 测试机 code 目录 | 未设置时自动探测：`git rev-parse --show-toplevel` |
> | `STABLE_ROOT` | 稳定版本备份库 | `/data/easim_stable` |
> | `PROD_CODE` | 生产机 code 运行目录 | `/data/easim_runtime/code` |
> | `ASSET_PATHS` | 纳入快照的资产相对路径**列表**（数组） | 见下方示例 |
>
> 其中 `ASSET_PATHS` 是一个数组，当前只有一项，未来增删资产或改名只改这里：
>
> ```bash
> # scripts/config.sh
> ASSET_PATHS=(
>   "assets/environment/Office_10F_Room01"
>   # 未来新增/改名直接增改本数组，例如：
>   # "assets/environment/Office_11F_Room02"
> )
> ```
>
> 通用性要点：
>
> - 脚本统一 `#!/usr/bin/env bash` + `set -euo pipefail`，并用 `command -v` 检查 git/rsync/ssh。
> - 脚本自身路径用 `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` 解析，不依赖执行目录。
> - `CODE_DIR` 不写死家目录，换台机器或换克隆位置都能自动适配。
> - **显式列出 `ASSET_PATHS` 而非整目录同步**，是为了避免把同级的 `_bak_` 历史备份（共约 45G）误卷入快照。

建议测试机维护如下目录（以默认 `STABLE_ROOT=/data/easim_stable` 为例）：

```text
/data/easim_stable/
├── 2.0.0/
│   ├── manifest.yaml
│   ├── ignored_assets/
│   │   └── assets/environment/Office_10F_Room01/
│   └── ignored_assets.sha256
├── 2.0.1/
│   ├── manifest.yaml
│   ├── ignored_assets/
│   │   └── assets/environment/Office_10F_Room01/
│   └── ignored_assets.sha256
├── stable_index.yaml
├── prod_hosts.txt
└── scripts/
    ├── config.sh
    ├── create_stable.sh
    ├── deploy_prod.sh
    ├── rollback_prod.sh
    └── status_prod.sh
```

说明：

- `2.0.0/`、`2.0.1/` 是历史稳定版本目录。
- `manifest.yaml` 记录该版本对应的 Git commit 和资产信息。
- `ignored_assets/` 保存该版本的 ignored 资产快照。
- `ignored_assets.sha256` 是该版本资产的校验清单。
- `stable_index.yaml` 记录所有稳定版本索引。
- `prod_hosts.txt` 记录生产机列表。
- `scripts/` 保存发布、回退、状态检查脚本。

## 5. 生产机目录结构

生产机运行目录建议如下（以默认 `PROD_CODE=/data/easim_runtime/code` 为例）：

```text
/data/easim_runtime/code/
├── yaml / py / 其它 Git 管理文件
├── assets/environment/Office_10F_Room01/
├── ignored_assets.sha256
└── current_version.txt
```

说明：

- `yaml`、`py` 等文件由 Git checkout 到指定 commit。
- `assets/environment/Office_10F_Room01/` 是被 Git ignore 的资产，由测试机 rsync 同步。
- `ignored_assets.sha256` 用于本机校验资产。
- `current_version.txt` 记录当前生产机运行版本。

## 6. manifest.yaml 示例

每个稳定版本目录都需要一个 `manifest.yaml`。

示例：

```yaml
version: 2.0.1

code:
  commit: 1f23a85c
  branch: feature/modelzoo_refactor-20260603

ignored_assets:
  paths:
    - assets/environment/Office_10F_Room01
  checksum_file: ignored_assets.sha256

created_at: "2026-06-30 15:30:00"
test_result: passed
```

关键字段：

- `version`：稳定版本号。
- `code.commit`：该版本对应的 Git commit。
- `ignored_assets.paths`：该版本**实际锁定**的资产路径列表，可以有多项。
- `ignored_assets.checksum_file`：资产校验文件。
- `test_result`：该版本是否已通过测试。

> 重要：`ignored_assets.paths` 由 `create_stable.sh` 在创建版本时，按当时的 `config.sh::ASSET_PATHS`
> 写入。**部署和回退只读取目标版本 manifest 里记录的 paths，不读当前 config**。
> 这样即使之后资产改名、新增资产或修改了 config，旧版本依然能精确复现它当初锁定的那批资产
> ——符合「版本不可变」原则。

## 7. prod_hosts.txt 示例

生产机列表可以使用简单文本格式：

```text
pc01 192.168.1.101 deploy
pc02 192.168.1.102 deploy
pc03 192.168.1.103 deploy
```

每行含义：

```text
机器名 IP SSH用户
```

测试机需要能通过 SSH 免密登录这些生产机。

## 8. 连接与操作方式

本方案使用：

```text
连接：SSH
文件同步：rsync
操作封装：Shell 脚本
```

测试机通过 SSH 命令生产机执行 Git 操作、资产校验、服务检查等动作。

测试机通过 rsync 将指定稳定版本的 ignored 资产同步到生产机。

## 9. 创建稳定版本流程

测试机完成测试后执行：

```bash
./scripts/create_stable.sh 2.0.1
```

脚本执行流程：

```text
1. 获取当前测试机 code 目录的 Git commit。
2. 校验该 commit 已存在于 gitlab 远程（否则生产机 fetch 不到，拒绝创建）。
3. 创建 $STABLE_ROOT/2.0.1/ 目录。
4. 遍历 config.sh::ASSET_PATHS，逐个把资产复制到 ignored_assets/（保留相对路径结构），
   排除 .git/.agents/.codex 等无关隐藏目录，不复制同级 _bak_ 备份目录。
5. 生成 ignored_assets.sha256（覆盖所有 ASSET_PATHS 下的文件）。
6. 生成 manifest.yaml，并把本次实际锁定的 ASSET_PATHS 写入 ignored_assets.paths。
7. 更新 stable_index.yaml。
```

如果资产很大（本项目单房间约 12G），建议备份资产时使用 `rsync --link-dest`，复用历史版本中未变化的文件，减少磁盘占用。

## 10. 发布流程

发布到生产机时，在测试机执行：

```bash
./scripts/deploy_prod.sh 2.0.1
```

脚本执行流程：

```text
1. 读取 $STABLE_ROOT/2.0.1/manifest.yaml（含 code.commit 与 ignored_assets.paths）。
2. 获取该版本对应的 Git commit。
3. 遍历 prod_hosts.txt 中的生产机。
4. 通过 SSH 命令生产机执行 git fetch。
5. 通过 SSH 命令生产机 checkout 到指定 commit。
6. 遍历 manifest 记录的每个资产路径，逐个 rsync 同步到生产机 code 目录对应路径。
7. 同步 ignored_assets.sha256 到生产机 code 目录。
8. 通过 SSH 命令生产机执行 sha256 校验。
9. 校验通过后写入 current_version.txt。
10. 执行生产机健康检查（功能待定，见第 12 节）。
```

核心命令逻辑（`$asset` 为 manifest 中 `ignored_assets.paths` 的每一项）：

```bash
ssh deploy@prod "cd $PROD_CODE && git fetch --all && git checkout <commit>"

# 对 manifest 记录的每个资产路径单独同步。
# 注意：rsync 必须限定到具体资产子目录，--delete 只在该目录内部生效，
# 避免误删生产机 code 目录下的 outputs/、datasets/、__pycache__ 等其它文件。
for asset in "${PATHS[@]}"; do
  ssh deploy@prod "mkdir -p $PROD_CODE/$asset"
  rsync -av --delete \
    "$STABLE_ROOT/2.0.1/ignored_assets/$asset/" \
    "deploy@prod:$PROD_CODE/$asset/"
done

rsync -av \
  "$STABLE_ROOT/2.0.1/ignored_assets.sha256" \
  "deploy@prod:$PROD_CODE/ignored_assets.sha256"

ssh deploy@prod "cd $PROD_CODE && sha256sum -c ignored_assets.sha256"
```

## 11. 回退流程

回退时，在测试机执行：

```bash
./scripts/rollback_prod.sh 2.0.0
```

回退本质上和发布相同，只是选择历史稳定版本。

脚本执行流程：

```text
1. 读取 $STABLE_ROOT/2.0.0/manifest.yaml（含 code.commit 与 ignored_assets.paths）。
2. 获取历史版本对应的 Git commit。
3. 命令生产机 checkout 到历史 commit。
4. 遍历该版本 manifest 记录的每个资产路径，逐个同步 2.0.0 的资产到生产机。
5. 同步 2.0.0 的 ignored_assets.sha256。
6. 生产机本地执行 sha256 校验。
7. 校验通过后写入 current_version.txt。
8. 执行健康检查（功能待定）。
```

注意：

回退时同步的是历史版本目录中的资产，且资产路径取自**该历史版本自己的 manifest**，例如：

```text
$STABLE_ROOT/2.0.0/ignored_assets/<2.0.0 manifest 记录的每个 path>/
```

不是测试机当前 code 目录里的资产，也不是当前 config.sh 里的 ASSET_PATHS。

## 12. 状态检查

测试机可以执行：

```bash
./scripts/status_prod.sh
```

状态检查建议包含：

- SSH 是否可连接。
- 当前版本号。
- 当前 Git commit。
- `sha256` 资产校验是否通过。
- 关键服务是否运行（**功能待定**：EASIM 生产机的"服务"具体指进程还是容器尚未确定，脚本中先以可关闭的占位钩子实现，后续接入）。
- 磁盘空间是否充足。

输出示例：

```text
pc01  online   version=2.0.1  commit=a1b2c3d4  assets=ok
pc02  online   version=2.0.1  commit=a1b2c3d4  assets=ok
pc03  offline  version=unknown
```

## 13. 生产机准备工作

每台生产机需要提前完成：

```text
1. 安装 openssh-server。
2. 安装 git。
3. 安装 rsync。
4. 创建统一 SSH 用户，例如 deploy。
5. 配置测试机到生产机的 SSH 免密登录。
6. 准备 /data/easim_runtime/code/ 目录。
7. 确保生产机 code 目录可以 fetch 到 Git 仓库。
```

测试机需要能执行：

```bash
ssh deploy@192.168.1.101
```

并且无需手动输入密码。

## 14. 关键规则

### 版本不可变

稳定版本目录一旦创建完成，不要手动修改：

```text
/data/easim_stable/2.0.1/
```

如果代码或资产发生变化，应创建新版本：

```text
/data/easim_stable/2.0.2/
```

### 生产机不自主更新

生产机不要自己执行：

```bash
git pull
```

也不要自己替换资产。

生产机只跟随测试机指定的版本。

### 禁止误删 ignored 资产

生产机不要执行：

```bash
git clean -fdx
```

因为 `-x` 会删除被 `.gitignore` 忽略的资产。

如果必须清理 Git 未跟踪文件，需要排除资产目录，例如：

```bash
git clean -fd -e assets/
```

### 发布失败处理

如果某台生产机发布失败：

- 停止或标记该机器发布失败。
- 保留错误日志。
- 不写入新的 `current_version.txt`。
- 必要时执行回退脚本。

## 15. 最终总结

本方案的最终模型是：

```text
代码靠 Git commit 保证一致；
资产靠测试机稳定快照保证一致；
sha256 负责确认资产同步无误；
SSH 负责远程控制；
rsync 负责高效同步；
Shell 脚本负责发布、回退和状态检查。
```

这样可以保证：

- 测试机测试通过的版本可以准确发布到所有生产机。
- 生产机代码和资产版本一一对应。
- 被 Git ignore 的资产也可以纳入版本管理。
- 任何历史稳定版本都可以被回退。
- 生产机之间的环境一致性可以被校验。
