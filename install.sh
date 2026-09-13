#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Global constants
# -----------------------------------------------------------------------------
readonly PROJECT_NAME="arch-install"
readonly MIRROR_COUNTRY="CN"
readonly MIRRORLIST="/etc/pacman.d/mirrorlist"

# Fixed mirrors, written verbatim in this order: no reflector, no probing. The
# first entry is always the primary; edit this array to change the mirrors.
readonly MIRROR_URLS=(
    "https://mirrors.ustc.edu.cn/archlinux"
    "https://mirrors.aliyun.com/archlinux"
    "https://mirrors.nju.edu.cn/archlinux"
    "https://mirrors.huaweicloud.com/archlinux"
    "https://mirrors.cloud.tencent.com/archlinux"
    "https://mirrors.cernet.edu.cn/archlinux"
    "https://mirrors.tuna.tsinghua.edu.cn/archlinux"
)

# -----------------------------------------------------------------------------
# Dual-boot behaviour (hardcoded, no toggles)
# -----------------------------------------------------------------------------
# Target: Y9000P 2022, Windows on one NVMe SSD and Arch on the other, each with
# its own ESP and bootloader. The two disks stay completely independent: Arch's
# GRUB menu contains Arch only, and switching OS is done in the firmware boot
# menu (F12) or the BIOS boot order. os-prober is deliberately NOT installed and
# no Windows entry is ever generated; the Windows disk is never read or written.

# Assignment must precede `readonly` (the reverse aborts on every run), and
# keeping it separate stops `readonly` from masking a failing $(...) under -e.
SCRIPT_DIR="$( cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P )"
readonly SCRIPT_DIR
LOG_FILE="/tmp/${PROJECT_NAME}-$(date -u +%Y%m%dT%H%M%SZ).log"
readonly LOG_FILE

TARGET_DISK=""
EFI_PART=""
ROOT_PART=""

HOSTNAME="archlinux"

# Hardcoded credentials: no prompts, set via chpasswd. The user and root share
# the password, which sits here in plaintext.
readonly USERNAME="peng"
readonly USER_PASSWORD="0000"

# -----------------------------------------------------------------------------
# Colored console output
# -----------------------------------------------------------------------------
# Decided once at startup, before init_logging() redirects stdout into the log
# tee: real tty + usable TERM + no NO_COLOR. The log copy is stripped on exit.
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

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
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
    # Strip ANSI SGR sequences so the log file stays plain and greppable.
    sed -i 's/\x1b\[[0-9;]*m//g' "$LOG_FILE" 2>/dev/null || true
}

init_logging() {
    touch "$LOG_FILE" || {
        printf 'Failed to create log file: %s\n' "$LOG_FILE" >&2
        exit 1
    }
    exec > >(tee -a "$LOG_FILE") 2>&1
    trap strip_log_colors EXIT
}

# -----------------------------------------------------------------------------
# Error handling
# -----------------------------------------------------------------------------
on_error() {
    local exit_code=$?
    if (( USE_COLOR )); then
        printf '\n%s[FAIL]%s Unexpected error (exit=%d, line=%s)\n' \
            "${C_RED}${C_BOLD}" "${C_RESET}" \
            "$exit_code" \
            "${BASH_LINENO[0]:-unknown}" >&2
        printf '%s[INFO]%s Log file: %s\n' \
            "${C_CYAN}" "${C_RESET}" "$LOG_FILE" >&2
    else
        printf '\n[FAIL] Unexpected error (exit=%d, line=%s)\n' \
            "$exit_code" \
            "${BASH_LINENO[0]:-unknown}" >&2
        printf '[INFO] Log file: %s\n' "$LOG_FILE" >&2
    fi
    exit "$exit_code"
}

on_interrupt() {
    if (( USE_COLOR )); then
        printf '\n%s[WARN]%s Installation interrupted by user.\n' \
            "${C_YELLOW}" "${C_RESET}" >&2
    else
        printf '\n[WARN] Installation interrupted by user.\n' >&2
    fi
    exit 130
}

trap on_error ERR
trap on_interrupt INT

# -----------------------------------------------------------------------------
# Version
# -----------------------------------------------------------------------------
get_version() {
    if command -v git >/dev/null 2>&1 \
        && git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git -C "$SCRIPT_DIR" describe \
            --tags \
            --always \
            --dirty 2>/dev/null || printf 'git-unknown'
    else
        printf 'snapshot'
    fi
}

