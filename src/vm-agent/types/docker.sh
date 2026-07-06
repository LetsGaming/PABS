#!/bin/bash
# =============================================================================
# types/docker.sh — Docker VM backup handler
#
# Sourced by agent.sh when type=docker. Must implement run_backup().
#
# WHAT THIS BACKS UP:
#   - All compose files + .env files (found via manager or path search)
#   - /etc/docker/daemon.json
#   - Package list (dpkg selections)
#   - ALL named Docker volumes (opt-OUT model — the volume data is the
#     irreplaceable part of a Docker VM, so nothing is excluded unless the
#     admin explicitly excludes it; every skip is reported loudly)
#   - Manager data (Dockge/Portainer) if detected or configured
#   - A restore-notes.txt explaining exactly what was found and how to restore
#
# DETECTION ORDER (first match wins, all overridable in config):
#   1. DOCKER_COMPOSE_DIR is set              → use it directly, skip detection
#   2. Dockge detected (binary or data dir)  → treat /opt/stacks as root
#   3. Portainer detected                    → extract stack configs via API
#   4. No manager found                      → search DOCKER_SEARCH_PATHS for
#                                              compose files (default: /opt /srv
#                                              /home /root /var/lib/docker/compose)
#
# ALL DEFAULTS ARE OVERRIDABLE in /etc/pabs-agent/config:
#
#   DOCKER_COMPOSE_DIR="/apps"        Force a single compose root (skips detection)
#   DOCKER_SEARCH_PATHS="/opt /srv"   Where to search when no manager found
#   DOCKER_SEARCH_DEPTH=2             How deep to recurse during search
#   DOCKER_INCLUDE_VOLUMES="vol1,vol2" Volumes to ALWAYS include (beats exclude/cap)
#   DOCKER_EXCLUDE_VOLUMES="vol1,vol2" Volumes to skip (explicit opt-out)
#   DOCKER_VOLUME_MAX_SIZE_MB=0        Skip volumes larger than this (0 = no cap)
#   DOCKER_SKIP_VOLUMES="true"         Disable volume backup entirely
#   DOCKER_QUIESCE_STACKS="true"       Stop containers using a volume during its
#                                      copy, restart after (consistent DB copies)
#   DOCKER_QUIESCE_STOP_TIMEOUT=30     Seconds docker stop waits before SIGKILL
#   DOCKER_MANAGER="none|dockge|portainer|auto"  Override manager detection
#   PORTAINER_URL="http://localhost:9000"
#   PORTAINER_TOKEN="ptr_..."          Portainer API token (if using Portainer)
#   EXTRA_PATHS="/opt/myapp/data /root/configs"  Extra paths to always include (universal — same variable across all types)
#
# VOLUME CAPTURE MODEL (agent v1.1 — changed from opt-in to opt-out):
#   Every named volume is included by default. Earlier versions auto-included
#   only volumes below DOCKER_VOLUME_AUTO_THRESHOLD_MB (default 5 MB), which
#   silently excluded exactly the data this tool exists to protect — database
#   and app-data volumes — while the run still reported SUCCESS. Anything not
#   captured is now an explicit choice and is reported in the log, in
#   restore-notes.txt, and to the Proxmox host's run summary and alert.
#   DOCKER_VOLUME_AUTO_THRESHOLD_MB is deprecated: if still set, it is honored
#   as DOCKER_VOLUME_MAX_SIZE_MB (same skip behavior for admins who chose it),
#   with a deprecation warning.
# =============================================================================

