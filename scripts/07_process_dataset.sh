#!/usr/bin/env bash
# =============================================================================
# 07_process_dataset.sh — replay 检查、剔除异常 trial、裁剪初始化帧并整理成品数据
# 运行位置：宿主机
# 输出位置：$EASIM_HOST_PATH/datasets/sim_data/<name>_processed_<YYmmdd_HHMM>/
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

SCENES=(
    "抓三个水果        |Easim-PickFruitsOffice-G1-O6-Bimanual-Replay-v0"
    "抓纸团果皮        |Easim-PickPaperBallsOffice-G1-O6-Bimanual-Replay-v0"
    "水果+纸团综合场景 |Easim-PickFruitsAndPaperBallsOffice-G1-O6-Bimanual-Replay-v0"
)

TRIM_THRESHOLD="0.002"
TRIM_ROT_THRESHOLD_RAD="0.02"
TRIM_MAX_KEEP_FRAMES="20"
HDF5_MIN_BYTES="2048"

EASIM_CONTAINER_PATH="/easim"
DATASETS_HOST_DIR="$EASIM_HOST_PATH/datasets"
IMIT_HOST_DIR="$DATASETS_HOST_DIR/imit_learning"
SIM_DATA_HOST_DIR="$DATASETS_HOST_DIR/sim_data"
REPLAY_HOST_ROOT="$EASIM_HOST_PATH/outputs/videos/replay_demo"

to_container_path() {
    local path="$1"
    if [[ "$path" == "$EASIM_HOST_PATH" ]]; then
        printf '%s\n' "$EASIM_CONTAINER_PATH"
    elif [[ "$path" == "$EASIM_HOST_PATH/"* ]]; then
        printf '%s/%s\n' "$EASIM_CONTAINER_PATH" "${path#"$EASIM_HOST_PATH/"}"
    else
        printf '%s\n' "$path"
    fi
}

to_runtime_path() {
    local path="$1"
    if [ "$RUN_ENV" = "docker" ]; then
        to_container_path "$path"
    else
        printf '%s\n' "$path"
    fi
}

helper_script_path() {
    if [ "$RUN_ENV" = "docker" ]; then
        printf '/deploy_scripts/hdf5_dataset_tools.py'
    else
        printf '%s/hdf5_dataset_tools.py' "$SCRIPT_DIR"
    fi
}

to_easim_relative() {
    local path="$1"
    if [[ "$path" == "$EASIM_HOST_PATH/"* ]]; then
        printf '%s\n' "${path#"$EASIM_HOST_PATH/"}"
    elif [[ "$path" == "$EASIM_CONTAINER_PATH/"* ]]; then
        printf '%s\n' "${path#"$EASIM_CONTAINER_PATH/"}"
    else
        printf '%s\n' "$path"
    fi
}

run_in_easim() {
    if [ "$RUN_ENV" = "docker" ]; then
        docker exec "$CONTAINER_NAME" bash -lc "cd /easim && $*"
    else
        bash -lc "cd '$EASIM_HOST_PATH' && $*"
    fi
}

python_cmd() {
    if [ "$RUN_ENV" = "docker" ]; then
        printf './isaac_workspace/IsaacLab/isaaclab.sh -p'
    else
        printf 'python'
    fi
}

quote_words() {
    local word
    for word in "$@"; do
        printf ' %q' "$word"
    done
}

ask_yes_no() {
    local prompt="$1"
    local default="$2"
    local answer
    local suffix
    if [ "$default" = "yes" ]; then
        suffix="[Y/n]"
    else
        suffix="[y/N]"
    fi
    read -rp "$prompt $suffix " answer
    answer="${answer:-}"
    if [ -z "$answer" ]; then
        [ "$default" = "yes" ]
        return
    fi
    [[ "$answer" =~ ^[Yy]$ ]]
}

slugify() {
    local value="$1"
    value="${value##*/}"
    value="${value%.hdf5}"
    value="$(echo "$value" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/_/g; s/^_+//; s/_+$//')"
    if [ -z "$value" ]; then
        value="dataset"
    fi
    printf '%s\n' "$value"
}

