#!/bin/bash
# =============================================================================
# setup/config_editor.sh — config.sh read / write helpers
#
# Sourced by setup.sh and install-agent.sh. All functions operate on the
# $CONFIG path exported by the caller.
# Nothing here produces user-visible output — callers handle that.
#
# Functions:
#   _cfg_get KEY               → print current value (empty if unset/commented)
#   _cfg_set KEY VALUE         → set quoted string value
#   _cfg_set_raw KEY VALUE     → set unquoted value (integers, booleans, arrays)
#   _cfg_append_vm_agent ENTRY → append one agent entry to VM_AGENTS array
# =============================================================================

# ---------------------------------------------------------------------------
# _cfg_get KEY
# Reads the active (uncommented) value of KEY from $CONFIG.
# Returns empty string if the key is missing or commented out.
# ---------------------------------------------------------------------------
_cfg_get() {
    local key="$1"
    grep -E "^${key}=" "$CONFIG" 2>/dev/null \
        | tail -1 \
        | sed -E "s/^[^=]+=[\"']?([^\"'#]*)[\"']?.*$/\\1/" \
        | sed 's/[[:space:]]*$//'
}

# ---------------------------------------------------------------------------
# _cfg_set KEY VALUE
# Sets KEY="VALUE" in $CONFIG.
#   - Replaces an existing active assignment in-place.
#   - Uncomments a DIRECTLY commented-out assignment (^# KEY= or ^#KEY=).
#     A "directly commented" line has at most one space between # and KEY.
#     This intentionally does NOT touch documentation comments that merely
#     mention the key name, such as:
#       #   RCLONE_KEEP_MIN=1    ← indented example (2+ spaces after #)
#       # e.g. RCLONE_KEEP_MIN  ← prose mention
#     Only lines matching exactly ^#\s?KEY= are candidates.
#   - Appends before the INTERNAL VARS sentinel if the key is absent entirely.
# Never touches the INTERNAL VARS section.
# ---------------------------------------------------------------------------
_cfg_set() {
    local key="$1"
    local value="$2"

    local escaped
    escaped=$(printf '%s' "$value" | sed 's/[\/&]/\\&/g')

    if grep -qE "^${key}=" "$CONFIG" 2>/dev/null; then
        # Active assignment exists — replace value in-place
        sed -i -E "s|^(${key}=).*|\1\"${escaped}\"|" "$CONFIG"

    elif grep -qE "^#[[:space:]]?${key}=" "$CONFIG" 2>/dev/null; then
        # Directly commented-out assignment — uncomment and set value.
        # Two-step: first strip the leading #(space), then normalise the value.
        # The 0, addr ensures only the first match is touched.
        sed -i -E "0,/^#[[:space:]]?${key}=/{s|^#[[:space:]]?(${key}=.*)|\1|}" "$CONFIG"
        sed -i -E "s|^(${key}=).*|\1\"${escaped}\"|" "$CONFIG"

    else
        # Key not present at all — insert before the INTERNAL VARS sentinel
        sed -i "/^# =*.*INTERNAL VARS/i ${key}=\"${escaped}\"" "$CONFIG"
    fi

    # CHANGED is initialised and exported by setup.sh; in install-agent.sh context
    # it is set but never read — harmless dead assignment there (SC2034).
    CHANGED=true
}

# ---------------------------------------------------------------------------
# _cfg_set_raw KEY VALUE
# Like _cfg_set but writes the value without surrounding quotes.
# Use for integers (KEEP_BACKUPS=4), booleans (BACKUP_ZFS=true), and arrays.
# ---------------------------------------------------------------------------
_cfg_set_raw() {
    local key="$1"
    local value="$2"

    local escaped
    escaped=$(printf '%s' "$value" | sed 's/[\/&]/\\&/g')

    if grep -qE "^${key}=" "$CONFIG" 2>/dev/null; then
        sed -i -E "s|^(${key}=).*|\1${escaped}|" "$CONFIG"

    elif grep -qE "^#[[:space:]]?${key}=" "$CONFIG" 2>/dev/null; then
        sed -i -E "0,/^#[[:space:]]?${key}=/{s|^#[[:space:]]?(${key}=.*)|\1|}" "$CONFIG"
        sed -i -E "s|^(${key}=).*|\1${escaped}|" "$CONFIG"

    else
        sed -i "/^# =*.*INTERNAL VARS/i ${key}=${escaped}" "$CONFIG"
    fi

    CHANGED=true
}

# ---------------------------------------------------------------------------
# _cfg_append_vm_agent ENTRY
# Appends one "label  host  user  path" entry to the VM_AGENTS array.
# Handles both the empty-array case (VM_AGENTS=()) and a populated array.
# ---------------------------------------------------------------------------
_cfg_append_vm_agent() {
    local entry="$1"

    if grep -qE "^VM_AGENTS=\(\)" "$CONFIG"; then
        sed -i -E "s|^VM_AGENTS=\(\)|VM_AGENTS=(\n    \"${entry}\"\n)|" "$CONFIG"
    else
        sed -i "/^VM_AGENTS=(/,/)/{/)$/i\\    \"${entry}\"
}" "$CONFIG"
    fi

    CHANGED=true
}
