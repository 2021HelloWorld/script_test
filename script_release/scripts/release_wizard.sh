#!/usr/bin/env bash
# release_wizard.sh —— EASIM 发布引导（交互式统一入口）
#
# 用法：
#   ./release_wizard.sh
#
# 本脚本只负责引导、校验、确认，不复写任何发布逻辑。
# 实际执行由以下核心脚本承担：
#   create_stable.sh  deploy_prod.sh  rollback_prod.sh  status_prod.sh
#
# 原则：交互脚本只做"问问题 + 展示状态 + 前置校验 + 调用核心脚本"。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# ---- 颜色（终端颜色已在 lib.sh 初始化，这里补充额外样式） -----------------
if [[ -t 1 ]]; then
  _C_BOLD=$'\033[1m'
  _C_DIM=$'\033[2m'
  _C_CYN=$'\033[36m'
  _C_MAG=$'\033[35m'
else
  _C_BOLD=''; _C_DIM=''; _C_CYN=''; _C_MAG=''
fi

# ---- 辅助函数 ---------------------------------------------------------------

# 打印带框标题
_banner() {
  local line="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  printf '\n%s%s%s\n' "$_C_CYN" "$line" "$_C_RST"
  printf '%s  EASIM 发布引导%s\n' "${_C_BOLD}${_C_CYN}" "$_C_RST"
  printf '%s%s%s\n\n' "$_C_CYN" "$line" "$_C_RST"
}

# 打印小节标题
_section() {
  printf '\n%s▸ %s%s\n' "${_C_BOLD}" "$*" "$_C_RST"
}

# 读取用户输入，$1=提示语 $2=变量名（通过 nameref 赋值）
_prompt() {
  local msg="$1"
  local -n _ref="$2"
  printf '%s%s%s ' "${_C_BOLD}" "$msg" "$_C_RST" >&2
  read -r _ref
}

