#!/bin/bash
# =============================================================================
# pabs-status.sh — PABS pre-flight status check
#
# Checks the current state of PABS without running a backup:
#   - USB mounted and space available
#   - USB drive health: kernel I/O errors, ro-remount, filesystem errors, SMART
#   - Most recent backup: date, size, manifest integrity
#   - All configured VM agents: SSH reachable
#   - Offsite remote reachable (if configured)
#   - Local stage disk space
#
# Usage:
#   ./pabs-status.sh
#
# Exit codes: 0 = OK, 1 = error, 2 = warning
# =============================================================================

set -euo pipefail

PABS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

JSON_MODE=false
for arg in "$@"; do
    case "$arg" in
        --json) JSON_MODE=true ;;
        --help|-h)
            echo "Usage: $0 [--json]"
            echo "  Checks PABS health without running a backup."
            echo "  --json  Emit machine-readable output (one JSON object per check,"
            echo "          plus a final summary object). Suitable for monitoring."
            echo "  Exit: 0=OK  1=error  2=warning"
            exit 0 ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done

source "$PABS_DIR/config.sh"
source "$PABS_DIR/src/lib/usb_health.sh"
source "$PABS_DIR/src/lib/host_health.sh"

PASS="✓"; FAIL="✗"; WARN="⚠"
OVERALL=0  # 0=OK, 1=error, 2=warning

# Structured records collected for --json output: "status<TAB>message" per line.
# The human-readable echo still happens unless --json suppresses it.
_RECORDS=()
_record() {
    local status="$1"; shift
    _RECORDS+=("${status}"$'\t'"$*")
}
# In JSON mode, human prose lines (echoed section headers etc.) go to stderr so
# stdout stays a clean JSON stream that a collector can parse.
_say() { if [[ "$JSON_MODE" == "true" ]]; then echo "$@" >&2; else echo "$@"; fi; }

_ok()   { _say "  $PASS  $*"; _record ok   "$*"; }
_warn() { _say "  $WARN  $*"; _record warn "$*"; [[ $OVERALL -eq 0 ]] && OVERALL=2; }
_fail() { _say "  $FAIL  $*"; _record fail "$*"; OVERALL=1; }

_say ""
_say "=== PABS Status ==="

# In JSON mode, send ALL human-readable output (section headers, health-lib
# echoes) to stderr by pointing stdout at fd 2 for the duration of the checks.
# fd 3 keeps the original stdout so the final JSON stream can be written there.
if [[ "$JSON_MODE" == "true" ]]; then
    exec 3>&1 1>&2
fi

# ---------------------------------------------------------------------------
# Root
# ---------------------------------------------------------------------------
echo ""
echo "--- Environment ---"
[[ $EUID -eq 0 ]] && _ok "Running as root" || _warn "Not running as root — some checks may be inaccurate"

# ---------------------------------------------------------------------------
# USB
# ---------------------------------------------------------------------------
echo ""
echo "--- USB / Backup Storage ---"

USB_OK=false
if mountpoint -q "$USB_MOUNT" 2>/dev/null; then
    _ok "USB mounted at $USB_MOUNT"
    USB_OK=true

    USB_FREE_GB=$(df -k "$USB_MOUNT" | awk 'NR==2{ printf "%.0f", $4/1024/1024 }')
    USB_USED_PCT=$(df -k "$USB_MOUNT" | awk 'NR==2{ printf "%.0f", $3/$2*100 }')
    _ok "USB free: ${USB_FREE_GB}GB  (${USB_USED_PCT}% used)"

    BACKUP_COUNT=0
    [[ -d "$BACKUP_ROOT" ]] && \
        BACKUP_COUNT=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d ! -name '.*' ! -name '*.tmp' | wc -l)
    _ok "$BACKUP_COUNT backup(s) in $BACKUP_ROOT"
else
    _fail "USB not mounted at $USB_MOUNT"
fi

# Run USB drive health checks only when the drive is mounted
if [[ "$USB_OK" == "true" ]]; then
    usb_health_check "$USB_MOUNT" "$BACKUP_ROOT"
fi

# ---------------------------------------------------------------------------
# Most recent backup
# ---------------------------------------------------------------------------
echo ""
echo "--- Most Recent Backup ---"

