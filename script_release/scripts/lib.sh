#!/usr/bin/env bash
# lib.sh —— EASIM 发布/回退方案公共函数库
#
# 被各脚本 source。提供：日志、依赖/配置校验、manifest 读写、
# 生产机清单解析、远程 git/资产同步/校验。
#
# 约定：所有函数不调用 exit（除 die），由调用方决定流程；
#       需要中断的致命错误统一走 die。

# ---- 颜色与日志 -----------------------------------------------------------
if [[ -t 2 ]]; then
  _C_RED=$'\033[31m'; _C_GRN=$'\033[32m'; _C_YEL=$'\033[33m'
  _C_BLU=$'\033[34m'; _C_RST=$'\033[0m'
else
  _C_RED=''; _C_GRN=''; _C_YEL=''; _C_BLU=''; _C_RST=''
fi

log()  { printf '%s[INFO]%s %s\n'  "$_C_BLU" "$_C_RST" "$*" >&2; }
ok()   { printf '%s[ OK ]%s %s\n'  "$_C_GRN" "$_C_RST" "$*" >&2; }
warn() { printf '%s[WARN]%s %s\n'  "$_C_YEL" "$_C_RST" "$*" >&2; }
err()  { printf '%s[FAIL]%s %s\n'  "$_C_RED" "$_C_RST" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---- 重试 -----------------------------------------------------------------
#
# retry <desc> -- cmd args...
#   把瞬时故障（SSH 抖动、fetch 网络中断、传输挂死）自愈掉：失败即按指数退避
#   重试，最多 RETRY_ATTEMPTS 次，退避 = RETRY_BASE_DELAY * 2^(n-1) + 随机抖动。
#   抖动用于打散多台并发主机的重试时刻，避免同步风暴。
#   注意：确定性故障（如版本号非法）不应走 retry，交由调用方直接判失败。
retry() {
  local desc="$1"; shift
  [[ "${1:-}" == "--" ]] && shift
  local attempts="${RETRY_ATTEMPTS:-3}"
  local base="${RETRY_BASE_DELAY:-5}"
  local n=1
  while true; do
    if "$@"; then
      (( n > 1 )) && ok "重试成功（第 $n 次）：$desc"
      return 0
    fi
    if (( n >= attempts )); then
      err "已重试 $attempts 次仍失败：$desc"
      return 1
    fi
    local delay=$(( base * (2 ** (n - 1)) + RANDOM % 3 ))
    warn "失败（第 $n/$attempts 次）：$desc —— ${delay}s 后重试"
    sleep "$delay"
    n=$(( n + 1 ))
  done
}


# ---- 依赖与配置校验 -------------------------------------------------------

# 校验本机所需命令存在。参数为命令列表。
require_cmds() {
  local miss=()
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || miss+=("$c")
  done
  if (( ${#miss[@]} > 0 )); then
    die "缺少必要命令：${miss[*]}（请先安装）"
  fi
}

# 校验测试机端通用前提：CODE_DIR 有效、是 git 仓库、STABLE_ROOT 可用。
validate_controller_env() {
  require_cmds git rsync ssh sha256sum

  [[ -n "${CODE_DIR:-}" ]] \
    || die "CODE_DIR 未设置且无法自动探测：请在 git 仓库内运行，或显式设置 CODE_DIR"
  [[ -d "$CODE_DIR/.git" ]] || git -C "$CODE_DIR" rev-parse --git-dir >/dev/null 2>&1 \
    || die "CODE_DIR 不是 git 仓库：$CODE_DIR"

  if (( ${#ASSET_PATHS[@]} == 0 )); then
    die "ASSET_PATHS 为空：请在 config.sh 中至少配置一个资产路径"
  fi

  log "CODE_DIR    = $CODE_DIR"
  log "STABLE_ROOT = $STABLE_ROOT"
  log "PROD_CODE   = $PROD_CODE"
}

# 版本号基础校验：非空、不含路径分隔符与空白。
validate_version() {
  local v="$1"
  [[ -n "$v" ]] || die "缺少版本号参数，例如：$0 2.0.1"
  [[ "$v" != *"/"* && "$v" != *" "* && "$v" != *".."* ]] \
    || die "非法版本号：'$v'（不能包含 / 空格 或 ..）"
}

# 返回某版本目录路径（不保证存在）。
version_dir() { printf '%s/%s' "$STABLE_ROOT" "$1"; }

# ---- Git 相关 -------------------------------------------------------------

# 获取 CODE_DIR 当前完整 commit。
git_current_commit() {
  git -C "$CODE_DIR" rev-parse HEAD 2>/dev/null \
    || die "无法获取 $CODE_DIR 的 git commit"
}

# 获取 CODE_DIR 当前分支名（detached 时返回 HEAD）。
git_current_branch() {
  git -C "$CODE_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "HEAD"
}

# 校验给定 commit 已存在于远程（否则生产机 fetch 不到）。
# 通过 `git branch -r --contains` 判断该 commit 是否被任一远程分支包含。
git_commit_on_remote() {
  local commit="$1"
  local remote_branches
  remote_branches="$(git -C "$CODE_DIR" branch -r --contains "$commit" 2>/dev/null \
                     | grep -c "^[[:space:]]*${GIT_REMOTE}/" || true)"
  [[ "${remote_branches:-0}" -gt 0 ]]
}

# ---- manifest 读写 --------------------------------------------------------
#
# manifest.yaml 结构固定且简单，故用轻量解析（不依赖 yq）。
# 写入时保证可被本库的读取函数复原。

# 写 manifest。参数：版本目录 version commit branch checksum_file
# 资产路径列表从全局数组 _MANIFEST_PATHS 读取。
write_manifest() {
  local vdir="$1" version="$2" commit="$3" branch="$4" checksum_file="$5"
  local mf="$vdir/manifest.yaml"
  {
    printf 'version: %s\n' "$version"
    printf '\n'
    printf 'code:\n'
    printf '  commit: %s\n' "$commit"
    printf '  branch: %s\n' "$branch"
    printf '\n'
    printf 'ignored_assets:\n'
    printf '  paths:\n'
    local p
    for p in "${_MANIFEST_PATHS[@]}"; do
      printf '    - %s\n' "$p"
    done
    printf '  checksum_file: %s\n' "$checksum_file"
    printf '\n'
    printf 'created_at: "%s"\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'test_result: %s\n' "passed"
  } > "$mf"
}

# 读 manifest 顶层标量字段（version/created_at/test_result）。
manifest_field() {
  local mf="$1" key="$2"
  sed -n "s/^${key}:[[:space:]]*//p" "$mf" | head -n1 \
    | sed 's/^"//; s/"$//'
}

# 读 manifest 中 code.commit。
manifest_commit() {
  local mf="$1"
  sed -n 's/^[[:space:]]*commit:[[:space:]]*//p' "$mf" | head -n1
}

# 读 manifest 中 ignored_assets.paths 列表，逐行输出。
manifest_paths() {
  local mf="$1"
  # 取 “  paths:” 之后、到下一个同级或更浅缩进键之前的所有 “    - xxx” 行。
  awk '
    /^[[:space:]]+paths:[[:space:]]*$/ { inblock=1; next }
    inblock {
      if ($0 ~ /^[[:space:]]+-[[:space:]]+/) {
        line=$0
        sub(/^[[:space:]]+-[[:space:]]+/, "", line)
        print line
        next
      }
      if ($0 ~ /^[[:space:]]*[^[:space:]-]/) { inblock=0 }
    }
  ' "$mf"
}

# 读取 manifest paths 到全局数组 MANIFEST_PATHS。
load_manifest_paths() {
  local mf="$1"
  MANIFEST_PATHS=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && MANIFEST_PATHS+=("$line")
  done < <(manifest_paths "$mf")
  (( ${#MANIFEST_PATHS[@]} > 0 )) || die "manifest 中未解析到任何资产路径：$mf"
}

# ---- 生产机清单解析 -------------------------------------------------------
#
# prod_hosts.txt 每行：机器名 IP SSH用户 [code路径]  （# 开头与空行忽略）
# 第四列 code 路径可选：留空则回退到全局 PROD_CODE，从而允许各机器路径不一致。
# 解析结果写入并行数组 HOST_NAMES / HOST_IPS / HOST_USERS / HOST_CODES。

load_hosts() {
  HOST_NAMES=(); HOST_IPS=(); HOST_USERS=(); HOST_CODES=()
  [[ -f "$PROD_HOSTS_FILE" ]] || die "找不到生产机清单：$PROD_HOSTS_FILE"
  local name ip user code
  while read -r name ip user code; do
    [[ -z "${name:-}" || "${name:0:1}" == "#" ]] && continue
    [[ -n "${ip:-}" && -n "${user:-}" ]] \
      || die "prod_hosts.txt 行格式错误（需 '机器名 IP 用户 [code路径]'）：$name ${ip:-} ${user:-}"
    HOST_NAMES+=("$name"); HOST_IPS+=("$ip"); HOST_USERS+=("$user")
    # 第四列留空时回退到全局 PROD_CODE
    HOST_CODES+=("${code:-$PROD_CODE}")
  done < "$PROD_HOSTS_FILE"
  (( ${#HOST_NAMES[@]} > 0 )) || die "生产机清单为空：$PROD_HOSTS_FILE"
}

# 按目标选择器裁剪 HOST_* 并行数组，只保留匹配的机器（就地修改）。
# 选择器从全局数组 DEPLOY_TARGETS 读取，每项可匹配【机器名或 IP】。
# DEPLOY_TARGETS 为空 -> 不裁剪（全部机器）。
# 任一选择器匹配不到任何机器 -> die（避免静默漏发）。
filter_hosts() {
  (( ${#DEPLOY_TARGETS[@]} == 0 )) && return 0

  # 校验每个选择器都能命中，收集未命中的以便一次性报错
  local sel miss=()
  for sel in "${DEPLOY_TARGETS[@]}"; do
    local hit=0 i
    for i in "${!HOST_NAMES[@]}"; do
      if [[ "${HOST_NAMES[$i]}" == "$sel" || "${HOST_IPS[$i]}" == "$sel" ]]; then
        hit=1; break
      fi
    done
    (( hit == 0 )) && miss+=("$sel")
  done
  (( ${#miss[@]} > 0 )) && die "以下目标不在生产机清单中：${miss[*]}"

  # 保留命中的机器，重建并行数组
  local -a n=() p=() u=() c=()
  local i
  for i in "${!HOST_NAMES[@]}"; do
    local keep=0 sel2
    for sel2 in "${DEPLOY_TARGETS[@]}"; do
      if [[ "${HOST_NAMES[$i]}" == "$sel2" || "${HOST_IPS[$i]}" == "$sel2" ]]; then
        keep=1; break
      fi
    done
    if (( keep )); then
      n+=("${HOST_NAMES[$i]}"); p+=("${HOST_IPS[$i]}")
      u+=("${HOST_USERS[$i]}"); c+=("${HOST_CODES[$i]}")
    fi
  done
  HOST_NAMES=("${n[@]}"); HOST_IPS=("${p[@]}")
  HOST_USERS=("${u[@]}"); HOST_CODES=("${c[@]}")
}

# ---- 远程操作（SSH / rsync） ----------------------------------------------

# 在远程执行命令。参数：user host 命令...
ssh_run() {
  local user="$1" host="$2"; shift 2
  ssh "${SSH_OPTS[@]}" "${user}@${host}" "$@"
}

# 测试 SSH 连通性。参数：user host
ssh_check() {
  local user="$1" host="$2"
  ssh "${SSH_OPTS[@]}" "${user}@${host}" "true" >/dev/null 2>&1
}

# 远程 git fetch + checkout 到指定 commit。参数：user host commit code
remote_checkout() {
  local user="$1" host="$2" commit="$3" code="$4"
  ssh_run "$user" "$host" \
    "cd '$code' && git fetch --all --quiet && git checkout --quiet '$commit'"
}

# 把单个资产目录从快照同步到生产机对应路径。
# 参数：snapshot_assets_root user host asset_rel code
sync_one_asset() {
  local snap_root="$1" user="$2" host="$3" asset="$4" code="$5"
  local src="$snap_root/$asset/"
  local dst="${user}@${host}:$code/$asset/"
  [[ -d "$src" ]] || die "快照中缺少资产目录：$src"
  # 先确保远端目标父目录存在
  ssh_run "$user" "$host" "mkdir -p '$code/$asset'"
  # --delete 仅在该资产子目录内部生效，不波及生产机其它文件
  # RSYNC_NET_OPTS 提供 --partial 断点续传与 --timeout 挂死检测，配合上层重试。
  rsync -a --delete "${RSYNC_NET_OPTS[@]}" "$src" "$dst"
}

# 同步 sha256 清单到生产机 code 根。参数：version_dir user host code
sync_checksum() {
  local vdir="$1" user="$2" host="$3" code="$4"
  rsync -a "$vdir/ignored_assets.sha256" \
    "${user}@${host}:$code/ignored_assets.sha256"
}

# 远程校验 sha256。参数：user host code
remote_verify_checksum() {
  local user="$1" host="$2" code="$3"
  ssh_run "$user" "$host" "cd '$code' && sha256sum -c --quiet ignored_assets.sha256"
}

# 远程写入 current_version.txt。参数：user host version code
remote_write_version() {
  local user="$1" host="$2" version="$3" code="$4"
  ssh_run "$user" "$host" "printf '%s\n' '$version' > '$code/current_version.txt'"
}

# 同步全部资产 + 校验清单，并远程 sha256 校验（一个可重试单元）。
# 校验失败绝大多数源于传输不完整/中断，故整单元一起重试：rsync --partial 让
# 重跑只补差量，避免重传 12G，也避免对真正的数据损坏无限重试（受 retry 次数上限约束）。
# 参数：version_dir user host code
sync_and_verify() {
  local vdir="$1" user="$2" host="$3" code="$4"
  local snap_root="$vdir/ignored_assets"

  local asset
  for asset in "${MANIFEST_PATHS[@]}"; do
    log "  同步资产：$asset"
    sync_one_asset "$snap_root" "$user" "$host" "$asset" "$code" \
      || { err "资产同步失败：$asset"; return 1; }
  done

  sync_checksum "$vdir" "$user" "$host" "$code"   || { err "校验清单同步失败"; return 1; }
  remote_verify_checksum "$user" "$host" "$code"  || { err "sha256 校验未通过"; return 1; }
  return 0
}

# ---- 部署编排（deploy 与 rollback 共用） ----------------------------------
#
# 把指定版本部署到 prod_hosts.txt 中的生产机。默认全部机器；若全局数组
# DEPLOY_TARGETS 非空，则只发布到匹配（机器名或 IP）的机器。
# 单台失败不影响其它机器，最后汇总并以失败台数作退出码。
# 参数：version  action_label(发布/回退)
# 依赖：已 source config.sh + lib.sh，且 validate_controller_env 已通过。
deploy_version_to_all() {
  local version="$1" label="${2:-发布}"
  local vdir; vdir="$(version_dir "$version")"

  [[ -d "$vdir" ]] || die "版本目录不存在：$vdir"
  local mf="$vdir/manifest.yaml"
  [[ -f "$mf" ]] || die "缺少 manifest：$mf"
  [[ -f "$vdir/ignored_assets.sha256" ]] || die "缺少校验清单：$vdir/ignored_assets.sha256"

  local commit; commit="$(manifest_commit "$mf")"
  [[ -n "$commit" ]] || die "manifest 未记录 commit：$mf"
  load_manifest_paths "$mf"   # -> MANIFEST_PATHS

  load_hosts                  # -> HOST_NAMES/HOST_IPS/HOST_USERS
  filter_hosts                # 按 DEPLOY_TARGETS 裁剪（为空则全部）
  if (( ${#DEPLOY_TARGETS[@]} > 0 )); then
    log "目标机器（指定 ${#DEPLOY_TARGETS[@]} 项）：${HOST_NAMES[*]}"
  fi

  local total="${#HOST_NAMES[@]}"
  local parallel="${MAX_PARALLEL:-4}"
  (( parallel < 1 )) && parallel=1
  (( parallel > total )) && parallel="$total"

  log "${label}版本 $version （commit=$commit，资产 ${#MANIFEST_PATHS[@]} 项，生产机 $total 台，并发 $parallel）"

  # 并发下各主机日志混打会乱，故每台写独立日志文件，退出码写独立 rc 文件，
  # 全部完成后按主机原始顺序回放，保证输出稳定、与完成先后无关。
  local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/easim_deploy.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  local i active=0
  for i in "${!HOST_NAMES[@]}"; do
    # 作业池限流：活动作业达上限时，回收一个已完成的再继续投放。
    while (( active >= parallel )); do
      wait -n 2>/dev/null || true
      active=$(( active - 1 ))
    done

    {
      local name="${HOST_NAMES[$i]}" ip="${HOST_IPS[$i]}"
      local user="${HOST_USERS[$i]}" code="${HOST_CODES[$i]}"
      log "---- [$name $ip] 开始${label}（code=$code） ----"
      if deploy_version_to_host "$vdir" "$commit" "$user" "$ip" "$version" "$code"; then
        ok "[$name] ${label}成功 -> $version"
        printf '0' > "$tmp/$i.rc"
      else
        err "[$name] ${label}失败（保留现状，未写入 current_version.txt）"
        printf '1' > "$tmp/$i.rc"
      fi
    } > "$tmp/$i.log" 2>&1 &
    active=$(( active + 1 ))
  done

  # 等待剩余作业收尾
  wait

  # 按原始顺序回放日志并汇总
  local fail=0
  for i in "${!HOST_NAMES[@]}"; do
    printf '%s========== [%s %s] ==========%s\n' \
      "$_C_BLU" "${HOST_NAMES[$i]}" "${HOST_IPS[$i]}" "$_C_RST" >&2
    [[ -f "$tmp/$i.log" ]] && cat "$tmp/$i.log" >&2
    local rc; rc="$(cat "$tmp/$i.rc" 2>/dev/null || echo 1)"
    [[ "$rc" == "0" ]] || fail=$(( fail + 1 ))
  done

  echo
  if (( fail == 0 )); then
    ok "全部 $total 台${label}成功：$version"
  else
    err "$fail/$total 台${label}失败，请查看上方日志"
  fi
  return "$fail"
}

# 把指定版本部署到单台生产机（任一步失败即返回非 0，且不写版本号）。
# 各步骤各自套 retry 自愈瞬时故障；sync+校验作为一个整体重试单元。
# 参数：version_dir commit user host version code
deploy_version_to_host() {
  local vdir="$1" commit="$2" user="$3" host="$4" version="$5" code="$6"

  retry "SSH 连通 $user@$host" -- \
    ssh_check "$user" "$host"                            || { err "SSH 不可达：$user@$host"; return 1; }
  retry "git checkout $commit" -- \
    remote_checkout "$user" "$host" "$commit" "$code"    || { err "git checkout 失败：$commit"; return 1; }
  retry "同步并校验资产" -- \
    sync_and_verify "$vdir" "$user" "$host" "$code"      || { err "资产同步/校验失败"; return 1; }
  # 全部通过后才写版本号
  retry "写入 current_version.txt" -- \
    remote_write_version "$user" "$host" "$version" "$code" \
    || { err "写入 current_version.txt 失败"; return 1; }
  return 0
}
