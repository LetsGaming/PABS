#!/bin/bash
# setup/steps/usb.sh — Step 2: USB target, UUID, fstab, retention, staging

_step_usb() {
    [[ -n "$JUMP_STEP" && "$JUMP_STEP" != "usb" ]] && return
    _header "Step 2 of 7 — USB Backup Target"

    # --- Show block devices so the user knows what's connected ---
    _step "Connected block devices"
    echo ""
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,LABEL 2>/dev/null | head -30 | sed 's/^/    /'
    echo ""
    _info "Identify your USB drive above (look for a small removable disk)."
    _info "PABS requires ext4 — it is the only format that supports symlinks,"
    _info "Unix permissions, and filesystem health checks. See docs/usb-health.md."

    # --- Format ---
    _step "Format USB drive"
    _info "If your drive is already formatted as ext4 you can skip this step."
    _info "Formatting will ERASE ALL DATA on the selected partition."
    echo ""
    if _ask_yn "Format a partition as ext4 now?" "n"; then
        _info "Enter the partition to format (e.g. /dev/sde1)."
        _info "Double-check the device name above — this will erase everything on it."
        local format_dev
        format_dev=$(_ask "Partition to format (e.g. /dev/sde1)")

        if [[ -z "$format_dev" ]]; then
            _warn "No device entered — skipping format"
        elif [[ ! -b "$format_dev" ]]; then
            _warn "$format_dev is not a block device — skipping format"
        else
            local current_fstype
            current_fstype=$(blkid -s TYPE -o value "$format_dev" 2>/dev/null || echo "unknown")
            local current_label
            current_label=$(blkid -s LABEL -o value "$format_dev" 2>/dev/null || true)

            echo ""
            _warn "About to format $format_dev (currently: ${current_fstype}${current_label:+, label: $current_label})"
            _warn "ALL DATA ON $format_dev WILL BE PERMANENTLY ERASED."
            echo ""

            if _ask_yn "Are you sure? This cannot be undone" "n"; then
                _info "Unmounting $format_dev if currently mounted..."
                umount "$format_dev" 2>/dev/null || true

                local vol_label="PABS-BACKUP"
                _info "Formatting $format_dev as ext4 (label: $vol_label)..."

                if mkfs.ext4 -L "$vol_label" -m 0 "$format_dev" 2>&1 | sed 's/^/    /'; then
                    _ok "Formatted $format_dev as ext4 (label: $vol_label)"
                    _info "Enabling filesystem features for long-term USB use..."
                    # Disable automatic fsck after N mounts — unnecessary for a backup drive
                    # that PABS already monitors via the health check
                    tune2fs -c 0 -i 0 "$format_dev" >/dev/null 2>&1 \
                        && _ok "Disabled automatic fsck mount-count interval" || true
                else
                    _warn "mkfs.ext4 failed — check the device name and try again"
                fi
            else
                _info "Format cancelled"
            fi
        fi
    else
        _info "Skipping format — make sure the drive is already ext4 before running backups"
    fi

    # --- Mount point ---
    _step "Mount point"
    local current_mount
    current_mount=$(_cfg_get "USB_MOUNT")
    _info "This is the directory where your USB drive will be mounted."
    _info "Default (/mnt/backup-usb) is fine for most setups."

    local mount_point
    mount_point=$(_ask "Mount point path" "${current_mount:-/mnt/backup-usb}")

    if [[ "$mount_point" != "$current_mount" ]]; then
        _cfg_set "USB_MOUNT" "$mount_point"
        _ok "USB_MOUNT set to $mount_point"
    fi

    if [[ ! -d "$mount_point" ]]; then
        _info "Directory $mount_point does not exist yet."
        if _ask_yn "Create $mount_point now?"; then
            mkdir -p "$mount_point"
            _ok "Created $mount_point"
        fi
    fi

    # --- Mount the drive ---
    _step "Mount the USB drive"
    if mountpoint -q "$mount_point" 2>/dev/null; then
        _ok "Drive already mounted at $mount_point"
    else
        _warn "No drive is currently mounted at $mount_point"
        _info "To mount now, enter the partition device (e.g. /dev/sde1)."
        _info "Leave empty to skip — you can mount the drive and re-run this step later."
        local device
        device=$(_ask "Device to mount (empty to skip)")
        if [[ -n "$device" ]]; then
            if [[ -b "$device" ]]; then
                if mount "$device" "$mount_point"; then
                    _ok "Mounted $device at $mount_point"
                else
                    _warn "Mount failed — check the device name and filesystem type"
                fi
            else
                _warn "$device is not a block device — skipping mount"
                _info "Available devices shown in the list above (look for your USB partition)"
            fi
        else
            _info "Skipping mount — remember to mount the USB before running backups"
        fi
    fi

    # --- UUID detection & targeting ---
    _step "UUID targeting (recommended)"
    local current_uuid
    current_uuid=$(_cfg_get "TARGET_UUID")

    if [[ -n "$current_uuid" ]]; then
        _ok "TARGET_UUID already set: $current_uuid"
    else
        local detected_uuid=""
        if mountpoint -q "$mount_point" 2>/dev/null; then
            local dev
            dev=$(findmnt -n -o SOURCE "$mount_point" 2>/dev/null || true)
            [[ -n "$dev" ]] && detected_uuid=$(blkid -s UUID -o value "$dev" 2>/dev/null || true)
        fi

        if [[ -n "$detected_uuid" ]]; then
            _info "UUID protects against accidentally writing to the wrong drive."
            _ok "Detected UUID: $detected_uuid"
            if _ask_yn "Lock backups to this UUID? (strongly recommended)"; then
                _cfg_set "TARGET_UUID" "$detected_uuid"
                _ok "TARGET_UUID set to $detected_uuid"
            else
                _warn "No UUID set — PABS will write to any drive mounted at $mount_point"
            fi
        else
            _warn "Cannot detect UUID (drive may not be mounted)."
            _info "You can set TARGET_UUID manually — run 'blkid /dev/sdX1' to find it."
            local manual_uuid
            manual_uuid=$(_ask "UUID (leave empty to skip)")
            if [[ -n "$manual_uuid" ]]; then
                _cfg_set "TARGET_UUID" "$manual_uuid"
                _ok "TARGET_UUID set to $manual_uuid"
            else
                _warn "No UUID set — PABS will write to any drive mounted at $mount_point"
            fi
        fi
    fi

    # --- fstab ---
    _step "Auto-mount on boot"
    local uuid_for_fstab
    uuid_for_fstab=$(_cfg_get "TARGET_UUID")

    if [[ -n "$uuid_for_fstab" ]]; then
        if grep -q "$uuid_for_fstab" /etc/fstab 2>/dev/null; then
            _ok "fstab entry already present — USB will auto-mount on boot"
        else
            _info "Without an fstab entry, you must manually run 'mount $mount_point'"
            _info "before each backup (or the cron job will fail)."
            if _ask_yn "Add fstab entry so the USB auto-mounts on boot? (recommended)"; then
                local dev_for_fs fs_type
                dev_for_fs=$(blkid -U "$uuid_for_fstab" 2>/dev/null || true)
                fs_type=$(blkid -s TYPE -o value "$dev_for_fs" 2>/dev/null || echo "auto")
                echo "UUID=$uuid_for_fstab  $mount_point  $fs_type  defaults,nofail  0  0" >> /etc/fstab
                _ok "fstab entry added (filesystem: $fs_type)"
                _info "Run 'mount -a' to activate without rebooting"
            fi
        fi
    else
        _info "Skipping fstab (no TARGET_UUID set)"
    fi

    # --- Retention ---
    _step "Backup retention"
    local current_keep
    current_keep=$(_cfg_get "KEEP_BACKUPS")
    _info "How many completed backups to keep on the USB drive."
    _info "Older backups are deleted automatically to free space."

    local keep
    keep=$(_ask "Number of backups to keep" "${current_keep:-4}")
    if [[ "$keep" != "$current_keep" ]]; then
        _cfg_set_raw "KEEP_BACKUPS" "$keep"
        _ok "Will keep $keep backup(s) on USB"
    fi

    # --- Staging directory ---
    _step "Local staging directory"
    _info "PABS assembles each backup here (on the Proxmox host's own disk) before"
    _info "writing to USB in a single fast pass. This avoids USB wear from small writes."
    echo ""

    local current_stage suggestion="/var/tmp/pabs-stage"
    current_stage=$(_cfg_get "LOCAL_STAGE_BASE")

    local root_avail_gb
    root_avail_gb=$(df -BG / --output=avail 2>/dev/null | tail -1 | tr -d 'G ' || echo 0)
    if [[ "$root_avail_gb" =~ ^[0-9]+$ && "$root_avail_gb" -lt 20 ]]; then
        _warn "Root partition only has ${root_avail_gb}GB free — staging there may be tight."
        if command -v zpool &>/dev/null && zpool list &>/dev/null 2>&1; then
            local pool
            pool=$(zpool list -H -o name 2>/dev/null | head -1 || true)
            if [[ -n "$pool" ]]; then
                suggestion="/rpool/data/pabs-stage"
                _info "ZFS detected — suggested path: $suggestion"
            fi
        fi
        if ls /mnt/pve/ &>/dev/null 2>&1; then
            _info "Proxmox storage detected under /mnt/pve/ — that's another option."
        fi
    else
        _info "Root has ${root_avail_gb}GB free — default staging path is fine."
    fi

    _info "This must be a directory path (e.g. /var/tmp/pabs-stage)."
    _info "It needs ~500 MB – 3 GB free space (more if you have large VM agents)."

    local stage_dir
    stage_dir=$(_ask "Staging directory path" "${current_stage:-$suggestion}")
    if [[ "$stage_dir" != "$current_stage" ]]; then
        _cfg_set "LOCAL_STAGE_BASE" "$stage_dir"
        _ok "Staging directory set to $stage_dir"
    fi

    echo ""
    _ok "USB configuration complete"
}
