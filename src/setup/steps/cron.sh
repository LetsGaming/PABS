#!/bin/bash
# setup/steps/cron.sh — Step 6: cron schedule

_step_cron() {
    [[ -n "$JUMP_STEP" && "$JUMP_STEP" != "cron" ]] && return
    _header "Step 6 of 7 — Cron Schedule"

    local existing_cron
    existing_cron=$(crontab -l 2>/dev/null | grep -F "$BACKUP_SCRIPT" || true)

    if [[ -n "$existing_cron" ]]; then
        _ok "PABS is already scheduled:"
        _dim "  $existing_cron"
        _ask_yn "Update the schedule?" "n" || return
    fi

    _step "Choose a backup schedule"

    local schedule_choice
    schedule_choice=$(_ask_choice "Schedule" "1" \
        "Weekly  — Sunday at 03:00    (recommended)" \
        "Weekly  — Saturday at 02:00" \
        "Daily   — every day at 03:00" \
        "Monthly — 1st of month at 03:00" \
        "Custom cron expression")

    local cron_expr
    case "$schedule_choice" in
        1) cron_expr="0 3 * * 0" ;;
        2) cron_expr="0 2 * * 6" ;;
        3) cron_expr="0 3 * * *" ;;
        4) cron_expr="0 3 1 * *" ;;
        5)
            _info "Format: minute  hour  day-of-month  month  day-of-week"
            _info "Example: '0 3 * * 0'  = every Sunday at 03:00"
            _info "         '30 2 * * 1' = every Monday at 02:30"
            cron_expr=$(_ask "Cron expression" "0 3 * * 0")
            ;;
    esac

    local cron_line="${cron_expr}  bash ${BACKUP_SCRIPT} >> /var/log/pabs-cron.log 2>&1"
    _info "Will add: $cron_line"

    if _ask_yn "Add this to root's crontab?"; then
        (crontab -l 2>/dev/null | grep -v "$BACKUP_SCRIPT" || true; echo "$cron_line") \
            | crontab -
        if crontab -l 2>/dev/null | grep -qF "$BACKUP_SCRIPT"; then
            _ok "Cron job added and verified"
        else
            _warn "Could not verify crontab entry — check with: crontab -l"
        fi
    else
        _info "Skipping cron setup"
        _dim "Add manually: crontab -e"
        _dim "Cron line:    $cron_line"
    fi

    echo ""
    _ok "Cron schedule configured"
}
