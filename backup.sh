#!/bin/bash
# =============================================================================
# PABS — Proxmox Automated Backup System
# Version 3.5
#
# Entry point. Sources config and library files, then runs the backup.
# The only logic here is the top-level execution sequence.
#
# File layout:
#   backup.sh                    ← you are here (run this)
#   config.sh                    ← edit this to configure your setup
#   setup.sh                     ← interactive setup wizard (start here)
#   src/lib/core.sh              ← logging, lock, trap, notifications
#   src/lib/offsite.sh           ← rclone encryption, upload, retention pruning
#   src/lib/preflight.sh         ← pre-flight validation checks
#   src/lib/sections.sh          ← 8 backup section functions + helpers
#   src/lib/host_health.sh       ← Proxmox host drive health checks (SMART, NVMe, dmesg)
#   src/lib/usb_health.sh        ← USB backup drive health checks
#   src/helpers/manifest.sh      ← SHA256 manifest generation/verification, rotation
#   src/helpers/output.sh        ← generates restore script and README inside each backup
#   src/vm-agent/agent.sh        ← deployed to VMs/LXCs for lightweight agent backups
#   install-agent.sh             ← one-time setup: deploys vm-agent to a VM over SSH
#   src/setup/                   ← wizard modules (ui, config_editor, step handlers)
#
# Usage:
#   ./backup.sh               — normal backup run
#   ./backup.sh --dry-run     — preflight checks + section log only, no writes
#   (schedule with cron: 0 3 * * 0 /path/to/pabs/backup.sh)
# =============================================================================

set -euo pipefail

# Resolve the directory this script lives in, regardless of how it was called
PABS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
DRY_RUN=false
VERIFY_MODE=false
VERIFY_TARGET=""
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --verify)  VERIFY_MODE=true ;;
        --verify=*) VERIFY_MODE=true; VERIFY_TARGET="${arg#*=}" ;;
        --help|-h)
            echo "Usage: $0 [--dry-run] [--verify[=BACKUP_DIR]]"
            echo "  --dry-run  Run preflight checks and log what would be backed up."
            echo "             No files are written to staging or USB."
            echo "  --verify   Verify the MANIFEST.sha256 of the latest backup on USB"
            echo "             (or of =BACKUP_DIR if given) without running a backup."
            echo "             Exit: 0 = all checksums OK, 1 = failure/corruption."
            exit 0
            ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done
export DRY_RUN

# Source config first — defines all variables consumed by the libs
source "$PABS_DIR/config.sh"

# Run-time vars — computed here so DATE is always the moment this run starts,
# never the moment config.sh was last sourced.
SCRIPT_VERSION="3.5"
DATE=$(date +"%Y-%m-%d_%H-%M-%S")
STAGE_DIR="$LOCAL_STAGE_BASE/.tmp-$DATE"
FINAL_DIR="$BACKUP_ROOT/$DATE"
readonly SCRIPT_VERSION DATE

# Source libs in dependency order:
#   core.sh sets up logging and the ERR/EXIT trap; everything after needs log()
source "$PABS_DIR/src/lib/core.sh"
source "$PABS_DIR/src/lib/offsite.sh"
source "$PABS_DIR/src/lib/preflight.sh"
source "$PABS_DIR/src/lib/sections.sh"
source "$PABS_DIR/src/lib/validate.sh"
source "$PABS_DIR/src/helpers/manifest.sh"
source "$PABS_DIR/src/helpers/output.sh"

# ---------------------------------------------------------------------------
# Dry-run wrapper: logs what would run, skips all writes
# ---------------------------------------------------------------------------
maybe_run() {
    # Usage: maybe_run <description> <function_or_command> [args...]
    # In dry-run mode: prints the description and returns without executing.
    local desc="$1"; shift
    if [[ "$DRY_RUN" == "true" ]]; then
        log "  [DRY-RUN] would run: $desc"
    else
        "$@"
    fi
}

# =============================================================================
# MAIN
# =============================================================================

check_root
check_usb_mounted

# ---------------------------------------------------------------------------
# --verify mode: re-check a backup's manifest and exit. No lock, no writes.
# This closes the loop on "is my backup actually restorable" by catching
# bit-rot / silent USB corruption between backup runs, on demand or via cron.
# ---------------------------------------------------------------------------
if [[ "$VERIFY_MODE" == "true" ]]; then
    target="$VERIFY_TARGET"
    if [[ -z "$target" ]]; then
        target=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d ! -name '.*' ! -name '*.tmp' \
            | sort | tail -1)
    fi
    [[ -n "$target" && -d "$target" ]] || die "No backup found to verify (looked in $BACKUP_ROOT)."
    [[ -f "$target/MANIFEST.sha256" ]] || die "No MANIFEST.sha256 in $target — cannot verify."

    log "Verifying backup: $target"
    if ( cd "$target" && sha256sum --quiet --check MANIFEST.sha256 2>>"$LOG" ); then
        file_count=$(wc -l < "$target/MANIFEST.sha256")
        log "  ✓ Integrity OK — all $file_count file(s) match their checksums"
        trap - ERR EXIT
        exit 0
    else
        log_err "Integrity FAILURE in $target — checksums do not match. Backup may be corrupt."
        dispatch_alert "VERIFY FAILED for $(basename "$target") — checksum mismatch. Backup may be corrupt."
        trap - ERR EXIT
        exit 1
    fi
fi

# Validate config before doing anything destructive or slow.
validate_config

mkdir -p "$BACKUP_ROOT" "$LOCAL_STAGE_BASE"

