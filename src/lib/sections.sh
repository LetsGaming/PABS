#!/bin/bash
# =============================================================================
# lib/sections.sh — Backup section functions (1/8 through 8/8)
#
# Each section_*() function stages one logical group of data into STAGE_DIR.
# Helpers backup_path() and backup_cmd_output() are defined here too since
# they're only used by the section functions.
# =============================================================================

# -----------------------------------------------------------------------------
# HELPERS
# -----------------------------------------------------------------------------

# Copy a filesystem path into the local staging tree, preserving its absolute
# path via rsync's --relative flag.
backup_path() {
    local src="$1"
    local label="$2"

    if [[ -e "$src" ]]; then
        if rsync -a --relative "$src" "$STAGE_DIR/" 2>>"$LOG"; then
            log "  ✓ $label"
        else
            log_err "rsync failed: $src — $label"
        fi
    else
        log_warn "Not found, skipped: $src — $label"
    fi
}

# Run a command and write its stdout to a relative path inside the staging tree.
# Usage: backup_cmd_output "relative/dest.txt" "Label" command [args...]
backup_cmd_output() {
    local dest_relative="$1"
    local label="$2"
    shift 2

    local dest="$STAGE_DIR/$dest_relative"
    mkdir -p "$(dirname "$dest")"

    if "$@" > "$dest" 2>>"$LOG"; then
        log "  ✓ $label"
    else
        log_warn "$label — command failed or partially failed"
    fi
}

# -----------------------------------------------------------------------------
# SECTION 1: Proxmox core configs
# -----------------------------------------------------------------------------

section_proxmox_configs() {
    log "[1/8] Proxmox core configs"

    # /etc/pve is a pmxcfs FUSE filesystem backed by SQLite.
    # tar reads the directory tree in one uninterrupted pass, avoiding the
    # edge-case lockups that rsync can trigger against a live pmxcfs mount.
    # --warning=no-file-ignored suppresses non-fatal noise from FUSE sockets
    # and named pipes that tar cannot serialize and skips automatically.
    # We do NOT suppress --warning=no-file-changed because a file changing
    # while being read is a genuine data integrity signal worth logging.
    local pve_tar="$STAGE_DIR/etc-pve.tar"
    if tar --warning=no-file-ignored -C / -cf "$pve_tar" etc/pve 2>>"$LOG"; then
        log "  ✓ /etc/pve (tar snapshot)"
    else
        log_err "/etc/pve tar failed"
    fi

    backup_path "/etc/network/interfaces"   "Network interfaces"
    backup_path "/etc/network/interfaces.d" "Network interfaces.d"
    backup_path "/etc/hosts"                "Hosts file"
    backup_path "/etc/hostname"             "Hostname"
    backup_path "/etc/resolv.conf"          "DNS resolver config"
    # /etc/apt/sources.list is absent on Debian 12+ (everything is in sources.list.d)
    [[ -e /etc/apt/sources.list ]] && backup_path "/etc/apt/sources.list" "APT sources.list"
    backup_path "/etc/apt/sources.list.d"   "APT sources.list.d"
}

# -----------------------------------------------------------------------------
# SECTION 2: VM and container definitions
# -----------------------------------------------------------------------------

section_vm_ct_definitions() {
    log "[2/8] VM and container definitions"

    local vm_dest="$STAGE_DIR/vm-ct-definitions"
    mkdir -p "$vm_dest/vms" "$vm_dest/containers"

    # Export individual configs via qm/pct for human-readable restore reference.
    # Raw config files from pmxcfs are also copied as a secondary source.
    local vm_count=0
    while IFS= read -r vmid; do
        [[ -z "$vmid" ]] && continue
        if qm config "$vmid" > "$vm_dest/vms/vm-${vmid}.conf" 2>>"$LOG"; then
            log "  ✓ VM $vmid"
            : $(( vm_count++ ))
        else
            log_warn "Could not export config for VM $vmid"
        fi
    done < <(qm list 2>/dev/null | awk 'NR>1{print $1}')

    local ct_count=0
    while IFS= read -r ctid; do
        [[ -z "$ctid" ]] && continue
        if pct config "$ctid" > "$vm_dest/containers/ct-${ctid}.conf" 2>>"$LOG"; then
            log "  ✓ CT $ctid"
            : $(( ct_count++ ))
        else
            log_warn "Could not export config for CT $ctid"
        fi
    done < <(pct list 2>/dev/null | awk 'NR>1{print $1}')

    log "  VMs: $vm_count  CTs: $ct_count"

    backup_path "/etc/pve/qemu-server" "Raw VM qemu-server configs"
    backup_path "/etc/pve/lxc"         "Raw CT lxc configs"
}

