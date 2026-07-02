#!/usr/bin/env bash
# rollback_prod.sh —— 把生产机回退到指定历史稳定版本
#
# 用法：
#   ./rollback_prod.sh <version> [host ...]
#
# 不带 host 参数：回退 prod_hosts.txt 中的所有生产机。
# 带 host 参数：只回退指定机器（可多台），host 可写机器名或 IP。
#
# 回退本质与发布相同，只是选择历史版本目录。资产与 commit 均取自
# 【该历史版本自己的 manifest】，而非当前 code 目录、也非当前 config。
# 退出码=失败台数。

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
# 其余参数为目标机器选择器（机器名或 IP）；为空则回退全部
DEPLOY_TARGETS=("$@")

validate_version "$VERSION"
validate_controller_env

if (( ${#DEPLOY_TARGETS[@]} > 0 )); then
  warn "即将把指定生产机回退到历史版本：$VERSION（目标：${DEPLOY_TARGETS[*]}）"
else
  warn "即将把所有生产机回退到历史版本：$VERSION"
fi
deploy_version_to_all "$VERSION" "回退"
