#!/bin/bash
# =============================================================================
# lib/core.sh — Logging, lock management, trap, and alert dispatch
#
# Sourced by backup.sh after config.sh. All other lib files depend on the
# functions defined here (log, log_warn, log_err, die, dispatch_alert).
# Offsite sync functions live in lib/offsite.sh.
# =============================================================================

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

# $LOG lives on the USB drive, which is precisely what is gone when an early
# preflight check fails. Writing there unconditionally turned FATAL messages
# into "tee: ...: No such device" noise in the cron log. Fall back to a local
# file so the reason a run aborted is always recorded somewhere.
PABS_FALLBACK_LOG="${PABS_FALLBACK_LOG:-/var/log/pabs-local.log}"

_append_log() {
    local line="$1"
    local dir="${LOG%/*}"
    [[ "$dir" == "$LOG" ]] && dir="."

    if [[ -d "$dir" ]] && printf '%s\n' "$line" >> "$LOG" 2>/dev/null; then
        return 0
    fi
    printf '%s\n' "$line" >> "$PABS_FALLBACK_LOG" 2>/dev/null || true
}

log() {
    local line
    line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$line"
    _append_log "$line"
}

log_warn() {
    log "⚠  $*"
    : $(( WARNINGS++ ))
}

log_err() {
    log "✗  $*"
    # (( ERRORS++ )) returns exit 1 when ERRORS==0, aborting under set -e.
    # The : $(( )) form is safe: the arithmetic is evaluated but exit code is 0.
    : $(( ERRORS++ ))
}

die() {
    log "FATAL: $*"
    exit 1
}

have_command() {
    # Usage: have_command <cmd> <what-is-lost-without-it>
    #
    # Optional-dependency probe for sections that can degrade. On absence it
    # states what will be missing from the backup, so a degraded run is never
    # mistaken for a complete one. Callers that guard backup payload should
    # also push a RUN_NOTICE; callers that guard diagnostics need not.
    local cmd="$1" consequence="$2"

    command -v "$cmd" >/dev/null 2>&1 && return 0
    log_warn "$cmd not found in PATH — $consequence"
    return 1
}

# ---------------------------------------------------------------------------
# Notifications — dual-channel: Discord (primary) + mail (fallback)
# ---------------------------------------------------------------------------

dispatch_alert() {
    local message="$1"
    local full_msg
    full_msg="[$(hostname)] Proxmox Backup v${SCRIPT_VERSION}: $message"

    # python3 handles JSON serialisation correctly for all edge cases (tabs,
    # control characters, non-ASCII, nested quotes). Message passed as argv —
    # never interpolated into Python code — so there is no injection surface.
    if [[ -n "${DISCORD_WEBHOOK:-}" ]]; then
        local json
        json=$(python3 -c \
            'import json,sys; print(json.dumps({"content":sys.argv[1]}))' \
            "$full_msg")
        # Delivery is best-effort and never fails the backup, but a permanently
        # broken webhook should be discoverable — record the outcome in the log.
        if curl -s -X POST \
             -H "Content-Type: application/json" \
             -d "$json" \
             --max-time 10 \
             "$DISCORD_WEBHOOK" >/dev/null 2>&1; then
            : # delivered
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] (notify) Discord webhook delivery failed (non-fatal)" >> "$LOG" 2>/dev/null || true
        fi
    fi

    # Fallback: local mail (failure alerts only — callers decide when to use this)
    if [[ -n "${NOTIFY_EMAIL:-}" ]]; then
        if echo "$full_msg" \
            | mail -s "PABS Alert: $(hostname)" "$NOTIFY_EMAIL" 2>/dev/null; then
            : # delivered
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] (notify) mail delivery to $NOTIFY_EMAIL failed (non-fatal)" >> "$LOG" 2>/dev/null || true
        fi
    fi
}

# ---------------------------------------------------------------------------
# Lock — prevents concurrent runs
# ---------------------------------------------------------------------------

acquire_lock() {
    mkdir -p "$LOCAL_STAGE_BASE"
    exec 9>"$LOCK_FILE"
    # Mark the lock fd close-on-exec so child processes (pvs, vgs, lvs,
    # vgcfgbackup, etc.) don't inherit it and emit "leaked fd" warnings.
    python3 -c \
        'import fcntl; fcntl.fcntl(9, fcntl.F_SETFD, fcntl.fcntl(9, fcntl.F_GETFD) | fcntl.FD_CLOEXEC)' \
        2>/dev/null || true
    if ! flock -n 9; then
        echo "Another backup is already running (lock: $LOCK_FILE). Aborting." >&2
        exit 1
    fi
}

release_lock() {
    flock -u 9 2>/dev/null || true
    rm -f "$LOCK_FILE"
}

# ---------------------------------------------------------------------------
# Trap — cleanup on unexpected exit
# ---------------------------------------------------------------------------

_on_exit() {
    local exit_code=$?

    # STAGE_DIR may already have been renamed to USB.
    # Only clean up if it still exists at the local staging path.
    if [[ -d "${STAGE_DIR:-}" ]]; then
        log "Cleaning up local staging directory after unexpected exit..."
        rm -rf "$STAGE_DIR"
    fi

    release_lock

    if [[ $exit_code -ne 0 ]]; then
        dispatch_alert "FAILED with exit code $exit_code. Review log: $LOG"
    fi
}

# Signal handler — fires on Ctrl-C / kill even during the atomic-commit window
# where the ERR/EXIT trap is intentionally detached. Without this, an interrupt
# there would leave $LOCK_FILE behind and block the next run. A half-written USB
# commit always lives under a .tmp suffix, so it is never mistaken for a complete
# backup; we remove staging and any orphaned .tmp, release the lock, then exit.
_on_signal() {
    local sig="$1"
    log "Received SIG${sig} — aborting and cleaning up..."
    [[ -d "${STAGE_DIR:-}" ]] && rm -rf "$STAGE_DIR"
    [[ -n "${FINAL_DIR:-}" && -d "${FINAL_DIR}.tmp" ]] && rm -rf "${FINAL_DIR}.tmp"
    release_lock
    trap - INT TERM ERR EXIT
    exit 130
}

# Attach on source — backup.sh detaches/reattaches the ERR/EXIT pair around the
# atomic commit, but INT/TERM stay armed for the whole run.
trap '_on_exit' ERR EXIT
trap '_on_signal INT'  INT
trap '_on_signal TERM' TERM
