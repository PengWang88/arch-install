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

# Declare separately from the command substitution so a failing $(...) still
# aborts under `set -e` (readonly would otherwise mask its exit status).
readonly SCRIPT_DIR
SCRIPT_DIR="$( cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P )"
readonly LOG_FILE
LOG_FILE="/tmp/${PROJECT_NAME}-$(date -u +%Y%m%dT%H%M%SZ).log"

TARGET_DISK=""
EFI_PART=""
SWAP_PART=""
ROOT_PART=""
SWAP_SIZE=""
SWAP_UUID=""
HOSTNAME="archlinux"
USERNAME=""

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
log()  { local level="$1"; shift; printf '[%-4s] %s\n' "$level" "$*"; }
info() { log "INFO" "$@"; }
ok()   { log "OK"   "$@"; }
warn() { log "WARN" "$@"; }
die()  { log "FAIL" "$@" >&2; exit 1; }

init_logging() {
    touch "$LOG_FILE" || {
        printf 'Failed to create log file: %s\n' "$LOG_FILE" >&2
        exit 1
    }
    exec > >(tee -a "$LOG_FILE") 2>&1
}

# -----------------------------------------------------------------------------
# Error handling
# -----------------------------------------------------------------------------
on_error() {
    local exit_code=$?
    set +e
    printf '\n[FAIL] Unexpected error (exit=%d, line=%s)\n' \
        "$exit_code" \
        "${BASH_LINENO[0]:-unknown}" >&2
    printf '[INFO] Log file: %s\n' "$LOG_FILE" >&2
    exit "$exit_code"
}

