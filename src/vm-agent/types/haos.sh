#!/bin/bash
# =============================================================================
# types/haos.sh — Home Assistant OS backup handler
#
# Sourced by agent.sh when type=haos. Must implement run_backup().
#
# WHAT THIS BACKS UP:
#   A full HAOS native snapshot (.tar) triggered via the `ha` CLI, which is
#   available inside the community SSH add-on. The snapshot is the officially
#   supported HAOS backup format — it can be restored in one click via the
#   HA UI (Settings → Backups → Upload) or via `ha backup restore <slug>`.
#
# HOW IT WORKS:
#   1. Triggers: ha backup new --name "pabs-<date>"
#   2. Polls until the backup appears in: ha backup list
#   3. Sets AGENT_PREBUILT_FILE to /backup/<slug>.tar
#   4. agent.sh moves that file directly to the output path — no re-compression.
#      The HA .tar is the backup. It is already internally compressed by HA.
#      Double-wrapping it in tar+zstd would waste CPU, waste space, and require
#      zstd to be installed in the HAOS SSH add-on environment (Alpine Linux).
#
# OUTPUT FORMAT:
#   <slug>.tar  — the native HA backup, restorable directly in the HA UI or
#                 via: ha backup restore <slug>
#   (+ optional .meta.tar.zst sidecar with restore-notes.txt if zstd available)
#
# ALL DEFAULTS ARE OVERRIDABLE in /etc/pabs-agent/config:
#
#   HAOS_BACKUP_DIR="/backup"           Where HA stores snapshots (inside add-on shell)
#   HAOS_BACKUP_NAME="pabs-auto"        Prefix for the generated backup name
#   HAOS_BACKUP_TYPE="full"             "full" or "partial"
#   HAOS_BACKUP_PASSWORD=""             Encrypt the snapshot (leave empty = no encryption)
#   HAOS_WAIT_SECONDS=300               Max seconds to wait for backup to finish
#   HAOS_POLL_INTERVAL=10               How often to poll (seconds)
#   HAOS_KEEP_ON_HOST=1                 How many pabs-* backups to keep on the HA host
#                                       (oldest auto-pruned after successful pull)
#   HAOS_PARTIAL_ADDONS=""              Comma-separated add-on slugs (partial backup only)
#   HAOS_PARTIAL_FOLDERS=""             Comma-separated folders (partial backup only)
#                                       Valid folders: homeassistant,ssl,share,media,addons/local
# =============================================================================

# --- Defaults ---
HAOS_BACKUP_DIR="${HAOS_BACKUP_DIR:-/backup}"
HAOS_BACKUP_NAME="${HAOS_BACKUP_NAME:-pabs-auto}"
HAOS_BACKUP_TYPE="${HAOS_BACKUP_TYPE:-full}"
HAOS_BACKUP_PASSWORD="${HAOS_BACKUP_PASSWORD:-}"
HAOS_WAIT_SECONDS="${HAOS_WAIT_SECONDS:-300}"
HAOS_POLL_INTERVAL="${HAOS_POLL_INTERVAL:-10}"
HAOS_KEEP_ON_HOST="${HAOS_KEEP_ON_HOST:-1}"
HAOS_PARTIAL_ADDONS="${HAOS_PARTIAL_ADDONS:-}"
HAOS_PARTIAL_FOLDERS="${HAOS_PARTIAL_FOLDERS:-}"

# -----------------------------------------------------------------------------
# HA CLI WRAPPER
# -----------------------------------------------------------------------------

# Check that the ha CLI is available — it's present in the SSH add-on shell
_check_ha_cli() {
    command -v ha &>/dev/null || die "ha CLI not found. Is this running inside the HAOS SSH add-on?"
}

# Run a ha CLI command and return its JSON output.
# The ha CLI outputs YAML by default; --raw-json returns clean JSON.
_ha() {
    ha --raw-json "$@" 2>/dev/null
}

# -----------------------------------------------------------------------------
# TRIGGER BACKUP
# -----------------------------------------------------------------------------

