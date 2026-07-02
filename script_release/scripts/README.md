# EASIM 测试机 → 生产机 发布 / 回退脚本

把「测试通过的 git commit + 当时的资产快照 + sha256 校验」冻结成不可变的稳定版本，
从测试机统一推送到多台生产机，并支持精确回退到任意历史版本。

## 生产机前置条件

每台生产机需安装 openssh-server / git / rsync，配置测试机到生产机的 SSH 免密登录，
并准备好可 fetch 到 git 仓库的 code 目录（即该机器在 `prod_hosts.txt` 第四列指定的路径）。

## 用法

推荐用交互式入口，会自动做前置校验、展示状态并二次确认：

```bash
./release_wizard.sh
```

也可直接调用核心脚本：

```bash
# 0) 首次：准备生产机清单
cp prod_hosts.txt.example "$STABLE_ROOT/prod_hosts.txt"   # 或放在 PROD_HOSTS_FILE 指向处
$EDITOR "$STABLE_ROOT/prod_hosts.txt"

# 1) 测试通过后，在测试机创建稳定版本（commit 须已 push 到远程）
./create_stable.sh <稳定版本号>

# 2) 发布到所有生产机
./deploy_prod.sh <版本号>

# 3) 需要时回退到历史版本
./rollback_prod.sh <历史版本号>

# 4) 巡检
./status_prod.sh
```

## 配置路径说明

| 变量 | 说明 |
|------|------|
| `CODE_DIR` | 测试机上的 easim 仓库根目录（资产快照来源）。显式设置优先，为空时自动探测当前 git 仓库根。 |
| `STABLE_ROOT` | 测试机上的稳定版本备份库，存放各版本快照与索引。 |
| `PROD_CODE` | 生产机默认 code 目录。 |
| `PROD_HOSTS_FILE` | 生产机清单文件路径。 |
| `ASSET_PATHS` | 纳入快照的资产相对路径列表（相对 `CODE_DIR`，可多项）。 |
| `HEALTHCHECK_ENABLED` | 是否启用发布后健康检查（当前为占位钩子，默认关闭）。 |


## 生产机清单（prod_hosts.txt）

每行格式：`机器名 IP SSH用户 [code路径]`，`#` 开头与空行忽略。

第四列 code 路径**可选**，用于各生产机路径不一致的场景：

- **填写**：该机器使用其专属 code 目录。
- **留空**：回退到全局 `PROD_CODE`。

```
# 机器名 IP SSH用户 [code路径]
pc01 192.168.1.101 deploy /home/sensetime/Test_env/easim
pc02 192.168.1.102 deploy /data/easim_runtime/code
pc03 192.168.1.103 deploy            # 留空 → 用全局 PROD_CODE
```



## 关键设计

- **版本不可变**：`create_stable.sh` 拒绝覆盖已存在版本；改动应创建新版本。
- **manifest 是唯一事实来源**：发布/回退读取目标版本 manifest 里记录的 commit 与
  资产路径，**不读当前 config**。旧版本即使日后改名/增删资产也能精确复现。
- **rsync `--delete` 限定到具体资产子目录**，不会误删生产机的 outputs/datasets 等。
- **失败隔离**：单台生产机失败不影响其它机器，失败机器不写 `current_version.txt`；
  脚本退出码 = 失败台数。
- **增量快照**：`create_stable.sh` 用 `rsync --link-dest` 复用上一版本未变文件，省磁盘。
- **每台路径可不同**：生产机 code 目录不一致时，在 `prod_hosts.txt` 第四列单独指定；
  未指定的机器回退到全局 `PROD_CODE`。checkout / rsync / 校验 / 写版本号全部按机器路径执行。



## 健康检查

`HEALTHCHECK_ENABLED=1` 启用。当前 `lib.sh::healthcheck_remote` 为占位钩子（恒成功），
待确定 EASIM 生产机的进程/容器检查方式后接入。

## 文件说明

| 文件 | 作用 |
|------|------|
| `config.sh` | 统一配置（默认路径、SSH/rsync 选项等） |
| `lib.sh` | 公共函数库（日志/校验/manifest/SSH/rsync/部署编排） |
| `create_stable.sh` | 创建稳定版本快照 |
| `deploy_prod.sh` | 发布指定版本到所有生产机 |
| `rollback_prod.sh` | 回退所有生产机到历史版本 |
| `status_prod.sh` | 只读巡检所有生产机状态 |
| `release_wizard.sh` | 交互式统一入口（引导/校验/确认，调用上述核心脚本） |
| `prod_hosts.txt.example` | 生产机清单模板 |