# 读取 y/N 确认，返回 0=yes 1=no
_confirm() {
  local answer
  printf '%s%s [y/N]%s ' "${_C_BOLD}" "$*" "$_C_RST" >&2
  read -r answer
  [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

# 暂停等待回车
_pause() {
  printf '%s%s（按 Enter 继续）%s' "$_C_DIM" "${1:-}" "$_C_RST" >&2
  read -r _
}

# 用 $EDITOR 或 vi 打开文件
_open_editor() {
  "${EDITOR:-vi}" "$1"
}

# ---- 环境概况 ---------------------------------------------------------------

_show_env() {
  _section "当前配置"
  printf '  %-20s %s\n' "CODE_DIR:"       "${CODE_DIR:-(未设置)}"
  printf '  %-20s %s\n' "STABLE_ROOT:"    "$STABLE_ROOT"
  printf '  %-20s %s\n' "PROD_CODE:"      "$PROD_CODE"
  printf '  %-20s %s\n' "PROD_HOSTS_FILE:" "$PROD_HOSTS_FILE"
  printf '  %-20s\n'    "ASSET_PATHS:"
  local p
  for p in "${ASSET_PATHS[@]}"; do
    printf '    %s- %s%s\n' "$_C_DIM" "$p" "$_C_RST"
  done

  _section "当前 Git"
  if [[ -n "${CODE_DIR:-}" && -d "${CODE_DIR}/.git" ]] \
     || git -C "${CODE_DIR:-.}" rev-parse --git-dir >/dev/null 2>&1; then
    local branch commit
    branch="$(git_current_branch)"
    commit="$(git -C "$CODE_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    printf '  %-20s %s\n' "branch:" "$branch"
    printf '  %-20s %s\n' "commit(short):" "$commit"
    printf '  %-20s %s\n' "remote:" "$GIT_REMOTE"
  else
    warn "CODE_DIR 不是 git 仓库或未设置"
  fi
  echo
}

# ---- 稳定版本索引 -----------------------------------------------------------

# 解析 stable_index.yaml，输出列表供用户选择。
# 设置全局数组 _VER_LIST（有序版本号，最新在前）。
_load_version_list() {
  _VER_LIST=()
  local idx="$STABLE_ROOT/stable_index.yaml"
  [[ -f "$idx" ]] || return 0
  # 读取所有 "version:" 行，保持 yaml 追加顺序，反转使最新在前
  while IFS= read -r line; do
    local v
    v="$(printf '%s' "$line" | sed 's/^[[:space:]]*-[[:space:]]*version:[[:space:]]*//')"
    [[ -n "$v" ]] && _VER_LIST=("$v" "${_VER_LIST[@]}")
  done < <(grep '^- version:' "$idx")
}

# 展示版本列表（带编号），供发布/回退选择
_show_version_list() {
  local idx="$STABLE_ROOT/stable_index.yaml"
  if [[ ! -f "$idx" ]] || [[ ${#_VER_LIST[@]} -eq 0 ]]; then
    warn "暂无可用稳定版本（stable_index.yaml 不存在或为空）"
    return 1
  fi
  _section "可用稳定版本"
  printf '  %-4s %-16s %-24s %s\n' "编号" "版本号" "创建时间" "Commit"

  local i=0
  local v
  for v in "${_VER_LIST[@]}"; do
    local vdir="$STABLE_ROOT/$v"
    local mf="$vdir/manifest.yaml"
    local created commit
    if [[ -f "$mf" ]]; then
      created="$(manifest_field "$mf" created_at)"
      commit="$(manifest_commit "$mf" | cut -c1-8)"
    else
      created="-"; commit="-"
    fi
    printf '  %-4s %-16s %-24s %s\n' "$((i+1))." "$v" "$created" "$commit"
    i=$((i+1))
  done
}

# 让用户选择版本（编号或直接输入版本号），将选中版本写入变量
# 参数：$1=变量名（nameref）
_pick_version() {
  local -n _ver_ref="$1"
  _show_version_list || { _ver_ref=""; return 1; }
  echo
  _prompt "请输入编号或版本号（留空取消）：" _input
  if [[ -z "$_input" ]]; then
    _ver_ref=""; return 1
  fi
  # 如果是数字，按编号查
  if [[ "$_input" =~ ^[0-9]+$ ]]; then
    local idx=$(( _input - 1 ))
    if (( idx >= 0 && idx < ${#_VER_LIST[@]} )); then
      _ver_ref="${_VER_LIST[$idx]}"
    else
      err "编号超出范围"; _ver_ref=""; return 1
    fi
  else
    _ver_ref="$_input"
  fi
}

# ---- 前置条件检查 -----------------------------------------------------------

# 检查单项，成功打 ok，失败打 warn/err，返回失败数
# 返回全局 _CHECK_FAIL 累加
_CHECK_FAIL=0

_chk() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    ok "$desc"
  else
    err "$desc"
    _CHECK_FAIL=$((_CHECK_FAIL + 1))
  fi
}

_run_prechecks() {
  _CHECK_FAIL=0
  _section "前置条件检查"

  # CODE_DIR
  _chk "CODE_DIR 已设置 (${CODE_DIR:-(空)})" \
       test -n "${CODE_DIR:-}"
  _chk "CODE_DIR 是 git 仓库" \
       git -C "${CODE_DIR:-.}" rev-parse --git-dir

  # ASSET_PATHS
  local p
  for p in "${ASSET_PATHS[@]}"; do
    _chk "资产路径存在：$p" \
         test -d "$CODE_DIR/$p"
  done

  # STABLE_ROOT
  _chk "STABLE_ROOT 存在且可写 ($STABLE_ROOT)" \
       bash -c "test -d '$STABLE_ROOT' && test -w '$STABLE_ROOT'"

  # 生产机清单
  _chk "生产机清单存在 ($PROD_HOSTS_FILE)" \
       test -f "$PROD_HOSTS_FILE"

  # 命令依赖
  local cmds=("git" "rsync" "ssh" "sha256sum")
  local c
  for c in "${cmds[@]}"; do
    _chk "命令可用：$c" command -v "$c"
  done

  echo
  if (( _CHECK_FAIL == 0 )); then
    ok "全部检查通过"
  else
    warn "$_CHECK_FAIL 项检查未通过，操作前请先修复"
  fi
  return "$_CHECK_FAIL"
}

# ---- 菜单动作实现 -----------------------------------------------------------

# 1. 首次初始化生产机清单
_action_init_hosts() {
  _section "初始化生产机清单"
  if [[ -f "$PROD_HOSTS_FILE" ]]; then
    ok "清单已存在：$PROD_HOSTS_FILE"
    if _confirm "是否重新编辑？"; then
      _open_editor "$PROD_HOSTS_FILE"
    fi
    return
  fi

  local example="$SCRIPT_DIR/prod_hosts.txt.example"
  printf '\n  未找到生产机清单：%s\n\n' "$PROD_HOSTS_FILE"
  printf '  1. 从模板创建（推荐）\n'
  printf '  2. 指定已有清单路径\n'
  printf '  3. 暂不处理\n\n'
  _prompt "请选择 [1/2/3]：" _choice

  case "${_choice:-3}" in
    1)
      if [[ ! -f "$example" ]]; then
        err "模板文件不存在：$example"; return 1
      fi
      mkdir -p "$(dirname "$PROD_HOSTS_FILE")"
      cp "$example" "$PROD_HOSTS_FILE"
      ok "已从模板复制到 $PROD_HOSTS_FILE"
      log "请编辑清单，填入实际机器名/IP/用户..."
      _pause
      _open_editor "$PROD_HOSTS_FILE"
      ;;
    2)
      _prompt "请输入已有清单路径：" _src
      if [[ ! -f "${_src:-}" ]]; then
        err "文件不存在：$_src"; return 1
      fi
      mkdir -p "$(dirname "$PROD_HOSTS_FILE")"
      cp "$_src" "$PROD_HOSTS_FILE"
      ok "已复制到 $PROD_HOSTS_FILE"
      ;;
    *)
      log "已跳过"; return 0
      ;;
  esac
}

# 2. 创建稳定版本
_action_create_stable() {
  _section "创建稳定版本 —— 前置检查"

  # 本地环境检查
  local fail=0
  _CHECK_FAIL=0
  _chk "CODE_DIR 已设置" test -n "${CODE_DIR:-}"
  _chk "CODE_DIR 是 git 仓库" git -C "${CODE_DIR:-.}" rev-parse --git-dir
  local p
  for p in "${ASSET_PATHS[@]}"; do
    _chk "资产路径存在：$p" test -d "$CODE_DIR/$p"
  done
  _chk "STABLE_ROOT 可写" bash -c "mkdir -p '$STABLE_ROOT' && test -w '$STABLE_ROOT'"

  # commit 是否已 push
  local commit branch
  commit="$(git_current_commit 2>/dev/null || true)"
  branch="$(git_current_branch 2>/dev/null || true)"
  if [[ -n "$commit" ]]; then
    if git_commit_on_remote "$commit"; then
      ok "当前 commit 已在远程 $GIT_REMOTE（$branch @ ${commit:0:8}）"
    else
      err "当前 commit ${commit:0:8} 尚未 push 到远程 $GIT_REMOTE"
      _CHECK_FAIL=$((_CHECK_FAIL + 1))
    fi
  fi

  if (( _CHECK_FAIL > 0 )); then
    warn "$_CHECK_FAIL 项检查失败，无法继续创建"
    return 1
  fi

  # 输入版本号
  echo
  _prompt "请输入新版本号（例如 2.0.1）：" _version
  [[ -z "$_version" ]] && { log "已取消"; return 0; }
  validate_version "$_version" 2>/dev/null \
    || { err "非法版本号：$_version"; return 1; }

  local vdir; vdir="$(version_dir "$_version")"
  if [[ -e "$vdir" ]]; then
    err "版本已存在，不可覆盖：$vdir"
    return 1
  fi

  # 确认页
  _section "确认创建"
  printf '  %-16s %s\n' "版本号:"    "$_version"
  printf '  %-16s %s\n' "commit:"    "${commit:0:8}"
  printf '  %-16s %s\n' "分支:"      "$branch"
  printf '  %-16s\n'    "资产:"
  for p in "${ASSET_PATHS[@]}"; do
    printf '    - %s\n' "$p"
  done
  echo

  _confirm "确认执行创建？" || { log "已取消"; return 0; }

  echo
  bash "$SCRIPT_DIR/create_stable.sh" "$_version"
}

# 3. 发布稳定版本到生产机
_action_deploy() {
  _section "发布稳定版本到生产机"
  _load_version_list

  local _version
  _pick_version _version || { log "已取消"; return 0; }
  [[ -z "$_version" ]] && { log "已取消"; return 0; }

  local vdir; vdir="$(version_dir "$_version")"
  local mf="$vdir/manifest.yaml"
  [[ -d "$vdir" ]] || { err "版本目录不存在：$vdir"; return 1; }
  [[ -f "$mf"   ]] || { err "缺少 manifest：$mf";    return 1; }

  # 读 manifest 信息
  local commit branch assets_list
  commit="$(manifest_commit "$mf")"
  branch="$(manifest_field  "$mf" branch 2>/dev/null || echo -)"
  assets_list="$(manifest_paths "$mf")"

  # 读生产机列表
  load_hosts 2>/dev/null || { err "生产机清单加载失败"; return 1; }

  # 确认页
  _section "发布确认"
  printf '  %-16s %s\n' "目标版本:"  "$_version"
  printf '  %-16s %s\n' "commit:"    "${commit:0:8}"
  printf '  %-16s %s\n' "分支:"      "$branch"
  printf '  %-16s\n'    "资产路径:"
  while IFS= read -r _ap; do
    [[ -n "$_ap" ]] && printf '    - %s\n' "$_ap"
  done <<< "$assets_list"
  printf '  %-16s\n'    "生产机:"
  local i
  for i in "${!HOST_NAMES[@]}"; do
    printf '    - %s %s (%s)  code=%s\n' \
      "${HOST_NAMES[$i]}" "${HOST_IPS[$i]}" "${HOST_USERS[$i]}" "${HOST_CODES[$i]}"
  done
  echo

  _confirm "确认发布到以上生产机？" || { log "已取消"; return 0; }

  echo
  bash "$SCRIPT_DIR/deploy_prod.sh" "$_version"
}

# 4. 回退到历史版本
_action_rollback() {
  _section "回退到历史版本"
  _load_version_list

  local _version
  _pick_version _version || { log "已取消"; return 0; }
  [[ -z "$_version" ]] && { log "已取消"; return 0; }

  local vdir; vdir="$(version_dir "$_version")"
  local mf="$vdir/manifest.yaml"
  [[ -d "$vdir" ]] || { err "版本目录不存在：$vdir"; return 1; }
  [[ -f "$mf"   ]] || { err "缺少 manifest：$mf";    return 1; }

  local commit branch assets_list
  commit="$(manifest_commit "$mf")"
  branch="$(manifest_field  "$mf" branch 2>/dev/null || echo -)"
  assets_list="$(manifest_paths "$mf")"
  load_hosts 2>/dev/null || { err "生产机清单加载失败"; return 1; }

  # 回退确认页（更醒目的警告）
  _section "⚠  回退确认"
  printf '  %s%s警告：即将把所有生产机回退到历史版本 %s%s\n' \
    "$_C_BOLD" "$_C_RED" "$_version" "$_C_RST"
  echo
  printf '  %-16s %s\n' "回退目标:"  "$_version"
  printf '  %-16s %s\n' "commit:"    "${commit:0:8}"
  printf '  %-16s %s\n' "分支:"      "$branch"
  printf '  %-16s\n'    "资产路径:"
  while IFS= read -r _ap; do
    [[ -n "$_ap" ]] && printf '    - %s\n' "$_ap"
  done <<< "$assets_list"
  printf '  %-16s\n'    "生产机："
  local i
  for i in "${!HOST_NAMES[@]}"; do
    printf '    - %s %s (%s)  code=%s\n' \
      "${HOST_NAMES[$i]}" "${HOST_IPS[$i]}" "${HOST_USERS[$i]}" "${HOST_CODES[$i]}"
  done
  echo

  # 二次确认：要求重新输入版本号
  local _confirm_ver
  printf '%s请重新输入版本号以二次确认（降低误操作风险）：%s ' \
    "${_C_BOLD}${_C_YEL}" "$_C_RST" >&2
  read -r _confirm_ver

  if [[ "$_confirm_ver" != "$_version" ]]; then
    err "版本号不一致，回退已取消"
    return 1
  fi

  echo
  bash "$SCRIPT_DIR/rollback_prod.sh" "$_version"
}

# 5. 查看生产机状态
_action_status() {
  _section "生产机状态巡检"
  echo
  bash "$SCRIPT_DIR/status_prod.sh"
}

# 6. 检查前置条件
_action_precheck() {
  _run_prechecks || true
}

# 7. 修改配置
_action_config() {
  local _conf="$SCRIPT_DIR/config.sh"

  while true; do
    _section "修改配置"
    printf '  %-22s %s\n' "1. CODE_DIR:"       "${CODE_DIR:-(自动探测)}"
    printf '  %-22s %s\n' "2. STABLE_ROOT:"    "$STABLE_ROOT"
    printf '  %-22s %s\n' "3. PROD_CODE:"      "$PROD_CODE"
    printf '  %-22s %s\n' "4. PROD_HOSTS_FILE:" "$PROD_HOSTS_FILE"
    printf '  %-22s %s\n' "5. GIT_REMOTE:"     "$GIT_REMOTE"
    printf '  %-22s %s\n' "6. ASSET_PATHS:"    "${ASSET_PATHS[*]}"
    printf '  %-22s %s\n' "7. SSH 超时(秒):"  "${SSH_CONNECT_TIMEOUT:-10}"
    printf '  %-22s %s\n' "8. RSYNC_EXCLUDES:" "${RSYNC_EXCLUDES[*]}"
    printf '\n  %s\n' "0. 返回主菜单"
    echo

    _prompt "请选择要修改的配置项 [0-8]：" _item

    case "${_item:-}" in
      1)
        _prompt "新的 CODE_DIR（当前 ${CODE_DIR:-(自动探测)}，留空则恢复自动探测）：" _val
        if [[ -z "$_val" ]]; then
          sed -i "s|^: \"\${CODE_DIR:=.*\"\$|: \"\${CODE_DIR:=}\"|" "$_conf"
          # 重新自动探测
          CODE_DIR="$(git -C "$(pwd)" rev-parse --show-toplevel 2>/dev/null || true)"
          ok "CODE_DIR 已恢复自动探测 -> ${CODE_DIR:-(空)}"
        else
          sed -i "s|^: \"\${CODE_DIR:=.*\"\$|: \"\${CODE_DIR:=$_val}\"|" "$_conf"
          CODE_DIR="$_val"
          ok "CODE_DIR 已更新 -> $_val"
        fi
        ;;
      2)
        _prompt "新的 STABLE_ROOT（当前 $STABLE_ROOT）：" _val
        [[ -z "$_val" ]] && { log "已取消"; continue; }
        sed -i "s|^: \"\${STABLE_ROOT:=.*\"\$|: \"\${STABLE_ROOT:=$_val}\"|" "$_conf"
        STABLE_ROOT="$_val"
        PROD_HOSTS_FILE="${STABLE_ROOT}/prod_hosts.txt"
        ok "STABLE_ROOT 已更新 -> $_val"
        ;;
      3)
        _prompt "新的 PROD_CODE（当前 $PROD_CODE）：" _val
        [[ -z "$_val" ]] && { log "已取消"; continue; }
        sed -i "s|^: \"\${PROD_CODE:=.*\"\$|: \"\${PROD_CODE:=$_val}\"|" "$_conf"
        PROD_CODE="$_val"
        ok "PROD_CODE 已更新 -> $_val"
        ;;
      4)
        _prompt "新的 PROD_HOSTS_FILE（当前 $PROD_HOSTS_FILE）：" _val
        [[ -z "$_val" ]] && { log "已取消"; continue; }
        sed -i "s|^: \"\${PROD_HOSTS_FILE:=.*\"\$|: \"\${PROD_HOSTS_FILE:=$_val}\"|" "$_conf"
        PROD_HOSTS_FILE="$_val"
        ok "PROD_HOSTS_FILE 已更新 -> $_val"
        ;;
      5)
        _prompt "新的 GIT_REMOTE（当前 $GIT_REMOTE）：" _val
        [[ -z "$_val" ]] && { log "已取消"; continue; }
        sed -i "s|^: \"\${GIT_REMOTE:=.*\"\$|: \"\${GIT_REMOTE:=$_val}\"|" "$_conf"
        GIT_REMOTE="$_val"
        ok "GIT_REMOTE 已更新 -> $_val"
        ;;
      6)
        _section "编辑 ASSET_PATHS"
        echo
        log "当前资产路径："
        local _i
        for _i in "${!ASSET_PATHS[@]}"; do
          printf '  %s. %s\n' "$((_i+1))" "${ASSET_PATHS[$_i]}"
        done
        echo
        printf '  a. 新增一行\n'
        printf '  d. 删除一行\n'
        printf '  0. 返回\n'
        echo
        _prompt "请选择：" _op
        case "${_op:-}" in
          a)
            _prompt "请输入新的资产相对路径（如 assets/environment/Office_11F_Room02）：" _new_path
            [[ -z "$_new_path" ]] && { log "已取消"; continue; }
            # 找到 ASSET_PATHS=( 行号，再找到它后面第一个 ) ，在 ) 之前插入
            local _start; _start="$(grep -n '^  ASSET_PATHS=(' "$_conf" | head -1 | cut -d: -f1)"
            local _end; _end="$(tail -n +"$_start" "$_conf" | grep -n '^  )$' | head -1 | cut -d: -f1)"
            _end=$((_start + _end - 1))
            sed -i "${_end}i\\    \"$_new_path\"" "$_conf"
            ASSET_PATHS+=("$_new_path")
            ok "已新增 -> $_new_path"
            ;;
          d)
            [[ ${#ASSET_PATHS[@]} -eq 1 ]] && { warn "至少保留一项"; continue; }
            _prompt "请输入要删除的编号（1-${#ASSET_PATHS[@]}）：" _del_idx
            [[ -z "$_del_idx" ]] && { log "已取消"; continue; }
            if [[ "$_del_idx" =~ ^[0-9]+$ ]] && (( _del_idx >= 1 && _del_idx <= ${#ASSET_PATHS[@]} )); then
              local _del_path="${ASSET_PATHS[$((_del_idx-1))]}"
              # 删除 config.sh 中匹配该路径的行
              sed -i "\|\"$_del_path\"|d" "$_conf"
              unset "ASSET_PATHS[$((_del_idx-1))]"
              ASSET_PATHS=("${ASSET_PATHS[@]}")
              ok "已删除 -> $_del_path"
            else
              err "无效编号"
            fi
            ;;
          0|"") ;;
          *) warn "无效选项" ;;
        esac
        ;;
      7)
        _prompt "新的 SSH 连接超时秒数（当前 ${SSH_CONNECT_TIMEOUT:-10}）：" _val
        [[ -z "$_val" ]] && { log "已取消"; continue; }
        sed -i "s|^: \"\${SSH_CONNECT_TIMEOUT:=.*\"\$|: \"\${SSH_CONNECT_TIMEOUT:=$_val}\"|" "$_conf"
        SSH_CONNECT_TIMEOUT="$_val"
        SSH_OPTS=(
          -o BatchMode=yes
          -o "ConnectTimeout=${SSH_CONNECT_TIMEOUT}"
          -o StrictHostKeyChecking=accept-new
        )
        ok "SSH_CONNECT_TIMEOUT 已更新 -> $_val"
        ;;
      8)
        _section "编辑 RSYNC_EXCLUDES"
        echo
        log "当前排除项："
        local _j
        for _j in "${!RSYNC_EXCLUDES[@]}"; do
          printf '  %s. %s\n' "$((_j+1))" "${RSYNC_EXCLUDES[$_j]}"
        done
        echo
        printf '  a. 新增\n'
        printf '  d. 删除\n'
        printf '  0. 返回\n'
        echo
        _prompt "请选择：" _op2
        case "${_op2:-}" in
          a)
            _prompt "请输入要排除的目录名（如 .cache）：" _new_ex
            [[ -z "$_new_ex" ]] && { log "已取消"; continue; }
            local _start2; _start2="$(grep -n '^RSYNC_EXCLUDES=(' "$_conf" | head -1 | cut -d: -f1)"
            local _end2; _end2="$(tail -n +"$_start2" "$_conf" | grep -n '^)$' | head -1 | cut -d: -f1)"
            _end2=$((_start2 + _end2 - 1))
            sed -i "${_end2}i\\    \"$_new_ex\"" "$_conf"
            RSYNC_EXCLUDES+=("$_new_ex")
            ok "已新增 -> $_new_ex"
            ;;
          d)
            [[ ${#RSYNC_EXCLUDES[@]} -eq 1 ]] && { warn "至少保留一项"; continue; }
            _prompt "请输入要删除的编号（1-${#RSYNC_EXCLUDES[@]}）：" _del_idx2
            [[ -z "$_del_idx2" ]] && { log "已取消"; continue; }
            if [[ "$_del_idx2" =~ ^[0-9]+$ ]] && (( _del_idx2 >= 1 && _del_idx2 <= ${#RSYNC_EXCLUDES[@]} )); then
              local _del_ex="${RSYNC_EXCLUDES[$((_del_idx2-1))]}"
              sed -i "\|\"$_del_ex\"|d" "$_conf"
              unset "RSYNC_EXCLUDES[$((_del_idx2-1))]"
              RSYNC_EXCLUDES=("${RSYNC_EXCLUDES[@]}")
              ok "已删除 -> $_del_ex"
            else
              err "无效编号"
            fi
            ;;
          0|"") ;;
          *) warn "无效选项" ;;
        esac
        ;;
      0|"") break ;;
      *) warn "无效选项：$_item" ;;
    esac

    echo
    _pause "按 Enter 继续"
  done
}

# ---- 主菜单循环 -------------------------------------------------------------

_main() {
  while true; do
    _banner
    _show_env

    printf '%s请选择操作：%s\n\n' "$_C_BOLD" "$_C_RST"
    printf '  1. 首次初始化生产机清单\n'
    printf '  2. 创建稳定版本\n'
    printf '  3. 发布稳定版本到生产机\n'
    printf '  4. 回退到历史版本\n'
    printf '  5. 查看生产机状态\n'
    printf '  6. 检查本机/生产机前置条件\n'
    printf '  7. 修改配置路径\n'
    printf '  0. 退出\n\n'

    _prompt "请输入选项 [0-7]：" _choice

    case "${_choice:-}" in
      1) _action_init_hosts   ;;
      2) _action_create_stable ;;
      3) _action_deploy       ;;
      4) _action_rollback     ;;
      5) _action_status       ;;
      6) _action_precheck     ;;
      7) _action_config       ;;
      0|q|Q|exit|quit)
        log "退出引导脚本。"
        exit 0
        ;;
      "")
        : # 直接回车，重绘菜单
        ;;
      *)
        warn "无效选项：$_choice"
        ;;
    esac

    echo
    _pause "操作完成。"
  done
}

_main