_trigger_backup() {
    local backup_label
    backup_label="${HAOS_BACKUP_NAME}-$(date '+%Y%m%d-%H%M')"
    log "Triggering HAOS $HAOS_BACKUP_TYPE backup: '$backup_label'"

    # Build the ha backup new command
    local cmd_args=("backup" "new" "--name" "$backup_label")

    if [[ "$HAOS_BACKUP_TYPE" == "partial" ]]; then
        # Partial backup — add-ons and/or folders
        if [[ -n "$HAOS_PARTIAL_ADDONS" ]]; then
            IFS=',' read -ra addon_slugs <<< "$HAOS_PARTIAL_ADDONS"
            for slug in "${addon_slugs[@]}"; do
                slug="$(echo "$slug" | xargs)"
                cmd_args+=("--addons" "$slug")
            done
        fi
        if [[ -n "$HAOS_PARTIAL_FOLDERS" ]]; then
            IFS=',' read -ra folders <<< "$HAOS_PARTIAL_FOLDERS"
            for folder in "${folders[@]}"; do
                folder="$(echo "$folder" | xargs)"
                cmd_args+=("--folders" "$folder")
            done
        fi
        log "  Partial backup: addons='$HAOS_PARTIAL_ADDONS' folders='$HAOS_PARTIAL_FOLDERS'"
    fi

    if [[ -n "$HAOS_BACKUP_PASSWORD" ]]; then
        cmd_args+=("--password" "$HAOS_BACKUP_PASSWORD")
        log "  Backup will be encrypted"
    fi

    # ha backup new returns either {"slug":"abcd1234"} (older HA versions)
    # or {"result":"ok","data":{"job_id":"...","slug":"abcd1234"}} (newer versions).
    local result
    result=$(_ha "${cmd_args[@]}") || die "ha backup new failed: $result"

    local slug
    # python3 is not available in all HAOS add-on shells — extract slug with grep.
    # Handles both {"slug":"abcd"} and {"result":"ok","data":{"slug":"abcd"}} formats.
    slug=$(echo "$result" | grep -o '"slug":"[^"]*"' | head -1 | grep -o '"[^"]*"$' | tr -d '"')

    [[ -n "$slug" ]] || die "ha backup new did not return a slug. Output: $result"

    echo "$slug"
}

# -----------------------------------------------------------------------------
# WAIT FOR BACKUP TO COMPLETE
# -----------------------------------------------------------------------------

_wait_for_backup() {
    local slug="$1"
    local waited=0

    log "Waiting for backup '$slug' to appear (max ${HAOS_WAIT_SECONDS}s)..."

    # Guard against HAOS_WAIT_SECONDS=0 which causes immediate timeout before
    # the backup has any chance to complete.
    if [[ "${HAOS_WAIT_SECONDS:-0}" -le 0 ]]; then
        die "HAOS_WAIT_SECONDS must be greater than 0 (got: '${HAOS_WAIT_SECONDS:-0}'). Check config."
    fi

    while true; do
        # ha backup list returns all backups; we look for our slug
        local list_json
        list_json=$(_ha backup list 2>/dev/null) || true

        local found
        # grep for the slug in the JSON — no python3 needed
        found=$(echo "$list_json" | grep -o '"slug":"'"${slug}"'"' | head -1)

        if [[ -n "$found" ]]; then
            log "  ✓ Backup '$slug' ready"
            return 0
        fi

        if [[ $waited -ge $HAOS_WAIT_SECONDS ]]; then
            die "Timed out waiting for HAOS backup '$slug' after ${HAOS_WAIT_SECONDS}s"
        fi

        sleep "$HAOS_POLL_INTERVAL"
        waited=$(( waited + HAOS_POLL_INTERVAL ))
        log "  ...still waiting (${waited}s elapsed)"
    done
}

# -----------------------------------------------------------------------------
# REGISTER PREBUILT FILE
# -----------------------------------------------------------------------------

# Signal to agent.sh that the HA .tar is the complete backup output.
# agent.sh will move it directly to the bundle output path — no re-compression.
# The HA snapshot is already internally compressed; wrapping it in tar+zstd
# would waste CPU, waste space, and require zstd in the HAOS SSH add-on shell.
#
# IMPORTANT: must be called directly, never inside $() — the AGENT_PREBUILT_FILE
# assignment must propagate to the caller's scope, not be lost in a subshell.
_register_prebuilt_file() {
    local slug="$1"
    local backup_file="$HAOS_BACKUP_DIR/${slug}.tar"

    [[ -f "$backup_file" ]] || die "Backup file not found at expected path: $backup_file"

    # agent.sh checks this variable after run_backup() returns.
    # When set, it skips tar+zstd and moves this file directly to output_path.
    AGENT_PREBUILT_FILE="$backup_file"

    HAOS_BACKUP_SIZE_MB=$(du -sm "$backup_file" 2>/dev/null | cut -f1)
    log "Backup file ready: $backup_file (${HAOS_BACKUP_SIZE_MB}MB)"
    log "  Passing to agent as prebuilt output — no re-compression"
}

# -----------------------------------------------------------------------------
# PRUNE OLD PABS BACKUPS FROM HA HOST
# -----------------------------------------------------------------------------

