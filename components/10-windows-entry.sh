#!/usr/bin/env bash
# name: 添加 Windows 引导项
# desc: 安装 os-prober + fuse3，并让 GRUB 生成 Windows Boot Manager 条目
# rerun: safe
#
# 说明：
#   Arch 的 grub 包没有 pacman hook，不会在内核更新后自动重跑 grub-mkconfig，
#   因此这里只需生成本条目一次即可长期保留；即便以后有人/某组件再次运行
#   grub-mkconfig，只要 os-prober + fuse3 在位且 GRUB_DISABLE_OS_PROBER 不为 true，
#   os-prober 会自行用 grub-mount 只读挂载 Windows ESP 并重新写回该条目。
#
#   os-prober 只读探测，不写 Windows 盘。
set -Eeuo pipefail
IFS=$'\n\t'

info() { printf '[INFO] %s\n' "$*"; }
ok()   { printf '[OK  ] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

if (( EUID != 0 )); then
    die "请以 root 运行。"
fi
if [[ ! -f /etc/arch-release ]]; then
    die "这不是 Arch Linux。"
fi
if [[ -d /run/archiso ]]; then
    die "检测到 Arch ISO 环境；请在装好的系统里运行。"
fi
if ! command -v grub-mkconfig >/dev/null 2>&1; then
    die "找不到 grub-mkconfig，GRUB 似乎未安装。"
fi
if [[ ! -f /etc/default/grub ]]; then
    die "找不到 /etc/default/grub。"
fi
if [[ ! -f /boot/grub/grub.cfg ]]; then
    warn "/boot/grub/grub.cfg 尚不存在，将新建。"
fi

# 1) 安装 os-prober 与 fuse3（grub-mount 依赖 fuse3）
missing=()
if ! pacman -Qi os-prober >/dev/null 2>&1; then
    missing+=(os-prober)
fi
if ! pacman -Qi fuse3 >/dev/null 2>&1; then
    missing+=(fuse3)
fi
if (( ${#missing[@]} > 0 )); then
    info "安装：${missing[*]}"
    pacman -S --needed --noconfirm "${missing[@]}" \
        || die "安装 ${missing[*]} 失败。"
else
    ok "os-prober 与 fuse3 已安装。"
fi

# 2) 允许 os-prober 运行
if grep -qE '^[[:space:]]*GRUB_DISABLE_OS_PROBER=' /etc/default/grub; then
    if grep -qE '^[[:space:]]*GRUB_DISABLE_OS_PROBER=(false|"false")' /etc/default/grub; then
        ok "GRUB_DISABLE_OS_PROBER 已为 false。"
    else
        [[ -e /etc/default/grub.bak ]] || cp -a /etc/default/grub /etc/default/grub.bak
        sed -i -E \
            's|^[[:space:]]*GRUB_DISABLE_OS_PROBER=.*|GRUB_DISABLE_OS_PROBER=false|' \
            /etc/default/grub
        info "已设置 GRUB_DISABLE_OS_PROBER=false（原文备份为 grub.bak）。"
    fi
else
    [[ -e /etc/default/grub.bak ]] || cp -a /etc/default/grub /etc/default/grub.bak
    printf '\n# Added by arch-install 10-windows-entry\nGRUB_DISABLE_OS_PROBER=false\n' \
        >> /etc/default/grub
    info "已追加 GRUB_DISABLE_OS_PROBER=false（原文备份为 grub.bak）。"
fi

# 3) 确保 os-prober 的 grub 脚本可执行
if [[ ! -f /etc/grub.d/30_os-prober ]]; then
    die "找不到 /etc/grub.d/30_os-prober。"
fi
chmod +x /etc/grub.d/30_os-prober

# 4) 重新生成 grub.cfg
#    os-prober 会通过 grub-mount 只读挂载包括 Windows ESP 在内的分区自行探测，
#    因此无需手动 mount Windows 分区。
info "运行 grub-mkconfig（os-prober 正在探测其他系统）……"
grub-mkconfig -o /boot/grub/grub.cfg || die "grub-mkconfig 失败。"

# 5) 验证
if grep -q "Windows Boot Manager" /boot/grub/grub.cfg; then
    ok "GRUB 菜单已包含 Windows Boot Manager。"
else
    die "未在 grub.cfg 中找到 Windows 条目。请确认：Windows 盘在位，且其 ESP 内存在 EFI/Microsoft/Boot/bootmgfw.efi。"
fi
