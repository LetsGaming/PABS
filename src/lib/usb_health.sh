#!/bin/bash
# =============================================================================
# lib/usb_health.sh — USB drive health assessment
#
# Sourced by pabs-status.sh. Entry point: usb_health_check MOUNT_POINT
#
# Checks four independent signal layers, each honest about its own
# reliability. Results are printed using the _ok/_warn/_fail helpers
# already defined in pabs-status.sh.
#
# Signal layers (in order of reliability):
#   1. Kernel error log  — dmesg I/O errors for this device (always works)
#   2. Filesystem state  — kernel ro-remount detection (always works)
#   3. Filesystem errors — dumpe2fs superblock error counters (ext2/3/4 only)
#   4. SMART health      — smartctl overall health (works on ~50% of USB sticks)
#
# SMART wear-level attributes (reallocated sectors etc.) are intentionally
# NOT checked: USB flash bridges rarely expose them accurately, and showing
# "Reallocated Sectors: 0" for a dying stick is more dangerous than silence.
# =============================================================================

# ---------------------------------------------------------------------------
# _usb_get_device MOUNT_POINT → prints /dev/sdX (the block device)
# Returns 1 if the device cannot be resolved.
# ---------------------------------------------------------------------------
_usb_get_device() {
    local mount="$1"
    findmnt -n -o SOURCE "$mount" 2>/dev/null | head -1
}

# ---------------------------------------------------------------------------
# _usb_get_disk PARTITION → prints the parent disk (/dev/sdX from /dev/sdX1)
# Used to scope dmesg and SMART checks to the whole disk, not just the partition.
# ---------------------------------------------------------------------------
_usb_get_disk() {
    local dev="$1"
    # Strip trailing digit(s) for simple partition naming (sdX1 → sdX)
    # Also handles nvmeXnYpZ → nvmeXnY via lsblk pkname
    local pkname
    pkname=$(lsblk -no PKNAME "$dev" 2>/dev/null | head -1)
    if [[ -n "$pkname" ]]; then
        echo "/dev/$pkname"
    else
        # Fallback: strip trailing partition number
        echo "$dev" | sed -E 's/p?[0-9]+$//'
    fi
}

