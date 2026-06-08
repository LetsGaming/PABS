#!/bin/bash
# =============================================================================
# setup/steps/update.sh — Post-git-pull update tasks
#
# Called by _do_update in setup.sh after a successful git pull (or when the
# code is already up to date). Handles two things that git pull cannot:
#
#   1. CONFIG MIGRATION — adds any keys that exist in config.template.sh but
#      are absent from the user's config.sh, using their template defaults.
#      Never touches keys that are already present. Never rewrites values the
#      user has customised.
#
#   2. AGENT FILE PUSH — rsync the updated vm-agent/ directory to every
#      registered agent host so they run the new code on the next backup.
#
# This is wired into _do_update in setup.sh so that
#   bash setup.sh --update
# does the full update in one command.
# =============================================================================

# ---------------------------------------------------------------------------
# _cfg_insert_block FULL_LINE
#
# Inserts FULL_LINE (which may span multiple lines, with backslash
# continuations) immediately before the INTERNAL VARS sentinel in $CONFIG.
#
# Uses python3 + a temp file to avoid two problems:
#   a) sed cannot insert multi-line blocks portably — trailing backslashes
#      are interpreted as line-continuations in the replacement string.
#   b) Passing multi-line strings with arbitrary quoting via shell args is
#      fragile. Writing to a temp file sidesteps all of it cleanly.
#
# python3 is already a hard dependency of PABS (used in core.sh and install).
# ---------------------------------------------------------------------------
_cfg_insert_block() {
    local full_line="$1"
    local tmp_block
    tmp_block=$(mktemp)
    printf '%s\n' "$full_line" > "$tmp_block"

    python3 - "$CONFIG" "$tmp_block" << 'PYEOF'
import sys

config_path = sys.argv[1]
block_path  = sys.argv[2]
sentinel    = "# INTERNAL VARS"

with open(block_path) as f:
    new_block = f.read()      # already ends with newline from printf

with open(config_path) as f:
    lines = f.readlines()

insert_at = len(lines)        # fallback: append at end
for i, line in enumerate(lines):
    if sentinel in line:
        insert_at = i
        break

lines.insert(insert_at, new_block)

with open(config_path, "w") as f:
    f.writelines(lines)
PYEOF

    rm -f "$tmp_block"
}

# ---------------------------------------------------------------------------
# Config migration
#
# Strategy: iterate over every top-level assignment in config.template.sh
# above the INTERNAL VARS sentinel. For each key, check whether it already
# exists (commented or uncommented) in config.sh. If not, extract its full
# default value from the template — including multi-line backslash
# continuations — and insert it before the INTERNAL VARS sentinel.
# ---------------------------------------------------------------------------

_update_migrate_config() {
    _header "Config migration"

    local added=0
    local skipped=0

    # Collect all user-facing key names from the template, stopping at the
    # INTERNAL VARS sentinel so we never try to migrate derived/internal vars.
    local -a keys=()
    while IFS= read -r line; do
        [[ "$line" =~ ^#.*INTERNAL\ VARS ]] && break
        if [[ "$line" =~ ^([A-Z_][A-Z_0-9]*)= ]]; then
            keys+=("${BASH_REMATCH[1]}")
        fi
    done < "$TEMPLATE"

    if [[ ${#keys[@]} -eq 0 ]]; then
        _warn "No keys found in config.template.sh — skipping migration"
        return
    fi

    _step "Checking for missing config keys (${#keys[@]} in template)..."
    echo ""

    for key in "${keys[@]}"; do
        # Key already present (active or commented-out) — leave it alone.
        # This intentionally preserves user-customised values.
        if grep -qE "^[[:space:]]*#?[[:space:]]?${key}[[:space:]]*=" "$CONFIG" 2>/dev/null; then
            : $(( skipped++ )) || true
            continue
        fi

        # Key absent — extract its full default value from the template.
        # Handles two shapes:
        #   Simple:     KEY=value
        #   Multi-line: KEY=( ... \
        #                    ... )
        local raw_value=""
        local in_block=false
        while IFS= read -r tline; do
            [[ "$tline" =~ ^#.*INTERNAL\ VARS ]] && break

            if ! $in_block; then
                if [[ "$tline" =~ ^${key}= ]]; then
                    raw_value="${tline#*=}"
                    in_block=true
                    [[ "$tline" == *\\ ]] || break   # no continuation — done
                fi
            else
                raw_value+=$'\n'"$tline"
                [[ "$tline" == *\\ ]] || break       # last continuation line
            fi
        done < "$TEMPLATE"

        local full_line="${key}=${raw_value}"
        _cfg_insert_block "$full_line"

        _ok "  Added: $key"
        _dim "        default: ${raw_value%%$'\n'*}"   # show only first line
        : $(( added++ )) || true
        CHANGED=true
    done

    echo ""
    if [[ $added -eq 0 ]]; then
        _ok "config.sh is already up to date — no new keys needed"
    else
        _ok "$added new key(s) added to config.sh with template defaults"
        _info "Review and adjust them at: $CONFIG"
    fi
}

# ---------------------------------------------------------------------------
# Agent file push
#
# Delegates entirely to update-agents.sh so the logic lives in one place.
# ---------------------------------------------------------------------------

_update_push_agents() {
    _header "Push updated agent files"

    local update_script="$SCRIPT_DIR/update-agents.sh"

    if [[ ! -f "$update_script" ]]; then
        _warn "update-agents.sh not found at $update_script — skipping agent push"
        return
    fi

    # Count configured agents (same grep as _step_agents uses)
    local agent_count
    agent_count=$(grep -cE '^[[:space:]]+"[a-zA-Z0-9].*\.sh"' "$CONFIG" 2>/dev/null || echo 0)

    if [[ "$agent_count" -eq 0 ]]; then
        _info "No agents configured in VM_AGENTS — nothing to push"
        return
    fi

    _info "$agent_count agent(s) configured."

    if ! _ask_yn "Push updated vm-agent files to all registered agents now?"; then
        _info "Skipped — push manually later with: bash update-agents.sh"
        return
    fi

    echo ""
    bash "$update_script"
    local rc=$?

    echo ""
    if [[ $rc -eq 0 ]]; then
        _ok "All agents updated successfully"
    else
        _warn "One or more agents failed — check output above"
        _dim  "Retry individual agents with: bash update-agents.sh --label <name>"
    fi
}

# ---------------------------------------------------------------------------
# Entry point — called by _do_update in setup.sh
# ---------------------------------------------------------------------------

_step_update() {
    _update_migrate_config
    _update_push_agents
}
