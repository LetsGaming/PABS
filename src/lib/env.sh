#!/bin/bash
# =============================================================================
# lib/env.sh — Runtime environment normalization
#
# Sourced FIRST by every entry point, before config.sh and before any external
# command runs. Depends on nothing: no config, no logging, no other lib.
#
# Why this exists:
#   cron and systemd start scripts with PATH=/usr/bin:/bin. Debian and Proxmox
#   install blkid, qm, pct, zpool, smartctl and the LVM tools under /usr/sbin,
#   so those commands do not exist as far as a cron-launched run is concerned.
#   PABS swallowed the resulting "command not found" and reported a missing
#   backup drive instead, which sent several weeks of failed runs chasing a USB
#   port that was fine. Normalizing PATH once, here, makes a run behave the same
#   from cron, systemd, ssh and an interactive terminal.
# =============================================================================

# Guard against double-sourcing: entry points that source both this file and a
# lib that re-sources it would otherwise fail on the readonly assignment.
[[ -n "${PABS_ENV_SOURCED:-}" ]] && return 0
PABS_ENV_SOURCED=1

# The PATH root gets from an interactive login shell on Debian/Proxmox.
PABS_BASE_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
readonly PABS_BASE_PATH

normalize_path() {
    # Standard system directories take precedence, so a run always resolves
    # blkid, qm and friends. Directories the caller already had are kept as a
    # tail so custom installs (rclone, gpg, python in /opt) keep working.
    local merged="$PABS_BASE_PATH"
    local dir
    local -a inherited=()

    IFS=':' read -ra inherited <<< "${PATH:-}"
    for dir in "${inherited[@]}"; do
        [[ -z "$dir" ]] && continue
        [[ ":$merged:" == *":$dir:"* ]] && continue
        merged+=":$dir"
    done

    export PATH="$merged"
    # Drop command locations bash cached under the old PATH.
    hash -r 2>/dev/null || true
}

missing_commands() {
    # Prints, one per line, whichever of the given commands are not on PATH.
    # Returns 1 when anything is missing so callers can branch without
    # capturing output. Deliberately does no logging: this file sits below
    # core.sh and must not depend on log()/die().
    local cmd
    local -i absent=0

    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 && continue
        printf '%s\n' "$cmd"
        absent+=1
    done

    [[ $absent -eq 0 ]]
}
