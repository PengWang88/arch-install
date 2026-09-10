#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Global constants
# -----------------------------------------------------------------------------
readonly PROJECT_NAME="arch-install"
readonly MIRROR_COUNTRY="${MIRROR_COUNTRY:-CN}"
readonly MIRROR_AGE="${MIRROR_AGE:-12}"
readonly MIRROR_PROTOCOL="${MIRROR_PROTOCOL:-https}"

# -----------------------------------------------------------------------------
# Dual-boot / hardware toggles
#   Defaults target: Lenovo Legion Y9000P 2022 (12th-gen Intel + RTX 30 series)
#   with Windows on ONE NVMe SSD and Arch Linux installed on the OTHER SSD.
#   Each OS keeps its own EFI partition and bootloader on its own disk.
# -----------------------------------------------------------------------------
# Add a Windows entry to the Arch GRUB menu via os-prober. os-prober only
# *detects* the Windows bootloader on the other disk and adds a chainload entry;
# it never writes to the Windows disk.
readonly ENABLE_OS_PROBER="${ENABLE_OS_PROBER:-1}"
# Install the NVIDIA driver for the RTX dGPU during pacstrap. Upstream replaced
# the closed-source `nvidia` package with the open kernel modules
# (nvidia-open) when the 590 driver shipped (2025-12); nvidia-open supports
# Turing (GTX 16xx / RTX 20) and newer GPUs - the Y9000P 2022's RTX 3060/3070
# Ti (Ampere) included. Install set: nvidia-open nvidia-utils nvidia-settings
# nvidia-prime.
readonly INSTALL_NVIDIA="${INSTALL_NVIDIA:-1}"
# Append nvidia-drm.modeset=1 to the kernel cmdline (early KMS; required by most
# Wayland/X sessions on hybrid-graphics laptops; harmless for console use).
readonly NVIDIA_DRM_MODESET="${NVIDIA_DRM_MODESET:-1}"

# Declare separately from the command substitution so a failing $(...) still
# aborts under `set -e` (readonly would otherwise mask its exit status).
# NOTE: assignment MUST precede `readonly` - the reverse order makes bash abort
# with "readonly variable" on every run.
SCRIPT_DIR="$( cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P )"
readonly SCRIPT_DIR
LOG_FILE="/tmp/${PROJECT_NAME}-$(date -u +%Y%m%dT%H%M%SZ).log"
readonly LOG_FILE

TARGET_DISK=""
EFI_PART=""
ROOT_PART=""

# Set to 1 once the NVIDIA driver packages were actually installed. It stays 0
# when INSTALL_NVIDIA=1 but the repositories cannot provide the packages, so
# NVIDIA-specific configuration (kernel param, notes) is skipped consistently.
NVIDIA_INSTALLED=0
HOSTNAME="archlinux"
USERNAME=""

# -----------------------------------------------------------------------------
# Colored console output
# -----------------------------------------------------------------------------
# Color support is decided ONCE at startup, before init_logging() redirects
# stdout into the log tee: it is enabled only when stdout is a real terminal,
# TERM is usable, and the standard NO_COLOR opt-out is unset. The ANSI codes
# pass through the tee to the terminal; the LOG_FILE copy is stripped again on
# exit so the log stays plain and greppable.
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
    # Remove ANSI SGR sequences written while the console was colorized so the
    # log file stays readable and greppable.
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
    set +e
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
    # Tools required in the live (ISO) environment. Commands that only run
    # inside the chroot (e.g. grub-install, grub-mkconfig) come from packages
    # installed by pacstrap and are deliberately not checked here.
    local commands=(
        curl date sleep tee timedatectl uname lsblk blkid findmnt od
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
    # Arch's GRUB is not signed for Secure Boot. The Y9000P ships (Windows 11
    # OEM) with Secure Boot enabled; warn early so the user can disable it in
    # the BIOS before the first boot of the installed system. Disabling Secure
    # Boot does not affect the existing Windows installation.
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
install_reflector() {
    if command -v reflector >/dev/null 2>&1; then
        ok "Reflector is already installed."
        return 0
    fi

    info "Installing reflector..."
    pacman \
        --noconfirm \
        -S \
        --needed \
        reflector || die "Failed to install reflector"
    ok "Reflector installed."
}

setup_mirrors() {
    info "Configuring pacman mirrors..."
    install_reflector

    reflector \
        --protocol "$MIRROR_PROTOCOL" \
        --age "$MIRROR_AGE" \
        --country "$MIRROR_COUNTRY" \
        --latest 10 \
        --sort rate \
        --save /etc/pacman.d/mirrorlist || {
            warn "Mirror optimization failed."
            warn "Keeping current mirrorlist."
            return 0
        }
    ok "Mirrorlist updated."
    ok "Country: $MIRROR_COUNTRY"
}

# -----------------------------------------------------------------------------
# Disk selection
# -----------------------------------------------------------------------------
get_live_device() {
    # Report block devices that host the running Arch ISO, if discoverable.
    # airootfs usually resolves to a loop/overlay device, while bootmnt is the
    # real USB partition when booting an official ISO from removable media.
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

windows_partition_on() {
    # Return 0 if any partition on $1 is formatted with a Microsoft filesystem
    # (i.e. the disk appears to hold the Windows installation or Windows data).
    local disk="$1" part fstype
    [[ -b "$disk" ]] || return 1
    while IFS= read -r part; do
        [[ "$part" == "$disk" ]] && continue
        case "$part" in
            "$disk"*) ;;
            *) continue ;;
        esac
        fstype="$( blkid -s TYPE -o value "$part" 2>/dev/null || true )"
        case "$fstype" in
            ntfs | exfat | msdos)
                return 0
                ;;
        esac
    done < <( lsblk -rno NAME "$disk" 2>/dev/null || true )
    return 1
}