LATEST=""
if [[ "$USB_OK" == "true" && -d "$BACKUP_ROOT" ]]; then
    LATEST=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d ! -name '.*' ! -name '*.tmp' \
        | sort | tail -1)
fi

if [[ -n "$LATEST" ]]; then
    LATEST_SIZE=$(du -sh "$LATEST" 2>/dev/null | cut -f1 || echo "unknown")
    _ok "Latest: $(basename "$LATEST")  ($LATEST_SIZE)"

    if [[ -f "$LATEST/MANIFEST.sha256" ]]; then
        if ( cd "$LATEST" && sha256sum --quiet --check MANIFEST.sha256 2>/dev/null ); then
            _ok "Manifest: all checksums OK"
        else
            _fail "Manifest: checksum failures in $(basename "$LATEST")"
        fi
    else
        _warn "Manifest: MANIFEST.sha256 not found"
    fi

    [[ -f "$LATEST/DISASTER-RECOVERY.md" ]] \
        && _ok "DISASTER-RECOVERY.md present" \
        || _warn "DISASTER-RECOVERY.md missing from latest backup"
else
    _warn "No backups found in $BACKUP_ROOT"
fi

# ---------------------------------------------------------------------------
# Host drive health
# ---------------------------------------------------------------------------
host_health_check

# ---------------------------------------------------------------------------
# Local stage
# ---------------------------------------------------------------------------
echo ""
echo "--- Local Stage (SSD) ---"

mkdir -p "$LOCAL_STAGE_BASE" 2>/dev/null || true
STAGE_FREE_GB=$(df -k "$LOCAL_STAGE_BASE" | awk 'NR==2{ printf "%.0f", $4/1024/1024 }')
if [[ "$STAGE_FREE_GB" -lt 2 ]]; then
    _warn "Stage free: ${STAGE_FREE_GB}GB — low (< 2GB)"
else
    _ok "Stage free: ${STAGE_FREE_GB}GB"
fi

# ---------------------------------------------------------------------------
# VM agents
# ---------------------------------------------------------------------------
echo ""
echo "--- VM Agent Connectivity ---"

