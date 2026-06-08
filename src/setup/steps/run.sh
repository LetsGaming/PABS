#!/bin/bash
# setup/steps/run.sh — Step 7: config summary, health check, first backup run

_print_config_summary() {
    local usb_mount target_uuid keep_backups stage_base
    local discord email rclone enc_pw agent_lines

    usb_mount=$(_cfg_get "USB_MOUNT")
    target_uuid=$(_cfg_get "TARGET_UUID")
    keep_backups=$(_cfg_get "KEEP_BACKUPS")
    stage_base=$(_cfg_get "LOCAL_STAGE_BASE")
    discord=$(_cfg_get "DISCORD_WEBHOOK")
    email=$(_cfg_get "NOTIFY_EMAIL")
    rclone=$(_cfg_get "RCLONE_REMOTE")
    enc_pw=$(_cfg_get "RCLONE_ENCRYPTION_PASSWORD")
    agent_lines=$(grep -c '".*\.sh"' "$CONFIG" 2>/dev/null || echo 0)

    printf "  %-25s %s\n" "USB_MOUNT"        "${usb_mount:-not set}"
    printf "  %-25s %s\n" "TARGET_UUID"      "${target_uuid:-not set (unsafe)}"
    printf "  %-25s %s\n" "KEEP_BACKUPS"     "${keep_backups:-4}"
    printf "  %-25s %s\n" "LOCAL_STAGE_BASE" "${stage_base:-/var/tmp/pabs-stage}"
    printf "  %-25s %s\n" "VM_AGENTS"        "${agent_lines} configured"
    printf "  %-25s %s\n" "Discord"          "$([[ -n "$discord" ]] && echo "configured" || echo "disabled")"
    printf "  %-25s %s\n" "Email"            "$([[ -n "$email"   ]] && echo "$email"     || echo "disabled")"
    printf "  %-25s %s\n" "Offsite remote"   "${rclone:-disabled}"
    printf "  %-25s %s\n" "Offsite encrypt"  "$([[ -n "$enc_pw"  ]] && echo "enabled"    || echo "disabled")"
}

_run_backup() {
    local mode="$1"  # "--dry-run" or ""
    echo ""
    _info "Running backup${mode:+ ($mode)}..."
    echo ""
    bash "$BACKUP_SCRIPT" $mode 2>&1 | sed 's/^/  /' \
        && _ok "Backup complete" \
        || _warn "Backup reported errors — check the log"
}

_step_run() {
    [[ -n "$JUMP_STEP" && "$JUMP_STEP" != "run" ]] && return
    _header "Step 7 of 7 — First Backup"

    _step "Configuration summary"
    echo ""
    _print_config_summary
    echo ""

    _step "Health check"
    echo ""
    bash "$STATUS_SCRIPT" 2>&1 | sed 's/^/  /' \
        && { echo ""; _ok "Health check passed"; } \
        || { echo ""; _warn "Health check issues above — you can still run the backup"; }
    echo ""

    _step "Ready to run"
    echo ""
    echo "  ${BOLD}Options:${RESET}"
    echo "  ${GREEN}1)${RESET} Dry run     — verify everything, no data written"
    echo "  ${GREEN}2)${RESET} Full backup — run the complete backup now"
    echo "  ${GREEN}3)${RESET} Skip        — exit (backup will run on schedule)"
    echo ""

    local choice
    choice=$(_ask "Choose" "1")

    case "$choice" in
        1)
            _run_backup "--dry-run"
            echo ""
            _ok "Dry run complete — check output above"
            if _ask_yn "Run full backup now?"; then
                _run_backup ""
            fi
            ;;
        2) _run_backup "" ;;
        *) _info "Skipping first run"; _dim "Run manually: bash $BACKUP_SCRIPT" ;;
    esac

    echo ""
    _ok "Setup complete"
}
