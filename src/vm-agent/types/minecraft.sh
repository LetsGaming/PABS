#!/bin/bash
# =============================================================================
# types/minecraft.sh — Minecraft VM backup handler
#
# Sourced by agent.sh when type=minecraft. Must implement run_backup().
#
# Designed to work in tandem with minecraft-server-setup:
#   https://github.com/LetsGaming/minecraft-server-setup
#
# Division of responsibility:
#   minecraft-server-setup  owns all server state: world data, configs, jars,
#                           mods, instance metadata (variables.txt,
#                           downloaded_versions.json). Its GFS rotation
#                           produces the .tar.zst archives this handler pulls.
#
#   PABS (this file)        is transport only: pull finalized archives off the
#                           VM, get them to USB + offsite with integrity
#                           guarantees. No config scraping, no duplication of
#                           what the archives already contain.
#
# Each weekly/monthly archive produced by minecraft-server-setup already
# includes the full SERVER_PATH snapshot plus a .mc-meta/ directory containing
# variables.txt and downloaded_versions.json. PABS does not need to capture
# these separately.
#
# Configuration (set in /etc/pabs-agent/config on the VM):
#
#   MINECRAFT_BASE          Parent backups/ directory. Each subdirectory is one
#     (default below)       INSTANCE_NAME. Matches minecraft-server-setup's
#                           default TARGET_DIR_NAME + BACKUPS_PATH layout.
#
#   MC_KEEP_WEEKLY=4        Weekly archives to pull per instance.
#   MC_KEEP_DAILY=0         Daily archives to pull (0 = skip).
#                           PABS runs weekly — daily archives add no safety
#                           margin and consume USB space. Keep at 0 unless
#                           you have a specific reason.
#   MC_MIN_AGE_MINUTES=5    Skip archives younger than this — guards against
#                           pulling a file still being compressed.
#   EXTRA_PATHS=""          Space-separated extra paths to include (universal — same variable across all types).
#                           Use this for anything outside the archive:
#                             EXTRA_PATHS="/etc/systemd/system/survival.service"
#                           Add the api-server service if enabled:
#                             EXTRA_PATHS="/etc/systemd/system/survival.service \
#                                          /etc/systemd/system/survival-api-server.service"
# =============================================================================

# --- Defaults (all match unmodified minecraft-server-setup) ---
MINECRAFT_BASE="${MINECRAFT_BASE:-/home/minecraft/minecraft-server/backups}"
MC_KEEP_WEEKLY="${MC_KEEP_WEEKLY:-4}"
MC_KEEP_DAILY="${MC_KEEP_DAILY:-0}"
MC_MIN_AGE_MINUTES="${MC_MIN_AGE_MINUTES:-5}"
MC_EXTRA_PATHS="${EXTRA_PATHS:-}"

# Populated during run_backup, used by restore notes
_mc_instances=()
_mc_total_archives=0
_mc_total_size_mb=0

# -----------------------------------------------------------------------------
# ARCHIVE DISCOVERY
# -----------------------------------------------------------------------------

# Find finalized archives in a given directory.
# Usage: _find_archives <dir> <keep_count>
# Prints the N most recent files by mtime, filtered by age-gate.
_find_archives() {
    local dir="$1"
    local keep="$2"

    [[ -d "$dir" ]] || return 0
    [[ "$keep" -gt 0 ]] || return 0

    # Age-gate: skip files still being written/compressed by MC backup script.
    # fuser/lsof would be ideal but are unreliable inside containers/VMs under
    # some configurations. mtime age-gating is the safe universal alternative.
    local age_args=()
    if [[ "$MC_MIN_AGE_MINUTES" -gt 0 ]]; then
        age_args=( -mmin "+${MC_MIN_AGE_MINUTES}" )
    fi

    # Sort by mtime ascending (oldest first), then take the last N (newest N).
    # Using -printf '%T@ %p\n' + sort-n + tail avoids eval entirely; $dir is
    # passed as a direct argument so shell metacharacters in the path are safe.
    find "$dir" -maxdepth 1 -type f \
        \( -name '*.tar.zst' -o -name '*.tar.gz' \) \
        "${age_args[@]}" \
        -printf '%T@ %p\n' 2>/dev/null \
        | sort -n | tail -n "$keep" | awk '{print $2}'
}

# -----------------------------------------------------------------------------
# INSTANCE BACKUP
# -----------------------------------------------------------------------------