# ---------------------------------------------------------------------------
# Signal 1: Kernel I/O error log
#
# Scans dmesg for I/O errors, SCSI/ATA resets, and filesystem errors
# attributed to this device. These are the earliest and most reliable
# indicator of a failing drive — the kernel logs them unconditionally.
#
# Searches both the partition name (sdb1) and disk name (sdb) to catch
# errors reported at different layers.
# ---------------------------------------------------------------------------
_usb_check_dmesg() {
    local dev="$1"   # e.g. /dev/sdb1
    local disk="$2"  # e.g. /dev/sdb

    local dev_name disk_name
    dev_name=$(basename "$dev")
    disk_name=$(basename "$disk")

    # Pattern covers:
    #   "I/O error, dev sdb"          — generic block layer error
    #   "blk_update_request: I/O error" — newer kernels
    #   "EXT4-fs error (device sdb1)"  — filesystem-level
    #   "SCSI error: return code"       — SCSI/USB bridge errors
    #   "reset high-speed USB device"  — USB device reset (often precedes failure)
    #   "device descriptor read error" — USB enumeration failure
    local error_pattern="I/O error.*${disk_name}|I/O error.*${dev_name}|blk_update_request.*${disk_name}|EXT.-fs error.*${dev_name}|SCSI error.*${disk_name}|reset.*USB device.*${disk_name}|${disk_name}.*reset"

    local error_lines
    error_lines=$(dmesg 2>/dev/null \
        | grep -iE "$error_pattern" \
        | grep -v "^$" \
        | tail -5 \
        || true)

    local error_count=0
    [[ -n "$error_lines" ]] && error_count=$(echo "$error_lines" | wc -l)

    if [[ $error_count -eq 0 ]]; then
        _ok  "Kernel log: no I/O errors for $disk_name since last boot"
        return 0
    else
        _fail "Kernel log: ${error_count} I/O error(s) for $disk_name since last boot"
        echo "$error_lines" | while IFS= read -r line; do
            echo "        ${line}"
        done
        _fail "    This is a strong indicator of hardware failure — replace the drive"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Signal 2: Filesystem read-only remount
#
# When the kernel detects write errors it remounts the filesystem read-only
# as a last-ditch safety measure. If this has happened, the drive is
# effectively dead for backup purposes regardless of what else we find.
# ---------------------------------------------------------------------------
_usb_check_ro_remount() {
    local mount="$1"

    # /proc/mounts lists the actual current mount options, including "ro"
    # if the kernel force-remounted it read-only after errors.
    if grep -qE "^[^ ]+ $mount [^ ]+ ro," /proc/mounts 2>/dev/null; then
        _fail "Filesystem: mounted READ-ONLY — kernel detected errors and remounted"
        _fail "    Backups cannot be written. Replace the drive immediately."
        return 1
    fi

    # Also check /proc/mounts for "errors=remount-ro" combined with error state
    # by looking at the actual current mount flags, not just mount options.
    local mount_opts
    mount_opts=$(findmnt -n -o OPTIONS "$mount" 2>/dev/null || true)
    if echo "$mount_opts" | grep -q "\bro\b"; then
        _fail "Filesystem: mounted read-only (detected via findmnt)"
        return 1
    fi

    _ok "Filesystem: mounted read-write (no forced remount)"
    return 0
}

# ---------------------------------------------------------------------------
# Signal 3: Filesystem error counters (ext2/ext3/ext4 only)
#
# The ext superblock tracks:
#   - Mount count since last fsck
#   - Filesystem error count (set by the kernel when errors are encountered)
#   - Last check date
#
# This is distinct from SMART — it's the filesystem layer's own error log,
# written into the superblock when the kernel's ext4 error handler fires.
# Only meaningful on ext-formatted drives. Silently skipped for FAT/exFAT/NTFS.
# ---------------------------------------------------------------------------
_usb_check_ext_superblock() {
    local dev="$1"

    # Detect filesystem type
    local fs_type
    fs_type=$(blkid -s TYPE -o value "$dev" 2>/dev/null || true)

    if [[ "$fs_type" != ext2 && "$fs_type" != ext3 && "$fs_type" != ext4 ]]; then
        _ok "Filesystem errors: skipped (filesystem is ${fs_type:-unknown}, not ext2/3/4)"
        return 0
    fi

    if ! command -v dumpe2fs &>/dev/null; then
        _ok "Filesystem errors: skipped (dumpe2fs not installed — apt install e2fsprogs)"
        return 0
    fi

    local sb
    sb=$(dumpe2fs -h "$dev" 2>/dev/null || true)

    if [[ -z "$sb" ]]; then
        _warn "Filesystem errors: could not read $fs_type superblock from $dev"
        return 0
    fi

    # Error count in the superblock — incremented by the kernel's ext4_error()
    local error_count
    error_count=$(echo "$sb" | grep -i "FS Error count:" | awk '{print $NF}' || echo 0)
    error_count="${error_count:-0}"

    # Mount count since last check
    local mount_count max_mount_count last_checked
    mount_count=$(echo    "$sb" | grep "^Mount count:"     | awk '{print $NF}' || echo "?")
    max_mount_count=$(echo "$sb" | grep "^Maximum mount count:" | awk '{print $NF}' || echo "?")
    last_checked=$(echo   "$sb" | grep "^Last checked:"    | sed 's/Last checked:[ \t]*//' || echo "unknown")

    if [[ "$error_count" =~ ^[0-9]+$ && "$error_count" -gt 0 ]]; then
        _fail "Filesystem errors: $error_count error(s) recorded in $fs_type superblock on $dev"
        _fail "    Run 'fsck -n $dev' (unmounted) to inspect without changes"
        return 1
    else
        _ok "Filesystem errors: $fs_type superblock reports 0 errors (mounts: ${mount_count}/${max_mount_count}, last check: $last_checked)"
        return 0
    fi
}

# ---------------------------------------------------------------------------
# Signal 4: SMART overall health
#
# USB drives present SMART data through their USB-to-SATA/NVMe bridge chip.
# Many cheap bridges block or fake SMART entirely. We therefore:
#   - Only attempt this if smartctl is installed
#   - Use -d sat (SCSI-ATA Translation) which works on most quality bridges
#   - Only check the overall PASSED/FAILED result, NOT individual attributes
#     (attributes are unreliable through USB bridges)
#   - Clearly note when SMART is unavailable rather than reporting a false OK
# ---------------------------------------------------------------------------
_usb_check_smart() {
    local disk="$1"

    if ! command -v smartctl &>/dev/null; then
        _ok "SMART: skipped (smartctl not installed — apt install smartmontools)"
        return 0
    fi

    # Try SAT pass-through first (works on most USB-SATA bridges)
    local smart_output
    smart_output=$(smartctl -H -d sat "$disk" 2>&1) || true

    # smartctl exit codes are bitmask flags — bit 0 = command line error,
    # bit 1 = device open failed, bits 2-7 = drive status flags.
    # Exit 0 or 4+ (status flags set but device readable) are meaningful.
    # Exit 1 = bad argument, exit 2 = device could not be opened.

    if echo "$smart_output" | grep -q "SMART support is: Unavailable\|Unable to detect device type\|Unsupported USB bridge\|Read Device Identity failed\|USB device doesn't support"; then
        _ok "SMART: not supported by this USB bridge (normal for many USB sticks)"
        return 0
    fi

    if echo "$smart_output" | grep -q "Permission denied\|No such device"; then
        _warn "SMART: could not access $disk (try running as root)"
        return 0
    fi

    # Check for SMART overall assessment line
    if echo "$smart_output" | grep -q "SMART overall-health self-assessment test result: PASSED"; then
        _ok "SMART: overall health PASSED"
        return 0
    fi

    if echo "$smart_output" | grep -q "SMART overall-health self-assessment test result: FAILED"; then
        _fail "SMART: overall health FAILED — drive is reporting imminent failure"
        _fail "    Replace the drive immediately and verify your last backup is intact"
        return 1
    fi

    # SMART available but result is ambiguous (some drives report "Unknown")
    local health_line
    health_line=$(echo "$smart_output" | grep -i "overall-health\|health status" || true)
    if [[ -n "$health_line" ]]; then
        _warn "SMART: health status ambiguous: $health_line"
    else
        _ok "SMART: device responded but no health assessment available (bridge limitation)"
    fi

    return 0
}

# ---------------------------------------------------------------------------
# _usb_backup_age_check BACKUP_ROOT
#
# Not a hardware signal — checks how long since the last successful backup.
# A very old backup combined with hardware warnings is a strong signal to act.
# ---------------------------------------------------------------------------
_usb_backup_age_check() {
    local backup_root="$1"

    [[ -d "$backup_root" ]] || return 0

    local latest
    latest=$(find "$backup_root" -mindepth 1 -maxdepth 1 -type d ! -name '.*' \
        | sort | tail -1)
    [[ -z "$latest" ]] && return 0

    local backup_name age_days
    backup_name=$(basename "$latest")

    # Parse date from directory name format: YYYY-MM-DD_HH-MM-SS
    local backup_epoch now_epoch
    backup_epoch=$(date -d "${backup_name:0:10} ${backup_name:11:2}:${backup_name:14:2}:${backup_name:17:2}" +%s 2>/dev/null || echo 0)
    now_epoch=$(date +%s)

    if [[ "$backup_epoch" -eq 0 ]]; then
        return 0  # Can't parse the date — skip silently
    fi

    age_days=$(( (now_epoch - backup_epoch) / 86400 ))

    if [[ $age_days -le 7 ]]; then
        _ok "Last backup: ${age_days} day(s) ago ($backup_name)"
    elif [[ $age_days -le 14 ]]; then
        _warn "Last backup: ${age_days} days ago — consider running a backup soon"
    else
        _fail "Last backup: ${age_days} days ago — overdue"
    fi
}

# ---------------------------------------------------------------------------
# usb_health_check MOUNT_POINT BACKUP_ROOT
# Public entry point called from pabs-status.sh.
# ---------------------------------------------------------------------------
usb_health_check() {
    local mount="$1"
    local backup_root="${2:-}"

    echo ""
    echo "--- USB Drive Health ---"

    # Resolve device paths
    local dev disk
    dev=$(_usb_get_device "$mount")
    if [[ -z "$dev" ]]; then
        _warn "USB health: cannot resolve device for $mount"
        return
    fi
    disk=$(_usb_get_disk "$dev")

    _ok "Device: $dev (disk: $disk)"

    # Run all four signal layers
    local health_score=0  # counts failures — used for final verdict

    _usb_check_ro_remount   "$mount"       || (( health_score++ )) || true
    _usb_check_dmesg        "$dev" "$disk" || (( health_score++ )) || true
    _usb_check_ext_superblock "$dev"       || (( health_score++ )) || true
    _usb_check_smart        "$disk"        || (( health_score++ )) || true

    [[ -n "$backup_root" ]] && _usb_backup_age_check "$backup_root"

    # Final verdict
    echo ""
    if [[ $health_score -eq 0 ]]; then
        _ok "Drive health verdict: no problems detected"
    elif [[ $health_score -eq 1 ]]; then
        _warn "Drive health verdict: 1 signal requires attention (see above)"
        _warn "    Consider replacing the drive and verifying your latest backup"
    else
        _fail "Drive health verdict: ${health_score} signals indicate drive problems"
        _fail "    Replace the drive. Verify your latest backup and enable offsite sync."
    fi
}
