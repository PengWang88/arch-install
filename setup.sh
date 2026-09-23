#!/usr/bin/env bash
#
# arch-install 组件总控脚本。
#
# 自动发现 components/NN-id.sh，提供交互菜单、运行状态记录与重跑警告。
# 只在「已安装并已启动的 Arch」系统上运行（sudo ./setup.sh）。
#
# 组件约定见 components/_TEMPLATE.sh。
set -Eeuo pipefail
IFS=$'\n\t'

readonly PROJECT_NAME="arch-install"
SCRIPT_DIR="$( cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P )"
readonly SCRIPT_DIR
readonly COMPONENTS_DIR="${SCRIPT_DIR}/components"
readonly STATE_DIR="/var/lib/arch-install/state"
readonly LOG_DIR="/var/log/arch-install"

LOG_FILE=""
MODE="menu"          # menu | list | run
RUN_IDS=""
FORCE=0

# 每项格式：id \t name \t desc \t rerun \t path
COMPONENTS=()
SELECTED=()

# ---------------------------------------------------------------------------
# 颜色与日志
# ---------------------------------------------------------------------------
USE_COLOR=0
C_RESET=$'\e[0m'
C_BOLD=$'\e[1m'
C_RED=$'\e[31m'
C_GREEN=$'\e[32m'
C_YELLOW=$'\e[33m'
C_CYAN=$'\e[36m'

setup_color() {
    if [[ -t 1 ]] \
        && [[ "${TERM:-dumb}" != "dumb" ]] \
        && [[ -z "${NO_COLOR:-}" ]]; then
        USE_COLOR=1
    fi
}

log() {
    local level="$1" tag
    shift
    if (( USE_COLOR )); then
        case "$level" in
            OK)   tag="${C_GREEN}${C_BOLD}[OK  ]${C_RESET}" ;;
            INFO) tag="${C_CYAN}[INFO]${C_RESET}" ;;
            WARN) tag="${C_YELLOW}[WARN]${C_RESET}" ;;
            FAIL) tag="${C_RED}${C_BOLD}[FAIL]${C_RESET}" ;;
            *)    tag="[${level}]" ;;
        esac
    else
        printf -v tag '[%-4s]' "$level"
    fi
    printf '%s %s\n' "$tag" "$*"
}
info() { log "INFO" "$@"; }
ok()   { log "OK"   "$@"; }
warn() { log "WARN" "$@"; }
die()  { log "FAIL" "$@" >&2; exit 1; }

strip_log_colors() {
    [[ -n "$LOG_FILE" ]] || return 0
    sed -i 's/\x1b\[[0-9;]*m//g' "$LOG_FILE" 2>/dev/null || true
}

init_logging() {
    mkdir -p "$LOG_DIR" || die "无法创建日志目录：$LOG_DIR"
    LOG_FILE="${LOG_DIR}/$(date -u +%Y%m%dT%H%M%SZ).log"
    touch "$LOG_FILE" || die "无法创建日志文件：$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    trap strip_log_colors EXIT
}

on_error() {
    local exit_code=$?
    if (( USE_COLOR )); then
        printf '\n%s[FAIL]%s 意外错误 (exit=%d, line=%s)\n' \
            "${C_RED}${C_BOLD}" "${C_RESET}" \
            "$exit_code" "${BASH_LINENO[0]:-unknown}" >&2
        [[ -n "$LOG_FILE" ]] && printf '%s[INFO]%s 日志：%s\n' \
            "${C_CYAN}" "${C_RESET}" "$LOG_FILE" >&2
    else
        printf '\n[FAIL] 意外错误 (exit=%d, line=%s)\n' \
            "$exit_code" "${BASH_LINENO[0]:-unknown}" >&2
        [[ -n "$LOG_FILE" ]] && printf '[INFO] 日志：%s\n' "$LOG_FILE" >&2
    fi
    exit "$exit_code"
}

on_interrupt() {
    printf '\n[WARN] 已被用户中断。\n' >&2
    exit 130
}

# ---------------------------------------------------------------------------
# 前置检查
# ---------------------------------------------------------------------------
check_root() {
    if (( EUID != 0 )); then
        die "请以 root 运行：sudo ./setup.sh"
    fi
}

check_installed_system() {
    if [[ ! -f /etc/arch-release ]]; then
        die "当前环境不是 Arch Linux。"
    fi
    if [[ -d /run/archiso ]]; then
        die "检测到 Arch ISO 环境；组件脚本请在装好的系统里运行。"
    fi
}

