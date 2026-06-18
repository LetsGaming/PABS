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
# _offsite_usage_bytes REMOTE_ROOT → total bytes used by PABS on the remote
# ---------------------------------------------------------------------------
_offsite_usage_bytes() {
    local remote_root="$1"
    rclone size "$remote_root" --json 2>/dev/null \
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('bytes',0))" 2>/dev/null \
        || echo 0
}

# ---------------------------------------------------------------------------
# _offsite_usage_gb REMOTE_ROOT → human-readable GB (2 dp)
# ---------------------------------------------------------------------------
_offsite_usage_gb() {
    local bytes
    bytes=$(_offsite_usage_bytes "$1")
    python3 -c "print(round($bytes / 1073741824, 2))" 2>/dev/null || echo 0
}

# ---------------------------------------------------------------------------
# _offsite_file_sizes REMOTE_ROOT
# Prints "<size_bytes> <filename>" for every PABS archive, oldest-first.
# Used so storage-cap pruning works from real per-file sizes instead of a
# fixed guess. Falls back gracefully (size 0) if rclone can't report a size.
# ---------------------------------------------------------------------------
_offsite_file_sizes() {
    local remote_root="$1"
    # rclone lsf --format "sp" → "<size>;<path>" per line
    rclone lsf "$remote_root" --files-only --format "sp" --separator ";" 2>/dev/null \
        | grep -E ';[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}\.tar\.zst(\.gpg)?$' \
        | awk -F';' '{ size=$1; $1=""; sub(/^;/,""); print size" "$0 }' \
        | sort -k2
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

    # Local membership test — replaces the previous broken construct that wrapped
    # each element in literal quotes (so grep -qxF never matched, allowing the
    # same file to be marked twice). Returns 0 if $1 is already in to_delete.
    _already_marked() {
        local needle="$1" d
        for d in ${to_delete[@]+"${to_delete[@]}"}; do
            [[ "$d" == "$needle" ]] && return 0
        done
        return 1
    }

    # --- Count-based pruning: mark the oldest (count - keep_max) ---
    if [[ $keep_max -gt 0 && $count -gt $keep_max ]]; then
        local excess=$(( count - keep_max ))
        log "  Offsite: count $count > RCLONE_KEEP_MAX $keep_max — marking $excess for pruning"
        for (( i=0; i<excess; i++ )); do
            to_delete+=("${remote_backups[$i]}")
        done
    fi

    # --- Storage-cap pruning: use REAL per-file sizes, oldest-first ---
    if [[ $max_gb -gt 0 ]]; then
        local cap_bytes used_bytes
        cap_bytes=$(python3 -c "print(int($max_gb * 1073741824))" 2>/dev/null || echo 0)
        used_bytes=$(_offsite_usage_bytes "$remote_root")
        log "  Offsite: remote usage $(python3 -c "print(round($used_bytes/1073741824,2))" 2>/dev/null || echo '?')GB / ${max_gb}GB cap"

        if [[ "$used_bytes" =~ ^[0-9]+$ && "$cap_bytes" =~ ^[0-9]+$ && $used_bytes -gt $cap_bytes ]]; then
            log "  Offsite: storage cap exceeded — marking oldest for pruning"
            local projected=$used_bytes fsize fname
            while IFS= read -r line; do
                [[ $projected -le $cap_bytes ]] && break
                fsize="${line%% *}"
                fname="${line#* }"
                [[ "$fsize" =~ ^[0-9]+$ ]] || fsize=0
                if ! _already_marked "$fname"; then
                    to_delete+=("$fname")
                    projected=$(( projected - fsize ))
                fi
            done < <(_offsite_file_sizes "$remote_root")
        fi
    fi

    # --- KEEP_MIN rescue: never drop below keep_min survivors ---
    # Rescue the NEWEST marked entries first (to_delete is oldest-first, so pop
    # from the end), guaranteeing the oldest backups are the ones actually pruned.
    local survivors=$(( count - ${#to_delete[@]} ))
    while [[ $survivors -lt $keep_min && ${#to_delete[@]} -gt 0 ]]; do
        log "  Offsite: rescued ${to_delete[-1]} from pruning (RCLONE_KEEP_MIN=$keep_min)"
        unset 'to_delete[-1]'
        to_delete=("${to_delete[@]}")
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

    # Encryption method:
    #   symmetric (default) — AES-256 with RCLONE_ENCRYPTION_PASSWORD. Simple,
    #                         but the passphrase must exist to both encrypt and
    #                         decrypt, so it lives on (or near) the backed-up host.
    #   gpg-key             — asymmetric: encrypt to RCLONE_ENCRYPTION_RECIPIENT's
    #                         public key. The private key needed to DECRYPT never
    #                         touches this host, which is the stronger model for
    #                         the "host is compromised / USB is lost" threat.
    local enc_method="${RCLONE_ENCRYPTION_METHOD:-symmetric}"
    local encrypted="false"
    if [[ "$enc_method" == "gpg-key" && -n "${RCLONE_ENCRYPTION_RECIPIENT:-}" ]]; then
        encrypted="true"
    elif [[ -n "${RCLONE_ENCRYPTION_PASSWORD:-}" ]]; then
        encrypted="true"
        enc_method="symmetric"
    fi

    log "Offsite sync starting"
    log "  Remote   : $RCLONE_REMOTE"
    log "  Encrypted: $encrypted${encrypted:+ ($enc_method)}"

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
            log_warn "Offsite: encryption requested but gpg not found — uploading unencrypted"
            log_warn "  Install with: apt install gnupg"
        else
            local enc_tmp="${archive_tmp}.gpg"
            local enc_ok="false"
            if [[ "$enc_method" == "gpg-key" ]]; then
                # Asymmetric: encrypt to a recipient public key. --trust-model
                # always avoids interactive trust prompts in batch mode; the
                # recipient key must already be in root's GPG keyring (import it
                # once with: gpg --import recipient.pub).
                log "  Encrypting archive to GPG key: $RCLONE_ENCRYPTION_RECIPIENT ..."
                if gpg --batch --yes \
                        --trust-model always \
                        --recipient "$RCLONE_ENCRYPTION_RECIPIENT" \
                        --cipher-algo AES256 \
                        --encrypt \
                        --output "$enc_tmp" \
                        "$archive_tmp" 2>>"$LOG"; then
                    enc_ok="true"
                fi
            else
                # Symmetric: AES-256 with a passphrase.
                log "  Encrypting archive (symmetric AES-256)..."
                if echo "$RCLONE_ENCRYPTION_PASSWORD" | gpg --batch --yes \
                        --passphrase-fd 0 \
                        --symmetric \
                        --cipher-algo AES256 \
                        --output "$enc_tmp" \
                        "$archive_tmp" 2>>"$LOG"; then
                    enc_ok="true"
                fi
            fi

            if [[ "$enc_ok" == "true" ]]; then
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
    # shellcheck disable=SC2206  # intentional: split RCLONE_EXTRA_OPTS into separate flags
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