# Log rotation — when backup.log exceeds 2 MB, shift existing rotated logs
# (.1 → .2 → ... → .5) and move the current log to .1. backup.log.5 is
# discarded when a .6 would be created. Keeps up to 5 archived logs.
if [[ -f "$LOG" ]] && [[ $(stat -c%s "$LOG" 2>/dev/null || echo 0) -gt 2097152 ]]; then
    for i in 4 3 2 1; do
        [[ -f "${LOG}.${i}" ]] && mv "${LOG}.${i}" "${LOG}.$((i+1))"
    done
    mv "$LOG" "${LOG}.1"
fi

[[ "$DRY_RUN" == "true" ]] && log "======== DRY-RUN MODE — no writes will occur ========"
acquire_lock

log "========================================"
log "PABS backup started — $DATE"
log "Version        : $SCRIPT_VERSION"
log "Host           : $(hostname)"
log "USB mount      : $USB_MOUNT"
log "Local stage    : $LOCAL_STAGE_BASE"
log "VM agents      : ${#VM_AGENTS[@]} configured"
[[ "$DRY_RUN" == "true" ]] && log "Mode           : DRY-RUN (no data written)"
log "========================================"

check_local_stage_space
check_usb_space

maybe_run "mkdir staging $STAGE_DIR" mkdir -p "$STAGE_DIR"

# --- Backup sections — all output goes to STAGE_DIR on local SSD --------
maybe_run "section_proxmox_configs"   section_proxmox_configs
maybe_run "section_vm_ct_definitions" section_vm_ct_definitions
maybe_run "section_cron_jobs"         section_cron_jobs
maybe_run "section_firewall"          section_firewall
maybe_run "section_ssh_keys"          section_ssh_keys
maybe_run "section_system_state"      section_system_state
maybe_run "section_custom_scripts"    section_custom_scripts
maybe_run "section_vm_agents"         section_vm_agents

if [[ "$DRY_RUN" == "true" ]]; then
    log "========================================"
    log "DRY-RUN complete — no data written."
    log "Warnings : $WARNINGS"
    log "Errors   : $ERRORS"
    log "========================================"
    release_lock
    trap - ERR EXIT
    exit 0
fi

# Verify integrity on local SSD before a single byte goes to USB.
# A failed check aborts cleanly; _on_exit cleans up STAGE_DIR.
generate_and_verify_manifest

# --- Atomic USB commit sequence -----------------------------------------

log "Flushing local write buffers..."
sync

log "Transferring verified backup to USB..."
# Detach the cleanup trap before the transfer. From here we handle errors
# manually so we can distinguish "local stage still exists" from "already on USB".
trap - ERR EXIT

# --whole-file disables rsync's delta algorithm — this is a local copy, not a
# network transfer, so there are no checksums to compare and no partial files
# to resume. A direct sequential stream is faster and kinder to flash storage.
# --inplace is intentionally NOT used: it writes in-place, leaving a
# partial/corrupt file indistinguishable from a complete one after power loss.
# Atomicity is provided by the .tmp → mv rename below.
#
# ext4 is required on the USB drive (setup wizard enforces this). It supports
# symlinks, Unix permissions, and filesystem health checks — none of which are
# available on exFAT/FAT32/NTFS. The preflight check warns if another filesystem
# is detected. See docs/usb-health.md for filesystem requirements.
if rsync -a --whole-file "$STAGE_DIR/" "$FINAL_DIR.tmp/" 2>>"$LOG"; then
    log "  Transfer complete."
else
    log "FATAL: rsync to USB failed. Cleaning up."
    rm -rf "$FINAL_DIR.tmp" "$STAGE_DIR"
    dispatch_alert "FAILED: rsync to USB failed during transfer. Backup not committed."
    release_lock
    exit 1
fi

sync

# Atomic rename — backup only becomes "visible" after all bytes are on flash
mv "$FINAL_DIR.tmp" "$FINAL_DIR" || {
    log "FATAL: atomic rename failed. Partial backup at $FINAL_DIR.tmp — remove manually."
    rm -rf "$FINAL_DIR.tmp" "$STAGE_DIR"
    dispatch_alert "FAILED: mv rename failed. Partial backup at $FINAL_DIR.tmp."
    release_lock
    exit 1
}
sync

# Local staging freed — USB holds the only copy now
rm -rf "$STAGE_DIR"

# Re-attach trap for post-commit work (generate_restore_script, verification)
trap '_on_exit' ERR EXIT

generate_restore_script
generate_readme
generate_dr_playbook
sync

# Belt-and-suspenders: re-verify the manifest against what landed on USB
verify_manifest_on_usb

# Offsite sync — runs only if RCLONE_REMOTE is configured, non-fatal on failure
offsite_sync

# Rotate old backups only after the new one is successfully committed
rotate_old_backups

release_lock
trap - ERR EXIT

# --- Summary ----------------------------------------------------------------
BACKUP_SIZE=$(du -sh "$FINAL_DIR" 2>/dev/null | cut -f1 || echo "unknown")
log "========================================"
log "Backup complete!"
log "Location : $FINAL_DIR"
log "Size     : $BACKUP_SIZE"
log "Warnings : $WARNINGS"
log "Errors   : $ERRORS"
log "========================================"

if [[ $ERRORS -gt 0 ]]; then
    log "⚠  Backup finished with $ERRORS error(s). Review the log."
    dispatch_alert "Backup $DATE finished with $ERRORS error(s). Review: $LOG"
    trap - ERR EXIT
    exit 1
fi

[[ $WARNINGS -gt 0 ]] && log "ℹ  $WARNINGS warning(s) — non-fatal, review log if unexpected."

dispatch_alert "SUCCESS — backup $DATE complete. Size: $BACKUP_SIZE. Warnings: $WARNINGS"

exit 0
