#!/bin/bash
# setup/steps/offsite.sh — Step 5: rclone remote, bandwidth, retention, encryption

# ---------------------------------------------------------------------------
# Provider selection → sets remote_name and remote_path in caller scope via nameref
# ---------------------------------------------------------------------------

_offsite_select_provider() {
    local -n _name=$1 _path=$2

    local choice
    choice=$(_ask_choice "Cloud provider" "1" \
        "Google Drive   — 15 GB free, OAuth (browser auth)" \
        "OneDrive       — 5 GB free, OAuth (browser auth)" \
        "Backblaze B2   — 10 GB free, API key" \
        "Hetzner SFTP   — paid, fixed pricing, EU-hosted" \
        "Custom         — any rclone-supported remote")

    case "$choice" in
        1) _name="gdrive";    _path="proxmox-backup" ;;
        2) _name="onedrive";  _path="proxmox-backup" ;;
        3) _name="backblaze"; _path="my-bucket/proxmox-backup" ;;
        4) _name="hetzner";   _path="backup/proxmox" ;;
        *)
            _info "Enter the remote name exactly as it appears in 'rclone config'."
            _name=$(_ask "rclone remote name")
            _path=$(_ask "Path within the remote" "proxmox-backup")
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Retention questions — sensible defaults vary by provider
# ---------------------------------------------------------------------------

_offsite_configure_retention() {
    local provider_choice="$1"

    _step "Offsite retention"
    _info "Controls how many backup archives to keep on the remote."
    _info "Minimum: always kept regardless of other limits."
    _info "Maximum: oldest deleted when exceeded (0 = no limit)."
    _info "Storage cap: oldest deleted to stay under limit in GB (0 = no limit)."
    echo ""

    local keep_min keep_max max_gb

    case "$provider_choice" in
        1) # Google Drive 15 GB
            _info "Google Drive free tier: 15 GB — suggested defaults shown below."
            keep_min=$(_ask "Minimum backups to always keep" "1")
            keep_max=$(_ask "Maximum backups to keep (then prune oldest)" "4")
            max_gb=$(_ask   "Storage cap in GB (0 = no limit)" "14")
            ;;
        2) # OneDrive 5 GB
            _info "OneDrive free tier: 5 GB — suggested defaults shown below."
            keep_min=$(_ask "Minimum backups to always keep" "1")
            keep_max=$(_ask "Maximum backups to keep (then prune oldest)" "2")
            max_gb=$(_ask   "Storage cap in GB (0 = no limit)" "4")
            ;;
        *)
            keep_min=$(_ask "Minimum backups to always keep" "1")
            keep_max=$(_ask "Maximum backups to keep (0 = unlimited)" "4")
            max_gb=$(_ask   "Storage cap in GB (0 = no limit)" "0")
            ;;
    esac

    _cfg_set_raw "RCLONE_KEEP_MIN"       "$keep_min"
    _cfg_set_raw "RCLONE_KEEP_MAX"       "$keep_max"
    _cfg_set_raw "RCLONE_MAX_STORAGE_GB" "$max_gb"
    _ok "Retention: always keep ${keep_min}, prune above ${keep_max:-unlimited}, cap ${max_gb:-unlimited}GB"
}

# ---------------------------------------------------------------------------
# Encryption setup
# ---------------------------------------------------------------------------

_offsite_configure_encryption() {
    _step "Encryption"
    _info "Each backup is uploaded as a single .tar.zst archive."
    _info "When a passphrase is set, it is encrypted with GPG (AES-256) before upload."
    _info "The cloud provider sees only an opaque .tar.zst.gpg blob."
    _info "To restore: gpg -d <DATE>.tar.zst.gpg | tar --use-compress-program=zstd -xf -"
    echo ""

    local current_pw
    current_pw=$(_cfg_get "RCLONE_ENCRYPTION_PASSWORD")
    if [[ -n "$current_pw" ]]; then
        _ok "Encryption already configured"
        _ask_yn "Change the encryption password?" "n" || return
    fi

    if ! _ask_yn "Enable encryption? (strongly recommended)" "y"; then
        _warn "Encryption disabled — your cloud provider can read your backup data"
        _cfg_set "RCLONE_ENCRYPTION_PASSWORD" ""
        return
    fi

    # Ensure gpg is available
    if ! command -v gpg &>/dev/null; then
        _warn "gpg is not installed — required for encryption."
        if _ask_yn "Install gnupg now?"; then
            apt-get install -y gnupg && _ok "gnupg installed"
        else
            _warn "Encryption not configured — install gnupg and re-run: bash setup.sh --step offsite"
            return
        fi
    fi

    local pw pw2
    pw=$(_ask_secret "Encryption passphrase")
    if [[ -z "$pw" ]]; then
        _warn "Empty passphrase — encryption not configured"
        return
    fi

    pw2=$(_ask_secret "Confirm passphrase")
    if [[ "$pw" != "$pw2" ]]; then
        _err "Passphrases do not match — encryption NOT saved"
        _info "Re-run: bash setup.sh --step offsite"
        return
    fi

    _cfg_set "RCLONE_ENCRYPTION_PASSWORD" "$pw"
    _ok "Encryption passphrase saved"

    echo ""
    _warn "IMPORTANT: your passphrase is stored in config.sh on this host."
    _warn "It is automatically REDACTED from the copy written to USB."
    _warn "Back it up in a password manager NOW — without it, offsite data is unrecoverable."
    _pause "Press Enter to confirm you have saved the passphrase"
}

