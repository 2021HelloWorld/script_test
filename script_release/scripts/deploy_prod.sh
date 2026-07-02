#!/usr/bin/env bash
# deploy_prod.sh —— 把指定稳定版本发布到所有生产机
#
# 用法：
#   ./deploy_prod.sh <version>
#
# 对 prod_hosts.txt 中每台生产机：
#   git fetch + checkout <commit> -> 逐个 rsync 资产 -> 同步并校验 sha256
#   -> 健康检查 -> 写 current_version.txt
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

validate_version "$VERSION"
validate_controller_env

deploy_version_to_all "$VERSION" "发布"