# --- Defaults (all overridable via /etc/pabs-agent/config) ---
DOCKER_SEARCH_PATHS="${DOCKER_SEARCH_PATHS:-/opt /srv /home /root /var/lib/docker/compose}"
DOCKER_SEARCH_DEPTH="${DOCKER_SEARCH_DEPTH:-3}"
DOCKER_EXCLUDE_VOLUMES="${DOCKER_EXCLUDE_VOLUMES:-}"
DOCKER_VOLUME_MAX_SIZE_MB="${DOCKER_VOLUME_MAX_SIZE_MB:-0}"
DOCKER_SKIP_VOLUMES="${DOCKER_SKIP_VOLUMES:-false}"
DOCKER_QUIESCE_STACKS="${DOCKER_QUIESCE_STACKS:-false}"
DOCKER_QUIESCE_STOP_TIMEOUT="${DOCKER_QUIESCE_STOP_TIMEOUT:-30}"
DOCKER_MANAGER="${DOCKER_MANAGER:-auto}"
PORTAINER_URL="${PORTAINER_URL:-http://localhost:9000}"
PORTAINER_TOKEN="${PORTAINER_TOKEN:-}"
DOCKGE_DATA_DIR="${DOCKGE_DATA_DIR:-/opt/dockge}"
DOCKGE_STACKS_DIR="${DOCKGE_STACKS_DIR:-/opt/stacks}"

# Populated during run_backup, used by restore notes and the skip summary
_found_manager="none"
_compose_files=()
_staged_volumes=()
_skipped_volumes=()
_handled_volumes=()
_hot_volume_count=0
_notes=()

# Older agent.sh versions don't define notify_host — degrade to a no-op so a
# partially-updated VM never crashes mid-backup under set -e.
declare -F notify_host >/dev/null 2>&1 || notify_host() { :; }

# -----------------------------------------------------------------------------
# MANAGER DETECTION
# -----------------------------------------------------------------------------

_detect_manager() {
    # Explicit config override
    if [[ "$DOCKER_MANAGER" != "auto" ]]; then
        echo "$DOCKER_MANAGER"
        return
    fi

    # Dockge: check for the binary, the data dir, or a running container
    if command -v dockge &>/dev/null \
    || [[ -d "$DOCKGE_DATA_DIR" ]] \
    || docker ps --format '{{.Names}}' 2>/dev/null | grep -qi dockge; then
        echo "dockge"
        return
    fi

    # Portainer: check for running container or binary
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qi portainer \
    || command -v portainer &>/dev/null; then
        echo "portainer"
        return
    fi

    echo "none"
}

# -----------------------------------------------------------------------------
# COMPOSE FILE DISCOVERY
# -----------------------------------------------------------------------------

# Find all compose files under a given root directory
_find_compose_files() {
    local root="$1"
    local depth="$2"
    find "$root" \
        -maxdepth "$depth" \
        \( -name "compose.yaml" \
        -o -name "compose.yml" \
        -o -name "docker-compose.yaml" \
        -o -name "docker-compose.yml" \) \
        -type f \
        2>/dev/null
}

# Stage compose file + its .env (if present) + any override files
_stage_compose_set() {
    local compose_file="$1"
    local dir
    dir="$(dirname "$compose_file")"

    stage_path "$compose_file" "compose: $compose_file"
    _compose_files+=("$compose_file")

    # .env alongside compose
    if [[ -f "$dir/.env" ]]; then
        stage_path "$dir/.env" "  .env: $dir/.env"
    fi

    # docker-compose.override.yml / compose.override.yaml
    for override in \
        "$dir/docker-compose.override.yml" \
        "$dir/docker-compose.override.yaml" \
        "$dir/compose.override.yml" \
        "$dir/compose.override.yaml"; do
        if [[ -f "$override" ]]; then
            stage_path "$override" "  override: $override"
        fi
    done
}

# -----------------------------------------------------------------------------
# MANAGER-SPECIFIC BACKUP
# -----------------------------------------------------------------------------

_backup_dockge() {
    log "Manager: Dockge"
    _found_manager="dockge"

    # Dockge's own config/data (stores stack metadata, settings)
    if [[ -d "$DOCKGE_DATA_DIR" ]]; then
        stage_path "$DOCKGE_DATA_DIR" "Dockge data dir"
        _notes+=("Dockge data dir backed up from $DOCKGE_DATA_DIR")
    fi

    # The stacks directory is the canonical source for all compose files
    local stacks_root="$DOCKGE_STACKS_DIR"
    if [[ -d "$stacks_root" ]]; then
        log "  Scanning Dockge stacks: $stacks_root"
        while IFS= read -r f; do
            _stage_compose_set "$f"
        done < <(_find_compose_files "$stacks_root" 2)
        _notes+=("Dockge stacks dir: $stacks_root")
    else
        log_warn "Dockge stacks dir not found at $stacks_root — falling back to path search"
        _notes+=("WARNING: Dockge stacks dir not found at $stacks_root, fell back to search")
        _backup_by_search
    fi
}

