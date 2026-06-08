#!/bin/bash
# =============================================================================
# lib/offsite.sh — Offsite sync: archive, encryption, upload, retention pruning
#
# Sourced by backup.sh after core.sh and config.sh.
# Entry point: offsite_sync() — called once per backup run after USB commit.
# Non-fatal: a remote failure never aborts a backup that is already on USB.
#
# Each backup is uploaded as a single compressed archive:
#   <DATE>.tar.zst        (plain)
#   <DATE>.tar.zst.gpg    (GPG-encrypted when RCLONE_ENCRYPTION_PASSWORD is set)
#
# This avoids rclone syncing a directory tree full of tiny files, eliminates
# symlink/permission issues on cloud targets, and makes encryption trivial —
# one file in, one file out.
# =============================================================================

# ---------------------------------------------------------------------------
# _offsite_list_backups REMOTE_ROOT
# Lists PABS archive filenames on the remote, sorted oldest-first.
# Matches <DATE>.tar.zst and <DATE>.tar.zst.gpg
# ---------------------------------------------------------------------------
_offsite_list_backups() {
    local remote_root="$1"
    rclone lsf "$remote_root" \
        --files-only \
        2>/dev/null \
        | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}\.tar\.zst(\.gpg)?$' \
        | sort
}

# ---------------------------------------------------------------------------
# _offsite_usage_gb REMOTE_ROOT
# ---------------------------------------------------------------------------
_offsite_usage_gb() {
    local remote_root="$1"
    local bytes
    bytes=$(rclone size "$remote_root" --json 2>/dev/null \
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('bytes',0))" 2>/dev/null \
        || echo 0)
    python3 -c "print(round($bytes / 1073741824, 2))" 2>/dev/null || echo 0
}

