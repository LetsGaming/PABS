#!/bin/bash
# setup/steps/agents.sh — Step 4: VM/LXC agent deployment

# ---------------------------------------------------------------------------
# Type-specific configuration questionnaires
# Each function receives a nameref to an array and appends --set flags.
# ---------------------------------------------------------------------------

_agent_type_docker() {
    local -n _flags=$1
    _flags+=(--set "PABS_TYPE=docker")
    echo ""
    _info "Docker manager detection: leave empty to auto-detect (recommended)."
    _info "Override only if auto-detect picks the wrong manager."
    local mgr
    mgr=$(_ask_choice "Docker manager" "1" \
        "Auto-detect (recommended)" \
        "None (plain docker-compose, no manager)" \
        "Dockge" \
        "Portainer")
    case "$mgr" in
        2) _flags+=(--set "DOCKER_MANAGER=none") ;;
        3)
            _flags+=(--set "DOCKER_MANAGER=dockge")
            local dir
            dir=$(_ask "Dockge stacks directory" "/opt/stacks")
            [[ "$dir" != "/opt/stacks" ]] && _flags+=(--set "DOCKGE_STACKS_DIR=$dir")
            ;;
        4)
            _flags+=(--set "DOCKER_MANAGER=portainer")
            local url token
            url=$(_ask "Portainer URL" "http://localhost:9000")
            [[ "$url" != "http://localhost:9000" ]] && _flags+=(--set "PORTAINER_URL=$url")
            _info "An API token lets PABS export your stack definitions via the Portainer API."
            _info "Create one in Portainer: Account → API Tokens → Add API Token"
            token=$(_ask "Portainer API token (ptr_..., leave empty to skip)")
            [[ -n "$token" ]] && _flags+=(--set "PORTAINER_TOKEN=$token")
            ;;
        *) ;;  # 1 = auto, no flag needed
    esac
}

_agent_type_haos() {
    # shellcheck disable=SC2178
    local -n _flags=$1
    _flags+=(--set "PABS_TYPE=haos")
    echo ""
    _info "HAOS backups use the native 'ha backup' command — restoreable directly from the HA UI."
    _info "The agent runs inside the SSH & Web Terminal add-on, which listens on port 22222 by default."
    local haos_port
    haos_port=$(_ask "SSH port for the HAOS SSH add-on" "22222")
    [[ "$haos_port" != "22" ]] && _flags+=(--port "$haos_port")

    local btype
    btype=$(_ask_choice "Backup type" "1" \
        "Full backup (everything — recommended)" \
        "Partial backup (select add-ons and folders)")
    [[ "$btype" == "2" ]] && _flags+=(--set "HAOS_BACKUP_TYPE=partial")

    if _ask_yn "Encrypt the HA snapshot with a password?" "n"; then
        local pass
        pass=$(_ask_secret "HA snapshot password")
        [[ -n "$pass" ]] && _flags+=(--set "HAOS_BACKUP_PASSWORD=$pass")
    fi

    local keep
    keep=$(_ask "How many old HA snapshots to keep on the HA host after PABS pulls them" "1")
    [[ "$keep" != "1" ]] && _flags+=(--set "HAOS_KEEP_ON_HOST=$keep")
}

_agent_type_minecraft() {
    # shellcheck disable=SC2178
    local -n _flags=$1
    _flags+=(--set "PABS_TYPE=minecraft")
    echo ""
    _info "Designed for minecraft-server-setup. Defaults match a standard install."
    _info "Only change these if you used custom paths in variables.json."

    local sys_user
    sys_user=$(_ask "Linux username running Minecraft" "minecraft")
    local base_default="/home/${sys_user}/minecraft-server/backups"

    local base weekly daily
    base=$(_ask "Backup archives directory (MINECRAFT_BASE)" "$base_default")
    [[ "$base" != "$base_default" ]] && _flags+=(--set "MINECRAFT_BASE=$base")

    weekly=$(_ask "Weekly archives to keep per instance" "4")
    [[ "$weekly" != "4" ]] && _flags+=(--set "MC_KEEP_WEEKLY=$weekly")

    daily=$(_ask "Daily archives to keep per instance (0 = skip dailies)" "0")
    [[ "$daily" != "0" ]] && _flags+=(--set "MC_KEEP_DAILY=$daily")
}