_backup_portainer() {
    log "Manager: Portainer"
    _found_manager="portainer"

    # Back up Portainer's own data volume first (contains all its config/stacks DB)
    local portainer_vol
    portainer_vol=$(docker volume ls --format '{{.Name}}' 2>/dev/null | grep -i portainer | head -1)
    if [[ -n "$portainer_vol" ]]; then
        _backup_named_volume "$portainer_vol" "force"
        _notes+=("Portainer data volume '$portainer_vol' backed up")
    fi

    # If an API token is configured, export stack compose definitions via API
    if [[ -n "$PORTAINER_TOKEN" ]]; then
        log "  Exporting Portainer stacks via API..."
        # The token travels via a curl config file, never as a -H argument:
        # /proc/<pid>/cmdline is world-readable, so `curl -H "X-API-Key: ..."`
        # would expose the token to every local user for the duration of the
        # request (SEC-01). mktemp creates the file 0600.
        local curl_cfg
        curl_cfg=$(mktemp)
        printf 'header = "X-API-Key: %s"\n' "$PORTAINER_TOKEN" > "$curl_cfg"
        local stacks_json
        stacks_json=$(curl -sf --config "$curl_cfg" \
            "$PORTAINER_URL/api/stacks" 2>/dev/null) || true
        rm -f "$curl_cfg"

        if [[ -n "$stacks_json" ]]; then
            local stack_count
            stack_count=$(echo "$stacks_json" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
            log "  Found $stack_count Portainer stacks"

            # Write each stack's compose content to staging
            export PABS_STAGE_DIR="$STAGE_DIR"
            echo "$stacks_json" | python3 -c '
import json, sys, os

data = json.load(sys.stdin)
stage = os.environ.get("PABS_STAGE_DIR", "/tmp/pabs-portainer")
os.makedirs(stage, exist_ok=True)

for stack in data:
    name = stack.get("Name", "unknown")
    content = stack.get("Content", "")  # Portainer API field for compose content
    if content:
        stack_dir = os.path.join(stage, "portainer-stacks", name)
        os.makedirs(stack_dir, exist_ok=True)
        with open(os.path.join(stack_dir, "docker-compose.yml"), "w") as f:
            f.write(content)

print(f"Exported {len(data)} stacks")
'
            _notes+=("Portainer stacks exported via API to portainer-stacks/")
        else
            log_warn "  Portainer API returned no stacks (check PORTAINER_TOKEN and PORTAINER_URL)"
            _notes+=("WARNING: Portainer API export failed — check PORTAINER_TOKEN/PORTAINER_URL in config")
        fi
    else
        log_warn "  No PORTAINER_TOKEN set — skipping API stack export"
        log "  (Portainer data volume backup still covers the full DB)"
        _notes+=("Portainer API export skipped: no PORTAINER_TOKEN configured")
        _notes+=("Recovery: restore Portainer data volume, Portainer will reconstruct stacks from it")
    fi

    # Still search for any compose files on disk as a safety net
    _backup_by_search
}

_backup_no_manager() {
    log "Manager: none — searching for compose files"
    _found_manager="none"
    _backup_by_search
}

_backup_by_search() {
    # If a single explicit root is configured, use only that
    if [[ -n "${DOCKER_COMPOSE_DIR:-}" ]]; then
        log "  Using configured DOCKER_COMPOSE_DIR: $DOCKER_COMPOSE_DIR"
        while IFS= read -r f; do
            _stage_compose_set "$f"
        done < <(_find_compose_files "$DOCKER_COMPOSE_DIR" "$DOCKER_SEARCH_DEPTH")
        _notes+=("Compose files sourced from configured DOCKER_COMPOSE_DIR=$DOCKER_COMPOSE_DIR")
        return
    fi

    # Otherwise search all configured paths
    log "  Search paths: $DOCKER_SEARCH_PATHS"
    local found=0
    for search_root in $DOCKER_SEARCH_PATHS; do
        [[ -d "$search_root" ]] || continue
        while IFS= read -r f; do
            _stage_compose_set "$f"
            (( ++found )) || true  # pre-increment: always truthy when found >= 1; safe under set -e
        done < <(_find_compose_files "$search_root" "$DOCKER_SEARCH_DEPTH")
    done

    if [[ $found -eq 0 ]]; then
        log_warn "No compose files found in search paths: $DOCKER_SEARCH_PATHS"
        _notes+=("WARNING: No compose files found. Set DOCKER_COMPOSE_DIR or DOCKER_SEARCH_PATHS in config.")
    else
        _notes+=("Compose files found via path search in: $DOCKER_SEARCH_PATHS")
    fi
}

# -----------------------------------------------------------------------------
# VOLUME BACKUP
# -----------------------------------------------------------------------------

_get_volume_size_mb() {
    local vol="$1"
    local mountpoint
    mountpoint=$(docker volume inspect "$vol" --format '{{.Mountpoint}}' 2>/dev/null) || return 1
    [[ -d "$mountpoint" ]] || return 1
    du -sm "$mountpoint" 2>/dev/null | cut -f1
}

# _in_csv NEEDLE CSV — exact membership test against a comma-separated list.
# Whitespace around items is trimmed. Exact match only: excluding "db" must
# never also exclude "my-db" (the previous `grep -qw` treated '-' as a word
# boundary and would have).
_in_csv() {
    local needle="$1" csv="$2" item
    [[ -z "$csv" ]] && return 1
    local -a __items=()
    IFS=',' read -ra __items <<< "$csv"
    for item in "${__items[@]}"; do
        item="${item#"${item%%[![:space:]]*}"}"   # ltrim
        item="${item%"${item##*[![:space:]]}"}"   # rtrim
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

_volume_already_handled() {
    local v
    for v in ${_handled_volumes[@]+"${_handled_volumes[@]}"}; do
        [[ "$v" == "$1" ]] && return 0
    done
    return 1
}

_record_skip() {
    local vol="$1" size="$2" reason="$3"
    _skipped_volumes+=("$vol (${size}MB) — $reason")
    _notes+=("Volume '$vol' (${size}MB) NOT backed up: $reason")
}

# _volume_decision VOL SIZE_MB
#   SIZE_MB is an integer or the literal "unknown".
#   Echoes "include <reason>" or "skip <reason>".
#   Pure decision — no side effects, no docker calls — so it is unit-testable.
#
# Precedence:
#   1. DOCKER_INCLUDE_VOLUMES  → include (force — beats exclude list and cap)
#   2. DOCKER_EXCLUDE_VOLUMES  → skip   (explicit admin opt-out)
#   3. DOCKER_VOLUME_MAX_SIZE_MB > 0:
#        known size > cap      → skip (reported loudly by the caller)
#        size unknown          → INCLUDE — a volume PABS cannot measure is
#                                exactly the data that must never be dropped
#                                silently; fail toward capturing it (BUG-03)
#   4. default                 → include (all named volumes are backed up)
_volume_decision() {
    local vol="$1" size_mb="$2"

    if _in_csv "$vol" "${DOCKER_INCLUDE_VOLUMES:-}"; then
        echo "include forced by DOCKER_INCLUDE_VOLUMES"
        return
    fi
    if _in_csv "$vol" "${DOCKER_EXCLUDE_VOLUMES:-}"; then
        echo "skip excluded by DOCKER_EXCLUDE_VOLUMES"
        return
    fi
    if [[ "$DOCKER_VOLUME_MAX_SIZE_MB" =~ ^[1-9][0-9]*$ ]]; then
        if [[ "$size_mb" == "unknown" ]]; then
            echo "include size unknown — cap not enforced, failing toward capture"
            return
        fi
        if [[ "$size_mb" -gt "$DOCKER_VOLUME_MAX_SIZE_MB" ]]; then
            echo "skip ${size_mb}MB exceeds DOCKER_VOLUME_MAX_SIZE_MB=${DOCKER_VOLUME_MAX_SIZE_MB} (add to DOCKER_INCLUDE_VOLUMES to include)"
            return
        fi
    fi
    echo "include default policy: all named volumes"
}

# _copy_volume VOL MOUNTPOINT SIZE_MB
# Stages the volume data, handling copy consistency (BUG-02): a live copy of
# a running database's data directory can be torn and unrestorable even
# though every byte later passes its SHA256 check. We either quiesce the
# containers using the volume (opt-in) or record honestly that the copy was
# hot — per volume, in the log and in restore-notes.txt.
_copy_volume() {
    local vol="$1" mountpoint="$2" size_mb="$3"

    local -a writers=()
    mapfile -t writers < <(docker ps -q --filter "volume=$vol" 2>/dev/null || true)

    local consistency="cold copy (no running containers were using this volume)"
    local -a stopped=()
    if [[ ${#writers[@]} -gt 0 ]]; then
        local writer_names
        writer_names=$(docker ps --filter "volume=$vol" --format '{{.Names}}' 2>/dev/null \
            | paste -sd ',' -) || writer_names="?"

        if [[ "$DOCKER_QUIESCE_STACKS" == "true" ]]; then
            log "  Quiescing ${#writers[@]} container(s) using '$vol': $writer_names"
            if docker stop -t "$DOCKER_QUIESCE_STOP_TIMEOUT" "${writers[@]}" >/dev/null 2>&1; then
                stopped=("${writers[@]}")
                consistency="cold copy (containers stopped during copy: $writer_names)"
            else
                log_warn "  Could not stop container(s) for '$vol' — copying HOT instead"
                consistency="HOT copy (quiesce failed; running during copy: $writer_names)"
                : $(( _hot_volume_count++ ))
            fi
        else
            consistency="HOT copy (running during copy: $writer_names)"
            : $(( _hot_volume_count++ ))
        fi
    fi

    stage_path "$mountpoint" "volume: $vol (${size_mb}MB)"

    # Restart everything we stopped — unconditionally, even if the copy
    # itself reported problems. A backup must never leave the stack down.
    if [[ ${#stopped[@]} -gt 0 ]]; then
        if docker start "${stopped[@]}" >/dev/null 2>&1; then
            log "  Restarted ${#stopped[@]} container(s) after copying '$vol'"
        else
            log_err "  Failed to restart container(s) for '$vol' — check: docker ps -a"
            notify_host "docker: container restart FAILED after quiesced copy of volume '$vol' — check the VM (docker ps -a)"
        fi
    fi

    _staged_volumes+=("$vol (${size_mb}MB) — $consistency")
    _notes+=("Volume '$vol' (${size_mb}MB) backed up from $mountpoint — $consistency")
}

_backup_named_volume() {
    local vol="$1"
    local mode="${2:-auto}"   # auto | force (force bypasses the decision, e.g. Portainer data volume)

    # De-dup: the Portainer handler force-includes its data volume before the
    # main sweep; without this it would be staged (or worse, skip-noted) twice.
    _volume_already_handled "$vol" && return 0
    _handled_volumes+=("$vol")

    local mountpoint
    mountpoint=$(docker volume inspect "$vol" --format '{{.Mountpoint}}' 2>/dev/null) || {
        log_warn "  Volume '$vol' not found — cannot back up"
        _record_skip "$vol" "?" "volume not found (docker volume inspect failed)"
        return
    }
    [[ -d "$mountpoint" ]] || {
        log_warn "  Volume '$vol' mountpoint missing — cannot back up"
        _record_skip "$vol" "?" "mountpoint missing: $mountpoint"
        return
    }

    # Size probe. A failed probe is NOT a reason to skip (BUG-03) — the old
    # `|| echo 999` default silently pushed unmeasurable volumes over the
    # threshold. Unknown size → include, warn, and bypass any size cap.
    local size_mb
    size_mb=$(_get_volume_size_mb "$vol") || size_mb="unknown"
    [[ "$size_mb" =~ ^[0-9]+$ ]] || size_mb="unknown"
    if [[ "$size_mb" == "unknown" ]]; then
        log_warn "  Volume '$vol': size probe failed — including anyway (unknown size is never a skip)"
    fi

    local verdict reason
    if [[ "$mode" == "force" ]]; then
        verdict="include"
        reason="forced by handler"
    else
        read -r verdict reason <<< "$(_volume_decision "$vol" "$size_mb")"
    fi

    if [[ "$verdict" == "skip" ]]; then
        log_warn "  Volume '$vol' (${size_mb}MB) NOT backed up: $reason"
        _record_skip "$vol" "$size_mb" "$reason"
        return
    fi

    _copy_volume "$vol" "$mountpoint" "$size_mb"
}

_backup_volumes() {
    if [[ "$DOCKER_SKIP_VOLUMES" == "true" ]]; then
        log_warn "  Volume backup disabled by config (DOCKER_SKIP_VOLUMES=true) — no volume data in this bundle"
        _notes+=("Volume backup DISABLED (DOCKER_SKIP_VOLUMES=true) — no named volume data in this bundle")
        notify_host "docker: ALL volume backups disabled by config (DOCKER_SKIP_VOLUMES=true)"
        return
    fi

    # Legacy option mapping — DOCKER_VOLUME_AUTO_THRESHOLD_MB used to opt
    # volumes IN below the threshold; skip-above-N is the behavior an admin
    # who set it explicitly chose, so it maps 1:1 onto the new size cap.
    # Only the DEFAULT changed (5 MB → unlimited).
    if [[ -n "${DOCKER_VOLUME_AUTO_THRESHOLD_MB:-}" ]]; then
        if [[ "$DOCKER_VOLUME_MAX_SIZE_MB" == "0" ]]; then
            DOCKER_VOLUME_MAX_SIZE_MB="$DOCKER_VOLUME_AUTO_THRESHOLD_MB"
        fi
        log_warn "  DOCKER_VOLUME_AUTO_THRESHOLD_MB is deprecated — rename it to DOCKER_VOLUME_MAX_SIZE_MB in the agent config (honored as a ${DOCKER_VOLUME_MAX_SIZE_MB}MB cap this run)"
    fi
    if ! [[ "$DOCKER_VOLUME_MAX_SIZE_MB" =~ ^[0-9]+$ ]]; then
        log_warn "  DOCKER_VOLUME_MAX_SIZE_MB='$DOCKER_VOLUME_MAX_SIZE_MB' is not a number — treating as 0 (no cap)"
        DOCKER_VOLUME_MAX_SIZE_MB=0
    fi

    local policy="all named volumes"
    [[ "$DOCKER_VOLUME_MAX_SIZE_MB" != "0" ]] && policy+=" up to ${DOCKER_VOLUME_MAX_SIZE_MB}MB"
    [[ -n "$DOCKER_EXCLUDE_VOLUMES" ]] && policy+=", excluding: $DOCKER_EXCLUDE_VOLUMES"
    log "  Volume policy: $policy"

    # Single sweep over every named volume; _volume_decision handles
    # include/exclude/cap. The grep filters out anonymous volumes (64-char
    # hex hashes) — they're ephemeral. || true: grep exits 1 when no named
    # volumes exist; under set -euo pipefail that would kill the agent, and
    # an empty result is a valid outcome.
    local vol
    while IFS= read -r vol; do
        _backup_named_volume "$vol" "auto"
    done < <(docker volume ls --format '{{.Name}}' 2>/dev/null | grep -v '^[a-f0-9]\{64\}$' || true)

    # Explicitly requested volumes that never appeared in the sweep: the
    # admin asked for these by name, so "it doesn't exist" must be loud too.
    if [[ -n "${DOCKER_INCLUDE_VOLUMES:-}" ]]; then
        local -a want=()
        IFS=',' read -ra want <<< "$DOCKER_INCLUDE_VOLUMES"
        for vol in "${want[@]}"; do
            vol="${vol#"${vol%%[![:space:]]*}"}"
            vol="${vol%"${vol##*[![:space:]]}"}"
            [[ -z "$vol" ]] && continue
            _volume_already_handled "$vol" || _backup_named_volume "$vol" "auto"
        done
    fi
}

# -----------------------------------------------------------------------------
# RESTORE NOTES
# -----------------------------------------------------------------------------

_write_restore_notes() {
    local notes_file="$STAGE_DIR/restore-notes.txt"
    {
        echo "PABS Docker VM Restore Notes"
        echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')  Host: $(hostname)"
        echo "Manager detected: $_found_manager"
        echo "========================================"
        echo ""

        echo "COMPOSE FILES BACKED UP (${#_compose_files[@]} total):"
        if [[ ${#_compose_files[@]} -gt 0 ]]; then
            for f in "${_compose_files[@]}"; do
                echo "  $f"
            done
        else
            echo "  (none found — check warnings above)"
        fi
        echo ""

        if [[ ${#_staged_volumes[@]} -gt 0 ]]; then
            echo "VOLUMES BACKED UP:"
            for v in "${_staged_volumes[@]}"; do
                echo "  $v"
            done
            echo ""
        fi

        if [[ ${#_skipped_volumes[@]} -gt 0 ]]; then
            echo "⚠ VOLUMES NOT BACKED UP (${#_skipped_volumes[@]}):"
            for v in "${_skipped_volumes[@]}"; do
                echo "  - $v"
            done
            echo ""
            echo "  Data in these volumes is NOT in this bundle. To capture a volume,"
            echo "  add it to DOCKER_INCLUDE_VOLUMES in the agent config, or remove it"
            echo "  from DOCKER_EXCLUDE_VOLUMES / raise DOCKER_VOLUME_MAX_SIZE_MB."
            echo ""
        fi

        if [[ $_hot_volume_count -gt 0 ]]; then
            echo "DATA CONSISTENCY:"
            echo "  $_hot_volume_count volume(s) above are marked 'HOT copy' — they were copied"
            echo "  while containers were still writing to them. Databases (Postgres,"
            echo "  MySQL/MariaDB, SQLite) restored from a hot copy may need crash"
            echo "  recovery on first start and can, in the worst case, be inconsistent."
            echo "  For guaranteed-clean copies set DOCKER_QUIESCE_STACKS=\"true\" in the"
            echo "  agent config (containers are stopped for the copy and restarted),"
            echo "  or schedule an app-level dump (pg_dump/mysqldump) into a path"
            echo "  listed in EXTRA_PATHS."
            echo ""
        fi

        echo "HOW TO RESTORE:"
        echo ""

        case "$_found_manager" in
            dockge)
                echo "  1. Fresh Docker VM + install Dockge"
                echo "  2. Restore Dockge data dir to $DOCKGE_DATA_DIR"
                echo "  3. Restore stacks dir to $DOCKGE_STACKS_DIR"
                echo "  4. Dockge will detect the stacks and show them in the UI"
                echo "  5. Start stacks from the Dockge UI"
                ;;
            portainer)
                echo "  1. Fresh Docker VM + install Portainer"
                if [[ ${#_staged_volumes[@]} -gt 0 ]]; then
                    echo "  2. Restore Portainer data volume (portainer_data)"
                    echo "     docker volume create portainer_data"
                    echo "     docker run --rm -v portainer_data:/target -v \$(pwd):/src alpine \\"
                    echo "       cp -a /src/portainer_data/. /target/"
                    echo "  3. Start Portainer — it will restore all stacks from its DB"
                fi
                if [[ -d "$STAGE_DIR/portainer-stacks" ]]; then
                    echo "  Alt: Re-create stacks manually from portainer-stacks/ directory"
                fi
                ;;
            none|*)
                echo "  1. Fresh Docker VM"
                echo "  2. Install Docker"
                echo "  3. For each compose file listed above:"
                echo "     - Copy the directory back to the same path"
                echo "     - cd <that directory>"
                echo "     - docker compose up -d"
                echo ""
                echo "  Tip: Most containers will pull their images automatically."
                echo "  Persistent data lives in named volumes or bind-mount paths."
                ;;
        esac

        echo ""
        echo "NOTES:"
        for note in "${_notes[@]}"; do
            echo "  - $note"
        done

        echo ""
        echo "RUNNING CONTAINERS AT BACKUP TIME:"
        docker ps --format "  {{.Names}}\t{{.Image}}\t{{.Status}}" 2>/dev/null || echo "  (could not query)"

        echo ""
        echo "DOCKER VERSION:"
        docker version --format "  Client: {{.Client.Version}}  Server: {{.Server.Version}}" 2>/dev/null || docker --version 2>/dev/null || echo "  unknown"

    } > "$notes_file"

    log "  ✓ restore-notes.txt written"
}

# -----------------------------------------------------------------------------
# ENTRY POINT
# -----------------------------------------------------------------------------

run_backup() {
    log "Docker backup starting on $(hostname)"

    # --- Detect manager ---
    local manager
    manager=$(_detect_manager)
    log "Detected manager: $manager"

    # --- Compose files ---
    case "$manager" in
        dockge)    _backup_dockge    ;;
        portainer) _backup_portainer ;;
        none)      _backup_no_manager ;;
        *)
            log_warn "Unknown manager '$manager' — falling back to path search"
            _backup_no_manager
            ;;
    esac

    # --- Docker daemon config ---
    stage_path "/etc/docker/daemon.json" "Docker daemon config"

    # --- Extra paths (always included if configured) ---
    if [[ -n "${EXTRA_PATHS:-}" ]]; then
        for extra in $EXTRA_PATHS; do
            stage_path "$extra" "extra path: $extra"
            _notes+=("Extra path included: $extra")
        done
    fi

    # --- System state (small but useful for rebuild) ---
    stage_cmd "system-state/dpkg-selections.txt" "Installed packages" dpkg --get-selections
    stage_cmd "system-state/hostname.txt"        "Hostname"           hostname
    stage_cmd "system-state/os-release.txt"      "OS release"         cat /etc/os-release

    # --- Volumes ---
    _backup_volumes

    # --- Loud skip summary (audit BUG-01/03) --------------------------------
    # A skip must never hide behind a SUCCESS exit: repeat every uncaptured
    # volume at the end of the log and push it to the Proxmox host, which
    # folds it into the final run summary and the dispatched alert.
    if [[ ${#_skipped_volumes[@]} -gt 0 ]]; then
        log_warn "${#_skipped_volumes[@]} named volume(s) NOT backed up:"
        local s
        for s in "${_skipped_volumes[@]}"; do
            log_warn "    - $s"
        done
        local preview
        preview=$(printf '%s; ' "${_skipped_volumes[@]:0:3}")
        preview="${preview%; }"
        [[ ${#_skipped_volumes[@]} -gt 3 ]] && preview+=" (+$(( ${#_skipped_volumes[@]} - 3 )) more, see restore-notes.txt)"
        notify_host "docker: ${#_skipped_volumes[@]} volume(s) NOT backed up: $preview"
    fi
    if [[ $_hot_volume_count -gt 0 ]]; then
        log_warn "$_hot_volume_count volume(s) copied HOT (containers running) — databases may need crash recovery on restore. See restore-notes.txt; consider DOCKER_QUIESCE_STACKS=true."
    fi

    # --- Restore notes ---
    _write_restore_notes

    log "Docker backup complete — ${#_compose_files[@]} compose file(s), ${#_staged_volumes[@]} volume(s) staged, ${#_skipped_volumes[@]} volume(s) skipped"
}
