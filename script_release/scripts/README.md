# EASIM 测试机 → 生产机 发布 / 回退脚本

实现 [../prompt/easim_test_to_prod_final_plan.md](../prompt/easim_test_to_prod_final_plan.md) 的发布/回退方案。

把「测试通过的 git commit + 当时的资产快照 + sha256 校验」冻结成不可变的稳定版本，
从测试机统一推送到多台生产机，并支持精确回退到任意历史版本。

## 文件

| 文件 | 作用 |
|------|------|
| `config.sh` | 统一配置（唯一存放机器相关路径处） |
| `lib.sh` | 公共函数库（日志/校验/manifest/SSH/rsync/部署编排） |
| `create_stable.sh` | 创建稳定版本快照 |
| `deploy_prod.sh` | 发布指定版本到所有生产机 |
| `rollback_prod.sh` | 回退所有生产机到历史版本 |
| `status_prod.sh` | 只读巡检所有生产机状态 |
| `prod_hosts.txt.example` | 生产机清单模板 |

## 配置（三级优先级：命令行 > 环境变量 > config.sh 默认）

| 变量 | 默认值 |
|------|--------|
| `CODE_DIR` | 自动探测当前 git 仓库根 |
| `STABLE_ROOT` | `/data/easim_stable` |
| `PROD_CODE` | `/data/easim_runtime/code` |
| `PROD_HOSTS_FILE` | `$STABLE_ROOT/prod_hosts.txt` |
| `ASSET_PATHS` | `assets/environment/Office_10F_Room01`（数组，可多项） |
| `HEALTHCHECK_ENABLED` | `0`（健康检查功能待定，默认关闭） |

环境变量覆盖示例：

```bash
STABLE_ROOT=/mnt/big/easim_stable PROD_CODE=/srv/easim ./deploy_prod.sh 2.0.1
ASSET_PATHS_OVERRIDE="assets/environment/RoomA assets/environment/RoomB" ./create_stable.sh 2.1.0
```

## 用法

```bash
# 0) 首次：准备生产机清单
cp prod_hosts.txt.example "$STABLE_ROOT/prod_hosts.txt"   # 或放在 PROD_HOSTS_FILE 指向处
$EDITOR "$STABLE_ROOT/prod_hosts.txt"

# 1) 测试通过后，在测试机创建稳定版本（commit 须已 push 到远程）
./create_stable.sh 2.0.1

# 2) 发布到所有生产机
./deploy_prod.sh 2.0.1

# 3) 需要时回退到历史版本
./rollback_prod.sh 2.0.0

# 4) 巡检
./status_prod.sh
```

## 关键设计

- **版本不可变**：`create_stable.sh` 拒绝覆盖已存在版本；改动应创建新版本。
- **manifest 是唯一事实来源**：发布/回退读取目标版本 manifest 里记录的 commit 与
  资产路径，**不读当前 config**。旧版本即使日后改名/增删资产也能精确复现。
- **rsync `--delete` 限定到具体资产子目录**，不会误删生产机的 outputs/datasets 等。
- **失败隔离**：单台生产机失败不影响其它机器，失败机器不写 `current_version.txt`；
  脚本退出码 = 失败台数。
- **增量快照**：`create_stable.sh` 用 `rsync --link-dest` 复用上一版本未变文件，省磁盘。

## 生产机前置条件

每台生产机需安装 openssh-server / git / rsync，配置测试机到生产机的 SSH 免密登录，
并准备好可 fetch 到 git 仓库的 `PROD_CODE` 目录。详见方案文档第 13 节。

## 健康检查

`HEALTHCHECK_ENABLED=1` 启用。当前 `lib.sh::healthcheck_remote` 为占位钩子（恒成功），
待确定 EASIM 生产机的进程/容器检查方式后接入。
