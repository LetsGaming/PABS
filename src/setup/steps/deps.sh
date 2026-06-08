#!/bin/bash
# setup/steps/deps.sh — Step 1: dependency installation

_step_deps() {
    [[ -n "$JUMP_STEP" && "$JUMP_STEP" != "deps" ]] && return
    _header "Step 1 of 7 — Dependencies"

    local -a missing=() optional_missing=()

    _step "Checking required packages..."
    for pkg in rsync zstd tar gzip curl python3 ssh; do
        if command -v "$pkg" &>/dev/null; then
            _ok "$pkg"
        else
            _err "$pkg — missing"
            missing+=("$pkg")
        fi
    done

    _step "Checking optional packages..."

    if command -v rclone &>/dev/null; then
        _ok "rclone (offsite sync)"
    else
        _warn "rclone — not installed (needed for offsite sync)"
        optional_missing+=("rclone")
    fi

    if command -v gpg &>/dev/null; then
        _ok "gpg (offsite encryption)"
    else
        _warn "gnupg — not installed (needed for offsite encryption)"
        optional_missing+=("gnupg")
    fi

    if command -v mail &>/dev/null || command -v sendmail &>/dev/null; then
        _ok "mail / sendmail (email notifications)"
    else
        _warn "mailutils — not installed (needed for email notifications)"
        optional_missing+=("mailutils")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo ""
        _warn "Required packages missing: ${missing[*]}"
        if _ask_yn "Install missing required packages now?"; then
            apt-get update -qq
            apt-get install -y "${missing[@]}"
            _ok "Required packages installed"
        else
            _die "Cannot continue without required packages"
        fi
    fi

    if [[ ${#optional_missing[@]} -gt 0 ]]; then
        echo ""
        _info "Optional packages not installed: ${optional_missing[*]}"

        if [[ " ${optional_missing[*]} " == *" rclone "* ]]; then
            if _ask_yn "Install rclone? (needed for offsite cloud/SFTP sync)" "n"; then
                apt-get install -y rclone
                _ok "rclone installed"
                optional_missing=("${optional_missing[@]/rclone}")
            fi
        fi

        if [[ " ${optional_missing[*]} " == *" gnupg "* ]]; then
            if _ask_yn "Install gnupg? (needed to encrypt offsite archives)" "n"; then
                apt-get install -y gnupg
                _ok "gnupg installed"
                optional_missing=("${optional_missing[@]/gnupg}")
            fi
        fi

        if [[ " ${optional_missing[*]} " == *" mailutils "* ]]; then
            if _ask_yn "Install mailutils? (needed for email failure alerts)" "n"; then
                apt-get install -y mailutils
                _ok "mailutils installed"
            fi
        fi
    fi

    echo ""
    _ok "Dependency check complete"
}