#!/usr/bin/env bash
# create_stable.sh —— 在测试机创建一个不可变的稳定版本快照
#
# 用法：
#   ./create_stable.sh <version> [--type full|patch] [--based-on <ver>]
#
# 流程：
#   1. 取当前 CODE_DIR 的 git commit
#   2. 校验该 commit 已在远程（否则生产机 fetch 不到，拒绝创建）
#   3. 创建 STABLE_ROOT/<version>/
#   4. 遍历 ASSET_PATHS 逐个快照到 ignored_assets/（排除 .git/.agents/.codex）
#      使用 --link-dest 复用上一个版本中未变文件，节省磁盘
#   5. 生成 ignored_assets.sha256
#   6. 生成 manifest.yaml（写入本次实际锁定的 paths）
#   7. 更新 stable_index.yaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# ---- 参数解析 -------------------------------------------------------------
VERSION=""
VTYPE="full"
BASED_ON="none"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --type)     VTYPE="${2:?--type 需要参数}"; shift 2 ;;
    --based-on) BASED_ON="${2:?--based-on 需要参数}"; shift 2 ;;
    -h|--help)  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)         die "未知选项：$1" ;;
    *)          [[ -z "$VERSION" ]] && VERSION="$1" || die "多余参数：$1"; shift ;;
  esac
done

validate_version "$VERSION"
validate_controller_env

VDIR="$(version_dir "$VERSION")"
[[ -e "$VDIR" ]] && die "版本已存在，不可覆盖（版本不可变）：$VDIR"

# ---- 1~2. commit 与远程校验 ----------------------------------------------
COMMIT="$(git_current_commit)"
BRANCH="$(git_current_branch)"
log "当前 commit = $COMMIT （分支 $BRANCH）"

if git_commit_on_remote "$COMMIT"; then
  ok "commit 已存在于远程 $GIT_REMOTE"
else
  die "commit $COMMIT 不在远程 $GIT_REMOTE，生产机将无法 fetch；请先 push 后再创建版本"
fi

# ---- 3. 创建版本目录 ------------------------------------------------------
log "创建版本目录：$VDIR"
mkdir -p "$VDIR/ignored_assets"

# 找上一个版本目录用于 --link-dest（取字典序最大且非当前版本的已存在版本）
PREV_VER="$(find "$STABLE_ROOT" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null \
            | grep -v "^${VERSION}\$" | sort -V | tail -n1 || true)"
if [[ -n "$PREV_VER" && -d "$STABLE_ROOT/$PREV_VER/ignored_assets" ]]; then
  log "复用上一版本做增量硬链接：$PREV_VER"
fi

# ---- 4. 逐个资产快照 ------------------------------------------------------
EXCLUDE_ARGS=()
for ex in "${RSYNC_EXCLUDES[@]}"; do
  EXCLUDE_ARGS+=( --exclude "$ex" )
done

_MANIFEST_PATHS=()
for asset in "${ASSET_PATHS[@]}"; do
  src="$CODE_DIR/$asset"
  [[ -d "$src" ]] || die "资产路径不存在：$src"
  log "快照资产：$asset"
  dst="$VDIR/ignored_assets/$asset"
  mkdir -p "$dst"

  # --link-dest 相对 dst 解析，故指向上一版本中“同一相对路径”的资产目录
  link_args=()
  if [[ -n "$PREV_VER" && -d "$STABLE_ROOT/$PREV_VER/ignored_assets/$asset" ]]; then
    link_args=( --link-dest "$STABLE_ROOT/$PREV_VER/ignored_assets/$asset" )
  fi

  rsync -a "${EXCLUDE_ARGS[@]}" "${link_args[@]}" "$src/" "$dst/"
  _MANIFEST_PATHS+=("$asset")
done

# ---- 5. 生成 sha256 清单 --------------------------------------------------
log "生成 ignored_assets.sha256（逐字节校验依据，资产较大时耗时数分钟）"
(
  cd "$VDIR/ignored_assets"
  # 相对 ignored_assets/ 记录路径，与生产机 code 根对齐
  find "${_MANIFEST_PATHS[@]}" -type f -print0 \
    | sort -z \
    | xargs -0 sha256sum
) > "$VDIR/ignored_assets.sha256"
ok "校验清单：$(wc -l < "$VDIR/ignored_assets.sha256") 个文件"

# ---- 6. 生成 manifest -----------------------------------------------------
write_manifest "$VDIR" "$VERSION" "$VTYPE" "$BASED_ON" \
  "$COMMIT" "$BRANCH" "ignored_assets.sha256"
ok "已写入 manifest.yaml"

# ---- 7. 更新索引 ----------------------------------------------------------
INDEX="$STABLE_ROOT/stable_index.yaml"
[[ -f "$INDEX" ]] || printf 'versions:\n' > "$INDEX"
printf -- '- version: %s\n  commit: %s\n  type: %s\n  created_at: "%s"\n' \
  "$VERSION" "$COMMIT" "$VTYPE" "$(date '+%Y-%m-%d %H:%M:%S')" >> "$INDEX"

ok "稳定版本创建完成：$VERSION  ->  $VDIR"
