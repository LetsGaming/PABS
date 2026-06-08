#!/bin/bash
# =============================================================================
# lib/preflight.sh — Pre-flight validation checks
#
# All functions here run before any data is staged or written.
# They call die() on hard failures and log_warn() on soft ones.
# =============================================================================

check_root() {
    [[ $EUID -eq 0 ]] || die "Run this script as root."
}

check_usb_mounted() {
    # UUID validation — ensures we write to the exact partition we expect,
    # not just whatever happens to be mounted at USB_MOUNT.
    if [[ -n "$TARGET_UUID" ]]; then
        local dev_path
        dev_path=$(blkid -U "$TARGET_UUID" 2>/dev/null || true)
        [[ -n "$dev_path" ]] \
            || die "UUID $TARGET_UUID not found. Wrong drive inserted or drive not connected."
    fi

    mountpoint -q "$USB_MOUNT" \
        || die "Nothing mounted at $USB_MOUNT. Mount the USB first: mount /dev/sdX1 $USB_MOUNT"

    # Write-test catches hardware read-only switches before we attempt a full backup
    touch "$USB_MOUNT/.write_test" 2>/dev/null && rm -f "$USB_MOUNT/.write_test" \
        || die "USB at $USB_MOUNT is mounted read-only."

    # Filesystem capability check — warn on filesystems that cannot store symlinks
    # or Unix permissions. exFAT/FAT32/NTFS will cause the USB rsync transfer to
    # fail. The setup wizard offers to format to ext4; see docs/usb-health.md.
    local usb_dev usb_fstype
    usb_dev=$(findmnt -n -o SOURCE "$USB_MOUNT" 2>/dev/null || true)
    if [[ -n "$usb_dev" ]]; then
        usb_fstype=$(blkid -s TYPE -o value "$usb_dev" 2>/dev/null || true)
        case "${usb_fstype,,}" in
            ext2|ext3|ext4) ;;  # fully supported
            exfat|vfat|fat32|ntfs|ntfs-3g)
                log_warn "USB filesystem is ${usb_fstype} — PABS requires ext4."
                log_warn "  ext4 supports symlinks, Unix permissions, and filesystem health checks."
                log_warn "  Backups WILL FAIL during the USB transfer step on ${usb_fstype}."
                log_warn "  Re-run the setup wizard to format the drive: bash /opt/pabs/setup.sh --step usb"
                ;;
            "")
                log_warn "Could not detect USB filesystem type — proceeding cautiously"
                ;;
            *)
                log_warn "USB filesystem is ${usb_fstype} — ext4 is recommended for full PABS support"
                ;;
        esac
    fi
}

# Shared helper: estimate the total KB we expect to back up this run.
# Used by both space-check functions to avoid duplicating the path list.
_estimate_backup_kb() {
    local needed_kb=0

    for path in /etc/pve /etc/network /etc/ssh /root/.ssh \
                /etc/crontab /etc/cron.d /var/spool/cron/crontabs \
                /etc/nftables.conf /etc/iptables /usr/local/bin /root/scripts; do
        [[ -e "$path" ]] \
            && needed_kb=$(( needed_kb + $(du -sk "$path" 2>/dev/null | cut -f1) ))
    done

    # VM agent bundles are pulled at runtime and not easily pre-estimated.
    # Add a rough heuristic: 512MB per configured agent to account for HAOS
    # snapshots and large Docker volume exports. The 20% margin in the callers
    # is insufficient for agent-heavy setups, so over-estimate deliberately.
    local agent_count=0
    if [[ -n "${VM_AGENTS[*]:-}" ]]; then
        agent_count=${#VM_AGENTS[@]}
    fi
    needed_kb=$(( needed_kb + agent_count * 524288 ))  # 512MB per agent

    echo "$needed_kb"
}

check_local_stage_space() {
    local needed_kb
    needed_kb=$(_estimate_backup_kb)
    local needed_with_margin=$(( needed_kb * 12 / 10 ))

    local available_kb
    available_kb=$(df -k "$LOCAL_STAGE_BASE" 2>/dev/null | awk 'NR==2{print $4}' \
        || df -k "$(dirname "$LOCAL_STAGE_BASE")" | awk 'NR==2{print $4}')

    if [[ $available_kb -lt $needed_with_margin ]]; then
        die "Not enough local staging space. Need ~$(( needed_with_margin / 1024 ))MB, \
have $(( available_kb / 1024 ))MB free. Adjust LOCAL_STAGE_BASE in config.sh."
    fi

    # Warn if staging is on the root device with low headroom
    local stage_dev root_dev
    stage_dev=$(df -k "$LOCAL_STAGE_BASE" | awk 'NR==2{print $1}')
    root_dev=$(df -k / | awk 'NR==2{print $1}')
    local warn_threshold_kb=$(( LOCAL_STAGE_WARN_GB * 1024 * 1024 ))
    if [[ "$stage_dev" == "$root_dev" && $available_kb -lt $warn_threshold_kb ]]; then
        log_warn "Staging is on the root filesystem with only $(( available_kb / 1024 ))MB free." \
                 "Consider pointing LOCAL_STAGE_BASE at a larger volume (see config.sh)."
    fi

    log "Local stage space OK ($(( available_kb / 1024 ))MB available on $stage_dev)"
}

check_usb_space() {
    local needed_kb
    needed_kb=$(_estimate_backup_kb)
    local needed_with_margin=$(( needed_kb * 12 / 10 ))

    local available_kb
    available_kb=$(df -k "$USB_MOUNT" | awk 'NR==2{print $4}')

    if [[ $available_kb -lt $needed_with_margin ]]; then
        # Try to recover space by purging the oldest completed backup —
        # but never if it's the last one (always keep at least one restore point).
        mapfile -t existing < <(
            find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d ! -name ".*" ! -name "*.tmp" | sort
        )

        if [[ ${#existing[@]} -gt 1 ]]; then
            log_warn "USB low on space. Auto-purging oldest backup: ${existing[0]}"
            dispatch_alert "Low USB space — purging oldest backup (${existing[0]##*/}) to make room."
            rm -rf "${existing[0]}"
            sync

            # Re-check after purge; die cleanly if still not enough
            available_kb=$(df -k "$USB_MOUNT" | awk 'NR==2{print $4}')
            if [[ $available_kb -lt $needed_with_margin ]]; then
                die "Still not enough USB space after purging oldest backup. Free space manually."
            fi
            log "Space recovered. Continuing."
        else
            die "Insufficient USB space and only 1 backup remains — refusing to purge the last restore point."
        fi
    fi

    log "USB space OK ($(( available_kb / 1024 ))MB available)"
}