_prune_old_host_backups() {
    if [[ $HAOS_KEEP_ON_HOST -le 0 ]]; then return; fi

    log "Pruning old pabs-* backups on HA host (keeping $HAOS_KEEP_ON_HOST)..."

    local list_json
    list_json=$(_ha backup list 2>/dev/null) || return

    # Collect pabs-* backup slugs sorted oldest-first, no python3 needed.
    # Extract "slug":"X","name":"Y" pairs, filter by backup name prefix,
    # then drop the newest HAOS_KEEP_ON_HOST entries (keep them, delete the rest).
    local all_slugs keep_count old_slugs total
    keep_count="${HAOS_KEEP_ON_HOST:-1}"
    all_slugs=$(echo "$list_json" \
        | grep -o '"slug":"[^"]*","name":"[^"]*"' \
        | grep '"name":"'${HAOS_BACKUP_NAME} \
        | grep -o '"slug":"[^"]*"' \
        | sed 's/"slug":"//;s/"//g') || true

    if [ -z "$all_slugs" ]; then
        log "  Nothing to prune"
        return
    fi

    total=$(echo "$all_slugs" | wc -l | tr -d ' ')
    if [ "$total" -le "$keep_count" ]; then
        log "  Nothing to prune ($total backup(s), keeping $keep_count)"
        return
    fi

    # Drop the last $keep_count lines (newest), delete the rest
    old_slugs=$(echo "$all_slugs" | head -n "$(( total - keep_count ))")

    while IFS= read -r slug; do
        [ -z "$slug" ] && continue
        log "  Removing old backup: $slug"
        _ha backup remove "$slug" >/dev/null 2>&1 \
            && log "  ✓ Removed $slug" \
            || log_warn "  Could not remove $slug (non-fatal)"
    done <<< "$old_slugs"
}

# -----------------------------------------------------------------------------
# RESTORE NOTES
# -----------------------------------------------------------------------------

_write_restore_notes() {
    local slug="$1"
    local size_mb="$2"
    local haos_version
    haos_version=$(ha core info --raw-json 2>/dev/null | grep -o '"version":"[^"]*"' | grep -o '"[^"]*"$' | tr -d '"' || echo "unknown")

    local encrypted_str partial_note type_note restore_cmd body_line
    encrypted_str=$([ -n "$HAOS_BACKUP_PASSWORD" ] && echo "YES (password required)" || echo "no")
    restore_cmd="ha backup restore ${slug}"
    [ -n "$HAOS_BACKUP_PASSWORD" ] && restore_cmd="$restore_cmd --password <your-password>"
    body_line=""
    [ -n "$HAOS_BACKUP_PASSWORD" ] && body_line='    Body: {"password": "<your-password>"}'
    partial_note=""
    if [ "$HAOS_BACKUP_TYPE" = "partial" ]; then
        partial_note="  - This is a PARTIAL backup (addons: $HAOS_PARTIAL_ADDONS / folders: $HAOS_PARTIAL_FOLDERS)"
    fi
    type_note=""
    [ "$HAOS_BACKUP_TYPE" = "full" ] && type_note="  - Full backup includes: HA config, add-ons, SSL, share, media, local add-ons"

    {
        echo "PABS Home Assistant OS Restore Notes"
        echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')  Host: $(hostname)"
        echo "Backup slug: $slug"
        echo "Backup size: ${size_mb}MB"
        echo "Backup type: $HAOS_BACKUP_TYPE"
        echo "Encrypted:   $encrypted_str"
        echo "========================================"
        echo ""
        echo "THE BACKUP FILE:"
        echo "  ${slug}.tar"
        echo "  (the native HA snapshot — restore directly via HA UI or CLI)"
        echo ""
        echo "HOW TO RESTORE:"
        echo ""
        echo "  OPTION A — Web UI (easiest):"
        echo "    1. Fresh HAOS install on new hardware"
        echo "    2. Wait for onboarding to appear"
        echo "    3. Click "Restore from backup" on the onboarding screen"
        echo "    4. Upload ${slug}.tar"
        echo "    5. Select what to restore and confirm"
        echo ""
        echo "  OPTION B — CLI:"
        echo "    1. Copy ${slug}.tar into the HA host /backup/ directory"
        echo "    2. SSH into the add-on shell"
        echo "    3. $restore_cmd"
        echo ""
        echo "  OPTION C — Supervisor API:"
        echo "    POST /api/backups/${slug}/restore/full"
        echo "    Header: Authorization: Bearer <long-lived-token>"
        [ -n "$body_line" ] && echo "$body_line"
        echo ""
        echo "NOTES:"
        [ -n "$partial_note" ] && echo "$partial_note"
        [ -n "$type_note" ] && echo "$type_note"
        echo "  - HAOS version at backup time: $haos_version"
    } > "$STAGE_DIR/restore-notes.txt"
    log "  ✓ restore-notes.txt written"
}

# -----------------------------------------------------------------------------
# ENTRY POINT
# -----------------------------------------------------------------------------

run_backup() {
    log "HAOS backup starting on $(hostname)"
    _check_ha_cli

    # Trigger the backup
    local slug
    slug=$(_trigger_backup)
    log "Backup slug: $slug"

    # Wait for it to finish
    _wait_for_backup "$slug"

    # Register the HA .tar as the prebuilt output — agent.sh moves it directly.
    # Called directly (not in a subshell) so AGENT_PREBUILT_FILE propagates.
    _register_prebuilt_file "$slug"
    local size_mb="${HAOS_BACKUP_SIZE_MB:-0}"

    # Write restore instructions
    _write_restore_notes "$slug" "$size_mb"

    # Clean up old pabs-* backups from the HA host
    _prune_old_host_backups

    log "HAOS backup complete — slug: $slug (${size_mb}MB) — prebuilt .tar, no re-compression"
}