_agent_type_generic() {
    # shellcheck disable=SC2178
    local -n _flags=$1
    _flags+=(--set "PABS_TYPE=generic")
    echo ""
    _info "Backs up /etc, cron jobs, /usr/local/bin, and installed package list."
    _info "Good for Pi-hole, AdGuard, Nginx, or any plain Debian/Ubuntu VM."
    local extra
    extra=$(_ask "Extra paths to include (space-separated, leave empty for none)")
    [[ -n "$extra" ]] && _flags+=(--set "EXTRA_PATHS=$extra")
}

# ---------------------------------------------------------------------------
# SSH key setup — runs once before the per-VM loop
# ---------------------------------------------------------------------------

_agents_setup_ssh_key() {
    _step "Dedicated SSH key for agent connections"
    local current_key key_path="/root/.ssh/id_ed25519_pabs_agent"
    current_key=$(_cfg_get "VM_SSH_KEY")

    if [[ -n "$current_key" ]]; then
        _ok "Shared agent SSH key already set: $current_key"
        return
    fi

    if [[ -f "$key_path" ]]; then
        _ok "Dedicated PABS key already exists at $key_path"
        if _ask_yn "Use $key_path as the agent SSH key?"; then
            _cfg_set "VM_SSH_KEY" "$key_path"
            _ok "VM_SSH_KEY set to $key_path"
        fi
        return
    fi

    _info "A dedicated SSH key is recommended so that rotating root's default key"
    _info "doesn't silently break all your agent backups."
    if _ask_yn "Generate a dedicated PABS agent SSH key at $key_path?"; then
        if ssh-keygen -t ed25519 -f "$key_path" -N "" -C "pabs-agent@$(hostname)"; then
            _ok "Key generated: $key_path"
            _cfg_set "VM_SSH_KEY" "$key_path"
            _ok "VM_SSH_KEY set to $key_path"
            echo ""
            _info "Next: copy this public key to each VM you want to back up:"
            _dim "  ssh-copy-id -i $key_path.pub root@<vm-ip>"
        else
            _warn "Key generation failed — continuing without a dedicated key"
        fi
    else
        _info "Skipping dedicated key — will use root's default SSH key"
    fi
}

# ---------------------------------------------------------------------------
# Deploy one VM — called inside the add-VM loop
# ---------------------------------------------------------------------------

_agents_add_one() {
    _step "Add a VM or LXC"

    _info "Enter the IP address or hostname of the VM/LXC to back up."
    local vm_host vm_user vm_label default_label
    vm_host=$(_ask "VM IP or hostname")
    [[ -z "$vm_host" ]] && { _warn "No host entered — skipping"; return 1; }

    vm_user=$(_ask "SSH user on the VM" "root")
    default_label="${vm_host//./-}"
    _info "The label is used as the folder name in your backup — keep it short and descriptive."
    vm_label=$(_ask "Label for this VM" "$default_label")

    _step "VM type"
    _info "The agent will auto-detect the type. Choose manually only if needed."

    local type_choice
    type_choice=$(_ask_choice "VM type" "5" \
        "Docker            — compose files, .env, volumes" \
        "Home Assistant OS — native HA snapshot (one-click restore)" \
        "Minecraft         — weekly archives (minecraft-server-setup)" \
        "Generic           — /etc, cron, scripts, packages" \
        "Auto-detect       — let the agent figure it out (recommended)")

    local -a set_flags=()
    case "$type_choice" in
        1) _agent_type_docker    set_flags ;;
        2) _agent_type_haos      set_flags ;;
        3) _agent_type_minecraft set_flags ;;
        4) _agent_type_generic   set_flags ;;
        *) _info "Auto-detect selected — no type flags needed" ;;
    esac

    local -a install_cmd=("bash" "$INSTALL_AGENT" "${vm_user}@${vm_host}")
    local agent_key
    agent_key=$(_cfg_get "VM_SSH_KEY")
    [[ -n "$agent_key" && -f "$agent_key" ]] && install_cmd+=(--key "$agent_key")
    install_cmd+=("${set_flags[@]}")
    # Extract --port from set_flags for the retry hint (set by _agent_type_haos)
    local vm_port=""
    local _prev=""
    for _f in "${set_flags[@]}"; do
        [[ "$_prev" == "--port" ]] && vm_port="$_f"
        _prev="$_f"
    done

    echo ""
    _step "Deploying agent to ${vm_user}@${vm_host}..."
    _dim "Running: ${install_cmd[*]}"
    echo ""

    if "${install_cmd[@]}"; then
        _ok "Agent deployed to ${vm_host}"
        _cfg_append_vm_agent "${vm_label}  ${vm_host}  ${vm_user}  /opt/pabs-agent/agent.sh"
        _ok "Added to VM_AGENTS: $vm_label → $vm_host (user: $vm_user)"
    else
        _err "Agent deployment failed for ${vm_host}"
        _info "Possible causes: SSH not reachable, wrong user, key not copied to VM."
        _info "Retry later with:"
        local _port_hint=""
        [[ -n "$vm_port" ]] && _port_hint=" --port $vm_port"
        _dim "  bash install-agent.sh ${vm_user}@${vm_host}${_port_hint}${set_flags[*]:+ ${set_flags[*]}}"
    fi
}

