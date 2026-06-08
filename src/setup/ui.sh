#!/bin/bash
# =============================================================================
# setup/ui.sh — Terminal output and interactive input helpers
#
# Sourced by setup.sh before any step modules. Defines all colour variables
# and every _ask / _header / _ok / _warn / ... function used across steps.
# Nothing in here reads or writes files — pure UI primitives only.
# =============================================================================

# ---------------------------------------------------------------------------
# Colour detection — disabled automatically in pipes / CI / dumb terminals
# ---------------------------------------------------------------------------

if [[ -t 2 ]] && command -v tput &>/dev/null && tput colors &>/dev/null 2>&1; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    CYAN=$(tput setaf 6)
    BOLD=$(tput bold)
    DIM=$(tput dim)
    RESET=$(tput sgr0)
else
    RED="" GREEN="" YELLOW="" CYAN="" BOLD="" DIM="" RESET=""
fi

export RED GREEN YELLOW CYAN BOLD DIM RESET

# ---------------------------------------------------------------------------
# Structural output
# ---------------------------------------------------------------------------

_header() {
    echo ""
    echo "${BOLD}${CYAN}══════════════════════════════════════════════════════${RESET}"
    echo "${BOLD}${CYAN}  $*${RESET}"
    echo "${BOLD}${CYAN}══════════════════════════════════════════════════════${RESET}"
    echo ""
}

_step() {
    echo ""
    echo "${BOLD}▸ $*${RESET}"
}

# ---------------------------------------------------------------------------
# Status line helpers
# ---------------------------------------------------------------------------

_ok()   { echo "  ${GREEN}✓${RESET}  $*"; }
_warn() { echo "  ${YELLOW}⚠${RESET}  $*"; }
_info() { echo "  ${CYAN}ℹ${RESET}  $*"; }
_err()  { echo "  ${RED}✗${RESET}  $*"; }
_dim()  { echo "  ${DIM}$*${RESET}"; }

_die() {
    _err "$*"
    exit 1
}

# ---------------------------------------------------------------------------
# Interactive input
# ---------------------------------------------------------------------------

# _ask PROMPT [DEFAULT]
# Prompts the user and returns the typed value, or DEFAULT if empty.
#
# CRITICAL: The prompt is written to stderr (>&2) so that callers using
# val=$(_ask ...) capture only the clean value on stdout, not the prompt text.
# Without this, val would contain the entire "  Prompt [default]: answer" line.
#
# In --yes mode, returns DEFAULT immediately without prompting.
_ask() {
    local prompt="$1"
    local default="${2:-}"
    local input

    if [[ -n "$default" ]]; then
        printf "  %s${BOLD} [%s]${RESET}: " "$prompt" "$default" >&2
    else
        printf "  %s: " "$prompt" >&2
    fi

    if ${AUTO_YES:-false} && [[ -n "$default" ]]; then
        printf '%s\n' "$default" >&2   # echo the default so output looks right
        printf '%s' "$default"
        return
    fi

    read -r input
    printf '%s' "${input:-$default}"
}

# _ask_yn PROMPT [DEFAULT: y|n]
# Returns 0 for yes, 1 for no.
# Prompt written to stderr; no stdout output (return code is the answer).
_ask_yn() {
    local prompt="$1"
    local default="${2:-y}"
    local yn

    if ${AUTO_YES:-false}; then
        [[ "$default" == "y" ]] && return 0 || return 1
    fi

    while true; do
        if [[ "$default" == "y" ]]; then
            printf "  %s ${BOLD}[Y/n]${RESET}: " "$prompt" >&2
        else
            printf "  %s ${BOLD}[y/N]${RESET}: " "$prompt" >&2
        fi
        read -r yn
        yn="${yn:-$default}"
        case "${yn,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *)     _warn "Please answer y or n" ;;
        esac
    done
}

# _ask_secret PROMPT
# Reads without echo. Prompt written to stderr. Never auto-fills in --yes mode.
_ask_secret() {
    local prompt="$1"
    local input
    printf "  %s: " "$prompt" >&2
    read -rs input
    echo "" >&2
    printf '%s' "$input"
}

# _ask_choice PROMPT DEFAULT OPTION1 OPTION2 ...
# Displays a numbered menu and returns the chosen number.
# Prompt and menu written to stderr; only the number goes to stdout.
_ask_choice() {
    local prompt="$1"
    local default="$2"
    shift 2
    local -a options=("$@")
    local choice

    echo "" >&2
    local i=1
    for opt in "${options[@]}"; do
        printf "  ${GREEN}%d)${RESET} %s\n" "$i" "$opt" >&2
        i=$(( i + 1 ))
    done
    echo "" >&2

    while true; do
        printf "  %s ${BOLD}[%s]${RESET}: " "$prompt" "$default" >&2
        read -r choice
        choice="${choice:-$default}"
        if [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le ${#options[@]} ]]; then
            printf '%s' "$choice"
            return
        fi
        _warn "Enter a number between 1 and ${#options[@]}"
    done
}

# _pause [MESSAGE]
# Waits for Enter. Skipped silently in --yes mode.
_pause() {
    ${AUTO_YES:-false} && return
    printf "  ${DIM}%s — press Enter to continue...${RESET}" "${1:-}" >&2
    read -r
}
