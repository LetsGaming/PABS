#!/bin/bash
# =============================================================================
# types/generic.sh — Generic Linux VM / LXC backup handler
#
# Sourced by agent.sh when type=generic. Must implement run_backup().
#
# WHAT THIS BACKS UP:
#   - /etc (full — typically tiny, contains all service config)
#   - Cron jobs
#   - /usr/local/bin, /root/scripts
#   - Installed package list (dpkg selections + apt marks)
#   - Any EXTRA_PATHS configured by the user
#   - A restore-notes.txt describing what was found
#
# This handler is intentionally broad — it's the catch-all for services
# like Pi-hole, AdGuard, Nginx, Gitea, etc. that store their config under
# /etc or a well-known path.
#
# ALL DEFAULTS ARE OVERRIDABLE in /etc/pabs-agent/config:
#
#   GENERIC_INCLUDE_ETC="true"          Back up /etc (default: true)
#   GENERIC_INCLUDE_CRON="true"         Back up crontabs (default: true)
#   GENERIC_INCLUDE_SCRIPTS="true"      Back up /usr/local/bin + /root/scripts
#   GENERIC_INCLUDE_PACKAGES="true"     Save dpkg selections (default: true)
#   EXTRA_PATHS="/var/lib/pihole /opt/myapp/config"  Extra paths (space-separated)
#   GENERIC_EXCLUDE_PATHS=""            Paths to exclude from /etc backup
#                                       (space-separated, passed to rsync --exclude)
#
# COMMON EXAMPLES for EXTRA_PATHS per service:
#   Pi-hole:     /etc/pihole  (already in /etc, but explicit is fine)
#   AdGuard:     /opt/AdGuardHome
#   Nginx:       /etc/nginx   (already in /etc)
#   Vaultwarden: /opt/vaultwarden/data
#   Gitea:       /opt/gitea/custom, /opt/gitea/data (config only — exclude repos)
#   Nextcloud:   /var/www/nextcloud/config
# =============================================================================

# --- Defaults ---
GENERIC_INCLUDE_ETC="${GENERIC_INCLUDE_ETC:-true}"
GENERIC_INCLUDE_CRON="${GENERIC_INCLUDE_CRON:-true}"
GENERIC_INCLUDE_SCRIPTS="${GENERIC_INCLUDE_SCRIPTS:-true}"
GENERIC_INCLUDE_PACKAGES="${GENERIC_INCLUDE_PACKAGES:-true}"
GENERIC_EXCLUDE_PATHS="${GENERIC_EXCLUDE_PATHS:-}"

_noted_paths=()

# -----------------------------------------------------------------------------
# BACKUP SECTIONS
# -----------------------------------------------------------------------------

_backup_etc() {
    [[ "$GENERIC_INCLUDE_ETC" == "true" ]] || return

    log "  Staging /etc..."

    local rsync_args=(-a --relative)

    # Add any configured excludes
    if [[ -n "$GENERIC_EXCLUDE_PATHS" ]]; then
        for excl in $GENERIC_EXCLUDE_PATHS; do
            rsync_args+=(--exclude="$excl")
        done
        log "    Excluding: $GENERIC_EXCLUDE_PATHS"
    fi

    # Always exclude a few things that are noisy and not useful for restore
    rsync_args+=(
        --exclude="*.log"
        --exclude="*.cache"
        --exclude="/etc/mtab"
        --exclude="/etc/fstab.d"
    )

    if rsync "${rsync_args[@]}" /etc "$STAGE_DIR/" 2>/dev/null; then
        local size_kb
        size_kb=$(du -sk "$STAGE_DIR/etc" 2>/dev/null | cut -f1)
        log "  ✓ /etc staged (${size_kb}KB)"
        _noted_paths+=("/etc (${size_kb}KB)")
    else
        log_warn "  /etc rsync had warnings (non-fatal)"
        _noted_paths+=("/etc (partial — check warnings)")
    fi
}

_backup_cron() {
    [[ "$GENERIC_INCLUDE_CRON" == "true" ]] || return

    stage_path "/etc/crontab"              "System crontab"
    stage_path "/etc/cron.d"               "cron.d jobs"
    stage_path "/etc/cron.daily"           "Daily cron jobs"
    stage_path "/etc/cron.weekly"          "Weekly cron jobs"
    stage_path "/var/spool/cron/crontabs"  "User crontabs"
}

_backup_scripts() {
    [[ "$GENERIC_INCLUDE_SCRIPTS" == "true" ]] || return

    stage_path "/usr/local/bin"  "/usr/local/bin"
    stage_path "/root/scripts"   "/root/scripts"
}

_backup_packages() {
    [[ "$GENERIC_INCLUDE_PACKAGES" == "true" ]] || return

    stage_cmd "system-state/dpkg-selections.txt" "Installed packages"          dpkg --get-selections
    stage_cmd "system-state/apt-holds.txt"       "APT held packages"           apt-mark showhold
    stage_cmd "system-state/apt-manual.txt"      "Manually installed packages" apt-mark showmanual
    stage_cmd "system-state/os-release.txt"      "OS release"                  cat /etc/os-release
    stage_cmd "system-state/hostname.txt"        "Hostname"                    hostname
}