on_interrupt() {
    printf '\n[WARN] Installation interrupted by user.\n' >&2
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
    # inside the chroot (e.g. snapper, grub-install, grub-mkconfig) come from
    # packages installed by pacstrap and are deliberately not checked here.
    local commands=(
        curl date sleep tee timedatectl uname lsblk blkid findmnt
        sgdisk partprobe mkfs.fat mkswap mkfs.btrfs btrfs free
        mount umount mountpoint swapon swapoff
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

list_disks() {
    printf '\n'
    printf 'Available disks:\n'
    printf '\n'
    lsblk \
        --nodeps \
        --paths \
        --output NAME,SIZE,MODEL,SERIAL,TYPE
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

    local swap_dev
    while read -r swap_dev; do
        case "$swap_dev" in
            "$TARGET_DISK"*)
                warn "Disabling leftover swap on target disk: $swap_dev"
                swapoff "$swap_dev" 2>/dev/null || true
                ;;
        esac
    done < <( swapon --show | awk 'NR > 1 {print $1}' )
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

ask_swap_size() {
    local swap_input
    local mem_total
    mem_total="$( free -h | awk '/^Mem:/ {print $2}' )"
    info "Physical memory: ${mem_total:-unknown}"
    info "For hibernation, swap should be at least as large as RAM."
    while true; do
        read -rp "Enter swap size (e.g., 8G, 4096M) [default: 8G]: " swap_input
        swap_input="${swap_input:-8G}"
        if [[ "$swap_input" =~ ^[0-9]+[GMgm]$ ]]; then
            SWAP_SIZE="$swap_input"
            info "Swap size set to: $SWAP_SIZE"
            return 0
        else
            warn "Invalid swap size format: '$swap_input'. Please use format like 8G or 4096M."
        fi
    done
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

    ask_swap_size

    EFI_PART="$(get_partition_name "$TARGET_DISK" 1)"
    SWAP_PART="$(get_partition_name "$TARGET_DISK" 2)"
    ROOT_PART="$(get_partition_name "$TARGET_DISK" 3)"

    printf '\n'
    printf 'Partition layout:\n'
    printf '  EFI  : %s\n' "$EFI_PART"
    printf '  SWAP : %s\n' "$SWAP_PART"
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
        -n 2:0:+"${SWAP_SIZE}" \
        -t 2:8200 \
        "$TARGET_DISK"
    sgdisk \
        -n 3:0:0 \
        -t 3:8300 \
        "$TARGET_DISK"

    partprobe "$TARGET_DISK"

    # Wait until the kernel exposes all partition nodes (NVMe/eMMC can be slow).
    local attempt
    for ((attempt = 0; attempt < 20; attempt++)); do
        if [[ -b "$EFI_PART" && -b "$SWAP_PART" && -b "$ROOT_PART" ]]; then
            break
        fi
        sleep 1
    done
    if [[ ! -b "$EFI_PART" || ! -b "$SWAP_PART" || ! -b "$ROOT_PART" ]]; then
        die "Partition nodes did not appear: $EFI_PART $SWAP_PART $ROOT_PART"
    fi

    mkfs.fat -F32 "$EFI_PART"
    mkswap "$SWAP_PART"
    mkfs.btrfs -f "$ROOT_PART"

    SWAP_UUID="$( blkid -s UUID -o value "$SWAP_PART" )"
    ok "Partitioning completed."
}

# -----------------------------------------------------------------------------
# Filesystem mounting (FIXED ORDER: mount @ first, then mkdir, then mount others)
# -----------------------------------------------------------------------------
mount_filesystems() {
    info "Mounting filesystems..."
    local btrfs_opts="noatime,compress=zstd:3,discard=async"

    # -------------------------------------------------------------------------
    # Step 1: Temporarily mount btrfs root and create subvolumes
    # -------------------------------------------------------------------------
    mount "$ROOT_PART" /mnt
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    btrfs subvolume create /mnt/@snapshots
    sync
    umount /mnt

    # -------------------------------------------------------------------------
    # Step 2: Mount @ (root) subvolume FIRST
    # -------------------------------------------------------------------------
    mount -o "$btrfs_opts",subvol=@ "$ROOT_PART" /mnt

    # -------------------------------------------------------------------------
    # Step 3: Create mount-point directories INSIDE @ (must come AFTER @ mount)
    # -------------------------------------------------------------------------
    mkdir -p /mnt/home /mnt/.snapshots /mnt/boot/efi

    # -------------------------------------------------------------------------
    # Step 4: Mount home subvolume
    # -------------------------------------------------------------------------
    mount -o "$btrfs_opts",subvol=@home "$ROOT_PART" /mnt/home

    # -------------------------------------------------------------------------
    # Step 5: Mount snapshots subvolume (for Snapper + grub-btrfs)
    # -------------------------------------------------------------------------
    mount -o "$btrfs_opts",subvol=@snapshots "$ROOT_PART" /mnt/.snapshots
    chmod 750 /mnt/.snapshots

    # -------------------------------------------------------------------------
    # Step 6: Mount EFI
    # -------------------------------------------------------------------------
    mount -o umask=0077 "$EFI_PART" /mnt/boot/efi

    # -------------------------------------------------------------------------
    # Step 7: Enable swap
    # -------------------------------------------------------------------------
    swapon "$SWAP_PART"

    # -------------------------------------------------------------------------
    # Step 8: Verify all mount points
    # -------------------------------------------------------------------------
    mountpoint -q /mnt             || die "Root filesystem mount failed."
    mountpoint -q /mnt/home        || die "Home filesystem mount failed."
    mountpoint -q /mnt/.snapshots  || die "Snapshots filesystem mount failed."
    mountpoint -q /mnt/boot/efi    || die "EFI filesystem mount failed."
    swapon --show | grep -q "$SWAP_PART" || die "Swap activation failed."

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

    local packages=(
        base linux linux-firmware
        btrfs-progs
        snapper grub-btrfs inotify-tools
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

# Enable Bluetooth service
systemctl enable bluetooth

# Enable laptop power management
systemctl enable tlp
systemctl mask systemd-rfkill.service systemd-rfkill.socket 2>/dev/null || true

# Enable Snapper cleanup / timeline timers
systemctl enable snapper-cleanup.timer
systemctl enable snapper-timeline.timer

# Enable grub-btrfsd (auto-update GRUB menu on new snapshots)
systemctl enable grub-btrfsd.service

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

configure_resume() {
    info "Configuring hibernation resume..."
    if [[ -z "$SWAP_UUID" ]]; then
        die "Swap UUID is empty. Cannot configure hibernation resume."
    fi

    arch-chroot /mnt bash -c '
        set -e
        cp /etc/mkinitcpio.conf /etc/mkinitcpio.conf.bak
        sed -i \
            "s|^HOOKS=.*|HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block resume filesystems fsck)|" \
            /etc/mkinitcpio.conf
    '

    sed -i \
        "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"quiet resume=UUID=$SWAP_UUID\"|" \
        /mnt/etc/default/grub

    arch-chroot /mnt mkinitcpio -P
    ok "Hibernate resume configured."
}

# -----------------------------------------------------------------------------
# Snapper + grub-btrfs snapshot configuration
# -----------------------------------------------------------------------------
configure_snapshots() {
    info "Configuring Snapper snapshots..."

    # Create snapper config (must use --no-dbus in chroot: no dbus-daemon running)
    arch-chroot /mnt snapper --no-dbus -c root create-config / || {
        die "Failed to create snapper config."
    }

    # Tune retention policy: keep 10 hourly + 7 daily
    # shellcheck disable=SC2016  # single quotes are intentional: $CFG must be
    #                             # expanded inside the chroot, not by this shell
    arch-chroot /mnt bash -c '
        set -e
        CFG=/etc/snapper/configs/root
        sed -i "s|^TIMELINE_LIMIT_HOURLY=.*|TIMELINE_LIMIT_HOURLY=\"10\"|"  $CFG
        sed -i "s|^TIMELINE_LIMIT_DAILY=.*|TIMELINE_LIMIT_DAILY=\"7\"|"     $CFG
        sed -i "s|^TIMELINE_LIMIT_WEEKLY=.*|TIMELINE_LIMIT_WEEKLY=\"0\"|"   $CFG
        sed -i "s|^TIMELINE_LIMIT_MONTHLY=.*|TIMELINE_LIMIT_MONTHLY=\"0\"|" $CFG
        sed -i "s|^TIMELINE_LIMIT_YEARLY=.*|TIMELINE_LIMIT_YEARLY=\"0\"|"   $CFG
    '

    # Create initial post-install snapshot so GRUB has at least one entry
    arch-chroot /mnt snapper --no-dbus -c root create \
        --description "Initial Arch Linux installation" || {
        warn "Failed to create initial snapshot (can be created later manually)."
    }

    ok "Snapper snapshots configured."
}

install_grub() {
    info "Installing GRUB bootloader..."

    # NOTE: must run AFTER configure_snapshots() so grub-btrfs hook can find
    # snapper configs and embed the snapshot boot entries into grub.cfg
    arch-chroot /mnt bash -c '
        set -e
        sed -i "s|^#\?GRUB_DISABLE_OS_PROBER=.*|GRUB_DISABLE_OS_PROBER=false|" /etc/default/grub

        grub-install \
            --target=x86_64-efi \
            --efi-directory=/boot/efi \
            --bootloader-id=Arch \
            --recheck

        grub-mkconfig -o /boot/grub/grub.cfg
    '
    ok "GRUB installation completed."
}

finish_installation() {
    info "Performing final installation cleanup..."
    sync

    if swapon --show | grep -q "$SWAP_PART"; then
        swapoff "$SWAP_PART"
    fi

    umount -R /mnt || {
        warn "Some mounts could not be unmounted."
        mount | grep /mnt || true
    }

    ok "Installation completed successfully."
    printf '\n'
    printf '=====================================\n'
    printf 'Arch Linux installation finished.\n'
    printf '\n'
    printf 'Snapper snapshot commands (after reboot):\n'
    printf '  sudo snapper list                          # List snapshots\n'
    printf '  sudo snapper create -d "Before update"    # Manual snapshot\n'
    printf '  sudo snapper rollback <number>            # Rollback to snapshot\n'
    printf '\n'
    printf 'You may reboot now.\n'
    printf 'Remove the installation media first.\n'
    printf '=====================================\n'
    printf '\n'
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
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

    configure_resume
    configure_snapshots
    install_grub

    finish_installation
}

main "$@"
