#!/bin/bash
# =============================================================================
# install-agent.sh — Deploy the PABS agent to a VM or LXC over SSH
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=src/lib/env.sh
source "$SCRIPT_DIR/src/lib/env.sh"
normalize_path

AGENT_SOURCE="$SCRIPT_DIR/src/vm-agent"
REMOTE_DIR=""          # resolved after argument parsing; see below
SSH_KEY=""
SSH_PORT=""
PABS_KNOWN_HOSTS="/root/.ssh/pabs_known_hosts"

# StrictHostKeyChecking=accept-new is trust-on-first-use (TOFU): the first
# connection to each host is accepted and its key pinned into the dedicated
# PABS_KNOWN_HOSTS file; any later key change is refused. The one-time window
# on the very first connect is an accepted tradeoff for a deploy tool on a
# trusted LAN (audit SEC-03). To close it entirely, pre-pin the key before
# running this script:
#   ssh-keyscan -H <vm-ip> >> /root/.ssh/pabs_known_hosts
SSH_OPTS=(
    -o BatchMode=yes
    -o ConnectTimeout=10
    -o StrictHostKeyChecking=accept-new
    -o UserKnownHostsFile="$PABS_KNOWN_HOSTS"
)

declare -a SET_VARS=()
LABEL=""

usage() {
    echo "Usage: $0 <user@host> [--label NAME] [--dir /remote/path] [--key /path/to/key] [--port PORT] [--set KEY=VALUE ...]"
    echo "  --label NAME   Short identifier used as the VM_AGENTS entry label and backup folder name."
    echo "                 Defaults to an auto-derived name from the hostname."
    echo "  --port PORT    SSH port on the remote host (default: 22). Use 22222 for HAOS SSH add-on."
    exit 1
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

[[ $# -lt 1 ]] && usage

TARGET="$1"
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --label)
            LABEL="$2"
            shift 2
            ;;
        --dir)
            REMOTE_DIR="$2"
            shift 2
            ;;
        --key)
            SSH_KEY="$2"
            shift 2
            ;;
        --port)
            SSH_PORT="$2"
            shift 2
            ;;
        --set)
            [[ "$2" == *=* ]] || {
                echo "--set requires KEY=VALUE format"
                exit 1
            }

            SET_VARS+=("$2")
            shift 2
            ;;
        *)
            echo "Unknown argument: $1"
            usage
            ;;
    esac
done

if [[ -n "$SSH_KEY" ]]; then
    [[ -f "$SSH_KEY" ]] || {
        echo "SSH key not found: $SSH_KEY"
        exit 1
    }

    SSH_OPTS+=(-i "$SSH_KEY")
fi

if [[ -n "$SSH_PORT" ]]; then
    SSH_OPTS+=(-p "$SSH_PORT")
fi

# Derive host and user parts early — used throughout the rest of the script
HOST_PART="${TARGET##*@}"
SSH_USER="${TARGET%%@*}"

# Resolve REMOTE_DIR now that SET_VARS and SSH_PORT are known.
# HAOS agents must live under /config/ — the only path that survives HAOS
# OS updates. /opt/, /etc/, and everything else in the add-on container is
# wiped on update. /config/ is mounted from the persistent HA host storage.
#
# We detect HAOS by either:
#   (a) the caller passed --set PABS_TYPE=haos, or
#   (b) the caller passed --port 22222 (the SSH add-on default) without an
#       explicit --dir override — port 22222 is only used by the HAOS SSH
#       add-on; no other supported VM type uses it.
if [[ -z "$REMOTE_DIR" ]]; then
    _is_haos=false
    for _sv in "${SET_VARS[@]:-}"; do
        [[ "$_sv" == "PABS_TYPE=haos" ]] && _is_haos=true && break
    done
    [[ "$SSH_PORT" == "22222" ]] && _is_haos=true
    if $_is_haos; then
        REMOTE_DIR="/config/.pabs-agent"
    else
        REMOTE_DIR="/opt/pabs-agent"
    fi
    unset _is_haos _sv
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
    echo "[install-agent] $*"
}

rrun() {
    ssh "${SSH_OPTS[@]}" "$TARGET" "$@"
}

# ---------------------------------------------------------------------------
# Verify agent source exists
# ---------------------------------------------------------------------------

[[ -f "$AGENT_SOURCE/agent.sh" ]] || {
    echo "vm-agent/agent.sh not found at $AGENT_SOURCE"
    exit 1
}

log "Target:       $TARGET"
log "Remote dir:   $REMOTE_DIR"

