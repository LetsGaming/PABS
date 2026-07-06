#!/bin/bash
# =============================================================================
# update-agents.sh — Push updated vm-agent files to all registered PABS agents
#
# Reads VM_AGENTS (and per-VM SSH key overrides) from config.sh, then syncs
# the local vm-agent/ directory to each host — identical to what install-agent.sh
# does for file transfer, but without the first-time setup steps (dependency
# checks, known_hosts registration, config.sh registration).
#
# USAGE:
#   bash update-agents.sh [--label <label>] [--dry-run] [--help]
#
# OPTIONS:
#   --label <label>   Update only the named agent (repeat for multiple).
#   --dry-run         Show what would be transferred; make no changes.
#   --help            Show this message.
#
# EXIT CODES:
#   0   All targeted agents updated successfully.
#   1   One or more agents failed; others may have succeeded.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_SOURCE="$SCRIPT_DIR/src/vm-agent"
CONFIG_FILE="$SCRIPT_DIR/config.sh"
PABS_KNOWN_HOSTS="/root/.ssh/pabs_known_hosts"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()      { echo "[update-agents] $*"; }
log_ok()   { echo "[update-agents]   ✓  $*"; }
log_warn() { echo "[update-agents]   ⚠  $*" >&2; }
log_err()  { echo "[update-agents]   ✗  $*" >&2; }

usage() {
    sed -n '/^# USAGE:/,/^# =/{ /^# =/d; s/^# \{0,3\}//; p }' "$0"
    exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

FILTER_LABELS=()
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --label)
            [[ -n "${2:-}" ]] || { log_err "--label requires a value"; exit 1; }
            FILTER_LABELS+=("$2")
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            usage
            ;;
        *)
            log_err "Unknown argument: $1"
            echo "Run with --help for usage." >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------

[[ -f "$AGENT_SOURCE/agent.sh" ]] || {
    log_err "vm-agent/agent.sh not found at $AGENT_SOURCE"
    log_err "Run this script from the PABS root directory."
    exit 1
}

[[ -f "$CONFIG_FILE" ]] || {
    log_err "config.sh not found at $CONFIG_FILE"
    log_err "Run the setup wizard first: bash $SCRIPT_DIR/setup.sh"
    exit 1
}

# ---------------------------------------------------------------------------
# Load config (VM_AGENTS, VM_SSH_KEY, VM_AGENT_SSH_OPTS, ...)
# ---------------------------------------------------------------------------

# shellcheck source=config.sh
source "$CONFIG_FILE"