# ---------------------------------------------------------------------------
# _offsite_prune REMOTE_ROOT
# ---------------------------------------------------------------------------
_offsite_prune() {
    local remote_root="$1"
    local keep_min="${RCLONE_KEEP_MIN:-1}"
    local keep_max="${RCLONE_KEEP_MAX:-4}"
    local max_gb="${RCLONE_MAX_STORAGE_GB:-0}"

    local -a remote_backups=()
    mapfile -t remote_backups < <(_offsite_list_backups "$remote_root")
    local count="${#remote_backups[@]}"
    [[ $count -eq 0 ]] && return 0

    log "  Offsite: $count archive(s) on remote"

    local -a to_delete=()

    if [[ $keep_max -gt 0 && $count -gt $keep_max ]]; then
        local excess=$(( count - keep_max ))
        log "  Offsite: count $count > RCLONE_KEEP_MAX $keep_max — marking $excess for pruning"
        for (( i=0; i<excess; i++ )); do
            to_delete+=("${remote_backups[$i]}")
        done
    fi

    if [[ $max_gb -gt 0 ]]; then
        local used_gb
        used_gb=$(_offsite_usage_gb "$remote_root")
        log "  Offsite: remote usage ${used_gb}GB / ${max_gb}GB cap"

        if python3 -c "import sys; sys.exit(0 if float('$used_gb') > float('$max_gb') else 1)" 2>/dev/null; then
            log "  Offsite: storage cap exceeded — marking oldest for pruning"
            local estimated_gb="$used_gb"
            for f in "${remote_backups[@]}"; do
                python3 -c "import sys; sys.exit(0 if float('$estimated_gb') > float('$max_gb') else 1)" 2>/dev/null \
                    || break
                printf '%s\n' "${to_delete[@]+\"${to_delete[@]}\"}" | grep -qxF "$f" \
                    || { to_delete+=("$f"); estimated_gb=$(python3 -c "print(round(float('$estimated_gb') - 0.1, 2))"); }
            done
        fi
    fi

    local survivors=$(( count - ${#to_delete[@]} ))
    while [[ $survivors -lt $keep_min && ${#to_delete[@]} -gt 0 ]]; do
        log "  Offsite: rescued ${to_delete[-1]} from pruning (RCLONE_KEEP_MIN=$keep_min)"
        to_delete=("${to_delete[@]::${#to_delete[@]}-1}")
        survivors=$(( survivors + 1 ))
    done

    if [[ ${#to_delete[@]} -eq 0 ]]; then
        log "  Offsite: nothing to prune"
        return 0
    fi

    for f in "${to_delete[@]}"; do
        log "  Offsite: pruning $f"
        if rclone deletefile "${remote_root}/${f}" 2>>"$LOG"; then
            log "  Offsite:   ✓ removed $f"
        else
            log_warn "Offsite: failed to remove $f — will retry next run"
        fi
    done
}

# ---------------------------------------------------------------------------
# offsite_sync — public entry point
# ---------------------------------------------------------------------------
offsite_sync() {
    [[ -z "${RCLONE_REMOTE:-}" ]] && return 0

    if ! command -v rclone &>/dev/null; then
        log_warn "RCLONE_REMOTE is set but rclone is not installed — skipping offsite sync"
        log_warn "  Install with: apt install rclone"
        return 0
    fi

    local encrypted="false"
    [[ -n "${RCLONE_ENCRYPTION_PASSWORD:-}" ]] && encrypted="true"

    log "Offsite sync starting"
    log "  Remote   : $RCLONE_REMOTE"
    log "  Encrypted: $encrypted"

    # --- Build archive in /tmp (fast local storage, not USB) ----------------
    local archive_name="${DATE}.tar.zst"
    local archive_tmp="/tmp/pabs-offsite-${DATE}.tar.zst"
    local upload_file="$archive_tmp"
    local upload_name="$archive_name"

    log "  Compressing backup to archive..."
    if ! tar -C "$(dirname "$FINAL_DIR")" \
             --use-compress-program="zstd -3 -T0" \
             -cf "$archive_tmp" \
             "$(basename "$FINAL_DIR")" 2>>"$LOG"; then
        log_err "Offsite: failed to create archive — skipping upload"
        rm -f "$archive_tmp"
        return 0
    fi

    local size_mb
    size_mb=$(du -sm "$archive_tmp" 2>/dev/null | cut -f1)
    log "  Archive ready: ${size_mb}MB"

    # --- Optionally encrypt with GPG ----------------------------------------
    if [[ "$encrypted" == "true" ]]; then
        if ! command -v gpg &>/dev/null; then
            log_warn "Offsite: RCLONE_ENCRYPTION_PASSWORD set but gpg not found — uploading unencrypted"
            log_warn "  Install with: apt install gnupg"
        else
            local enc_tmp="${archive_tmp}.gpg"
            log "  Encrypting archive..."
            if echo "$RCLONE_ENCRYPTION_PASSWORD" | gpg --batch --yes \
                    --passphrase-fd 0 \
                    --symmetric \
                    --cipher-algo AES256 \
                    --output "$enc_tmp" \
                    "$archive_tmp" 2>>"$LOG"; then
                rm -f "$archive_tmp"
                upload_file="$enc_tmp"
                upload_name="${archive_name}.gpg"
                log "  Encryption complete"
            else
                log_err "Offsite: gpg encryption failed — skipping upload"
                rm -f "$archive_tmp" "$enc_tmp"
                return 0
            fi
        fi
    fi

    # --- Upload single file via rclone --------------------------------------
    local dest="${RCLONE_REMOTE%/}/${upload_name}"
    local -a extra_opts=($RCLONE_EXTRA_OPTS)

    log "  Uploading ${upload_name} to ${RCLONE_REMOTE}..."
    if rclone copyto "$upload_file" "$dest" \
            "${extra_opts[@]}" \
            --log-file="$LOG" \
            --log-level INFO \
            2>>"$LOG"; then
        log "  ✓ Offsite upload complete (${size_mb}MB)"
    else
        log_err "Offsite sync to $RCLONE_REMOTE failed — USB backup is intact"
        dispatch_alert "WARNING — offsite sync $DATE FAILED to $RCLONE_REMOTE. USB backup intact. Review: $LOG"
        rm -f "$upload_file"
        return 0
    fi

    rm -f "$upload_file"

    _offsite_prune "${RCLONE_REMOTE%/}"
}