if [[ ${#VM_AGENTS[@]} -eq 0 ]]; then
    _warn "No VM_AGENTS configured"
else
    for entry in "${VM_AGENTS[@]}"; do
        # agent_path is parsed but not used for the connectivity check (SC2034)
        # shellcheck disable=SC2034
        read -r label vm_host ssh_user agent_path <<< "$entry"
        [[ -z "$label" ]] && continue

        ssh_opts=("${VM_AGENT_SSH_OPTS[@]}")
        key_var="VM_SSH_KEY_${label//-/_}"
        [[ -n "${!key_var:-}" ]] && ssh_opts+=(-i "${!key_var}")
        [[ -n "${VM_SSH_KEY:-}" && -z "${!key_var:-}" ]] && ssh_opts+=(-i "$VM_SSH_KEY")

        if ssh "${ssh_opts[@]}" -o ConnectTimeout=5 "$ssh_user@$vm_host" exit 2>/dev/null; then
            _ok "[$label] $ssh_user@$vm_host"
        else
            _fail "[$label] $ssh_user@$vm_host — unreachable"
        fi
    done
fi

# ---------------------------------------------------------------------------
# Offsite sync
# ---------------------------------------------------------------------------
echo ""
echo "--- Offsite Sync (rclone) ---"

if [[ -z "${RCLONE_REMOTE:-}" ]]; then
    _warn "RCLONE_REMOTE not configured — no offsite backup (3-2-1 incomplete)"
elif ! command -v rclone &>/dev/null; then
    _fail "RCLONE_REMOTE is set but rclone is not installed (apt install rclone)"
else
    # Encryption status
    if [[ -n "${RCLONE_ENCRYPTION_PASSWORD:-}" ]]; then
        _ok "Encryption: enabled (crypt remote)"
    else
        _warn "Encryption: disabled — provider can read your data (set RCLONE_ENCRYPTION_PASSWORD)"
    fi

    # Retention config summary
    keep_min="${RCLONE_KEEP_MIN:-1}"
    keep_max="${RCLONE_KEEP_MAX:-4}"
    max_gb="${RCLONE_MAX_STORAGE_GB:-0}"
    retention_msg="min=${keep_min}"
    [[ $keep_max -gt 0 ]] && retention_msg+=", max=${keep_max}" || retention_msg+=", max=unlimited"
    [[ $max_gb -gt 0 ]]   && retention_msg+=", cap=${max_gb}GB" || retention_msg+=", cap=unlimited"
    _ok "Retention policy: $retention_msg"

    # Reachability check
    if rclone lsd "$RCLONE_REMOTE" --max-depth 1 &>/dev/null; then
        _ok "Remote reachable: $RCLONE_REMOTE"

        # Count existing offsite archives and show storage usage.
        # Offsite backups are flat files: <DATE>.tar.zst[.gpg], not directories.
        offsite_count=$({ rclone lsf "$RCLONE_REMOTE" --files-only 2>/dev/null \
            | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}\.tar\.zst(\.gpg)?$' \
            || true; } | wc -l)
        offsite_gb=$(rclone size "$RCLONE_REMOTE" --json 2>/dev/null \
            | python3 -c "import json,sys; b=json.load(sys.stdin).get('bytes',0); print(round(b/1073741824,2))" \
            2>/dev/null || echo "?")
        _ok "Remote backups: ${offsite_count} backup(s), ${offsite_gb}GB used"

        # Warn if below KEEP_MIN (e.g. fresh setup or after a prune issue)
        if [[ "$offsite_count" =~ ^[0-9]+$ && $offsite_count -lt $keep_min ]]; then
            _warn "Only ${offsite_count} offsite backup(s) — below RCLONE_KEEP_MIN=${keep_min}"
        fi

        # Warn if over storage cap
        if [[ $max_gb -gt 0 && "$offsite_gb" =~ ^[0-9] ]]; then
            if python3 -c "import sys; sys.exit(0 if float('$offsite_gb') > float('$max_gb') else 1)" 2>/dev/null; then
                _warn "Remote usage ${offsite_gb}GB exceeds RCLONE_MAX_STORAGE_GB=${max_gb} — will prune on next backup"
            fi
        fi
    else
        _fail "Remote unreachable: $RCLONE_REMOTE"
    fi
fi

# ---------------------------------------------------------------------------
# Lock
# ---------------------------------------------------------------------------
echo ""
echo "--- Lock ---"
[[ -f "$LOCK_FILE" ]] \
    && _warn "Lock file exists: $LOCK_FILE (backup may be running or crashed)" \
    || _ok "No lock file"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [[ "$JSON_MODE" == "true" ]]; then
    # Restore real stdout (fd 3) and emit the JSON stream there.
    exec 1>&3 3>&-
    overall_str=OK
    [[ $OVERALL -eq 1 ]] && overall_str=ERROR
    [[ $OVERALL -eq 2 ]] && overall_str=WARNING
    # One JSON object per check, then a summary object — newline-delimited JSON
    # (jsonl), which Prometheus textfile collectors and log shippers parse easily.
    # python3 does the escaping so messages with quotes/unicode are safe.
    ok_n=0; warn_n=0; fail_n=0
    for (( _i=0; _i<${#_RECORDS[@]}; _i++ )); do
        st="${_RECORDS[$_i]%%$'\t'*}"
        case "$st" in ok) : $(( ok_n++ ));; warn) : $(( warn_n++ ));; fail) : $(( fail_n++ ));; esac
    done
    {
        for (( _i=0; _i<${#_RECORDS[@]}; _i++ )); do
            st="${_RECORDS[$_i]%%$'\t'*}"
            msg="${_RECORDS[$_i]#*$'\t'}"
            python3 -c 'import json,sys; print(json.dumps({"type":"check","status":sys.argv[1],"message":sys.argv[2]}))' "$st" "$msg"
        done
        python3 -c 'import json,sys; print(json.dumps({"type":"summary","overall":sys.argv[1],"exit_code":int(sys.argv[2]),"ok":int(sys.argv[3]),"warnings":int(sys.argv[4]),"errors":int(sys.argv[5]),"host":sys.argv[6]}))' \
            "$overall_str" "$OVERALL" "$ok_n" "$warn_n" "$fail_n" "$(hostname)"
    }
else
    echo ""
    case $OVERALL in
        0) echo "  Overall: OK" ;;
        1) echo "  Overall: ERROR" ;;
        2) echo "  Overall: WARNING" ;;
    esac
    echo ""
fi

exit $OVERALL