# ---------------------------------------------------------------------------
# Step entry point
# ---------------------------------------------------------------------------

_step_agents() {
    [[ -n "$JUMP_STEP" && "$JUMP_STEP" != "agents" ]] && return
    _header "Step 4 of 7 — VM / LXC Agent Backups"

    _info "PABS backs up VMs and LXCs using a lightweight agent script — no disk images needed."
    _info "The agent is deployed once per VM, then PABS pulls a backup bundle over SSH."
    echo ""
    _info "Supported types: Docker · Home Assistant OS · Minecraft · Generic (any Linux VM)"

    # Count only real (non-comment) agent entries
    local agent_count
    agent_count=$(grep -cE '^\s+"[a-zA-Z0-9].*\.sh"' "$CONFIG" 2>/dev/null || echo 0)
    if [[ "$agent_count" -gt 0 ]]; then
        echo ""
        _ok "$agent_count agent(s) already configured:"
        grep -E '^\s+"[a-zA-Z0-9]' "$CONFIG" 2>/dev/null | grep '\.sh"' | sed 's/^/    /'
        echo ""
    fi

    if ! _ask_yn "Add a VM/LXC agent now?" "n"; then
        _info "Skipping — add agents later with: bash setup.sh --step agents"
        _dim "Or directly: bash install-agent.sh root@<vm-ip>"
        return
    fi

    _agents_setup_ssh_key

    while true; do
        echo ""
        _agents_add_one || true   # failure inside one VM never aborts the loop
        echo ""
        _ask_yn "Add another VM/LXC?" "n" || break
    done

    # Parallelism — only offer if there are multiple agents
    local final_count
    final_count=$(grep -cE '^\s+"[a-zA-Z0-9].*\.sh"' "$CONFIG" 2>/dev/null || echo 0)
    if [[ "$final_count" -gt 1 ]]; then
        _step "Parallel agent backups"
        local current_parallel parallel
        current_parallel=$(_cfg_get "VM_AGENT_MAX_PARALLEL")
        _info "PABS can run multiple agent backups simultaneously to reduce total backup time."
        _info "Rule of thumb: 1 parallel per 500 MB of expected bundle size."
        parallel=$(_ask "Maximum simultaneous agent backups" "${current_parallel:-1}")
        if [[ "$parallel" != "${current_parallel:-1}" ]]; then
            _cfg_set_raw "VM_AGENT_MAX_PARALLEL" "$parallel"
            _ok "VM_AGENT_MAX_PARALLEL set to $parallel"
        fi
    fi

    echo ""
    _ok "VM agent configuration complete"
}