# -----------------------------------------------------------------------------
# SECTION 3: Cron jobs
# -----------------------------------------------------------------------------

section_cron_jobs() {
    log "[3/8] Cron jobs"
    backup_path "/etc/crontab"              "System crontab"
    backup_path "/etc/cron.d"              "Cron.d jobs"
    backup_path "/etc/cron.daily"          "Daily cron jobs"
    backup_path "/etc/cron.weekly"         "Weekly cron jobs"
    backup_path "/var/spool/cron/crontabs" "User crontabs"
}

# -----------------------------------------------------------------------------
# SECTION 4: Firewall rules
# -----------------------------------------------------------------------------

section_firewall() {
    log "[4/8] Firewall rules"
    backup_path "/etc/nftables.conf" "nftables rules"
    # /etc/iptables is absent on systems using nftables — skip silently
    [[ -e /etc/iptables ]] && backup_path "/etc/iptables" "iptables rules"
    backup_path "/etc/pve/firewall"  "Proxmox firewall rules"
}

# -----------------------------------------------------------------------------
# SECTION 5: SSH keys and daemon config
# -----------------------------------------------------------------------------

section_ssh_keys() {
    log "[5/8] SSH keys and daemon config"
    backup_path "/etc/ssh/sshd_config"   "SSH daemon config"
    backup_path "/etc/ssh/sshd_config.d" "SSH daemon config.d"
    backup_path "/root/.ssh"             "Root SSH keys / authorized_keys"
}

# -----------------------------------------------------------------------------
# SECTION 6: System state snapshot
# -----------------------------------------------------------------------------

section_system_state() {
    log "[6/8] System state snapshot"
    local s="system-state"
    mkdir -p "$STAGE_DIR/$s"

    # Package state — lets you reproduce the exact package set:
    #   dpkg --set-selections < dpkg-selections.txt && apt-get dselect-upgrade
    backup_cmd_output "$s/dpkg-selections.txt"   "Installed packages"          dpkg --get-selections
    backup_cmd_output "$s/apt-holds.txt"         "APT held packages"           apt-mark showhold
    backup_cmd_output "$s/apt-manual.txt"        "Manually installed packages" apt-mark showmanual

    backup_cmd_output "$s/proxmox-version.txt"   "Proxmox version"             pveversion --verbose
    backup_cmd_output "$s/kernel-version.txt"    "Kernel version"              uname -r
    backup_cmd_output "$s/disk-layout-lsblk.txt" "Disk layout (lsblk)" \
        lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,UUID
    backup_cmd_output "$s/disk-layout-fdisk.txt" "Disk layout (fdisk -l)"     fdisk -l

    backup_path "/etc/fstab" "fstab"

    if [[ "$BACKUP_ZFS" == "true" ]]; then
        backup_cmd_output "$s/zfs-pool-status.txt"       "ZFS pool status"               zpool status
        backup_cmd_output "$s/zfs-pool-status-by-id.txt" "ZFS pool status (by-id paths)" zpool status -P
        backup_cmd_output "$s/zfs-pool-list.txt"         "ZFS pool list"                 zpool list -v
        backup_cmd_output "$s/zfs-dataset-list.txt"      "ZFS dataset list"              zfs list -t all

        local zfs_dir="$STAGE_DIR/$s/zfs-configs"
        mkdir -p "$zfs_dir"
        while IFS= read -r pool; do
            [[ -z "$pool" ]] && continue
            zpool get all "$pool" > "$zfs_dir/${pool}-properties.txt" 2>>"$LOG" \
                && log "  ✓ ZFS pool properties: $pool" \
                || log_warn "ZFS pool property export failed: $pool"
        done < <(zpool list -H -o name 2>/dev/null)
    fi

    # LVM — export human-readable summaries and a machine-readable vgcfgbackup
    # that can be restored with: vgcfgrestore -f lvm-vg-<name>.cfg <vg-name>
    if command -v vgs &>/dev/null && vgs &>/dev/null; then
        backup_cmd_output "$s/lvm-pvs.txt" "LVM physical volumes" bash -c 'exec 9>&-; pvs --units b --nosuffix'
        backup_cmd_output "$s/lvm-vgs.txt" "LVM volume groups"    bash -c 'exec 9>&-; vgs --units b --nosuffix'
        backup_cmd_output "$s/lvm-lvs.txt" "LVM logical volumes"  bash -c 'exec 9>&-; lvs --units b --nosuffix'
        ( exec 9>&-; vgcfgbackup -f "$STAGE_DIR/$s/lvm-vg-%s.cfg" ) 2>>"$LOG" \
            && log "  ✓ LVM VG configs (restorable with vgcfgrestore)" \
            || log_warn "LVM vgcfgbackup failed (non-fatal)"
    fi
}

