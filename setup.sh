#!/bin/bash
# =============================================================================
# setup.sh — PABS Interactive Setup Wizard
#
# Orchestrator only — all step logic lives in setup/steps/*.sh.
# This file handles argument parsing, preflight, module loading, and the
# final summary. Nothing else.
#
# Usage:
#   sudo bash setup.sh                  # full wizard
#   sudo bash setup.sh --step usb       # jump to a specific step
#   sudo bash setup.sh --yes            # non-interactive / CI mode
#
# Steps: deps | usb | notifications | agents | offsite | cron | run
# =============================================================================

# Interactive wizard — do NOT use set -e here.
# set -e causes silent exits on any non-zero command, which is catastrophic in
# a wizard: the user has no idea why the program disappeared. Every step handles
# its own errors explicitly instead.
#
# set -o pipefail is also omitted: grep exits 1 on no matches, which under
# pipefail silently kills any pipeline containing a grep that found nothing.
#
# set -u (unbound variables) is kept — an unbound variable is a real bug that
# should be loud, not silently treated as empty.
#
# backup.sh (the actual backup runner) still uses set -euo pipefail because
# there, bailing out on any error is the right behaviour.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=src/lib/env.sh
source "$SCRIPT_DIR/src/lib/env.sh"
normalize_path

CONFIG="$SCRIPT_DIR/config.sh"
TEMPLATE="$SCRIPT_DIR/config.template.sh"
INSTALL_AGENT="$SCRIPT_DIR/install-agent.sh"
BACKUP_SCRIPT="$SCRIPT_DIR/backup.sh"
STATUS_SCRIPT="$SCRIPT_DIR/pabs-status.sh"
export CONFIG INSTALL_AGENT BACKUP_SCRIPT STATUS_SCRIPT

# ---------------------------------------------------------------------------
# Self-update — plain git pull
# ---------------------------------------------------------------------------
# config.sh is .gitignored and never tracked. git pull updates only code files.
# Your settings in config.sh are never touched regardless of what upstream
# changed. After pulling, a new config.template.sh may contain new variables
# that your config.sh doesn't have yet — _cfg_set handles this gracefully by
# appending missing keys before the INTERNAL VARS sentinel.
# ---------------------------------------------------------------------------

_do_update() {
    echo "[PABS update] Checking for git..."
    command -v git &>/dev/null || {
        echo "[PABS update] ERROR: git is not installed. Install it with: apt install git"
        return 1
    }

    cd "$SCRIPT_DIR" || { echo "[PABS update] ERROR: cannot cd to $SCRIPT_DIR"; return 1; }

    git rev-parse --is-inside-work-tree &>/dev/null || {
        echo "[PABS update] ERROR: $SCRIPT_DIR is not a git repository."
        echo "             If you installed PABS by extracting a zip, update by downloading"
        echo "             the latest release, extracting it, and keeping your config.sh."
        return 1
    }

    local current_branch old_rev
    current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    old_rev=$(git rev-parse --short HEAD)
    echo "[PABS update] Branch: $current_branch  Current: $old_rev"

    echo "[PABS update] Pulling latest changes..."
    if ! git pull --ff-only 2>&1; then
        echo "[PABS update] ERROR: git pull failed."
        echo "             config.sh was not modified (it is .gitignored)."
        return 1
    fi

    local new_rev
    new_rev=$(git rev-parse --short HEAD)

    if [[ "$old_rev" == "$new_rev" ]]; then
        echo "[PABS update] Already up to date ($new_rev)."
    else
        echo "[PABS update] Updated $old_rev → $new_rev"
        echo ""
        echo "[PABS update] Changes:"
        git log --oneline "${old_rev}..${new_rev}" 2>/dev/null || true
    fi

    echo ""

    # Load UI + config helpers so _step_update can use _ok / _warn / _cfg_set_raw.
    # These may not be sourced yet when --update is the only argument passed.
    source "$SCRIPT_DIR/src/setup/ui.sh"
    source "$SCRIPT_DIR/src/setup/config_editor.sh"
    source "$SCRIPT_DIR/src/setup/steps/update.sh"

    # Bootstrap config.sh from the template if this is somehow a first run
    if [[ ! -f "$CONFIG" ]]; then
        cp "$TEMPLATE" "$CONFIG"
        chmod 600 "$CONFIG"
        echo "[PABS update] Created config.sh from template (first run)"
    fi

    _step_update

    echo ""
    echo "[PABS update] Done."
    return 0
}