# ---------------------------------------------------------------------------
# Step entry point
# ---------------------------------------------------------------------------

_step_offsite() {
    [[ -n "$JUMP_STEP" && "$JUMP_STEP" != "offsite" ]] && return
    _header "Step 5 of 7 — Offsite Sync (3-2-1 Backup)"

    _info "Offsite sync gives you the third copy in a 3-2-1 backup strategy:"
    _info "  Copy 1  — local SSD staging (temporary, deleted after USB write)"
    _info "  Copy 2  — USB stick (primary restore target)"
    _info "  Copy 3  — cloud or remote server via rclone  ← this step"
    _info ""
    _info "Each backup run uploads one .tar.zst archive (optionally GPG-encrypted)."
    echo ""

    local current_remote
    current_remote=$(_cfg_get "RCLONE_REMOTE")
    if [[ -n "$current_remote" ]]; then
        _ok "Offsite already configured: $current_remote"
        _ask_yn "Update the offsite configuration?" "n" || return
    fi

    if ! command -v rclone &>/dev/null; then
        _warn "rclone is not installed (required for offsite sync)."
        if _ask_yn "Install rclone now?"; then
            apt-get install -y rclone && _ok "rclone installed"
        else
            _info "Skipping — configure later: bash setup.sh --step offsite"
            return
        fi
    fi

    if ! _ask_yn "Set up offsite sync?"; then
        _info "Skipping — configure later: bash setup.sh --step offsite"
        return
    fi

    # --- Provider ---
    _step "Select provider"
    local remote_name remote_path
    _offsite_select_provider remote_name remote_path
    local remote_full="${remote_name}:${remote_path}"

    # --- Configure rclone remote if not already done ---
    if rclone listremotes 2>/dev/null | grep -q "^${remote_name}:"; then
        _ok "rclone remote '${remote_name}' is already configured"
    else
        _warn "rclone remote '${remote_name}' is not configured yet."
        echo ""
        _info "You need to run 'rclone config' to authorise access to your cloud provider."
        _info "For OAuth providers (Google Drive, OneDrive) on a headless server:"
        _info "  1. Run 'rclone config' and create a new remote named '${remote_name}'"
        _info "  2. When asked 'Use auto config?' choose 'n'"
        _info "  3. Run the printed rclone authorize command on a machine with a browser"
        _info "  4. Paste the resulting token back here"
        echo ""
        if _ask_yn "Open 'rclone config' now to set up the remote?"; then
            rclone config
        else
            _warn "Skipping rclone config — remote '${remote_name}' will not work until configured"
        fi
    fi

    # --- Connectivity check ---
    _step "Testing remote connectivity..."
    if rclone lsd "${remote_name}:" --max-depth 1 &>/dev/null 2>&1; then
        _ok "Remote '${remote_name}' is reachable"
        rclone mkdir "$remote_full" 2>/dev/null \
            && _ok "Remote path ready: $remote_full" \
            || _warn "Could not create $remote_full — check permissions on the remote"
    else
        _warn "Could not reach '${remote_name}' — check your rclone config"
        if ! _ask_yn "Save this remote setting anyway (and fix connectivity later)?" "n"; then
            _info "Skipping offsite config"
            return
        fi
    fi

    _cfg_set "RCLONE_REMOTE" "$remote_full"
    _ok "RCLONE_REMOTE set to $remote_full"

    # --- Bandwidth ---
    _step "Bandwidth limiting"
    _info "Capping upload speed prevents PABS from saturating your internet connection."
    _info "Examples: 5M = 5 MB/s, 10M = 10 MB/s, 0 = unlimited."
    local bwlimit
    bwlimit=$(_ask "Upload speed limit" "5M")
    if [[ "$bwlimit" == "0" ]]; then
        _cfg_set "RCLONE_EXTRA_OPTS" ""
        _ok "No bandwidth limit set"
    else
        _cfg_set "RCLONE_EXTRA_OPTS" "--bwlimit $bwlimit"
        _ok "Upload capped at $bwlimit"
    fi

    # --- Retention ---
    local provider_num=5
    case "$remote_name" in
        gdrive)   provider_num=1 ;;
        onedrive) provider_num=2 ;;
    esac
    _offsite_configure_retention "$provider_num"

    # --- Encryption ---
    _offsite_configure_encryption

    echo ""
    _ok "Offsite configuration complete"
}