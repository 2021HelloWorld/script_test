#!/usr/bin/env bash
# deploy_prod.sh —— 把指定稳定版本发布到生产机
#
# 用法：
#   ./deploy_prod.sh <version> [host ...]
#
# 不带 host 参数：发布到 prod_hosts.txt 中的所有生产机。
# 带 host 参数：只发布到指定机器（可多台），host 可写机器名或 IP。
#
# 对每台目标生产机：
#   git fetch + checkout <commit> -> 逐个 rsync 资产 -> 同步并校验 sha256
#   -> 写 current_version.txt
# 单台失败不影响其它机器；失败机器不写版本号。退出码=失败台数。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

VERSION="${1:-}"
[[ "${VERSION}" == "-h" || "${VERSION}" == "--help" ]] && {
  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;
}
shift || true
# 其余参数为目标机器选择器（机器名或 IP）；为空则发布到全部
DEPLOY_TARGETS=("$@")

validate_version "$VERSION"
validate_controller_env

deploy_version_to_all "$VERSION" "发布"