list_disks() {
    local disk
    printf '\n'
    printf 'Available disks:\n'
    printf '\n'
    lsblk \
        --nodeps \
        --paths \
        --output NAME,SIZE,MODEL,SERIAL,TYPE
    printf '\n'
    printf 'Notes (autodetected):\n'
    while IFS= read -r disk; do
        case "$disk" in
            /dev/loop*) continue ;;
        esac
        if windows_partition_on "$disk"; then
            printf '  %-22s Windows data detected -- do NOT select unless wiping it\n' "$disk"
        else
            printf '  %-22s no Windows data detected\n' "$disk"
        fi
    done < <( lsblk -dn -o PATH 2>/dev/null || true )
    printf '\n'
    printf 'Pick the SSD that does NOT hold Windows. If one/both NVMe drives are\n'
    printf 'missing here, see the README: BIOS storage mode (VMD/RST vs AHCI).\n'
    printf '\n'
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
    printf '\n'

    local answer
    read -rp "Type YES to continue: " answer
    if [[ "$answer" != "YES" ]]; then
        die "Disk selection cancelled."
    fi

    if windows_partition_on "$TARGET_DISK"; then
        warn "This disk contains partitions that look like a Windows installation."
        warn "If this is the Windows SSD, STOP here and re-run selecting the other disk."
        read -rp 'Type ERASE to wipe this disk anyway: ' answer
        if [[ "$answer" != "ERASE" ]]; then
            die "Aborted: refusing to wipe a disk that appears to contain Windows."
        fi
    fi
    ok "Disk confirmed."
}

