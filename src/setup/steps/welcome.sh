#!/bin/bash
# setup/steps/welcome.sh — PABS ASCII banner and intro screen

_step_welcome() {
    clear
    echo ""
    echo "${BOLD}${CYAN}"
    cat << 'BANNER'
  ██████╗  █████╗ ██████╗ ███████╗
  ██╔══██╗██╔══██╗██╔══██╗██╔════╝
  ██████╔╝███████║██████╔╝███████╗
  ██╔═══╝ ██╔══██║██╔══██╗╚════██║
  ██║     ██║  ██║██████╔╝███████║
  ╚═╝     ╚═╝  ╚═╝╚═════╝ ╚══════╝
  Proxmox Automated Backup System
BANNER
    echo "${RESET}"
    _dim "Version: $PABS_VERSION"
    _dim "Config:  $CONFIG"
    echo ""
    echo "  This wizard will guide you through:"
    echo "  ${GREEN}1.${RESET} Installing dependencies"
    echo "  ${GREEN}2.${RESET} Configuring the USB backup target"
    echo "  ${GREEN}3.${RESET} Setting up notifications"
    echo "  ${GREEN}4.${RESET} Deploying VM/LXC agents (optional)"
    echo "  ${GREEN}5.${RESET} Configuring offsite sync (optional)"
    echo "  ${GREEN}6.${RESET} Scheduling with cron"
    echo "  ${GREEN}7.${RESET} Running the first backup"
    echo ""
    echo "  ${DIM}Re-run this wizard at any time to update settings.${RESET}"
    echo "  ${DIM}Press Ctrl+C at any prompt to abort without saving.${RESET}"
    echo ""
    _pause "Ready to start"
}