_backup_extra_paths() {
    [[ -n "${EXTRA_PATHS:-}" ]] || return

    log "  Staging extra paths..."
    for path in $EXTRA_PATHS; do
        stage_path "$path" "extra: $path"
        _noted_paths+=("$path (configured via EXTRA_PATHS)")
    done
}

# -----------------------------------------------------------------------------
# AUTO-DETECT WELL-KNOWN SERVICE PATHS
# -----------------------------------------------------------------------------
# If the user hasn't configured EXTRA_PATHS, check for common services and
# log a hint — we don't auto-include them (could be huge) but we tell the
# user they should configure it.

_hint_common_services() {
    local hints=()

    declare -A service_paths=(
        ["AdGuard Home"]="/opt/AdGuardHome"
        ["Vaultwarden"]="/opt/vaultwarden/data"
        ["Gitea"]="/opt/gitea/custom"
        ["Nextcloud config"]="/var/www/nextcloud/config"
        ["Nginx Proxy Manager"]="/opt/nginx-proxy-manager/data"
        ["Uptime Kuma"]="/opt/uptime-kuma"
        ["Immich config"]="/opt/immich"
        ["Jellyfin config"]="/etc/jellyfin"
    )

    for service in $(echo "${!service_paths[@]}" | tr ' ' '\n' | sort); do
        local path="${service_paths[$service]}"
        if [[ -d "$path" ]]; then
            # Only hint if not already in /etc (already covered) or EXTRA_PATHS
            if [[ "$path" != /etc/* ]] && ! echo "${EXTRA_PATHS:-}" | grep -q "$path"; then
                hints+=("$service at $path")
            fi
        fi
    done

    if [[ ${#hints[@]} -gt 0 ]]; then
        log_warn "  Detected service data outside /etc — consider adding to EXTRA_PATHS:"
        for hint in "${hints[@]}"; do
            log_warn "    $hint"
        done
    fi
}

# -----------------------------------------------------------------------------
# RESTORE NOTES
# -----------------------------------------------------------------------------

_write_restore_notes() {
    cat > "$STAGE_DIR/restore-notes.txt" << EOF
PABS Generic VM / LXC Restore Notes
Generated: $(date '+%Y-%m-%d %H:%M:%S')  Host: $(hostname)
Type:       generic
========================================

WHAT WAS BACKED UP:
$([ "$GENERIC_INCLUDE_ETC" == "true" ]      && echo "  ✓ /etc (full)")
$([ "$GENERIC_INCLUDE_CRON" == "true" ]     && echo "  ✓ Cron jobs")
$([ "$GENERIC_INCLUDE_SCRIPTS" == "true" ]  && echo "  ✓ /usr/local/bin, /root/scripts")
$([ "$GENERIC_INCLUDE_PACKAGES" == "true" ] && echo "  ✓ Package list (dpkg selections)")
$([ ${#_noted_paths[@]} -gt 0 ] && printf "  ✓ %s\n" "${_noted_paths[@]}")

HOW TO RESTORE:

  1. Fresh VM or LXC (same base OS as backed up)
     Detected OS: $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')

  2. Restore packages (requires internet):
       dpkg --set-selections < system-state/dpkg-selections.txt
       apt-get -y dselect-upgrade

  3. Restore /etc:
       rsync -a etc/ /etc/
     Or selectively: cp etc/myservice.conf /etc/myservice.conf

  4. Restore cron jobs:
       cp etc/crontab /etc/crontab
       rsync -a etc/cron.d/ /etc/cron.d/

  5. Restore scripts:
       rsync -a usr/local/bin/ /usr/local/bin/
       chmod +x /usr/local/bin/*

  6. Restart services:
       systemctl daemon-reload
       systemctl restart <your-services>

NOTES:
  - /etc is the primary source of truth for most Linux services
  - Service data (databases, media, etc.) is NOT backed up here
  - For stateful services, consider adding their data dirs to EXTRA_PATHS
  - Package restore installs all packages from backup time; some may not be
    available if the OS version has changed

RUNNING SERVICES AT BACKUP TIME:
$(systemctl list-units --type=service --state=running --no-legend 2>/dev/null | \
  awk '{print "  " $1}' | head -30 || echo "  (systemctl not available)")

EOF
    log "  ✓ restore-notes.txt written"
}

# -----------------------------------------------------------------------------
# ENTRY POINT
# -----------------------------------------------------------------------------

run_backup() {
    log "Generic backup starting on $(hostname)"

    _backup_etc
    _backup_cron
    _backup_scripts
    _backup_packages
    _backup_extra_paths
    _hint_common_services
    _write_restore_notes

    log "Generic backup complete"
}