if [[ ${#SET_VARS[@]} -gt 0 ]]; then
    log "Config overrides: ${SET_VARS[*]}"
fi

log ""

# ---------------------------------------------------------------------------
# Check remote dependencies
# ---------------------------------------------------------------------------

log "Checking remote dependencies..."

# For each required tool: check if present, try apt-get install if missing,
# warn (but do not abort) on systems without apt-get (e.g. HAOS, Alpine, Arch).
_check_dep() {
    local tool="$1"
    local pkg="${2:-$1}"
    # Pass the script via stdin to avoid quoting and newline-escaping issues
    # with passing multi-line scripts as a single SSH argument.
    # shellcheck disable=SC2087  # intentional: $tool/$pkg expand client-side before send
    ssh "${SSH_OPTS[@]}" "$TARGET" "bash -s" << SSHEOF
        if command -v ${tool} >/dev/null 2>&1; then
            exit 0
        fi
        if command -v apt-get >/dev/null 2>&1; then
            echo '[install-agent] Installing ${pkg} via apt-get...'
            apt-get install -y ${pkg} 2>&1 | sed 's/^/  /'
            exit \$?
        fi
        if command -v apk >/dev/null 2>&1; then
            echo '[install-agent] Installing ${pkg} via apk...'
            apk add --no-cache ${pkg} 2>&1 | sed 's/^/  /'
            exit \$?
        fi
        echo '[install-agent] WARNING: ${tool} not found and no apt-get/apk available.'
        echo '[install-agent] Install ${tool} manually on the remote system, then re-run install-agent.sh.'
        exit 0
SSHEOF
}

_check_dep rsync
_check_dep zstd
_check_dep python3

# ---------------------------------------------------------------------------
# Copy agent files
# ---------------------------------------------------------------------------

log "Copying agent files to $TARGET:$REMOTE_DIR ..."

rrun "mkdir -p $REMOTE_DIR/types"

# Prefer rsync (faster, handles updates cleanly). Fall back to scp -r on systems
# where rsync is not installed (e.g. HAOS SSH add-on, Alpine-based containers).
REMOTE_HAS_RSYNC=false
rrun "command -v rsync >/dev/null 2>&1" && REMOTE_HAS_RSYNC=true || true

set +e

if $REMOTE_HAS_RSYNC; then
    COPY_OUTPUT="$(
        rsync -a --delete \
            -e "ssh ${SSH_OPTS[*]@Q}" \
            "$AGENT_SOURCE/" \
            "$TARGET:$REMOTE_DIR/" 2>&1
    )"
    COPY_RC=$?
else
    log "rsync not available on remote — falling back to scp"
    # Build scp options from scratch — do not mangle SSH_OPTS whose elements
    # already contain the leading "-o" flag, as scp uses a different option syntax.
    SCP_OPTS=(
        -o BatchMode=yes
        -o ConnectTimeout=10
        -o StrictHostKeyChecking=accept-new
        -o "UserKnownHostsFile=$PABS_KNOWN_HOSTS"
    )
    [[ -n "$SSH_KEY"  ]] && SCP_OPTS+=(-i "$SSH_KEY")
    [[ -n "$SSH_PORT" ]] && SCP_OPTS+=(-P "$SSH_PORT")   # scp uses -P (capital), not -p
    COPY_OUTPUT="$(
        scp -q -r "${SCP_OPTS[@]}" "$AGENT_SOURCE/." "$TARGET:$REMOTE_DIR/" 2>&1
    )"
    COPY_RC=$?
fi

set -e

if [[ $COPY_RC -ne 0 ]]; then
    echo "$COPY_OUTPUT"
    log "ERROR: agent file copy failed (tried $(${REMOTE_HAS_RSYNC} && echo rsync || echo scp))"
    exit $COPY_RC
fi

rrun "chmod +x \"$REMOTE_DIR/agent.sh\""
rrun "chmod 644 \"$REMOTE_DIR\"/types/*.sh"

# ---------------------------------------------------------------------------
# Run remote installer
# ---------------------------------------------------------------------------

log "Running agent --install on $TARGET ..."

set +e

INSTALL_OUTPUT="$(
    rrun "$REMOTE_DIR/agent.sh --install" 2>&1
)"
INSTALL_RC=$?

set -e

echo "$INSTALL_OUTPUT"

if [[ $INSTALL_RC -ne 0 ]]; then
    if grep -q "Install complete" <<< "$INSTALL_OUTPUT"; then
        : # agent exited non-zero but completed successfully (common on Alpine/HAOS
          # where set -euo pipefail catches a sub-command in do_install)
    else
        log "ERROR: remote install failed (exit $INSTALL_RC)"
        exit $INSTALL_RC
    fi
fi

# ---------------------------------------------------------------------------
# Apply config overrides
# ---------------------------------------------------------------------------