# ---------------------------------------------------------------------------
# 组件发现
# ---------------------------------------------------------------------------
parse_meta() { # parse_meta FILE KEY
    local file="$1" key="$2"
    grep -m1 -E "^#[[:space:]]*${key}:" "$file" 2>/dev/null \
        | sed -E "s/^#[[:space:]]*${key}:[[:space:]]*//" \
        || true
}

load_components() {
    COMPONENTS=()
    if [[ ! -d "$COMPONENTS_DIR" ]]; then
        die "找不到组件目录：$COMPONENTS_DIR"
    fi

    local file base id name desc rerun
    shopt -s nullglob
    # 依赖 bash 的 glob 排序（字典序）实现按 NN 前缀排序。
    for file in "$COMPONENTS_DIR"/*.sh; do
        base="$(basename "$file")"
        if [[ "$base" == _* ]]; then
            continue
        fi
        id="${base%.sh}"
        if [[ "$id" =~ ^[0-9]{2}- ]]; then
            id="${id:3}"
        fi
        name="$(parse_meta "$file" name)"
        desc="$(parse_meta "$file" desc)"
        rerun="$(parse_meta "$file" rerun)"
        if [[ -z "$name" ]]; then
            name="$id"
        fi
        if [[ -z "$desc" ]]; then
            desc="(无说明)"
        fi
        if [[ -z "$rerun" ]]; then
            rerun="warn"
        fi
        case "$rerun" in
            safe|warn|unsafe) ;;
            *)
                warn "组件 $base 的 rerun 值 '$rerun' 无效，按 warn 处理。"
                rerun="warn"
                ;;
        esac
        COMPONENTS+=("$(printf '%s\t%s\t%s\t%s\t%s' \
            "$id" "$name" "$desc" "$rerun" "$file")")
    done
    shopt -u nullglob

    if (( ${#COMPONENTS[@]} == 0 )); then
        die "没有发现任何组件：${COMPONENTS_DIR}/*.sh"
    fi
}

find_component_by_id() { # find_component_by_id ID
    local want="$1" entry id
    for entry in "${COMPONENTS[@]}"; do
        IFS=$'\t' read -r id _ _ _ _ <<<"$entry"
        if [[ "$id" == "$want" ]]; then
            printf '%s' "$entry"
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# 运行状态
# ---------------------------------------------------------------------------
state_file() { printf '%s/%s.done' "$STATE_DIR" "$1"; }
is_done()    { [[ -f "$(state_file "$1")" ]]; }
done_at()    { cat "$(state_file "$1")" 2>/dev/null || true; }
mark_done() {
    mkdir -p "$STATE_DIR"
    date -u +%Y-%m-%dT%H:%M:%SZ > "$(state_file "$1")"
}

# ---------------------------------------------------------------------------
# 列出 / 菜单 / 执行
# ---------------------------------------------------------------------------
list_components() {
    local entry id name desc rerun path note
    printf '\n'
    printf '%-16s %-22s %s\n' "ID" "名称" "说明 / 状态"
    printf '%-16s %-22s %s\n' "----------------" "----------------------" "-----------"
    for entry in "${COMPONENTS[@]}"; do
        IFS=$'\t' read -r id name desc rerun path <<<"$entry"
        if is_done "$id"; then
            note="[已运行 $(done_at "$id")]"
        else
            note="[未运行]"
        fi
        printf '%-16s %-22s %s %s\n' "$id" "$name" "$desc" "$note"
    done
    printf '\n'
}

print_menu() {
    printf '\n'
    printf '%s组件菜单%s\n' "$C_BOLD" "$C_RESET"
    printf '\n'
    local i entry id name desc rerun path marker
    for i in "${!COMPONENTS[@]}"; do
        IFS=$'\t' read -r id name desc rerun path <<<"${COMPONENTS[$i]}"
        marker=""
        if is_done "$id"; then
            marker=" ${C_YELLOW}[已运行]${C_RESET}"
        fi
        printf '  %2d) %s%s%s  %s%s\n' \
            "$((i + 1))" "$C_BOLD" "$name" "$C_RESET" "$desc" "$marker"
    done
    printf '\n'
}

select_menu() {
    local answer=""
    printf '选择要运行的组件：编号（多个用空格/逗号分隔）、%sa%s=全部、%sq%s=退出\n' \
        "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"
    read -rp "> " answer || true

    case "$answer" in
        q|Q|"")
            warn "已取消。"
            return 1
            ;;
        a|A)
            SELECTED=("${COMPONENTS[@]}")
            return 0
            ;;
    esac

    SELECTED=()
    answer="${answer//,/ }"
    local -a tokens=()
    IFS=' ' read -r -a tokens <<<"$answer"
    local token idx
    for token in "${tokens[@]}"; do
        if [[ -z "$token" ]]; then
            continue
        fi
        if [[ "$token" =~ ^[0-9]+$ ]] && (( token >= 1 && token <= ${#COMPONENTS[@]} )); then
            idx=$((token - 1))
            SELECTED+=("${COMPONENTS[$idx]}")
        else
            warn "忽略无效选择：$token"
        fi
    done

    if (( ${#SELECTED[@]} == 0 )); then
        warn "没有选中任何组件。"
        return 1
    fi
    return 0
}

run_component() { # run_component ENTRY FORCE
    local entry="$1" force="$2"
    local id name desc rerun path when ans=""
    IFS=$'\t' read -r id name desc rerun path <<<"$entry"

    if [[ "$force" != "1" ]] && is_done "$id"; then
        when="$(done_at "$id")"
        case "$rerun" in
            safe)
                info "$id 已运行过（$when）；该组件标记为可安全重跑。"
                ;;
            unsafe)
                warn "$id 已于 $when 运行过，且标记为 unsafe。"
                warn "重复运行可能造成不可逆后果，请确认你清楚在做什么。"
                read -rp "输入 YES 强制重跑 $id：" ans || true
                if [[ "$ans" != "YES" ]]; then
                    warn "已跳过 $id。"
                    return 0
                fi
                ;;
            *)
                warn "$id 已于 $when 运行过。"
                warn "该组件应自带幂等，但重复执行仍可能改动系统配置，风险自负。"
                read -rp "仍要重跑 $id 吗？[y/N] " ans || true
                if [[ ! "$ans" =~ ^[Yy]$ ]]; then
                    warn "已跳过 $id。"
                    return 0
                fi
                ;;
        esac
    fi

    printf '\n'
    info "运行：$name（id=$id）"
    printf '        %s\n' "$path"
    if bash "$path"; then
        mark_done "$id"
        ok "完成：$id"
    else
        die "失败：$id（重试：sudo ./setup.sh --run $id --force）"
    fi
}

# ---------------------------------------------------------------------------
# 参数与入口
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
${PROJECT_NAME} 组件总控

用法：
  sudo ./setup.sh                      交互式菜单
  sudo ./setup.sh --list               列出组件与运行状态
  sudo ./setup.sh --run <id>[,<id>]    直接运行指定组件
  sudo ./setup.sh --run <id> --force   忽略「已运行」提示，强制重跑
  ./setup.sh --help                    显示本帮助

组件约定：
  components/NN-id.sh，NN 为两位序号（决定菜单顺序，glob 字典序）
  文件头用 '# name:' / '# desc:' / '# rerun: safe|warn|unsafe' 声明元数据
  每个组件是可独立执行、幂等的普通脚本，退出码 0=成功
EOF
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --list)
                MODE="list"
                shift
                ;;
            --run)
                if (( $# < 2 )); then
                    die "--run 需要一个参数：<id>[,<id>...]"
                fi
                MODE="run"
                RUN_IDS="$2"
                shift 2
                ;;
            --force)
                FORCE=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "未知参数：$1（用 --help 查看用法）"
                ;;
        esac
    done
}

run_from_ids() {
    local -a ids=()
    IFS=',' read -r -a ids <<<"$RUN_IDS"
    local id entry
    for id in "${ids[@]}"; do
        id="${id// /}"
        if [[ -z "$id" ]]; then
            continue
        fi
        if ! entry="$(find_component_by_id "$id")"; then
            die "找不到组件：$id（用 --list 查看全部）"
        fi
        run_component "$entry" "$FORCE"
    done
}

run_interactive() {
    print_menu
    if ! select_menu; then
        return 0
    fi

    local entry id name _rest
    printf '\n将依次运行：\n'
    for entry in "${SELECTED[@]}"; do
        IFS=$'\t' read -r id name _rest <<<"$entry"
        printf '  - %s（%s）\n' "$name" "$id"
    done

    local ans=""
    read -rp "开始？[Y/n] " ans || true
    if [[ "$ans" =~ ^[Nn]$ ]]; then
        warn "已取消。"
        return 0
    fi

    for entry in "${SELECTED[@]}"; do
        run_component "$entry" "$FORCE"
    done
}

main() {
    parse_args "$@"
    setup_color
    check_root

    printf '\n'
    printf '%s%s%s\n' "$C_BOLD" "${PROJECT_NAME} 组件总控" "$C_RESET"

    init_logging
    check_installed_system
    load_components

    printf '组件目录：%s\n' "$COMPONENTS_DIR"
    printf '日志文件：%s\n' "$LOG_FILE"

    case "$MODE" in
        list) list_components ;;
        run)  run_from_ids ;;
        *)    run_interactive ;;
    esac

    sync
    ok "全部完成。"
}

trap on_error ERR
trap on_interrupt INT
main "$@"
