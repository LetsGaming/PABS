#!/bin/bash
# =============================================================================
# lib/validate.sh — Central configuration validation
#
# Sourced by backup.sh after config.sh and core.sh. Entry point:
#   validate_config   — checks every config value once, up front, so a typo in
#                       config.sh fails loudly at startup instead of producing
#                       a subtly-wrong backup (or a confusing mid-run abort).
#
# Hard errors call die(). Soft problems call log_warn() and continue.
# =============================================================================

# Helper: true if $1 is a non-negative integer
_is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
# Helper: true if $1 is a positive integer (>= 1)
_is_pint() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }

validate_config() {
    local errors=0

    # --- Required paths ---
    [[ -n "${USB_MOUNT:-}" ]]        || { log_err "USB_MOUNT is empty in config.sh"; (( errors++ )); }
    [[ -n "${LOCAL_STAGE_BASE:-}" ]] || { log_err "LOCAL_STAGE_BASE is empty in config.sh"; (( errors++ )); }
    [[ -n "${BACKUP_ROOT:-}" ]]      || { log_err "BACKUP_ROOT is empty (derived from USB_MOUNT)"; (( errors++ )); }

    # --- Integers ---
    _is_pint "${KEEP_BACKUPS:-}" \
        || { log_err "KEEP_BACKUPS must be an integer ≥ 1 (got '${KEEP_BACKUPS:-}')"; (( errors++ )); }

    for var in VM_AGENT_KEEP_BUNDLES VM_AGENT_MAX_PARALLEL VM_AGENT_TIMEOUT \
               VM_AGENT_STAGE_MIN_FREE_KB LOCAL_STAGE_WARN_GB; do
        local val="${!var:-}"
        [[ -z "$val" ]] && continue   # optional — defaults applied elsewhere
        _is_uint "$val" || { log_err "$var must be a non-negative integer (got '$val')"; (( errors++ )); }
    done

    # --- Booleans ---
    case "${BACKUP_ZFS:-true}" in
        true|false) ;;
        *) log_err "BACKUP_ZFS must be 'true' or 'false' (got '${BACKUP_ZFS:-}')"; (( errors++ )) ;;
    esac

    # --- TARGET_UUID format (if set) ---
    if [[ -n "${TARGET_UUID:-}" ]]; then
        # ext-style UUID: 8-4-4-4-12 hex. Loose check — just catch obvious typos.
        [[ "$TARGET_UUID" =~ ^[0-9a-fA-F-]{8,}$ ]] \
            || log_warn "TARGET_UUID '$TARGET_UUID' does not look like a UUID — double-check 'blkid'"
    fi

    # --- Offsite retention coherence ---
    local keep_min="${RCLONE_KEEP_MIN:-1}"
    local keep_max="${RCLONE_KEEP_MAX:-4}"
    local max_gb="${RCLONE_MAX_STORAGE_GB:-0}"
    _is_uint "$keep_min" || { log_err "RCLONE_KEEP_MIN must be a non-negative integer (got '$keep_min')"; (( errors++ )); }
    _is_uint "$keep_max" || { log_err "RCLONE_KEEP_MAX must be a non-negative integer (got '$keep_max')"; (( errors++ )); }
    _is_uint "$max_gb"   || { log_err "RCLONE_MAX_STORAGE_GB must be a non-negative integer (got '$max_gb')"; (( errors++ )); }
    if _is_uint "$keep_min" && _is_uint "$keep_max" && [[ $keep_max -gt 0 && $keep_min -gt $keep_max ]]; then
        log_warn "RCLONE_KEEP_MIN ($keep_min) > RCLONE_KEEP_MAX ($keep_max) — KEEP_MIN wins, max is effectively raised"
    fi

    # --- Offsite encryption method (new in 3.5) ---
    if [[ -n "${RCLONE_ENCRYPTION_METHOD:-}" ]]; then
        case "$RCLONE_ENCRYPTION_METHOD" in
            symmetric|gpg-key) ;;
            *) log_err "RCLONE_ENCRYPTION_METHOD must be 'symmetric' or 'gpg-key' (got '$RCLONE_ENCRYPTION_METHOD')"; (( errors++ )) ;;
        esac
        if [[ "$RCLONE_ENCRYPTION_METHOD" == "gpg-key" && -z "${RCLONE_ENCRYPTION_RECIPIENT:-}" ]]; then
            log_err "RCLONE_ENCRYPTION_METHOD=gpg-key requires RCLONE_ENCRYPTION_RECIPIENT (key id / email / fingerprint)"
            (( errors++ ))
        fi
    fi

    # --- VM_AGENTS entries: shape + label charset ---
    if [[ -n "${VM_AGENTS[*]:-}" ]]; then
        local seen_labels=" "
        for entry in "${VM_AGENTS[@]}"; do
            local l h u p
            read -r l h u p <<< "$entry"
            if [[ -z "$l" || -z "$h" || -z "$u" || -z "$p" ]]; then
                log_err "VM_AGENTS entry malformed (need 'label host user path'): '$entry'"
                (( errors++ )); continue
            fi
            if [[ ! "$l" =~ ^[A-Za-z0-9._-]+$ ]]; then
                log_err "VM_AGENTS label '$l' has unsafe characters (allowed: A-Z a-z 0-9 . _ -)"
                (( errors++ ))
            fi
            if [[ "$seen_labels" == *" $l "* ]]; then
                log_err "VM_AGENTS has duplicate label '$l' — labels must be unique"
                (( errors++ ))
            fi
            seen_labels+="$l "
        done
    fi

    if [[ $errors -gt 0 ]]; then
        die "$errors configuration error(s) found in config.sh — fix the items above and re-run."
    fi

    log "Config validation passed"
}
