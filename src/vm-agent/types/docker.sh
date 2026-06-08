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
#   - Named Docker volumes that are small enough (opt-in or auto if tiny)
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
#   DOCKER_INCLUDE_VOLUMES="vol1,vol2" Named volumes to always include
#   DOCKER_VOLUME_AUTO_THRESHOLD_MB=5  Auto-include volumes smaller than this
#   DOCKER_SKIP_VOLUMES="true"         Disable volume backup entirely
#   DOCKER_MANAGER="none|dockge|portainer|auto"  Override manager detection
#   PORTAINER_URL="http://localhost:9000"
#   PORTAINER_TOKEN="ptr_..."          Portainer API token (if using Portainer)
#   EXTRA_PATHS="/opt/myapp/data /root/configs"  Extra paths to always include (universal — same variable across all types)
# =============================================================================

# --- Defaults (all overridable via /etc/pabs-agent/config) ---
DOCKER_SEARCH_PATHS="${DOCKER_SEARCH_PATHS:-/opt /srv /home /root /var/lib/docker/compose}"
DOCKER_SEARCH_DEPTH="${DOCKER_SEARCH_DEPTH:-3}"
DOCKER_VOLUME_AUTO_THRESHOLD_MB="${DOCKER_VOLUME_AUTO_THRESHOLD_MB:-5}"
DOCKER_SKIP_VOLUMES="${DOCKER_SKIP_VOLUMES:-false}"
DOCKER_MANAGER="${DOCKER_MANAGER:-auto}"
PORTAINER_URL="${PORTAINER_URL:-http://localhost:9000}"
PORTAINER_TOKEN="${PORTAINER_TOKEN:-}"
DOCKGE_DATA_DIR="${DOCKGE_DATA_DIR:-/opt/dockge}"
DOCKGE_STACKS_DIR="${DOCKGE_STACKS_DIR:-/opt/stacks}"

# Populated during run_backup, used by restore notes
_found_manager="none"
_compose_files=()
_staged_volumes=()
_notes=()

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
        local stacks_json
        stacks_json=$(curl -sf \
            -H "X-API-Key: $PORTAINER_TOKEN" \
            "$PORTAINER_URL/api/stacks" 2>/dev/null) || true

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

_backup_named_volume() {
    local vol="$1"
    local mode="${2:-auto}"   # auto | force | skip
    local mountpoint
    mountpoint=$(docker volume inspect "$vol" --format '{{.Mountpoint}}' 2>/dev/null) || {
        log_warn "  Volume '$vol' not found — skipped"
        return
    }

    [[ -d "$mountpoint" ]] || { log_warn "  Volume '$vol' mountpoint missing — skipped"; return; }

    local size_mb
    size_mb=$(_get_volume_size_mb "$vol" || echo 999)

    if [[ "$mode" == "skip" ]]; then
        log_warn "  Volume '$vol' skipped (DOCKER_SKIP_VOLUMES=true)"
        return
    fi

    if [[ "$mode" == "auto" && $size_mb -gt $DOCKER_VOLUME_AUTO_THRESHOLD_MB ]]; then
        log_warn "  Volume '$vol' is ${size_mb}MB > threshold ${DOCKER_VOLUME_AUTO_THRESHOLD_MB}MB — skipped"
        log_warn "  Add to DOCKER_INCLUDE_VOLUMES to force-include it"
        _notes+=("Volume '$vol' (${size_mb}MB) skipped: exceeds auto-threshold. Add to DOCKER_INCLUDE_VOLUMES to include.")
        return
    fi

    stage_path "$mountpoint" "volume: $vol (${size_mb}MB)"
    _staged_volumes+=("$vol (${size_mb}MB)")
    _notes+=("Volume '$vol' (${size_mb}MB) backed up from $mountpoint")
}

_backup_volumes() {
    if [[ "$DOCKER_SKIP_VOLUMES" == "true" ]]; then
        _notes+=("Volume backup disabled (DOCKER_SKIP_VOLUMES=true)")
        return
    fi

    # Force-include explicitly listed volumes
    if [[ -n "${DOCKER_INCLUDE_VOLUMES:-}" ]]; then
        log "  Force-including configured volumes: $DOCKER_INCLUDE_VOLUMES"
        IFS=',' read -ra vols <<< "$DOCKER_INCLUDE_VOLUMES"
        for vol in "${vols[@]}"; do
            vol="$(echo "$vol" | xargs)"  # trim whitespace
            _backup_named_volume "$vol" "force"
        done
    fi

    # Auto-include any named volume under the size threshold
    while IFS= read -r vol; do
        # Skip if already handled above
        if [[ -n "${DOCKER_INCLUDE_VOLUMES:-}" ]]; then
            if echo "$DOCKER_INCLUDE_VOLUMES" | grep -qw "$vol"; then
                continue
            fi
        fi
        _backup_named_volume "$vol" "auto"
    done < <(docker volume ls --format '{{.Name}}' 2>/dev/null | grep -v '^[a-f0-9]\{64\}$' || true)
    # The grep filters out anonymous volumes (64-char hex hashes) — they're ephemeral.
    # || true: grep exits 1 when no named volumes exist; under set -euo pipefail
    # that would kill the agent. An empty result is a valid outcome.
    # The grep filters out anonymous volumes (64-char hex hashes) — they're ephemeral
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

    # --- Restore notes ---
    _write_restore_notes

    log "Docker backup complete — ${#_compose_files[@]} compose file(s) staged"
}