# -----------------------------------------------------------------------------
# SECTION 7: Custom scripts
# -----------------------------------------------------------------------------

section_custom_scripts() {
    log "[7/8] Custom scripts"
    backup_path "/usr/local/bin" "Custom scripts in /usr/local/bin"
    # /root/scripts is optional — skip silently if not present
    [[ -e /root/scripts ]] && backup_path "/root/scripts" "Root scripts folder"

    # back up the backup script itself so it travels with the backup
    local pabs_root
    pabs_root="$(realpath "${BASH_SOURCE[0]%/lib/*}")"
    backup_path "$pabs_root/backup.sh" "backup.sh"

    # config.sh is backed up with secrets redacted — the restored copy is useful
    # for reference (paths, SSH opts, flags) but must not expose credentials if
    # the USB medium is lost or shared.  The original on the host is not modified.
    local config_src="$pabs_root/config.sh"
    local config_dest="$STAGE_DIR/config.sh"

    if [[ -f "$config_src" ]]; then
        sed \
            -e 's|\(DISCORD_WEBHOOK=\)"\([^"]\+\)"|\1"<REDACTED>"|g' \
            -e 's|\(NOTIFY_EMAIL=\)"\([^"]\+\)"|\1"<REDACTED>"|g' \
            -e 's|\(PORTAINER_TOKEN=\)"\([^"]\+\)"|\1"<REDACTED>"|g' \
            -e 's|\(RCLONE_ENCRYPTION_PASSWORD=\)"\([^"]\+\)"|\1"<REDACTED>"|g' \
            -e '/[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]\|[Ss][Ee][Cc][Rr][Ee][Tt]\|_TOKEN\|_KEY\|WEBHOOK/s|="\([^"]\{4,\}\)"|="<REDACTED>"|g' \
            "$config_src" > "$config_dest"
        chmod 600 "$config_dest"
        log "  ✓ config.sh (secrets redacted)"
    else
        log_warn "config.sh not found at $config_src — skipping"
    fi
}

# -----------------------------------------------------------------------------
# SECTION 8: VM / LXC agent backups
# -----------------------------------------------------------------------------

section_vm_agents() {
    log "[8/8] VM agent backups"

    if [[ ${#VM_AGENTS[@]} -eq 0 ]]; then
        log "  No VM_AGENTS configured — skipping"
        return
    fi

    local total_ok=0 total_fail=0 total_skip=0
    local max_parallel="${VM_AGENT_MAX_PARALLEL:-1}"
    local pids=()

    _run_agent() {
        local entry="$1"
        local label vm_host ssh_user agent_path
        read -r label vm_host ssh_user agent_path <<< "$entry"

        if [[ -z "$label" || -z "$vm_host" || -z "$ssh_user" || -z "$agent_path" ]]; then
            log "  ⚠  Skipping malformed VM_AGENTS entry: '$entry'"
            return 2
        fi

        log "  [$label] $ssh_user@$vm_host"

        local ssh_opts=("${VM_AGENT_SSH_OPTS[@]}")
        local key_var="VM_SSH_KEY_${label//-/_}"
        [[ -n "${!key_var:-}" ]] && ssh_opts+=(-i "${!key_var}")
        [[ -n "${VM_SSH_KEY:-}" && -z "${!key_var:-}" ]] && ssh_opts+=(-i "$VM_SSH_KEY")

        if ! ssh "${ssh_opts[@]}" "$ssh_user@$vm_host" exit 2>/dev/null; then
            log "  ✗  [$label] Cannot connect to $vm_host — skipping"
            return 1
        fi

        # The agent outputs the path(s) it wrote to stdout — one per line.
        # stderr is the human-readable log, redirected to $LOG as before.
        # We pass a path prefix (no extension); the agent appends the right ext.
        local remote_prefix="/tmp/pabs-bundle-${label}-${DATE}"
        local local_dest="$STAGE_DIR/vm-agents/$label"
        mkdir -p "$local_dest"

        local agent_timeout="${VM_AGENT_TIMEOUT:-600}"
        local agent_stdout
        agent_stdout=$(
            timeout "$agent_timeout" ssh "${ssh_opts[@]}" "$ssh_user@$vm_host" \
                "bash '$agent_path' --bundle-output '$remote_prefix'" 2>>"$LOG"
        ) || {
            local ssh_rc=$?
            [[ $ssh_rc -eq 124 ]]                 && log "  ✗  [$label] Agent timed out after ${agent_timeout}s on $vm_host"                 || log "  ✗  [$label] Agent failed on $vm_host (exit ${ssh_rc})"
            # Log any stdout the agent produced before dying — helps diagnose failures
            if [[ -n "$agent_stdout" ]]; then
                log "  [$label] Agent stdout before failure: $agent_stdout"
            fi
            # Best-effort cleanup of any partial files matching the prefix
            ssh "${ssh_opts[@]}" "$ssh_user@$vm_host"                 "rm -f '${remote_prefix}'.*" 2>/dev/null || true
            return 1
        }

        # Parse the output — each non-empty line is a file to pull
        local -a remote_files=()
        while IFS= read -r line; do
            [[ -n "$line" ]] && remote_files+=("$line")
        done <<< "$agent_stdout"

        if [[ ${#remote_files[@]} -eq 0 ]]; then
            log "  ✗  [$label] Agent produced no output paths"
            return 1
        fi

        # Pull every file the agent listed
        local pull_ok=true
        for remote_file in "${remote_files[@]}"; do
            if ! rsync -a -e "ssh ${ssh_opts[*]@Q}" \
                    "$ssh_user@$vm_host:$remote_file" "$local_dest/" 2>>"$LOG"; then
                log "  ✗  [$label] rsync failed for $(basename "$remote_file")"
                pull_ok=false
            fi
        done

        # Always clean up remote files, even on partial failure
        ssh "${ssh_opts[@]}" "$ssh_user@$vm_host" \
            "rm -f '${remote_prefix}'.*" 2>/dev/null || true

        $pull_ok || return 1

        local total_kb
        total_kb=$(du -sk "$local_dest" 2>/dev/null | cut -f1)
        log "  ✓  [$label] pulled ${#remote_files[@]} file(s) (${total_kb}KB total)"

        # Space check after pull
        local avail_kb
        avail_kb=$(df -k "$LOCAL_STAGE_BASE" | awk 'NR==2{print $4}')
        if [[ $avail_kb -lt "${VM_AGENT_STAGE_MIN_FREE_KB:-524288}" ]]; then
            log "  ✗  [$label] Stage critically low (${avail_kb}KB free) — aborting agent section"
            return 3
        fi

        # Prune old bundles for this VM.
        # Match any file format the agent may have produced (.tar.zst or .tar)
        # but exclude .meta.tar.zst sidecars — they're small and pruned with
        # their primary file by name prefix matching below.
        local keep="${VM_AGENT_KEEP_BUNDLES:-2}"
        local old_bundles=()
        mapfile -t old_bundles < <(
            find "$local_dest" -maxdepth 1 -type f \( -name "*.tar.zst" -o -name "*.tar" \) \
                ! -name "*.meta.tar.zst" \
                -printf '%T@ %p\n' | sort -n | awk '{print $2}' | head -n -"$keep"
        )
        for b in "${old_bundles[@]}"; do
            # Also remove the companion .meta.tar.zst sidecar if present
            local meta_b="${b%.tar}.meta.tar.zst"
            [[ -f "$meta_b" ]] && rm -f "$meta_b" \
                && log "    [$label] pruned sidecar: $(basename "$meta_b")"
            rm -f "$b"
            log "    [$label] pruned old bundle: $(basename "$b")"
        done

        return 0
    }

    _wait_one() {
        local pid=$1 rc
        wait "$pid" && rc=0 || rc=$?
        case $rc in
            0) : $(( total_ok++ ))   ;;
            2) : $(( total_skip++ )) ;;
            3) : $(( total_fail++ )); return 3 ;;  # abort: stage full
            *) : $(( total_fail++ )) ;;
        esac
        return 0
    }

    local abort=false
    for entry in "${VM_AGENTS[@]}"; do
        $abort && break

        if [[ $max_parallel -le 1 ]]; then
            _run_agent "$entry" && : $(( total_ok++ )) || {
                local rc=$?
                case $rc in
                    2) : $(( total_skip++ )) ;;
                    3) : $(( total_fail++ )); abort=true ;;
                    *) : $(( total_fail++ )) ;;
                esac
            }
        else
            _run_agent "$entry" &
            pids+=($!)
            if [[ ${#pids[@]} -ge $max_parallel ]]; then
                _wait_one "${pids[0]}" || abort=true
                pids=("${pids[@]:1}")
            fi
        fi
    done

    for pid in "${pids[@]}"; do
        _wait_one "$pid" || abort=true
    done

    log "  VM agents: $total_ok OK, $total_fail failed, $total_skip skipped"
    if [[ $total_fail -gt 0 ]]; then log_err "$total_fail VM agent(s) failed"; fi
    return 0
}