# -----------------------------------------------------------------------------
# Partitioning
# -----------------------------------------------------------------------------
cleanup_disk_state() {
    # Make re-runs safe: drop anything left behind by a previous, possibly
    # failed, run of this installer before touching the target disk.
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

partition_disk() {
    cleanup_disk_state
    assert_disk_unused

    EFI_PART="$(get_partition_name "$TARGET_DISK" 1)"
    ROOT_PART="$(get_partition_name "$TARGET_DISK" 2)"

    printf '\n'
    printf 'Partition layout:\n'
    printf '  EFI  : %s\n' "$EFI_PART"
    printf '  ROOT : %s\n' "$ROOT_PART"
    printf '\n'

    local answer
    read -rp "Continue partitioning? Type YES: " answer
    if [[ "$answer" != "YES" ]]; then
        die "Partitioning cancelled."
    fi

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

    mkfs.fat -F32 "$EFI_PART"
    mkfs.btrfs -f "$ROOT_PART"

    ok "Partitioning completed."
}

# -----------------------------------------------------------------------------
# Filesystem mounting (FIXED ORDER: mount @ first, then mkdir, then mount others)
# -----------------------------------------------------------------------------
mount_filesystems() {
    info "Mounting filesystems..."
    local btrfs_opts="noatime,compress=zstd:3,discard=async"

    # -------------------------------------------------------------------------
    # Step 1: Temporarily mount btrfs root and create the @ and @home
    #         subvolumes. No /.snapshots is created: the layout stays
    #         snapshot-ready for a later Snapper setup.
    # -------------------------------------------------------------------------
    mount "$ROOT_PART" /mnt
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    sync
    umount /mnt

    # -------------------------------------------------------------------------
    # Step 2: Mount @ (root) subvolume FIRST
    # -------------------------------------------------------------------------
    mount -o "$btrfs_opts",subvol=@ "$ROOT_PART" /mnt

    # -------------------------------------------------------------------------
    # Step 3: Create mount-point directories INSIDE @ (must come AFTER @ mount).
    # -------------------------------------------------------------------------
    mkdir -p /mnt/home /mnt/boot/efi

    # -------------------------------------------------------------------------
    # Step 4: Mount home subvolume
    # -------------------------------------------------------------------------
    mount -o "$btrfs_opts",subvol=@home "$ROOT_PART" /mnt/home

    # -------------------------------------------------------------------------
    # Step 5: Mount EFI
    # -------------------------------------------------------------------------
    mount -o umask=0077 "$EFI_PART" /mnt/boot/efi

    # -------------------------------------------------------------------------
    # Step 6: Verify all mount points
    # -------------------------------------------------------------------------
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

    # Base packages only - NVIDIA support is optional and is handled below in a
    # way that can never abort the base installation.
    local packages=(
        base linux linux-firmware
        btrfs-progs
        grub efibootmgr os-prober
        fuse3 ntfs-3g
        networkmanager
        bluez bluez-utils
        pipewire pipewire-pulse wireplumber mesa
        linux-headers git sudo vim base-devel
        tlp xf86-input-libinput
        sof-firmware alsa-ucm-conf acpi
    )

    if [[ -n "$microcode" ]]; then
        packages+=("$microcode")
        info "CPU microcode package: $microcode"
    else
        warn "Unable to detect CPU microcode package."
    fi

    # -------------------------------------------------------------------------
    # Preferred path: everything (base + NVIDIA) in ONE pacstrap so the NVIDIA
    # kernel module and the `linux` kernel are guaranteed to match.
    #
    # Driver set: nvidia-open nvidia-utils nvidia-settings nvidia-prime.
    # The old closed-source `nvidia` package no longer exists in the Arch
    # repos (upstream 590 driver switch, 2025-12), so requesting it aborts
    # pacstrap with "error: target not found: nvidia". If the repos still
    # cannot provide the driver (stale/incomplete mirror db), we fall back to
    # a base-only pacstrap below instead of failing the whole installation.
    # -------------------------------------------------------------------------
    if (( INSTALL_NVIDIA )); then
        info "NVIDIA driver requested (INSTALL_NVIDIA=1):"
        info "  nvidia-open nvidia-utils nvidia-settings nvidia-prime"
        if pacstrap -K /mnt \
            "${packages[@]}" \
            nvidia-open nvidia-utils nvidia-settings nvidia-prime; then
            NVIDIA_INSTALLED=1
            ok "Base system installed (with NVIDIA driver)."
            return 0
        fi

        warn "Installing the base system together with the NVIDIA packages failed."
        warn "Retrying with the base packages only; NVIDIA is re-attempted in a"
        warn "separate step (install_nvidia_after_base) and can no longer abort"
        warn "the installation."
        if ! pacstrap -K /mnt "${packages[@]}"; then
            die "Failed to install the base system even without the NVIDIA packages."
        fi
        warn "Base system installed WITHOUT the NVIDIA driver."
        return 0
    fi

    pacstrap -K /mnt "${packages[@]}" || die "Failed to install base system."
    ok "Base system installed."
}

install_nvidia_after_base() {
    # Only reached when INSTALL_NVIDIA=1 and the combined pacstrap above could
    # not install the driver. Gives the NVIDIA set one more isolated attempt
    # now that the base system is in place. Failure here only warns.
    (( INSTALL_NVIDIA )) || return 0
    if (( NVIDIA_INSTALLED )); then
        return 0
    fi

    info "Attempting NVIDIA driver installation as a separate step..."
    if pacstrap -K /mnt \
        nvidia-open nvidia-utils nvidia-settings nvidia-prime; then
        NVIDIA_INSTALLED=1
        ok "NVIDIA driver installed."
        return 0
    fi

    warn "The NVIDIA driver could not be installed from the current mirrors."
    warn "The system will still boot, using the Intel iGPU (RTX dGPU idle)."
    warn "After this installation completes, fix the mirrors and run on Arch:"
    warn "  sudo pacman -Syy"
    warn "  sudo pacman -S nvidia-open nvidia-utils nvidia-settings nvidia-prime"
    warn "  sudo mkinitcpio -P"
    return 0
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

# Enable Bluetooth service
systemctl enable bluetooth

# Enable laptop power management
systemctl enable tlp
systemctl mask systemd-rfkill.service systemd-rfkill.socket 2>/dev/null || true

# NOTE: no nvidia-suspend/-hibernate/-resume units are enabled here - the
# current open-module driver (nvidia-utils 560+) enables DRM by default and no
# longer ships those systemd units.
EOF
    ok "Basic system configuration completed."
}

create_user() {
    read -rp "Username: " USERNAME
    if [[ -z "$USERNAME" ]]; then
        die "Username cannot be empty."
    fi

    arch-chroot /mnt useradd \
        -m \
        -G wheel \
        -s /bin/bash \
        "$USERNAME"

    printf '\n'
    printf '=====================================\n'
    printf 'Set password for user: %s\n' "$USERNAME"
    printf '=====================================\n'
    printf '\n'
    arch-chroot /mnt passwd "$USERNAME"

    sed -i \
        's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' \
        /mnt/etc/sudoers

    printf '\n'
    printf '=====================================\n'
    printf 'Set password for root user\n'
    printf '=====================================\n'
    printf '\n'
    arch-chroot /mnt passwd root
    ok "User created."
}

configure_kernel_cmdline() {
    # No swap is created, so there is no hibernation/suspend-to-disk and no
    # `resume=` parameter (nor the initramfs `resume` hook) to configure.
    # The NVIDIA early-KMS parameter is kept: it is independent of swap and is
    # required by most Wayland/X sessions on hybrid-graphics laptops.
    if (( ! NVIDIA_INSTALLED || ! NVIDIA_DRM_MODESET )); then
        info "Kernel cmdline left at distribution default (no NVIDIA KMS requested)."
        return 0
    fi

    local kernel_cmdline="quiet nvidia-drm.modeset=1"
    info "GRUB kernel cmdline: $kernel_cmdline"
    sed -i \
        "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$kernel_cmdline\"|" \
        /mnt/etc/default/grub
    ok "NVIDIA DRM kernel modeset configured."
}

# -----------------------------------------------------------------------------
# Snapshots: intentionally NOT configured
# -----------------------------------------------------------------------------
# This installer does not set up Snapper/grub-btrfs snapshots. The btrfs
# subvolume layout (@, @home) is snapshot-ready, but /.snapshots is deliberately
# left absent: `snapper create-config` creates that nested subvolume itself and
# refuses to run when the directory already exists (errno 17, "File exists").
# To enable snapshots later, on the installed system:
#   pacman -S snapper grub-btrfs inotify-tools
#   snapper --no-dbus -c root create-config /
#   chmod 750 /.snapshots
#   systemctl enable --now snapper-timeline.timer snapper-cleanup.timer
#   systemctl enable --now grub-btrfsd.service
#   grub-mkconfig -o /boot/grub/grub.cfg

# -----------------------------------------------------------------------------
# Bootloader
# -----------------------------------------------------------------------------
install_grub() {
    info "Installing GRUB bootloader..."

    arch-chroot /mnt env \
        ENABLE_OS_PROBER="$ENABLE_OS_PROBER" \
        bash -c '
            set -e
            if [ "$ENABLE_OS_PROBER" = "1" ]; then
                sed -i "s|^#\?GRUB_DISABLE_OS_PROBER=.*|GRUB_DISABLE_OS_PROBER=false|" /etc/default/grub
            else
                sed -i "s|^#\?GRUB_DISABLE_OS_PROBER=.*|GRUB_DISABLE_OS_PROBER=true|" /etc/default/grub
            fi

            grub-install \
                --target=x86_64-efi \
                --efi-directory=/boot/efi \
                --bootloader-id=Arch \
                --recheck

            # os-prober inspects the OTHER SSD (Windows disk, untouched by this
            # installer) and appends a "Windows Boot Manager" chainload entry.
            # Windows keeps its own bootloader on its own disk either way.
            if [ "$ENABLE_OS_PROBER" = "1" ]; then
                os-prober || true
            fi

            grub-mkconfig -o /boot/grub/grub.cfg
        '
    ok "GRUB installation completed."
}

reorder_boot_entries() {
    # Two disks (Windows + Arch), each with its own ESP => the firmware holds two
    # boot entries. Show them, then optionally make Arch GRUB the first entry so
    # the machine boots into the GRUB menu (where Windows can be picked too).
    info "Checking UEFI boot entries..."
    local output arch_num order new_order entry answer
    output="$( arch-chroot /mnt efibootmgr 2>/dev/null || true )"
    if [[ -z "$output" ]]; then
        warn "efibootmgr returned nothing; cannot show boot entries."
        return 0
    fi

    printf '%s\n' "$output" | grep '^Boot[0-9A-Fa-f]' || true
    printf '\n'

    arch_num="$( printf '%s\n' "$output" \
        | awk '/^Boot[0-9A-Fa-f]{4}\*/ { if (index($0,"Arch")) { print substr($1,5,4); exit } }' )"
    if [[ -z "$arch_num" ]]; then
        warn "No 'Arch' boot entry found; skipping boot-order change."
        return 0
    fi
    order="$( printf '%s\n' "$output" | awk '/^BootOrder:/ {print $2}' )"
    if [[ -z "$order" ]]; then
        warn "No BootOrder found; skipping boot-order change."
        return 0
    fi

    read -rp "Set Arch (GRUB) as the first boot entry? [Y/n]: " answer
    case "${answer,,}" in
        n | no)
            info "Boot order left unchanged."
            return 0
            ;;
    esac

    new_order="$arch_num"
    local order_array
    IFS=',' read -r -a order_array <<< "$order"
    for entry in "${order_array[@]}"; do
        if [[ "$entry" == "$arch_num" ]]; then
            continue
        fi
        new_order+=",$entry"
    done

    if arch-chroot /mnt efibootmgr -o "$new_order" >/dev/null 2>&1; then
        ok "Boot order updated: Arch ($arch_num) is now the first boot entry."
        ok "Windows Boot Manager remains selectable in GRUB and via F12."
    else
        warn "Failed to update boot order (efivarfs permission / Secure Boot?)."
    fi
}