JUMP_STEP=""
AUTO_YES=false
CHANGED=false   # set to true by _cfg_set/_cfg_set_raw; triggers final reminder
export AUTO_YES CHANGED

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --step)   JUMP_STEP="$2"; shift 2 ;;
        --yes)    AUTO_YES=true; shift ;;
        --update) _do_update; exit $? ;;
        -h|--help)
            echo "Usage: $0 [--step STEP] [--yes] [--update]"
            echo "Steps: deps | usb | notifications | agents | offsite | cron | run"
            echo ""
            echo "  --update   Pull the latest PABS code without touching config.sh"
            exit 0
            ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done
export JUMP_STEP

# ---------------------------------------------------------------------------
# Load shared modules
# ---------------------------------------------------------------------------

source "$SCRIPT_DIR/src/setup/ui.sh"
source "$SCRIPT_DIR/src/setup/config_editor.sh"

# Load all step modules
# shellcheck disable=SC1090  # dynamic: step modules discovered at runtime
for _step_file in "$SCRIPT_DIR"/src/setup/steps/*.sh; do
    source "$_step_file"
done
unset _step_file

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

_preflight() {
    [[ "$(id -u)" -eq 0 ]]        || _die "setup.sh must be run as root (sudo bash setup.sh)"
    [[ -f "$TEMPLATE" ]]           || _die "config.template.sh not found at $TEMPLATE — re-clone the repo"
    [[ -f "$INSTALL_AGENT" ]]      || _die "install-agent.sh not found at $INSTALL_AGENT"
    command -v apt-get &>/dev/null || _die "Requires a Debian/Ubuntu system (apt-get not found)"

    # Bootstrap config.sh from the template on first run.
    # config.sh is .gitignored — git pulls never touch it.
    if [[ ! -f "$CONFIG" ]]; then
        cp "$TEMPLATE" "$CONFIG"
        chmod 600 "$CONFIG"
        _ok "Created config.sh from template"
    fi
}

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------

_final_summary() {
    _header "Setup Complete"
    _ok "PABS is configured and ready"
    echo ""
    echo "  ${BOLD}Useful commands:${RESET}"
    echo ""
    printf "  %-45s %s\n" "Run a backup:"          "bash $BACKUP_SCRIPT"
    printf "  %-45s %s\n" "Dry run (no writes):"   "bash $BACKUP_SCRIPT --dry-run"
    printf "  %-45s %s\n" "Health check:"          "bash $STATUS_SCRIPT"
    printf "  %-45s %s\n" "Check cron:"            "crontab -l"
    printf "  %-45s %s\n" "View log:"              "tail -f $(_cfg_get "USB_MOUNT")/proxmox-backup/backup.log"
    printf "  %-45s %s\n" "Add a VM agent:"        "bash $SCRIPT_DIR/install-agent.sh root@<ip>"
    printf "  %-45s %s\n" "Re-run wizard:"         "bash $SCRIPT_DIR/setup.sh"
    printf "  %-45s %s\n" "Jump to a step:"        "bash $SCRIPT_DIR/setup.sh --step offsite"
    printf "  %-45s %s\n" "Update PABS:"           "bash $SCRIPT_DIR/setup.sh --update"
    echo ""
    echo "  ${BOLD}Documentation:${RESET}"
    printf "  %-45s %s\n" "All options:"           "$SCRIPT_DIR/docs/configuration.md"
    printf "  %-45s %s\n" "VM agents:"             "$SCRIPT_DIR/docs/vm-agents.md"
    printf "  %-45s %s\n" "Offsite sync:"          "$SCRIPT_DIR/docs/offsite.md"
    printf "  %-45s %s\n" "Restore procedures:"    "$SCRIPT_DIR/docs/restore.md"
    echo ""
    if $CHANGED; then
        _info "config.sh was updated during this session."
        _dim  "Review it at: $CONFIG"
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

_preflight

[[ -z "$JUMP_STEP" ]] && _step_welcome

_step_deps
_step_usb
_step_notifications
_step_agents
_step_offsite
_step_cron
_step_run

_final_summary
