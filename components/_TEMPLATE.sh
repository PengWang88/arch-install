#!/usr/bin/env bash
# name: 模板组件
# desc: 复制本文件为 components/NN-id.sh 后按需修改
# rerun: warn
#
# 元数据说明（setup.sh 用 grep 解析文件头部的注释，需保持以下格式）：
#   name   菜单显示名
#   desc   一句话说明
#   rerun  重复运行策略：safe | warn | unsafe（缺省 warn）
#          safe   —— 重跑无副作用，仅提示
#          warn   —— 默认，重跑前询问 y/N
#          unsafe —— 重跑前要求输入 YES
#
# 约定（D2 轻量）：
#   - 每个组件是一个可独立执行、可被 setup.sh 以 root 调用的普通脚本。
#   - 必须幂等：重复运行要么无副作用，要么先检测再跳过。
#   - 退出码 0 = 成功；非 0 = 失败（setup.sh 会记录并中止）。
#   - 配置类改动前先备份为 <file>.bak。
#   - 不解析命令行参数、不自己调用 setup.sh。
set -Eeuo pipefail
IFS=$'\n\t'

info() { printf '[INFO] %s\n' "$*"; }
ok()   { printf '[OK  ] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

if (( EUID != 0 )); then
    die "请以 root 运行。"
fi

# ---- 幂等示例：先检测，再决定是否动手 ----
marker="/etc/example-component.done"
if [[ -f "$marker" ]]; then
    ok "已安装，跳过。"
    exit 0
fi

info "执行安装动作……"
# pacman -S --needed --noconfirm <包名>
printf 'installed %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$marker"
ok "完成。"
