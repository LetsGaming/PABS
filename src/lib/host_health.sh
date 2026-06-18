#!/bin/bash
# =============================================================================
# src/lib/host_health.sh — Proxmox host drive health assessment
#
# Sourced by pabs-status.sh. Entry point: host_health_check
#
# Checks the drives that the Proxmox host itself runs on — the drives whose
# silent failure causes the exact data-loss scenario PABS exists to prevent.
#
# Signal layers (checked per device, in order of reliability):
#   1. Kernel I/O error log  — dmesg errors for this device (always works)
#   2. Filesystem state      — ro-remount detection (always works)
#   3. Filesystem errors     — ext4 superblock counters OR zpool status
#   4. SMART overall health  — smartctl PASSED/FAILED (direct-attach, reliable)
#   5. SMART critical attrs  — reallocated sectors, pending sectors, uncorrectable
#   6. NVMe-specific health  — nvme smart-log: critical_warning, percentage_used
#
# Unlike USB drives, direct-attached SATA/NVMe drives expose SMART attributes
# reliably. Signals 5 and 6 are therefore included here but deliberately
# omitted from usb_health.sh.
# =============================================================================

# ---------------------------------------------------------------------------
# _host_get_root_devices → prints one /dev/xxx per line
#
# Finds the block devices backing /, /var, and key Proxmox paths.
# Deduplicates — if / and /var are on the same device, it's returned once.
# Handles:
#   - Plain partitions:  /dev/sda2, /dev/nvme0n1p3
#   - LVM logical vols:  /dev/mapper/pve-root  → traces back to /dev/sda etc.
#   - ZFS pools:         detected separately via zpool status
# ---------------------------------------------------------------------------
_host_get_root_devices() {
    local seen=()

    for mountpoint in / /var /var/lib/pve /etc/pve; do
        [[ -d "$mountpoint" ]] || continue

        local source fstype
        source=$(findmnt -n -o SOURCE "$mountpoint" 2>/dev/null | head -1)
        [[ -z "$source" ]] && continue

        fstype=$(findmnt -n -o FSTYPE "$mountpoint" 2>/dev/null | head -1)

        # ZFS — handled separately; skip here
        [[ "$fstype" == "zfs" ]] && continue

        # LVM mapper device — trace back to physical disk(s)
        if [[ "$source" == /dev/mapper/* ]]; then
            local lv_name
            lv_name=$(basename "$source")
            # Get the VG name, then find its PVs
            local vg_name
            vg_name=$(lvs --noheadings -o vg_name "$source" 2>/dev/null | tr -d ' ' | head -1)
            if [[ -n "$vg_name" ]]; then
                while IFS= read -r pv; do
                    [[ -z "$pv" ]] && continue
                    local disk
                    disk=$(_host_get_disk "$pv")
                    # Deduplicate
                    local already_seen=false
                    for s in "${seen[@]:-}"; do [[ "$s" == "$disk" ]] && already_seen=true; done
                    if [[ "$already_seen" == "false" ]]; then
                        seen+=("$disk")
                        echo "$disk"
                    fi
                done < <(pvs --noheadings -o pv_name --select "vg_name=$vg_name" 2>/dev/null | tr -d ' ')
                continue
            fi
        fi

        # Plain partition — get parent disk
        local disk
        disk=$(_host_get_disk "$source")
        local already_seen=false
        for s in "${seen[@]:-}"; do [[ "$s" == "$disk" ]] && already_seen=true; done
        if [[ "$already_seen" == "false" ]]; then
            seen+=("$disk")
            echo "$disk"
        fi
    done
}

# ---------------------------------------------------------------------------
# _host_get_disk PARTITION → /dev/sda or /dev/nvme0n1
# ---------------------------------------------------------------------------
_host_get_disk() {
    local dev="$1"
    local pkname
    pkname=$(lsblk -no PKNAME "$dev" 2>/dev/null | head -1)
    if [[ -n "$pkname" ]]; then
        echo "/dev/$pkname"
    else
        echo "$dev" | sed -E 's/p?[0-9]+$//'
    fi
}

# ---------------------------------------------------------------------------
# Signal 1: Kernel I/O error log
#
# NVMe drives appear as nvme0, nvme0n1, nvme0n1p1 in dmesg.
# SATA drives appear as sda, sda1 etc.
# We search for the disk name to catch all partitions and the raw device.
# ---------------------------------------------------------------------------
_host_check_dmesg() {
    local disk="$1"
    local disk_name
    disk_name=$(basename "$disk")

    # NVMe controller name differs from namespace name: nvme0n1 → also check nvme0
    local ctrl_name="$disk_name"
    [[ "$disk_name" =~ ^nvme([0-9]+)n ]] && ctrl_name="nvme${BASH_REMATCH[1]}"

    local error_pattern="I/O error.*${disk_name}|blk_update_request.*${disk_name}|EXT.-fs error.*${disk_name}|${disk_name}.*error|nvme.*error.*${ctrl_name}|${ctrl_name}.*failed|Buffer I/O error.*${disk_name}"

    # Source the kernel log. Prefer journalctl -k -b (the persistent journal for
    # the current boot) when available — dmesg reads a fixed-size ring buffer
    # that can wrap and silently drop old errors on busy systems. Fall back to
    # dmesg where journald isn't present.
    local log_source="kernel ring buffer"
    local kernel_log
    if command -v journalctl &>/dev/null && journalctl -k -b -n0 &>/dev/null; then
        kernel_log=$(journalctl -k -b --no-pager 2>/dev/null || true)
        log_source="kernel journal (this boot)"
    else
        kernel_log=$(dmesg 2>/dev/null || true)
    fi

    local error_lines
    error_lines=$(printf '%s\n' "$kernel_log" \
        | grep -iE "$error_pattern" \
        | grep -v "^$" \
        | tail -5 \
        || true)

    local error_count=0
    [[ -n "$error_lines" ]] && error_count=$(echo "$error_lines" | wc -l)

    if [[ $error_count -eq 0 ]]; then
        _ok  "  Kernel log: no I/O errors for $disk_name (${log_source})"
    else
        _fail "  Kernel log: ${error_count} I/O error(s) for $disk_name (${log_source})"
        echo "$error_lines" | while IFS= read -r line; do
            echo "          $line"
        done
        _fail "      This is a strong indicator of hardware failure — back up immediately"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Signal 2: Root filesystem read-only remount
# ---------------------------------------------------------------------------
_host_check_ro_remount() {
    for mount in / /var /var/lib/pve; do
        [[ -d "$mount" ]] || continue
        if grep -qE "^[^ ]+ $mount [^ ]+ ro[,]" /proc/mounts 2>/dev/null; then
            _fail "  Filesystem: $mount is mounted READ-ONLY — kernel detected errors"
            _fail "      Proxmox may be in a degraded state. Replace the drive immediately."
            return 1
        fi
    done
    _ok "  Filesystem: root mounts are read-write (no forced remount)"
}

# ---------------------------------------------------------------------------
# Signal 3a: ext4 superblock error counters
# ---------------------------------------------------------------------------
_host_check_ext_superblock() {
    local disk="$1"

    # Find the root partition device (not the disk — dumpe2fs needs the partition)
    local root_dev
    root_dev=$(findmnt -n -o SOURCE / 2>/dev/null | head -1)
    [[ -z "$root_dev" ]] && return 0

    # For LVM, skip — the PV layer doesn't have ext superblock
    [[ "$root_dev" == /dev/mapper/* ]] && return 0

    local fs_type
    fs_type=$(blkid -s TYPE -o value "$root_dev" 2>/dev/null || true)
    [[ "$fs_type" != ext2 && "$fs_type" != ext3 && "$fs_type" != ext4 ]] && return 0

    command -v dumpe2fs &>/dev/null || return 0

    local sb
    sb=$(dumpe2fs -h "$root_dev" 2>/dev/null || true)
    [[ -z "$sb" ]] && return 0

    local error_count
    error_count=$(echo "$sb" | grep -i "FS Error count:" | awk '{print $NF}' || echo 0)
    error_count="${error_count:-0}"

    if [[ "$error_count" =~ ^[0-9]+$ && "$error_count" -gt 0 ]]; then
        _fail "  Filesystem errors: $error_count error(s) in $fs_type superblock on $root_dev"
        _fail "      Run 'fsck -n $root_dev' (unmounted) to inspect"
        return 1
    else
        local last_checked
        last_checked=$(echo "$sb" | grep "^Last checked:" | sed 's/Last checked:[ \t]*//' || echo "unknown")
        _ok "  Filesystem errors: $fs_type superblock reports 0 errors (last check: $last_checked)"
    fi
}

# ---------------------------------------------------------------------------
# Signal 3b: ZFS pool health
# ---------------------------------------------------------------------------
_host_check_zfs() {
    command -v zpool &>/dev/null || return 0

    local pools
    pools=$(zpool list -H -o name 2>/dev/null || true)
    [[ -z "$pools" ]] && return 0

    while IFS= read -r pool; do
        local health
        health=$(zpool list -H -o health "$pool" 2>/dev/null || echo "UNKNOWN")
        local errors
        errors=$(zpool status "$pool" 2>/dev/null | grep -c "FAULTED\|DEGRADED\|errors:" || true)

        if [[ "$health" == "ONLINE" ]]; then
            _ok "  ZFS pool $pool: ONLINE"
        elif [[ "$health" == "DEGRADED" ]]; then
            _fail "  ZFS pool $pool: DEGRADED — check 'zpool status $pool'"
            return 1
        else
            _warn "  ZFS pool $pool: $health — check 'zpool status $pool'"
        fi
    done <<< "$pools"
}

# ---------------------------------------------------------------------------
# Signal 4: SMART overall health (reliable for direct-attached drives)
# ---------------------------------------------------------------------------
_host_check_smart_health() {
    local disk="$1"

    command -v smartctl &>/dev/null || {
        _warn "  SMART: smartctl not installed — apt install smartmontools"
        _warn "      SMART monitoring is strongly recommended for host drives"
        return 0
    }

    local smart_output
    smart_output=$(smartctl -H "$disk" 2>&1) || true

    if echo "$smart_output" | grep -q "Permission denied\|No such device"; then
        _warn "  SMART: cannot access $disk (run as root)"
        return 0
    fi

    if echo "$smart_output" | grep -q "SMART support is: Unavailable\|Unable to detect"; then
        _warn "  SMART: not supported by $disk"
        return 0
    fi

    if echo "$smart_output" | grep -q "SMART overall-health self-assessment test result: PASSED"; then
        _ok "  SMART: overall health PASSED"
        return 0
    fi

    if echo "$smart_output" | grep -q "SMART overall-health self-assessment test result: FAILED"; then
        _fail "  SMART: overall health FAILED — drive is predicting imminent failure"
        _fail "      Back up immediately and replace the drive"
        return 1
    fi

    _warn "  SMART: health status could not be determined for $disk"
}

# ---------------------------------------------------------------------------
# Signal 5: SMART critical attributes (SATA/SAS)
#
# Attributes that definitively indicate physical media damage:
#   ID 5   — Reallocated Sectors Count (sectors remapped due to read errors)
#   ID 187  — Reported Uncorrectable Errors
#   ID 197  — Current Pending Sector Count (sectors awaiting reallocation)
#   ID 198  — Offline Uncorrectable Sector Count
#
# Any non-zero value in these is a serious warning. Unlike SMART overall health,
# a drive can pass the overall test while already accumulating bad sectors.
# ---------------------------------------------------------------------------
_host_check_smart_attrs() {
    local disk="$1"

    command -v smartctl &>/dev/null || return 0

    # NVMe uses a different interface — handled in signal 6
    local drive_type
    drive_type=$(smartctl -i "$disk" 2>/dev/null | grep -i "Transport protocol\|NVMe" || true)
    [[ "$drive_type" =~ NVMe ]] && return 0

    local attrs
    attrs=$(smartctl -A "$disk" 2>/dev/null || true)
    [[ -z "$attrs" ]] && return 0

    local found_critical=false

    # Check each critical attribute — ID followed by name, flags, value, worst, threshold, raw
    while IFS= read -r line; do
        local id raw_val attr_name
        id=$(echo "$line" | awk '{print $1}')
        attr_name=$(echo "$line" | awk '{print $2}')
        raw_val=$(echo "$line" | awk '{print $NF}')

        # Raw value may be hex or decimal; treat as integer
        raw_val=$(echo "$raw_val" | sed 's/^0x//' | grep -E '^[0-9]+$' || echo 0)
        raw_val="${raw_val:-0}"

        if [[ "$raw_val" =~ ^[0-9]+$ && "$raw_val" -gt 0 ]]; then
            _fail "  SMART attr: $attr_name (ID $id) = $raw_val — non-zero indicates media damage"
            found_critical=true
        fi
    done < <(echo "$attrs" | grep -E "^\s*(5|187|197|198)\s+" || true)

    if [[ "$found_critical" == "false" ]]; then
        _ok "  SMART attrs: reallocated=0, pending=0, uncorrectable=0"
    else
        _fail "      Non-zero critical SMART attributes are a strong failure predictor"
        _fail "      Do not ignore these. Back up now and replace the drive."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Signal 6: NVMe-specific health (nvme-cli smart-log)
#
# NVMe drives expose health via a dedicated log page, not SMART attributes.
# Key fields:
#   critical_warning     — bitmask; any non-zero bit = serious problem
#                           bit 0: spare capacity below threshold
#                           bit 1: temperature above threshold
#                           bit 2: NVM subsystem reliability degraded
#                           bit 3: media in read-only mode
#                           bit 4: volatile memory backup failed
#   percentage_used      — drive's own wear estimate; 100+ = rated lifetime exceeded
#   available_spare      — drops as NAND wears out; warn below threshold
#   media_errors         — uncorrectable read errors (like SMART ID 198 for SATA)
#   num_err_log_entries  — accumulated error log entries
# ---------------------------------------------------------------------------
_host_check_nvme_health() {
    local disk="$1"

    # Only run on NVMe devices
    [[ "$disk" =~ /dev/nvme ]] || return 0

    if ! command -v nvme &>/dev/null; then
        _warn "  NVMe health: nvme-cli not installed — apt install nvme-cli"
        _warn "      NVMe health monitoring is strongly recommended for NVMe host drives"
        return 0
    fi

    local smart_log
    smart_log=$(nvme smart-log "$disk" 2>/dev/null || true)
    [[ -z "$smart_log" ]] && {
        _warn "  NVMe health: could not read smart-log from $disk"
        return 0
    }

    local failed=false

    # Critical warning bitmask
    local crit_warn
    crit_warn=$(echo "$smart_log" | grep -i "critical_warning" | awk '{print $NF}' | tr -d ',' || echo 0)
    crit_warn="${crit_warn:-0}"
    # Handle hex values
    if [[ "$crit_warn" =~ ^0x ]]; then
        crit_warn=$(( 16#${crit_warn#0x} ))
    fi
    if [[ "$crit_warn" =~ ^[0-9]+$ && "$crit_warn" -gt 0 ]]; then
        _fail "  NVMe: critical_warning = $crit_warn (non-zero — drive has active health alert)"
        # Decode the bits for the user
        (( crit_warn & 1  )) && _fail "      bit 0: available spare below threshold"
        (( crit_warn & 2  )) && _fail "      bit 1: temperature above threshold"
        (( crit_warn & 4  )) && _fail "      bit 2: NVM subsystem reliability degraded"
        (( crit_warn & 8  )) && _fail "      bit 3: media placed in read-only mode"
        (( crit_warn & 16 )) && _fail "      bit 4: volatile memory backup device failed"
        failed=true
    else
        _ok "  NVMe: critical_warning = 0 (no active alerts)"
    fi

    # Percentage used — drive's own wear estimate
    local pct_used
    pct_used=$(echo "$smart_log" | grep -i "^percentage_used\|^Percentage Used" | awk '{print $NF}' | tr -d '%,' || echo "?")
    if [[ "$pct_used" =~ ^[0-9]+$ ]]; then
        if [[ "$pct_used" -ge 100 ]]; then
            _fail "  NVMe: percentage_used = ${pct_used}% — rated write lifetime exceeded"
            failed=true
        elif [[ "$pct_used" -ge 90 ]]; then
            _warn "  NVMe: percentage_used = ${pct_used}% — approaching rated write lifetime"
        else
            _ok "  NVMe: percentage_used = ${pct_used}%"
        fi
    fi

    # Available spare
    local avail_spare spare_thresh
    avail_spare=$(echo  "$smart_log" | grep -i "^available_spare\b" | awk '{print $NF}' | tr -d '%,' || echo "?")
    spare_thresh=$(echo "$smart_log" | grep -i "^available_spare_threshold\|spare_thresh" | awk '{print $NF}' | tr -d '%,' || echo "10")
    if [[ "$avail_spare" =~ ^[0-9]+$ && "$spare_thresh" =~ ^[0-9]+$ ]]; then
        if [[ "$avail_spare" -le "$spare_thresh" ]]; then
            _fail "  NVMe: available_spare = ${avail_spare}% (at or below threshold ${spare_thresh}%)"
            failed=true
        else
            _ok "  NVMe: available_spare = ${avail_spare}% (threshold: ${spare_thresh}%)"
        fi
    fi

    # Media errors
    local media_errors
    media_errors=$(echo "$smart_log" | grep -i "^media_errors\|^Media Errors" | awk '{print $NF}' | tr -d ',' || echo 0)
    media_errors="${media_errors:-0}"
    if [[ "$media_errors" =~ ^[0-9]+$ && "$media_errors" -gt 0 ]]; then
        _fail "  NVMe: media_errors = $media_errors — uncorrectable read errors detected"
        failed=true
    else
        _ok "  NVMe: media_errors = 0"
    fi

    # Error log entries — informational, warn only if growing
    local err_entries
    err_entries=$(echo "$smart_log" | grep -i "^num_err_log_entries\|^Error Information Log Entries" | awk '{print $NF}' | tr -d ',' || echo 0)
    err_entries="${err_entries:-0}"
    if [[ "$err_entries" =~ ^[0-9]+$ && "$err_entries" -gt 0 ]]; then
        _warn "  NVMe: num_err_log_entries = $err_entries — check 'nvme error-log $disk' for details"
    fi

    [[ "$failed" == "true" ]] && return 1
    return 0
}

# ---------------------------------------------------------------------------
# host_health_check
# Public entry point called from pabs-status.sh.
# Discovers all devices backing the Proxmox host root filesystem and checks
# each one through all applicable signal layers.
# ---------------------------------------------------------------------------
host_health_check() {
    echo ""
    echo "--- Host Drive Health ---"

    local devices
    mapfile -t devices < <(_host_get_root_devices)

    if [[ ${#devices[@]} -eq 0 ]]; then
        _warn "Host health: could not identify host block device(s) — skipping"
        _warn "    Manual check: smartctl -a <device> and dmesg | grep -i error"
        return
    fi

    # ZFS check is pool-level, not per-device
    _host_check_zfs

    local total_score=0

    for disk in "${devices[@]}"; do
        echo ""
        _ok "Checking device: $disk"

        local score=0
        _host_check_dmesg         "$disk" || (( score++ )) || true
        _host_check_ro_remount           || (( score++ )) || true
        _host_check_ext_superblock "$disk" || (( score++ )) || true
        _host_check_smart_health  "$disk" || (( score++ )) || true
        _host_check_smart_attrs   "$disk" || (( score++ )) || true
        _host_check_nvme_health   "$disk" || (( score++ )) || true

        (( total_score += score )) || true

        echo ""
        if [[ $score -eq 0 ]]; then
            _ok "$disk: no problems detected"
        elif [[ $score -eq 1 ]]; then
            _warn "$disk: 1 signal requires attention (see above)"
        else
            _fail "$disk: ${score} warning signals — review all items above"
        fi
    done

    # Overall verdict
    echo ""
    if [[ $total_score -eq 0 ]]; then
        _ok "Host drive verdict: all host drive(s) healthy"
    elif [[ $total_score -le 2 ]]; then
        _warn "Host drive verdict: ${total_score} signal(s) require attention"
        _warn "    Monitor closely and consider scheduling a full backup immediately"
    else
        _fail "Host drive verdict: ${total_score} warning signals across host drive(s)"
        _fail "    This system is at risk of data loss. Back up immediately."
        _fail "    Consider running: bash /opt/pabs/backup.sh"
    fi
}