# -----------------------------------------------------------------------------
# Environment checks
# -----------------------------------------------------------------------------
require_command() {
    local command_name="$1"
    command -v "$command_name" >/dev/null 2>&1 \
        || die "Missing required command: $command_name"
}

check_commands() {
    # Live-ISO tools only; chroot-only tools (grub-install) come from pacstrap.
    local commands=(
        curl date sleep tee timedatectl uname lsblk findmnt od blkid wipefs
        sgdisk partprobe mkfs.fat mkfs.btrfs btrfs
        mount umount mountpoint
        pacman pacstrap genfstab arch-chroot
        sed awk grep sync mkdir cat
    )
    local command_name
    for command_name in "${commands[@]}"; do
        require_command "$command_name"
    done
    ok "Required commands are available."
}

check_root() {
    if (( EUID != 0 )); then
        die "This installer must be run as root."
    fi
    ok "Running as root."
}

check_archiso() {
    if [[ ! -f /etc/arch-release ]]; then
        die "This does not appear to be an Arch Linux environment."
    fi
    if [[ ! -d /run/archiso ]]; then
        die "This installer must be run from an Arch ISO environment."
    fi
    ok "Arch ISO environment detected."
}

check_architecture() {
    local architecture
    architecture="$(uname -m)"
    if [[ "$architecture" != "x86_64" ]]; then
        die "Unsupported architecture: $architecture"
    fi
    ok "Architecture: $architecture"
}

check_uefi() {
    if [[ ! -d /sys/firmware/efi ]]; then
        die "UEFI boot mode is required."
    fi
    ok "Boot mode: UEFI"

    if [[ ! -d /sys/firmware/efi/efivars ]]; then
        warn "UEFI variables are not available."
        warn "Bootloader installation may require special handling."
    fi
}

check_secure_boot() {
    # Arch's GRUB is unsigned, so warn early: Secure Boot must be disabled in
    # the BIOS before the first boot (this does not affect the Windows install).
    local efivar="/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
    local state
    if [[ ! -r "$efivar" ]]; then
        info "Secure Boot status: unknown (efivar not readable)."
        return 0
    fi
    state="$( od -An -j4 -N1 -t u1 "$efivar" 2>/dev/null | tr -d ' ' )"
    case "$state" in
        1)
            warn "Secure Boot is ENABLED."
            warn "The GRUB bootloader installed by this script is NOT signed, so the"
            warn "firmware will refuse to boot Arch unless Secure Boot is disabled in"
            warn "the BIOS (this does not affect the existing Windows installation)."
            warn "Disable it now, or set up sbctl/shim with your own keys after boot."
            ;;
        0) ok "Secure Boot is disabled." ;;
        *) warn "Secure Boot status could not be determined." ;;
    esac
}

check_network() {
    info "Checking network connectivity..."
    if ! curl \
        --fail \
        --silent \
        --show-error \
        --location \
        --connect-timeout 5 \
        --max-time 10 \
        --output /dev/null \
        https://archlinux.org/; then
        die "Network connectivity check failed. Configure the network and retry."
    fi
    ok "Network connectivity is available."
}

check_time() {
    info "Checking system clock synchronization..."
    if ! timedatectl set-ntp true >/dev/null 2>&1; then
        warn "Unable to enable network time synchronization."
        return 0
    fi

    local state
    local attempt
    for ((attempt = 1; attempt <= 10; attempt++)); do
        state="$( timedatectl show \
            --property=NTPSynchronized \
            --value 2>/dev/null || true )"
        case "$state" in
            yes | true)
                ok "System clock is synchronized."
                return 0
                ;;
        esac
        sleep 1
    done

    warn "System clock has not synchronized yet."
    warn "Installation may continue, but package verification can fail if the clock is incorrect."
}

# -----------------------------------------------------------------------------
# Mirror configuration
# -----------------------------------------------------------------------------
write_mirrorlist() { # write_mirrorlist URL...
    local url
    {
        printf '# Generated by %s - fixed Chinese mirrors, in priority order.\n' \
            "$PROJECT_NAME"
        printf '# Hardcoded list, written verbatim: no probing, no reordering.\n'
        for url in "$@"; do
            printf '\n## %s\n' "$url"
            printf 'Server = %s/$repo/os/$arch\n' "$url"
        done
    } > "$MIRRORLIST"
}