finish_installation() {
    info "Performing final installation cleanup..."
    sync

    umount -R /mnt || {
        warn "Some mounts could not be unmounted."
        mount | grep /mnt || true
    }

    ok "Installation completed successfully."

    if (( NVIDIA_INSTALLED )); then
        cat <<'NOTE'
* NVIDIA driver (nvidia-open) was installed; launch apps on the RTX dGPU with:
      prime-run <command>
NOTE
    elif (( INSTALL_NVIDIA )); then
        cat <<'NOTE'
* NVIDIA was requested but could NOT be installed from the current mirrors
  (see the warnings above). The system will boot using the Intel iGPU. To add
  the NVIDIA driver later, run on Arch:
      sudo pacman -Syy
      sudo pacman -S nvidia-open nvidia-utils nvidia-settings nvidia-prime
      sudo mkinitcpio -P
NOTE
    fi

    cat <<EOF

=====================================
Arch Linux installation finished.

This installer only touched: $TARGET_DISK
The Windows SSD (the other disk) was left untouched.

-- Dual boot (two SSDs, one OS per disk) --
* Boot into Arch GRUB:  entry 'Arch' is first if you confirmed the reorder,
  otherwise press F12 at power-on and pick 'Arch'.
* Boot into Windows:    pick 'Windows Boot Manager' at F12, or choose it from
  the Arch GRUB menu (os-prober only *detects* it; Windows is never modified).
* If Windows is missing from the GRUB menu after reboot, run on Arch:
      sudo os-prober && sudo grub-mkconfig -o /boot/grub/grub.cfg
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
    # Decide color support while stdout is still the real terminal (init_logging
    # redirects it into the log tee right after).
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
    install_nvidia_after_base
    generate_fstab

    configure_system
    create_user

    configure_kernel_cmdline
    install_grub
    reorder_boot_entries

    finish_installation
}

main "$@"