if [[ ${#VM_AGENTS[@]} -eq 0 ]]; then
    log "No agents configured in VM_AGENTS — nothing to do."
    exit 0
fi

# Resolve SSH opts from config (same defaults as install-agent.sh)
BASE_SSH_OPTS=(
    -o BatchMode=yes
    -o ConnectTimeout=10
    -o StrictHostKeyChecking=yes
    -o "UserKnownHostsFile=$PABS_KNOWN_HOSTS"
)

# VM_AGENT_SSH_OPTS from config.sh overrides the defaults if present
if [[ -n "${VM_AGENT_SSH_OPTS[*]+set}" && ${#VM_AGENT_SSH_OPTS[@]} -gt 0 ]]; then
    BASE_SSH_OPTS=("${VM_AGENT_SSH_OPTS[@]}")
fi

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------

total=0
ok=0
failed=0
skipped=0

# ---------------------------------------------------------------------------
# Per-agent update function
# ---------------------------------------------------------------------------

_update_agent() {
    local entry="$1"
    local label vm_host ssh_user agent_path remote_dir
    read -r label vm_host ssh_user agent_path <<< "$entry"

    if [[ -z "$label" || -z "$vm_host" || -z "$ssh_user" || -z "$agent_path" ]]; then
        log_warn "Malformed VM_AGENTS entry, skipping: '$entry'"
        : $(( skipped++ )) || true
        return
    fi

    : $(( total++ )) || true

    # Apply --label filter
    if [[ ${#FILTER_LABELS[@]} -gt 0 ]]; then
        local match=false
        for f in "${FILTER_LABELS[@]}"; do
            [[ "$f" == "$label" ]] && match=true && break
        done
        if ! $match; then
            : $(( skipped++ )) || true
            return
        fi
    fi

    remote_dir="$(dirname "$agent_path")"

    log "[$label] $ssh_user@$vm_host → $remote_dir"

    # Build SSH opts for this agent (per-VM key override, same logic as sections.sh)
    local ssh_opts=("${BASE_SSH_OPTS[@]}")
    local key_var="VM_SSH_KEY_${label//-/_}"
    [[ -n "${!key_var:-}" ]] && ssh_opts+=(-i "${!key_var}")
    [[ -n "${VM_SSH_KEY:-}" && -z "${!key_var:-}" ]] && ssh_opts+=(-i "$VM_SSH_KEY")

    # Connectivity check
    if ! ssh "${ssh_opts[@]}" "$ssh_user@$vm_host" exit 2>/dev/null; then
        log_err "[$label] Cannot connect to $vm_host — skipping"
        : $(( failed++ )) || true
        return
    fi

    # Dry-run: just show what rsync would transfer
    if $DRY_RUN; then
        log "[$label]   (dry-run) rsync --dry-run from $AGENT_SOURCE/ to $vm_host:$remote_dir/"
        rsync --dry-run -av --delete \
            -e "ssh ${ssh_opts[*]@Q}" \
            "$AGENT_SOURCE/" \
            "$ssh_user@$vm_host:$remote_dir/" \
            2>&1 | sed "s/^/[$label]   /"
        : $(( ok++ )) || true
        return
    fi

    # Check if remote has rsync; fall back to scp if not
    local remote_has_rsync=false
    if ssh "${ssh_opts[@]}" "$ssh_user@$vm_host" "command -v rsync >/dev/null 2>&1"; then
        remote_has_rsync=true
    fi

    local copy_rc=0

    if $remote_has_rsync; then
        rsync -a --delete \
            -e "ssh ${ssh_opts[*]@Q}" \
            "$AGENT_SOURCE/" \
            "$ssh_user@$vm_host:$remote_dir/" \
            2>&1 | sed "s/^/[$label]   /" \
            || copy_rc=$?
    else
        log_warn "[$label] rsync not available on remote — falling back to scp"
        local scp_opts=(
            -o BatchMode=yes
            -o ConnectTimeout=10
            -o StrictHostKeyChecking=yes
            -o "UserKnownHostsFile=$PABS_KNOWN_HOSTS"
        )
        [[ -n "${!key_var:-}"     ]] && scp_opts+=(-i "${!key_var}")
        [[ -n "${VM_SSH_KEY:-}"   ]] && [[ -z "${!key_var:-}" ]] && scp_opts+=(-i "$VM_SSH_KEY")

        scp -q -r "${scp_opts[@]}" "$AGENT_SOURCE/." "$ssh_user@$vm_host:$remote_dir/" \
            2>&1 | sed "s/^/[$label]   /" \
            || copy_rc=$?
    fi

    if [[ $copy_rc -ne 0 ]]; then
        log_err "[$label] File transfer failed (exit $copy_rc)"
        : $(( failed++ )) || true
        return
    fi

    # Fix permissions (same as install-agent.sh)
    ssh "${ssh_opts[@]}" "$ssh_user@$vm_host" \
        "chmod +x \"$agent_path\" && chmod 644 \"$remote_dir\"/types/*.sh" 2>/dev/null

    # Ensure required tools are present — an update may introduce a new dep.
    # Tries apt-get (Debian/Ubuntu), then apk (Alpine/HAOS), then warns.
    for _dep in rsync zstd python3; do
        # shellcheck disable=SC2087  # intentional: $_dep expands client-side before send
        ssh "${ssh_opts[@]}" "$ssh_user@$vm_host" "bash -s" << SSHEOF 2>/dev/null || true
            command -v ${_dep} >/dev/null 2>&1 && exit 0
            if command -v apt-get >/dev/null 2>&1; then
                apt-get install -y ${_dep} >/dev/null 2>&1 && exit 0
            fi
            if command -v apk >/dev/null 2>&1; then
                apk add --no-cache ${_dep} >/dev/null 2>&1 && exit 0
            fi
            echo "[update-agents]   ⚠  ${_dep} not found and could not be installed automatically on $vm_host"
SSHEOF
    done
    unset _dep

    # Quick smoke-test: ask the agent to report its detected type
    local detected_type
    detected_type="$(
        ssh "${ssh_opts[@]}" "$ssh_user@$vm_host" \
            "bash '$agent_path' --type" 2>/dev/null | tail -1 \
        || echo "unknown"
    )"

    log_ok "[$label] Updated — detected type: $detected_type"
    : $(( ok++ )) || true
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

log "========================================"
$DRY_RUN && log "DRY RUN — no changes will be made"
log "Agent source : $AGENT_SOURCE"
log "Agents       : ${#VM_AGENTS[@]} configured"
[[ ${#FILTER_LABELS[@]} -gt 0 ]] && log "Filter       : ${FILTER_LABELS[*]}"
log "========================================"
log ""

for entry in "${VM_AGENTS[@]}"; do
    _update_agent "$entry"
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

log ""
log "========================================"
log "Done.  OK: $ok   Failed: $failed   Skipped: $skipped"
log "========================================"

if [[ $failed -gt 0 ]]; then
    exit 1
fi