normalize_hdf5_path() {
    local raw="$1"
    raw="${raw/#\~/$HOME}"
    if [[ "$raw" = /* ]]; then
        if [[ "$raw" == "$EASIM_CONTAINER_PATH/"* ]]; then
            printf '%s/%s\n' "$EASIM_HOST_PATH" "${raw#"$EASIM_CONTAINER_PATH/"}"
        else
            printf '%s\n' "$raw"
        fi
    elif [[ "$raw" == datasets/* ]]; then
        printf '%s/%s\n' "$EASIM_HOST_PATH" "$raw"
    else
        printf '%s/%s\n' "$IMIT_HOST_DIR" "$raw"
    fi
}

select_run_env() {
    RUN_ENV="${DEFAULT_RUN_ENV:-}"
    if [ -z "$RUN_ENV" ]; then
        echo -e "${YELLOW}请选择运行环境：${NC}"
        echo "  1) Docker 容器"
        echo "  2) 本机（conda 环境）"
        echo ""
        read -rp "输入序号 [1-2]: " env_idx
        case "$env_idx" in
            1) RUN_ENV="docker" ;;
            2) RUN_ENV="native" ;;
            *) error "无效输入：$env_idx" ;;
        esac
    fi

    case "$RUN_ENV" in
        docker)
            ENV_LABEL="Docker 容器"
            if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
                warn "容器 $CONTAINER_NAME 未运行，正在启动..."
                bash "$SCRIPT_DIR/04_start_container.sh" || error "容器启动失败"
            fi
            ;;
        native)
            ENV_LABEL="本机（conda）"
            ;;
        *)
            error "DEFAULT_RUN_ENV 只支持 docker/native/空值，当前为：$RUN_ENV"
            ;;
    esac
}

select_mode() {
    echo -e "${YELLOW}请选择处理模式：${NC}"
    echo "  1) 单个 hdf5 处理"
    echo "  2) 多个 hdf5 合并后统一处理"
    echo ""
    read -rp "输入序号 [1-2]: " mode_idx
    case "$mode_idx" in
        1) PROCESS_MODE="single" ;;
        2) PROCESS_MODE="merge" ;;
        *) warn "无效输入：$mode_idx"; return 1 ;;
    esac
}

select_scene() {
    echo ""
    echo -e "${YELLOW}请选择场景：${NC}"
    local i name
    for i in "${!SCENES[@]}"; do
        name="$(echo "${SCENES[$i]}" | cut -d'|' -f1 | xargs)"
        echo "  $((i+1))) $name"
    done
    echo ""
    read -rp "输入序号 [1-${#SCENES[@]}]: " scene_idx
    if ! [[ "$scene_idx" =~ ^[0-9]+$ ]] || [ "$scene_idx" -lt 1 ] || [ "$scene_idx" -gt "${#SCENES[@]}" ]; then
        warn "无效输入：$scene_idx"
        return 1
    fi
    SELECTED_SCENE="${SCENES[$((scene_idx-1))]}"
    SCENE_NAME="$(echo "$SELECTED_SCENE" | cut -d'|' -f1 | xargs)"
    REPLAY_TASK="$(echo "$SELECTED_SCENE" | cut -d'|' -f2 | xargs)"
}

load_hdf5_candidates() {
    mapfile -t HDF5_CANDIDATES < <(
        find "$IMIT_HOST_DIR" -maxdepth 1 -type f -name '*.hdf5' -printf '%T@ %p\n' 2>/dev/null \
            | sort -nr \
            | head -30 \
            | cut -d' ' -f2-
    )
}

print_hdf5_candidates() {
    local i rel
    if [ "${#HDF5_CANDIDATES[@]}" -eq 0 ]; then
        warn "未在 $IMIT_HOST_DIR 找到 hdf5 文件，请手动输入路径。"
        return
    fi
    for i in "${!HDF5_CANDIDATES[@]}"; do
        rel="$(to_easim_relative "${HDF5_CANDIDATES[$i]}")"
        echo "  $((i+1))) $rel"
    done
    echo "  m) 手动输入路径"
}

resolve_selected_hdf5() {
    local token="$1"
    local path
    if [[ "$token" =~ ^[0-9]+$ ]] && [ "$token" -ge 1 ] && [ "$token" -le "${#HDF5_CANDIDATES[@]}" ]; then
        path="${HDF5_CANDIDATES[$((token-1))]}"
    else
        path="$(normalize_hdf5_path "$token")"
    fi
    if [ ! -f "$path" ]; then
        warn "HDF5 文件不存在：$path"
        return 1
    fi
    printf '%s\n' "$path"
}

select_datasets() {
    load_hdf5_candidates
    echo ""
    if [ "$PROCESS_MODE" = "single" ]; then
        echo -e "${YELLOW}请选择要处理的 hdf5：${NC}"
        print_hdf5_candidates
        echo ""
        read -rp "输入序号或路径: " choice
        if [ "$choice" = "m" ] || [ "$choice" = "M" ]; then
            read -rp "请输入 hdf5 路径: " choice
        fi
        local resolved
        if ! resolved="$(resolve_selected_hdf5 "$choice")"; then
            return 1
        fi
        SELECTED_DATASETS=("$resolved")
        DATASET_BASE="$(slugify "${SELECTED_DATASETS[0]}")"
    else
        echo -e "${YELLOW}请选择要合并的 hdf5：${NC}"
        print_hdf5_candidates
        echo ""
        echo "输入多个序号或路径，空格分隔；也可以输入 m 后手动填写多个路径。"
        read -rp "> " choices
        if [ "$choices" = "m" ] || [ "$choices" = "M" ]; then
            read -rp "请输入多个 hdf5 路径，空格分隔: " choices
        fi
        read -r -a choice_array <<< "$choices"
        if [ "${#choice_array[@]}" -lt 2 ]; then
            warn "合并模式至少需要选择 2 个 hdf5"
            return 1
        fi
        SELECTED_DATASETS=()
        local token resolved
        for token in "${choice_array[@]}"; do
            if ! resolved="$(resolve_selected_hdf5 "$token")"; then
                return 1
            fi
            SELECTED_DATASETS+=("$resolved")
        done
        echo ""
        read -rp "合并后数据名（直接回车使用 merged_dataset）: " merge_name
        DATASET_BASE="$(slugify "${merge_name:-merged_dataset}")"
    fi
}

create_package_dirs() {
    TIMESTAMP="$(date +%y%m%d_%H%M)"
    PACKAGE_NAME="${DATASET_BASE}_processed_${TIMESTAMP}"
    PACKAGE_HOST_DIR="$SIM_DATA_HOST_DIR/$PACKAGE_NAME"
    local suffix=2
    while [ -e "$PACKAGE_HOST_DIR" ]; do
        PACKAGE_NAME="${DATASET_BASE}_processed_${TIMESTAMP}_${suffix}"
        PACKAGE_HOST_DIR="$SIM_DATA_HOST_DIR/$PACKAGE_NAME"
        suffix=$((suffix + 1))
    done
    WORK_HOST_DIR="$PACKAGE_HOST_DIR/_work"
    ORIGINALS_HOST_DIR="$WORK_HOST_DIR/originals"
    FINAL_HOST_HDF5="$PACKAGE_HOST_DIR/${DATASET_BASE}_processed.hdf5"
    FINAL_HOST_VIDEOS="$PACKAGE_HOST_DIR/videos"
    SUMMARY_HOST_FILE="$PACKAGE_HOST_DIR/process_summary.txt"
    TRIAL_MAPPING_HOST_FILE="$PACKAGE_HOST_DIR/trial_mapping.csv"
    CURRENT_MAPPING_HOST_FILE="$WORK_HOST_DIR/current_trial_mapping.csv"
}

confirm_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  环境：${CYAN}$ENV_LABEL${NC}"
    echo -e "  场景：${CYAN}$SCENE_NAME${NC}"
    echo -e "  模式：${CYAN}$PROCESS_MODE${NC}"
    echo -e "  输出包：${CYAN}$PACKAGE_HOST_DIR${NC}"
    echo "  原始 hdf5："
    local path
    for path in "${SELECTED_DATASETS[@]}"; do
        echo -e "    ${CYAN}$(to_easim_relative "$path")${NC}"
    done
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    if ! ask_yes_no "确认开始处理？" "yes"; then
        echo "已取消"
        exit 0
    fi
}

copy_originals() {
    mkdir -p "$ORIGINALS_HOST_DIR"
    WORK_ORIGINALS=()
    local src dest
    for src in "${SELECTED_DATASETS[@]}"; do
        dest="$ORIGINALS_HOST_DIR/$(basename "$src")"
        if [ -e "$dest" ]; then
            dest="$ORIGINALS_HOST_DIR/$(slugify "$src")_$(date +%s).hdf5"
        fi
        if ! cp -p "$src" "$dest"; then
            warn "复制 HDF5 失败：$src -> $dest"
            return 1
        fi
        WORK_ORIGINALS+=("$dest")
    done
}

precheck_selected_hdf5() {
    info "检查原始 HDF5 文件..."
    local path size
    for path in "${SELECTED_DATASETS[@]}"; do
        if [ ! -f "$path" ]; then
            warn "HDF5 文件不存在：$path"
            return 1
        fi
        if ! size="$(stat -c '%s' "$path")"; then
            warn "无法读取 HDF5 文件大小：$path"
            return 1
        fi
        if [ "$size" -lt "$HDF5_MIN_BYTES" ]; then
            warn "HDF5 文件过小，疑似未写完整：$path (${size} bytes < ${HDF5_MIN_BYTES} bytes)。请重新生成或重新下载后再处理。"
            return 1
        fi
    done
    info "原始文件大小检查通过。"
}

validate_work_originals() {
    info "检查 HDF5 是否可打开并包含 /data/demo_*..."
    local helper_runtime
    local args=()
    local path
    helper_runtime="$(helper_script_path)"
    for path in "${WORK_ORIGINALS[@]}"; do
        args+=("$(to_runtime_path "$path")")
    done
    run_in_easim "$(python_cmd) $(printf '%q' "$helper_runtime") check$(quote_words "${args[@]}") --min_bytes $HDF5_MIN_BYTES --require_data --require_demos" \
        || { warn "HDF5 文件检查失败，请确认原始文件没有损坏；必要时删除后重新生成或重新下载。"; return 1; }
}

count_csv_rows() {
    local path="$1"
    [ -f "$path" ] || error "CSV 文件不存在：$path"
    awk 'NR > 1 { count++ } END { print count + 0 }' "$path"
}

format_success_rate() {
    local kept="$1"
    local total="$2"
    awk -v kept="$kept" -v total="$total" 'BEGIN {
        if (total > 0) {
            printf "%.2f%%", kept * 100 / total
        } else {
            printf "N/A"
        }
    }'
}

record_original_trial_count() {
    ORIGINAL_TRIAL_COUNT="$(count_csv_rows "$CURRENT_MAPPING_HOST_FILE")"
    KEPT_TRIAL_COUNT="$ORIGINAL_TRIAL_COUNT"
    COLLECTION_SUCCESS_RATE="$(format_success_rate "$KEPT_TRIAL_COUNT" "$ORIGINAL_TRIAL_COUNT")"
    info "初始 trial 数：$ORIGINAL_TRIAL_COUNT"
}

record_kept_trial_count() {
    KEPT_TRIAL_COUNT="$(count_csv_rows "$CURRENT_MAPPING_HOST_FILE")"
    COLLECTION_SUCCESS_RATE="$(format_success_rate "$KEPT_TRIAL_COUNT" "$ORIGINAL_TRIAL_COUNT")"
    info "剔除后 trial 数：$KEPT_TRIAL_COUNT，采集成功率：$KEPT_TRIAL_COUNT/$ORIGINAL_TRIAL_COUNT ($COLLECTION_SUCCESS_RATE)"
}

select_and_validate_datasets() {
    while true; do
        SELECTED_DATASETS=()
        WORK_ORIGINALS=()
        PROCESS_MODE=""
        DATASET_BASE=""
        ORIGINAL_TRIAL_COUNT=0
        KEPT_TRIAL_COUNT=0
        COLLECTION_SUCCESS_RATE="N/A"

        if ! select_mode; then
            echo ""
            continue
        fi
        if ! select_scene; then
            echo ""
            continue
        fi
        if ! select_datasets; then
            warn "返回处理模式选择。"
            echo ""
            continue
        fi

        create_package_dirs
        confirm_summary

        if ! precheck_selected_hdf5; then
            warn "返回处理模式选择。"
            echo ""
            continue
        fi
        if ! copy_originals; then
            warn "返回处理模式选择。"
            echo ""
            continue
        fi
        if ! validate_work_originals; then
            warn "返回处理模式选择。"
            echo ""
            continue
        fi
        break
    done
}

prepare_work_hdf5() {
    local helper_runtime
    helper_runtime="$(helper_script_path)"
    if [ "$PROCESS_MODE" = "single" ]; then
        CURRENT_HOST_HDF5="$WORK_HOST_DIR/${DATASET_BASE}_work.hdf5"
        cp -p "${WORK_ORIGINALS[0]}" "$CURRENT_HOST_HDF5"
        run_in_easim "$(python_cmd) $(printf '%q' "$helper_runtime") init-map --input $(printf '%q' "$(to_runtime_path "$CURRENT_HOST_HDF5")") --output $(printf '%q' "$(to_runtime_path "$CURRENT_MAPPING_HOST_FILE")") --source_file $(printf '%q' "${SELECTED_DATASETS[0]}")"
    else
        CURRENT_HOST_HDF5="$WORK_HOST_DIR/${DATASET_BASE}_merged_work.hdf5"
        local args=()
        local labels=()
        local path
        local i
        for i in "${!WORK_ORIGINALS[@]}"; do
            path="${WORK_ORIGINALS[$i]}"
            args+=("$(to_runtime_path "$path")")
            labels+=("${SELECTED_DATASETS[$i]}")
        done
        local output_runtime mapping_runtime
        output_runtime="$(to_runtime_path "$CURRENT_HOST_HDF5")"
        mapping_runtime="$(to_runtime_path "$CURRENT_MAPPING_HOST_FILE")"
        run_in_easim "$(python_cmd) $(printf '%q' "$helper_runtime") merge$(quote_words "${args[@]}") --output $(printf '%q' "$output_runtime") --mapping_csv $(printf '%q' "$mapping_runtime") --overwrite --source_labels$(quote_words "${labels[@]}")"
    fi
}

snapshot_replay_dirs() {
    mkdir -p "$REPLAY_HOST_ROOT"
    find "$REPLAY_HOST_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort > "$WORK_HOST_DIR/replay_dirs_before.txt"
}

find_new_replay_dir() {
    find "$REPLAY_HOST_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort > "$WORK_HOST_DIR/replay_dirs_after.txt"
    mapfile -t NEW_REPLAY_DIRS < <(comm -13 "$WORK_HOST_DIR/replay_dirs_before.txt" "$WORK_HOST_DIR/replay_dirs_after.txt")
    if [ "${#NEW_REPLAY_DIRS[@]}" -eq 1 ]; then
        CURRENT_HOST_VIDEO_DIR="$REPLAY_HOST_ROOT/${NEW_REPLAY_DIRS[0]}"
        return
    fi
    if [ "${#NEW_REPLAY_DIRS[@]}" -gt 1 ]; then
        echo ""
        warn "检测到多个新增 replay 视频目录，请选择："
        local i
        for i in "${!NEW_REPLAY_DIRS[@]}"; do
            echo "  $((i+1))) ${NEW_REPLAY_DIRS[$i]}"
        done
        read -rp "输入序号: " idx
        if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ] || [ "$idx" -gt "${#NEW_REPLAY_DIRS[@]}" ]; then
            error "无效输入：$idx"
        fi
        CURRENT_HOST_VIDEO_DIR="$REPLAY_HOST_ROOT/${NEW_REPLAY_DIRS[$((idx-1))]}"
        return
    fi

    warn "未自动识别 replay 视频目录。"
    read -rp "请输入 replay 视频目录路径: " manual_dir
    if [[ "$manual_dir" == "$EASIM_CONTAINER_PATH/"* ]]; then
        manual_dir="$EASIM_HOST_PATH/${manual_dir#"$EASIM_CONTAINER_PATH/"}"
    elif [[ "$manual_dir" != /* ]]; then
        manual_dir="$EASIM_HOST_PATH/$manual_dir"
    fi
    [ -d "$manual_dir" ] || error "视频目录不存在：$manual_dir"
    CURRENT_HOST_VIDEO_DIR="$manual_dir"
}

run_replay() {
    info "执行 replay，生成检查视频..."
    snapshot_replay_dirs
    local dataset_rel dataset_arg replay_cmd
    dataset_rel="$(to_easim_relative "$CURRENT_HOST_HDF5")"
    dataset_arg="$dataset_rel"
    replay_cmd="$(python_cmd) source/easim/model_zoo/IL_workflow_office/run_0_R_replay_demonstration.py --task $(printf '%q' "$REPLAY_TASK") --replay_mode kinematic --num_envs 1 --headless --replay_camera_mode stable --dataset_file $(printf '%q' "$dataset_arg")"
    run_in_easim "$replay_cmd"
    find_new_replay_dir
    info "replay 视频目录：$CURRENT_HOST_VIDEO_DIR"
}

normalize_trials() {
    NORMALIZED_TRIALS=()
    local raw token number normalized
    raw="$1"
    raw="${raw//,/ }"
    read -r -a tokens <<< "$raw"
    declare -A seen=()
    for token in "${tokens[@]}"; do
        token="${token#"${token%%[![:space:]]*}"}"
        token="${token%"${token##*[![:space:]]}"}"
        [ -z "$token" ] && continue
        if [[ "$token" =~ ^trial[_-]?([0-9]+)$ ]]; then
            number="${BASH_REMATCH[1]}"
        elif [[ "$token" =~ ^[0-9]+$ ]]; then
            number="$token"
        else
            error "无法解析 trial：$token。请输入数字或 trial_N。"
        fi
        normalized="trial_$((10#$number))"
        if [ -z "${seen[$normalized]+x}" ]; then
            NORMALIZED_TRIALS+=("$normalized")
            seen[$normalized]=1
        fi
    done
}

inspect_and_remove_trials() {
    echo ""
    echo -e "${YELLOW}请人工检查 replay 视频：${NC}"
    echo -e "  宿主机路径：${CYAN}$CURRENT_HOST_VIDEO_DIR${NC}"
    echo -e "  容器内路径：${CYAN}$(to_container_path "$CURRENT_HOST_VIDEO_DIR")${NC}"
    echo ""
    echo "检查完成后输入异常 trial 编号，多个用空格分隔。"
    echo "支持：1 3 8 或 trial_1 trial_3；直接回车表示无异常。"
    read -rp "> " bad_trials_raw
    normalize_trials "$bad_trials_raw"
    REMOVED_TRIALS=("${NORMALIZED_TRIALS[@]}")

    if [ "${#REMOVED_TRIALS[@]}" -eq 0 ]; then
        info "未输入异常 trial，跳过剔除。"
        record_kept_trial_count
        return
    fi

    echo ""
    echo "将剔除以下 trial："
    printf '  %s\n' "${REMOVED_TRIALS[@]}"
    if ! ask_yes_no "确认执行剔除？" "yes"; then
        warn "已跳过异常 trial 剔除。"
        REMOVED_TRIALS=()
        record_kept_trial_count
        return
    fi

    local edited_host_hdf5 edited_runtime_hdf5 current_runtime_hdf5 video_runtime_dir
    edited_host_hdf5="$WORK_HOST_DIR/${DATASET_BASE}_edited.hdf5"
    current_runtime_hdf5="$(to_runtime_path "$CURRENT_HOST_HDF5")"
    edited_runtime_hdf5="$(to_runtime_path "$edited_host_hdf5")"
    video_runtime_dir="$(to_runtime_path "$CURRENT_HOST_VIDEO_DIR")"

    run_in_easim "$(python_cmd) source/easim/model_zoo/tools/remove_bad_replay_trials.py --dataset_file $(printf '%q' "$current_runtime_hdf5") --output_file $(printf '%q' "$edited_runtime_hdf5") --video_dir $(printf '%q' "$video_runtime_dir") --move_failed_videos --yes --quiet --remove_trials$(quote_words "${REMOVED_TRIALS[@]}")"
    CURRENT_HOST_HDF5="$edited_host_hdf5"

    local updated_mapping_host
    updated_mapping_host="$WORK_HOST_DIR/current_trial_mapping_after_remove.csv"
    run_in_easim "$(python_cmd) $(printf '%q' "$(helper_script_path)") filter-map --input $(printf '%q' "$(to_runtime_path "$CURRENT_MAPPING_HOST_FILE")") --output $(printf '%q' "$(to_runtime_path "$updated_mapping_host")") --remove_trials$(quote_words "${REMOVED_TRIALS[@]}")"
    CURRENT_MAPPING_HOST_FILE="$updated_mapping_host"
    record_kept_trial_count
    info "异常 trial 已剔除，当前 HDF5：$CURRENT_HOST_HDF5"
}

maybe_trim_prefix() {
    TRIM_ENABLED="no"
    echo ""
    if ! ask_yes_no "是否裁剪初始化不稳定帧？" "yes"; then
        info "跳过初始化裁剪。"
        return
    fi
    TRIM_ENABLED="yes"
    local trimmed_host_hdf5 trimmed_host_videos report_host generated_report current_runtime_hdf5 video_runtime_dir
    trimmed_host_hdf5="$WORK_HOST_DIR/${DATASET_BASE}_trimmed.hdf5"
    trimmed_host_videos="$WORK_HOST_DIR/videos_trimmed"
    report_host="$WORK_HOST_DIR/trim_report.json"
    generated_report="${trimmed_host_hdf5%.hdf5}.trim_report.json"
    current_runtime_hdf5="$(to_runtime_path "$CURRENT_HOST_HDF5")"
    video_runtime_dir="$(to_runtime_path "$CURRENT_HOST_VIDEO_DIR")"

    run_in_easim "$(python_cmd) scripts/teleop_scripts/trim_pick_fruits_unstable_prefix.py --input_hdf5 $(printf '%q' "$current_runtime_hdf5") --input_video_dir $(printf '%q' "$video_runtime_dir") --output_hdf5 $(printf '%q' "$(to_runtime_path "$trimmed_host_hdf5")") --output_video_dir $(printf '%q' "$(to_runtime_path "$trimmed_host_videos")") --threshold $TRIM_THRESHOLD --rot_threshold_rad $TRIM_ROT_THRESHOLD_RAD --max_trim_keep_frames $TRIM_MAX_KEEP_FRAMES --overwrite"
    if [ -f "$generated_report" ]; then
        mv "$generated_report" "$report_host"
    fi
    CURRENT_HOST_HDF5="$trimmed_host_hdf5"
    CURRENT_HOST_VIDEO_DIR="$trimmed_host_videos"
    local updated_mapping_host
    updated_mapping_host="$WORK_HOST_DIR/current_trial_mapping_after_trim.csv"
    run_in_easim "$(python_cmd) $(printf '%q' "$(helper_script_path)") align-map --input $(printf '%q' "$(to_runtime_path "$CURRENT_MAPPING_HOST_FILE")") --hdf5 $(printf '%q' "$(to_runtime_path "$CURRENT_HOST_HDF5")") --output $(printf '%q' "$(to_runtime_path "$updated_mapping_host")")"
    CURRENT_MAPPING_HOST_FILE="$updated_mapping_host"
    info "初始化裁剪完成。"
}

finalize_package() {
    info "整理最终 hdf5 和视频到 sim_data 成品目录..."
    local current_runtime_hdf5 video_runtime_dir final_runtime_hdf5 final_runtime_videos final_mapping_runtime helper_runtime
    current_runtime_hdf5="$(to_runtime_path "$CURRENT_HOST_HDF5")"
    video_runtime_dir="$(to_runtime_path "$CURRENT_HOST_VIDEO_DIR")"
    final_runtime_hdf5="$(to_runtime_path "$FINAL_HOST_HDF5")"
    final_runtime_videos="$(to_runtime_path "$FINAL_HOST_VIDEOS")"
    final_mapping_runtime="$(to_runtime_path "$TRIAL_MAPPING_HOST_FILE")"
    helper_runtime="$(helper_script_path)"

    run_in_easim "$(python_cmd) $(printf '%q' "$helper_runtime") reindex --input $(printf '%q' "$current_runtime_hdf5") --output $(printf '%q' "$final_runtime_hdf5") --video_dir $(printf '%q' "$video_runtime_dir") --output_video_dir $(printf '%q' "$final_runtime_videos") --mapping_csv $(printf '%q' "$final_mapping_runtime") --source_mapping_csv $(printf '%q' "$(to_runtime_path "$CURRENT_MAPPING_HOST_FILE")") --overwrite"
}

write_summary() {
    {
        echo "easim dataset process summary"
        echo "time: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "environment: $ENV_LABEL"
        echo "scene: $SCENE_NAME"
        echo "replay_task: $REPLAY_TASK"
        echo "mode: $PROCESS_MODE"
        echo "package: $PACKAGE_HOST_DIR"
        echo ""
        echo "original_hdf5:"
        local path
        for path in "${SELECTED_DATASETS[@]}"; do
            echo "  - $path"
        done
        echo ""
        echo "removed_trials:"
        if [ "${#REMOVED_TRIALS[@]}" -eq 0 ]; then
            echo "  - none"
        else
            for path in "${REMOVED_TRIALS[@]}"; do
                echo "  - $path"
            done
        fi
        echo "original_trial_count: ${ORIGINAL_TRIAL_COUNT:-0}"
        echo "kept_trial_count_after_remove: ${KEPT_TRIAL_COUNT:-0}"
        echo "collection_success_rate: ${KEPT_TRIAL_COUNT:-0}/${ORIGINAL_TRIAL_COUNT:-0} (${COLLECTION_SUCCESS_RATE:-N/A})"
        echo ""
        echo "trim_enabled: $TRIM_ENABLED"
        echo "trim_threshold: $TRIM_THRESHOLD"
        echo "trim_rot_threshold_rad: $TRIM_ROT_THRESHOLD_RAD"
        echo "trim_max_keep_frames: $TRIM_MAX_KEEP_FRAMES"
        echo ""
        echo "final_hdf5: $FINAL_HOST_HDF5"
        echo "final_videos: $FINAL_HOST_VIDEOS"
        echo "trial_mapping: $TRIAL_MAPPING_HOST_FILE"
    } > "$SUMMARY_HOST_FILE"
}

print_done() {
    echo ""
    echo -e "${GREEN}===== 数据处理完成 =====${NC}"
    echo -e "最终 HDF5：${CYAN}$FINAL_HOST_HDF5${NC}"
    echo -e "最终视频： ${CYAN}$FINAL_HOST_VIDEOS${NC}"
    echo -e "处理摘要： ${CYAN}$SUMMARY_HOST_FILE${NC}"
    echo -e "trial 映射：${CYAN}$TRIAL_MAPPING_HOST_FILE${NC}"
}

main() {
    [ -n "${EASIM_HOST_PATH:-}" ] || error "config.sh 中 EASIM_HOST_PATH 未设置"
    [ -d "$EASIM_HOST_PATH" ] || error "EASIM_HOST_PATH 不存在：$EASIM_HOST_PATH"
    [ -d "$IMIT_HOST_DIR" ] || error "imit_learning 目录不存在：$IMIT_HOST_DIR"

    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════╗"
    echo "║         easim 数据处理脚本               ║"
    echo "╚══════════════════════════════════════════╝"
    echo -e "${NC}"

    select_run_env
    select_and_validate_datasets
    prepare_work_hdf5
    record_original_trial_count
    run_replay
    inspect_and_remove_trials
    maybe_trim_prefix
    finalize_package
    write_summary
    print_done
}

main "$@"