setup_mirrors() {
    info "Configuring pacman mirrors (hardcoded Chinese mirrors)..."

    if [[ -e "$MIRRORLIST" ]]; then
        cp -a "$MIRRORLIST" "${MIRRORLIST}.iso-backup"
    fi

    # Write the fixed list as declared: nothing is probed, nothing is dropped.
    write_mirrorlist "${MIRROR_URLS[@]}"

    # pacstrap does not sync itself, and the ISO's databases can be stale
    # (resolving versions from them then 404s against the new mirrors).
    info "Syncing package databases..."
    pacman -Sy --noconfirm || die "Failed to synchronize package databases."
    ok "Package databases synchronized."

    ok "Mirrorlist written: $MIRRORLIST"
    ok "Country: $MIRROR_COUNTRY (${#MIRROR_URLS[@]} fixed mirrors, primary: ${MIRROR_URLS[0]})"
}

# -----------------------------------------------------------------------------
# Disk selection
# -----------------------------------------------------------------------------
get_live_device() {
    # Block devices hosting the running ISO: airootfs (loop/overlay) and, for
    # removable media, bootmnt (the real USB partition).
    local mount_point source
    for mount_point in /run/archiso/airootfs /run/archiso/bootmnt; do
        source="$( findmnt \
            -n \
            -o SOURCE \
            "$mount_point" 2>/dev/null || true )"
        if [[ "$source" == /dev/* ]]; then
            printf '%s\n' "$source"
        fi
    done
}

list_disks() {
    printf '\n'
    printf 'Available disks:\n'
    printf '\n'
    lsblk \
        --nodeps \
        --paths \
        --output NAME,SIZE,MODEL,SERIAL,TYPE
    printf '\n'
    printf 'Pick the SSD that should hold Arch Linux (the other one keeps Windows).\n'
    printf 'If one/both NVMe drives are missing here, see the README: BIOS storage\n'
    printf 'mode (VMD/RST vs AHCI).\n'
    printf '\n'
}

list_signatures() {
    # Read-only inventory of what survives on the disk: sgdisk --zap-all
    # rewrites the table but leaves old filesystems, swap headers and RAID/LVM
    # metadata behind. This is the last chance to spot a wrong disk, and stale
    # signatures (a leftover mkswap header makes mount see type "swap") have to
    # be wiped later. wipefs --no-act writes nothing; the disk's own tables
    # (gpt/PMBR/dos) are filtered out.
    local device line
    local found=0
    local devices=()
    while IFS= read -r device; do
        [[ -n "$device" ]] && devices+=("$device")
    done < <( lsblk --paths --list --output NAME "$TARGET_DISK" 2>/dev/null || true )
    if (( ${#devices[@]} == 0 )); then
        devices=("$TARGET_DISK")
    fi

    printf '\n'
    printf 'Signatures currently on %s (read-only check, all of it will be erased):\n' \
        "$TARGET_DISK"
    for device in "${devices[@]}"; do
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            printf '  %-16s %s\n' "$device" "$line"
            found=1
        done < <( wipefs \
            --no-act \
            --noheadings \
            --output TYPE,OFFSET,UUID \
            "$device" 2>/dev/null \
            | awk '$1 != "gpt" && $1 != "PMBR" && $1 != "dos"' || true )
    done

    if (( found )); then
        printf '\n'
        warn "The signatures above are old data: partitioning destroys them."
        warn "If that is not what you want, stop and re-check the disk (model/serial)."
    else
        printf '  (no signature found at the offsets wipefs probes)\n'
        if (( ${#devices[@]} <= 1 )); then
            printf '  Note: there is no partition table here, so data hidden inside\n'
            printf '  former partitions stays invisible until wipefs clears it later.\n'
        fi
    fi
}

validate_disk() {
    local disk="$1"
    [[ -b "$disk" ]] || return 1
    [[ "$(lsblk -dn -o TYPE "$disk")" == "disk" ]] || return 1
    return 0
}

is_live_device() {
    local disk="$1"
    local live_device parent
    while IFS= read -r live_device; do
        [[ -n "$live_device" ]] || continue
        [[ "$disk" == "$live_device" ]] && return 0

        parent="$( lsblk -no PKNAME "$live_device" 2>/dev/null || true )"
        [[ -n "$parent" && "$disk" == "/dev/$parent" ]] && return 0
    done < <(get_live_device)
    return 1
}

select_disk() {
    local disk
    while true; do
        printf '\n'
        read -rp "Enter target disk: " disk
        if ! validate_disk "$disk"; then
            warn "Invalid disk: $disk"
            continue
        fi
        if is_live_device "$disk"; then
            warn "This disk contains the Arch ISO."
            warn "Please select another disk."
            continue
        fi
        TARGET_DISK="$disk"
        break
    done
    ok "Target disk: $TARGET_DISK"
}

confirm_disk() {
    printf '\n'
    printf 'WARNING: ALL DATA ON THIS DISK WILL BE ERASED.\n'
    printf '\n'
    lsblk "$TARGET_DISK"

    list_signatures

    printf '\n'
    printf 'It will be WIPED and repartitioned as:\n'
    printf '  %s  1 GiB  EFI (FAT32)  -> /boot/efi\n' \
        "$(get_partition_name "$TARGET_DISK" 1)"
    printf '  %s  rest   Btrfs root   -> /\n' \
        "$(get_partition_name "$TARGET_DISK" 2)"
    printf '\n'

    local answer
    read -rp "Type YES to continue: " answer
    if [[ "$answer" != "YES" ]]; then
        die "Disk selection cancelled."
    fi
    ok "Disk confirmed."
}

# -----------------------------------------------------------------------------
# Partitioning
# -----------------------------------------------------------------------------
cleanup_disk_state() {
    # Drop leftovers from a previous (possibly failed) run.
    if mountpoint -q /mnt 2>/dev/null; then
        warn "Unmounting leftover mounts under /mnt from a previous run..."
        umount -R /mnt 2>/dev/null || true
    fi
}

assert_disk_unused() {
    # Refuse to repartition a disk whose partitions are still mounted/used.
    local used
    used="$( { lsblk -no MOUNTPOINTS "$TARGET_DISK" 2>/dev/null || true; } \
        | awk 'NF' \
        | tr '\n' ' ' )"
    used="${used% }"
    [[ -z "$used" ]] || die "Target disk is still in use: $used"
}

get_partition_name() {
    local disk="$1"
    local number="$2"
    if [[ "$disk" =~ nvme|mmcblk ]]; then
        printf '%sp%s' "$disk" "$number"
    else
        printf '%s%s' "$disk" "$number"
    fi
}

# Signature types wipefs reports for the given devices, one per line.
signature_types() {
    wipefs \
        --no-act --noheadings --output TYPE "$@" 2>/dev/null \
        | awk 'NF' || true
}

# True when wipefs reports this type. Membership, not equality: one filesystem
# can emit the same TYPE several times (a fresh FAT32 yields three "vfat").
has_signature() {
    local expected="$1"
    shift
    signature_types "$@" | grep -qxF -- "$expected"
}

partition_disk() {
    cleanup_disk_state
    assert_disk_unused

    EFI_PART="$(get_partition_name "$TARGET_DISK" 1)"
    ROOT_PART="$(get_partition_name "$TARGET_DISK" 2)"

    # Layout is fixed and confirm_disk() already required an explicit YES.
    printf '\n'
    printf 'Partition layout:\n'
    printf '  EFI  : %s\n' "$EFI_PART"
    printf '  ROOT : %s\n' "$ROOT_PART"
    printf '\n'

    sgdisk --zap-all "$TARGET_DISK"
    sgdisk \
        -n 1:0:+1G \
        -t 1:ef00 \
        "$TARGET_DISK"
    sgdisk \
        -n 2:0:0 \
        -t 2:8300 \
        "$TARGET_DISK"

    partprobe "$TARGET_DISK"

    # Wait until the kernel exposes all partition nodes (NVMe/eMMC can be slow).
    local attempt
    for ((attempt = 0; attempt < 20; attempt++)); do
        if [[ -b "$EFI_PART" && -b "$ROOT_PART" ]]; then
            break
        fi
        sleep 1
    done
    if [[ ! -b "$EFI_PART" || ! -b "$ROOT_PART" ]]; then
        die "Partition nodes did not appear: $EFI_PART $ROOT_PART"
    fi

    # Erase old signatures explicitly: libblkid probes swap before btrfs, so a
    # stale mkswap header on the new root would hijack mount's detection.
    # No --force: that would also erase the disk's own backup GPT.
    wipefs --all "$EFI_PART" "$ROOT_PART"

    mkfs.fat -F32 "$EFI_PART"
    mkfs.btrfs -f "$ROOT_PART"

    # Verify with wipefs (blkid reports nothing once a device carries several
    # signatures) and fail loudly rather than mount something unexpected.
    local signatures
    if ! has_signature "btrfs" "$ROOT_PART"; then
        die "No btrfs signature on $ROOT_PART after mkfs: $( signature_types "$ROOT_PART" )"
    fi

    if ! has_signature "vfat" "$EFI_PART"; then
        die "No FAT signature on $EFI_PART after mkfs: $( signature_types "$EFI_PART" )"
    fi

    signatures="$( wipefs \
        --no-act --noheadings --output TYPE --types swap \
        "$EFI_PART" "$ROOT_PART" 2>/dev/null \
        | awk 'NF' || true )"
    if [[ -n "$signatures" ]]; then
        die "Stale swap signature still present: $signatures"
    fi

    ok "Partitioning completed."
}

# -----------------------------------------------------------------------------
# Filesystem mounting (FIXED ORDER: mount @ first, then mkdir, then mount others)
# -----------------------------------------------------------------------------
mount_filesystems() {
    info "Mounting filesystems..."
    local btrfs_opts="noatime,compress=zstd:3,discard=async"

    # Step 1: temporary mount, create @ and @home (no /.snapshots: snapshot-ready
    # only). Always pass -t: autodetection can pick a stale signature's type.
    mount -t btrfs "$ROOT_PART" /mnt
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    sync
    umount /mnt

    # Step 2: mount @ as root.
    mount -t btrfs -o "$btrfs_opts",subvol=@ "$ROOT_PART" /mnt

    # Step 3: mount-point dirs inside @. -p is required: @ is empty, so /mnt/boot
    # does not exist yet.
    mkdir -p /mnt/home /mnt/boot/efi

    # Step 4: mount @home.
    mount -t btrfs -o "$btrfs_opts",subvol=@home "$ROOT_PART" /mnt/home

    # Step 5: mount the ESP.
    mount -t vfat -o umask=0077 "$EFI_PART" /mnt/boot/efi

    # Step 6: verify all mount points.
    mountpoint -q /mnt             || die "Root filesystem mount failed."
    mountpoint -q /mnt/home        || die "Home filesystem mount failed."
    mountpoint -q /mnt/boot/efi    || die "EFI filesystem mount failed."

    ok "Filesystems mounted."
}

# -----------------------------------------------------------------------------
# Base system installation
# -----------------------------------------------------------------------------
get_microcode_package() {
    local vendor
    vendor="$( awk -F ': ' '/vendor_id/ {print $2; exit}' /proc/cpuinfo )"
    case "$vendor" in
        GenuineIntel) printf 'intel-ucode\n' ;;
        AuthenticAMD) printf 'amd-ucode\n' ;;
        *) return 1 ;;
    esac
}

install_base_system() {
    info "Installing base system..."

    local microcode=""
    microcode="$(get_microcode_package || true)"

    # i915 + mesa come from linux-firmware and the kernel; no dGPU driver here.
    local packages=(
        base linux linux-firmware
        btrfs-progs
        grub efibootmgr
        ntfs-3g
        networkmanager
        pipewire pipewire-pulse wireplumber mesa
        git sudo vim base-devel
        xf86-input-libinput
        sof-firmware alsa-ucm-conf
    )

    if [[ -n "$microcode" ]]; then
        packages+=("$microcode")
        info "CPU microcode package: $microcode"
    else
        warn "Unable to detect CPU microcode package."
    fi

    pacstrap -K /mnt "${packages[@]}" || die "Failed to install base system."
    ok "Base system installed."
}

generate_fstab() {
    info "Generating fstab..."
    genfstab -U /mnt > /mnt/etc/fstab || die "Failed to generate fstab."

    printf '\n'
    cat /mnt/etc/fstab
    printf '\n'
    ok "fstab generated."
}

# -----------------------------------------------------------------------------
# System configuration
# -----------------------------------------------------------------------------
configure_system() {
    info "Configuring installed system..."

    arch-chroot /mnt /bin/bash <<EOF
set -e

# timezone
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
hwclock --systohc

# locale
sed -i \
    -e 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' \
    -e 's/^#zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' \
    /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# hostname
echo "$HOSTNAME" > /etc/hostname

# hosts
cat > /etc/hosts <<HOSTS
127.0.0.1 localhost
::1 localhost
127.0.1.1 $HOSTNAME.localdomain $HOSTNAME
HOSTS

# enable network
systemctl enable NetworkManager

# Enable time synchronization (NetworkManager does not sync the clock itself)
systemctl enable systemd-timesyncd
EOF
    ok "Basic system configuration completed."
}

create_user() {
    info "Creating user: $USERNAME"

    arch-chroot /mnt useradd \
        -m \
        -G wheel \
        -s /bin/bash \
        "$USERNAME"

    # Passwords go in on stdin: no prompt, nothing visible in the process list.
    printf '%s:%s\n' "$USERNAME" "$USER_PASSWORD" \
        | arch-chroot /mnt chpasswd \
        || die "Failed to set the password for $USERNAME."
    printf 'root:%s\n' "$USER_PASSWORD" \
        | arch-chroot /mnt chpasswd \
        || die "Failed to set the root password."

    sed -i \
        's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' \
        /mnt/etc/sudoers

    ok "User created: $USERNAME (password set for $USERNAME and root)."
}

# -----------------------------------------------------------------------------
# Snapshots: intentionally NOT configured
# -----------------------------------------------------------------------------
# Snapper/grub-btrfs are NOT set up. The layout (@, @home) is snapshot-ready,
# but /.snapshots is deliberately absent: `snapper create-config` creates that
# subvolume itself and fails when the directory already exists. To enable later:
#   pacman -S snapper grub-btrfs inotify-tools
#   snapper --no-dbus -c root create-config / && chmod 750 /.snapshots
#   systemctl enable --now snapper-timeline.timer snapper-cleanup.timer
#   systemctl enable --now grub-btrfsd.service
#   grub-mkconfig -o /boot/grub/grub.cfg

# -----------------------------------------------------------------------------
# Bootloader
# -----------------------------------------------------------------------------
install_grub() {
    info "Installing GRUB bootloader..."

    arch-chroot /mnt bash -c '
        set -e
        grub-install \
            --target=x86_64-efi \
            --efi-directory=/boot/efi \
            --bootloader-id=Arch \
            --recheck

        # Arch only: os-prober is not installed and GRUB_DISABLE_OS_PROBER is
        # left at its default, so this menu never gains a Windows entry.
        grub-mkconfig -o /boot/grub/grub.cfg
    '
    ok "GRUB installation completed."
}

finish_installation() {
    info "Performing final installation cleanup..."
    sync

    umount -R /mnt || {
        warn "Some mounts could not be unmounted."
        mount | grep /mnt || true
    }

    ok "Installation completed successfully."

    cat <<EOF

=====================================
Arch Linux installation finished.

This installer only touched: $TARGET_DISK
The Windows SSD (the other disk) was left untouched.

-- Dual boot (two SSDs, one OS per disk) --
* The two disks are fully independent: this GRUB menu boots Arch only, and the
  Windows disk is never read, mounted or written.
* Boot into Arch:    press F12 at power-on and pick 'Arch' (or set it as the
  first boot entry in the BIOS once, and it will boot straight into GRUB).
* Boot into Windows: press F12 at power-on and pick 'Windows Boot Manager'.
  Nothing else to configure: no Windows entry is added to GRUB (os-prober is
  intentionally not installed).
* Clock skew between Windows and Arch (an 8 h difference): run once in Windows
  as administrator:
      reg add "HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation" /v RealTimeIsUniversal /t REG_DWORD /d 1 /f

Remove the installation media, then reboot.
=====================================
EOF
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    # Decide color while stdout is still the terminal (init_logging redirects).
    setup_color
    init_logging

    local version
    version="$(get_version)"
    printf '\n'
    printf 'Arch Linux Installer\n'
    printf 'Version: %s\n' "$version"
    printf 'Log: %s\n' "$LOG_FILE"
    printf '\n'

    check_root
    check_archiso
    check_commands
    check_architecture
    check_uefi
    check_secure_boot
    check_network
    check_time
    setup_mirrors

    list_disks
    select_disk
    confirm_disk

    partition_disk
    mount_filesystems

    install_base_system
    generate_fstab

    configure_system
    create_user

    install_grub

    finish_installation
}

main "$@"