_backup_instance() {
    local instance_name="$1"
    local instance_backup_dir="$MINECRAFT_BASE/$instance_name"
    local dest="$STAGE_DIR/minecraft/$instance_name"
    mkdir -p "$dest/archives"

    log "  Instance: $instance_name"

    local instance_archives=0

    # --- Weekly archives ---
    local weekly_dir="$instance_backup_dir/archives/weekly"
    if [[ -d "$weekly_dir" ]]; then
        while IFS= read -r archive; do
            if [[ -z "$archive" ]]; then continue; fi
            local fname size_mb
            fname=$(basename "$archive")
            size_mb=$(du -sm "$archive" 2>/dev/null | cut -f1)

            if cp "$archive" "$dest/archives/$fname" 2>/dev/null; then
                log "    ✓ weekly: $fname (${size_mb}MB)"
                (( instance_archives++ )) || true
                (( _mc_total_archives++ )) || true
                (( _mc_total_size_mb += size_mb )) || true
            else
                log_warn "    failed to stage: $fname"
            fi
        done < <(_find_archives "$weekly_dir" "$MC_KEEP_WEEKLY")
    else
        log_warn "    no weekly archive dir found at $weekly_dir"
        log_warn "    has minecraft-server-setup run at least one weekly backup?"
    fi

    # --- Daily archives (opt-in) ---
    if [[ "$MC_KEEP_DAILY" -gt 0 ]]; then
        local daily_dir="$instance_backup_dir/archives/daily"
        if [[ -d "$daily_dir" ]]; then
            while IFS= read -r archive; do
                if [[ -z "$archive" ]]; then continue; fi
                local fname size_mb
                fname=$(basename "$archive")
                size_mb=$(du -sm "$archive" 2>/dev/null | cut -f1)

                if cp "$archive" "$dest/archives/daily-$fname" 2>/dev/null; then
                    log "    ✓ daily: $fname (${size_mb}MB)"
                    (( instance_archives++ )) || true
                    (( _mc_total_archives++ )) || true
                    (( _mc_total_size_mb += size_mb )) || true
                else
                    log_warn "    failed to stage daily: $fname"
                fi
            done < <(_find_archives "$daily_dir" "$MC_KEEP_DAILY")
        else
            log_warn "    MC_KEEP_DAILY>0 but no daily archive dir at $daily_dir"
        fi
    fi

    if [[ $instance_archives -eq 0 ]]; then
        log_warn "    no finalized archives found for $instance_name"
        log_warn "    (still compressing, or no backup has run yet)"
    fi

    _mc_instances+=("$instance_name ($instance_archives archives)")
}

# -----------------------------------------------------------------------------
# RESTORE NOTES
# -----------------------------------------------------------------------------

_write_restore_notes() {
    cat > "$STAGE_DIR/restore-notes.txt" << EOF
PABS Minecraft VM Restore Notes
Generated: $(date '+%Y-%m-%d %H:%M:%S')  Host: $(hostname)
minecraft-server-setup: https://github.com/LetsGaming/minecraft-server-setup
========================================

INSTANCES BACKED UP:
$(printf "  %s\n" "${_mc_instances[@]:-  (none found)}")

Total archives: $_mc_total_archives  (~${_mc_total_size_mb}MB)
Age-gate:       files older than ${MC_MIN_AGE_MINUTES} minute(s) only

BUNDLE LAYOUT:
  minecraft/<instance>/archives/        Weekly (and optionally daily) .tar.zst archives
                                        Each archive contains the full server snapshot
                                        plus .mc-meta/variables.txt and
                                        .mc-meta/downloaded_versions.json

HOW TO RESTORE A WORLD:

  The .tar.zst archives are native minecraft-server-setup backups.
  Use minecraft-server-setup's own restore script (recommended):

    cd ~/minecraft-server/scripts/<instance>/backup/
    bash restore.sh --archive          # restore from archive (weekly/monthly)
    bash restore.sh --ago 3d           # restore closest backup to 3 days ago
    bash restore.sh --file minecraft_backup_2026-05-25_03-00-00.tar.zst

  Or manually:
    1. Stop the server:
         systemctl stop <instance>.service
    2. Extract the archive:
         cd /home/minecraft/minecraft-server/<instance>
         tar -I zstd -xf /path/to/archive.tar.zst
    3. Start the server:
         systemctl start <instance>.service

HOW TO REBUILD THE SERVER FROM SCRATCH:

  The .mc-meta/ directory inside each archive contains variables.txt and
  downloaded_versions.json — everything needed to reconstruct the environment.

  1. Fresh Debian VM
  2. Clone and re-run minecraft-server-setup:
       https://github.com/LetsGaming/minecraft-server-setup
  3. Restore variables.txt to scripts/<instance>/common/ — this restores all
     paths, retention config, RCON settings, and webhook URL.
  4. Restore downloaded_versions.json to scripts/<instance>/update/ — this
     restores the mod/pack version baseline for update-server.js.
  5. Restore the world from the archive (see above).
  6. Start the server.

EOF
    log "  ✓ restore-notes.txt written"
}

# -----------------------------------------------------------------------------
# ENTRY POINT
# -----------------------------------------------------------------------------

run_backup() {
    log "Minecraft backup starting on $(hostname)"

    [[ -d "$MINECRAFT_BASE" ]] || {
        die "MINECRAFT_BASE not found: $MINECRAFT_BASE — set it in /etc/pabs-agent/config"
    }

    # Discover instances — each subdirectory of MINECRAFT_BASE is one instance
    local instance_dirs=()
    while IFS= read -r d; do
        instance_dirs+=("$(basename "$d")")
    done < <(find "$MINECRAFT_BASE" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

    if [[ ${#instance_dirs[@]} -eq 0 ]]; then
        log_warn "No instance directories found under $MINECRAFT_BASE"
        log_warn "Has minecraft-server-setup run at least one backup cycle?"
    else
        log "Found ${#instance_dirs[@]} instance(s): ${instance_dirs[*]}"
        for instance in "${instance_dirs[@]}"; do
            _backup_instance "$instance"
        done
    fi

    # Extra paths — use for anything outside the archives (e.g. systemd service files)
    if [[ -n "$MC_EXTRA_PATHS" ]]; then
        log "  Staging extra paths..."
        for extra_path in $MC_EXTRA_PATHS; do
            stage_path "$extra_path" "extra: $extra_path"
        done
    fi

    # System context — Java version and OS for rebuild reference
    stage_cmd "system-state/java-version.txt"  "Java version"  bash -c 'java -version 2>&1'
    stage_cmd "system-state/os-release.txt"    "OS release"    cat /etc/os-release
    stage_cmd "system-state/hostname.txt"      "Hostname"      hostname

    _write_restore_notes

    log "Minecraft backup complete — $_mc_total_archives archive(s), ~${_mc_total_size_mb}MB"
}