if [[ ${#SET_VARS[@]} -gt 0 ]]; then
    # The agent resolves its config file relative to its own directory first
    # (see agent.sh AGENT_CONFIG resolution). Match that logic here so --set
    # writes to the same file the agent will actually read.
    AGENT_CONFIG="$REMOTE_DIR/config"
    log "Applying config overrides to $AGENT_CONFIG ..."

    for kv in "${SET_VARS[@]}"; do
        local_key="${kv%%=*}"
        local_val="${kv#*=}"

        log "  $local_key=$local_val"

        # Use sed to update the config on the remote — works on all targets
        # including Alpine/HAOS where python3 is not installed.
        # Escape characters that are special in sed's replacement string.
        val_escaped="${local_val//\\/\\\\}"   # backslashes first
        val_escaped="${val_escaped//|/\\|}"   # | is our sed delimiter
        val_escaped="${val_escaped//&/\\&}"   # & means "matched text" in sed replacement

        # shellcheck disable=SC2087  # intentional: config key/value expand client-side
        ssh "${SSH_OPTS[@]}" "$TARGET" "bash -s" << SSHEOF
CONFIG="$AGENT_CONFIG"
KEY="$local_key"
NEW_LINE="${local_key}=\"${val_escaped}\""
if grep -qE "^[[:space:]]*#?[[:space:]]*${local_key}[[:space:]]*=" "\$CONFIG" 2>/dev/null; then
    sed -i "s|^[[:space:]]*#\?[[:space:]]*${local_key}[[:space:]]*=.*|\${NEW_LINE}|" "\$CONFIG"
else
    printf '\n# Set by install-agent.sh\n%s\n' "\${NEW_LINE}" >> "\$CONFIG"
fi
SSHEOF
    done

    log "✓ Config overrides applied"
fi

# ---------------------------------------------------------------------------
# Register SSH host key
# ---------------------------------------------------------------------------

log "Registering host key in $PABS_KNOWN_HOSTS ..."

mkdir -p "$(dirname "$PABS_KNOWN_HOSTS")"

touch "$PABS_KNOWN_HOSTS"
chmod 600 "$PABS_KNOWN_HOSTS"

ssh-keygen -R "$HOST_PART" -f "$PABS_KNOWN_HOSTS" 2>/dev/null || true

ssh-keyscan -H ${SSH_PORT:+-p "$SSH_PORT"} "$HOST_PART" >> "$PABS_KNOWN_HOSTS" 2>/dev/null \
    && log "✓ Host key registered for $HOST_PART" \
    || log "⚠ ssh-keyscan failed"

# ---------------------------------------------------------------------------
# Detect VM type
# ---------------------------------------------------------------------------

log ""
log "Detecting VM type..."

DETECTED_TYPE="$(
    rrun "$REMOTE_DIR/agent.sh --type" 2>/dev/null | tail -1 || echo "unknown"
)"

log "Detected type: $DETECTED_TYPE"

# ---------------------------------------------------------------------------
# Register VM in config.sh
# ---------------------------------------------------------------------------

CONFIG_FILE="$SCRIPT_DIR/config.sh"

if [[ ! -f "$CONFIG_FILE" ]]; then
    log "ERROR: config.sh not found at $CONFIG_FILE"
    log "Run the setup wizard first: bash $SCRIPT_DIR/setup.sh"
    exit 1
fi

# Derive label: use --label if provided, otherwise sanitise the hostname part
# of TARGET (strip user@, replace dots and underscores with dashes, lowercase)
if [[ -z "$LABEL" ]]; then
    LABEL="$(echo "$HOST_PART" | sed 's/:[0-9]*$//' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/^-*//; s/-*$//')"
fi

log ""
log "Registering VM agent in config.sh ..."
log "  Label:  $LABEL"
log "  Host:   $HOST_PART"
log "  User:   $SSH_USER"

# Source config_editor so we can use _cfg_append_vm_agent — the same function
# the setup wizard uses. This keeps all config.sh write logic in one place.
CONFIG="$CONFIG_FILE"
# shellcheck source=setup/config_editor.sh
source "$SCRIPT_DIR/src/setup/config_editor.sh"

ENTRY="${LABEL}  ${HOST_PART}  ${SSH_USER}  ${REMOTE_DIR}/agent.sh"

# Check for a duplicate entry before inserting
if grep -Fq "\"${LABEL}  ${HOST_PART}" "$CONFIG_FILE" 2>/dev/null; then
    log "  ✓ VM already present in VM_AGENTS — skipping"
else
    _cfg_append_vm_agent "$ENTRY"
    log "  ✓ Added to VM_AGENTS: $ENTRY"
fi

log ""
log "============================================================"
log "Agent deployed and registered"
log "  Label:  $LABEL"
log "  Host:   $HOST_PART"
log "  Type:   $DETECTED_TYPE"
log "============================================================"
log ""
log "VM_AGENTS entry written to config.sh."
log "Run 'bash backup.sh --dry-run' to verify the agent is reachable."