#!/usr/bin/env bash
# status_prod.sh —— 巡检所有生产机状态
#
# 用法：
#   ./status_prod.sh
#
# 对 prod_hosts.txt 每台输出一行：
#   <name>  online/offline  version=..  commit=..  assets=ok/bad  disk=..%
# 不修改任何远程状态，纯只读巡检。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && {
  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;
}

require_cmds ssh
load_hosts

printf '%-8s %-8s %-18s %-12s %-10s %-7s\n' \
  HOST STATUS VERSION COMMIT ASSETS DISK

for i in "${!HOST_NAMES[@]}"; do
  name="${HOST_NAMES[$i]}"; ip="${HOST_IPS[$i]}"; user="${HOST_USERS[$i]}"

  if ! ssh_check "$user" "$ip"; then
    printf '%-8s %-8s %-18s %-12s %-10s %-7s\n' \
      "$name" "offline" "-" "-" "-" "-"
    continue
  fi

  # 一次 SSH 取回多项信息，减少往返。各项缺失时给占位符。
  remote_out="$(ssh_run "$user" "$ip" "
    cd '$PROD_CODE' 2>/dev/null || { echo 'NO_CODE_DIR'; exit 0; }
    ver=\$(cat current_version.txt 2>/dev/null || echo unknown)
    commit=\$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
    if [ -f ignored_assets.sha256 ]; then
      if sha256sum -c --quiet ignored_assets.sha256 >/dev/null 2>&1; then
        assets=ok
      else
        assets=bad
      fi
    else
      assets=none
    fi
    disk=\$(df -P . | awk 'NR==2{print \$5}')
    printf '%s|%s|%s|%s\n' \"\$ver\" \"\$commit\" \"\$assets\" \"\$disk\"
  " 2>/dev/null || echo "ERR")"

  if [[ "$remote_out" == "NO_CODE_DIR" || "$remote_out" == "ERR" || -z "$remote_out" ]]; then
    printf '%-8s %-8s %-18s %-12s %-10s %-7s\n' \
      "$name" "online" "no-code-dir" "-" "-" "-"
    continue
  fi

  IFS='|' read -r ver commit assets disk <<< "$remote_out"
  printf '%-8s %-8s %-18s %-12s %-10s %-7s\n' \
    "$name" "online" "${ver:-unknown}" "${commit:-unknown}" "${assets:-?}" "${disk:-?}"
done
