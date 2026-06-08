#!/bin/bash
# setup/steps/notifications.sh — Step 3: Discord webhook and email alerts

_step_notifications() {
    [[ -n "$JUMP_STEP" && "$JUMP_STEP" != "notifications" ]] && return
    _header "Step 3 of 7 — Notifications"

    _info "PABS can alert you on backup success, failure, and low-disk-space events."
    _info "Both channels are optional — skip either or both if you don't need them."

    # --- Discord ---
    _step "Discord webhook (recommended)"
    local current_webhook
    current_webhook=$(_cfg_get "DISCORD_WEBHOOK")

    if [[ -n "$current_webhook" ]]; then
        _ok "Discord webhook already configured"
        if ! _ask_yn "Update it?" "n"; then
            echo ""
        else
            current_webhook=""
        fi
    fi

    if [[ -z "$current_webhook" ]]; then
        _info "To create a webhook: open your Discord server → Settings → Integrations → Webhooks"
        _info "Click 'New Webhook', choose a channel, and copy the URL."
        if _ask_yn "Set up Discord notifications?" "n"; then
            local webhook
            webhook=$(_ask "Paste your Discord webhook URL")
            if [[ -n "$webhook" ]]; then
                _info "Sending a test message to verify the webhook..."
                local http_code
                http_code=$(curl -s -o /dev/null -w "%{http_code}" \
                    -H "Content-Type: application/json" \
                    -d '{"content":"✅ PABS setup test — Discord notifications working!"}' \
                    "$webhook" 2>/dev/null || echo "000")
                if [[ "$http_code" == "204" ]]; then
                    _ok "Test message sent successfully — check your Discord channel"
                    _cfg_set "DISCORD_WEBHOOK" "$webhook"
                    _ok "Discord webhook saved"
                else
                    _warn "Test failed (HTTP $http_code)"
                    if [[ "$http_code" == "000" ]]; then
                        _warn "Could not reach Discord — check your network connection."
                    elif [[ "$http_code" == "401" || "$http_code" == "404" ]]; then
                        _warn "Webhook URL appears invalid — double-check you copied the full URL."
                    fi
                    if _ask_yn "Save the webhook URL anyway?" "n"; then
                        _cfg_set "DISCORD_WEBHOOK" "$webhook"
                        _ok "Discord webhook saved (test failed — verify manually)"
                    fi
                fi
            else
                _info "No URL entered — skipping Discord"
            fi
        else
            _info "Skipping Discord notifications"
        fi
    fi

    # --- Email ---
    _step "Email notifications (failure alerts only)"
    local current_email
    current_email=$(_cfg_get "NOTIFY_EMAIL")

    if [[ -n "$current_email" ]]; then
        _ok "Email already configured: $current_email"
        if _ask_yn "Update it?" "n"; then
            current_email=""
        fi
    fi

    if [[ -z "$current_email" ]]; then
        if command -v mail &>/dev/null || command -v sendmail &>/dev/null; then
            if _ask_yn "Set up email failure alerts?" "n"; then
                local email
                email=$(_ask "Email address for failure alerts")
                if [[ -n "$email" ]]; then
                    _cfg_set "NOTIFY_EMAIL" "$email"
                    _ok "NOTIFY_EMAIL set to $email"
                    if _ask_yn "Send a test email now?"; then
                        echo "PABS setup test — email notifications working" \
                            | mail -s "PABS test alert" "$email" 2>/dev/null \
                            && _ok "Test email sent" \
                            || _warn "mail command failed — check your MTA (postfix/nullmailer) configuration"
                    fi
                fi
            else
                _info "Skipping email notifications"
            fi
        else
            _info "mailutils is not installed — email notifications unavailable."
            _dim "Install it later with: apt install mailutils"
            _dim "Then re-run: bash setup.sh --step notifications"
        fi
    fi

    echo ""
    _ok "Notification configuration complete"
}
