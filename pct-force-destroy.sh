#!/usr/bin/env bash

# Force destroy a Proxmox LXC container with stale locks
# https://github.com/SunBroLynk/Proxmox-Scripts
# License: MIT
#
# Clears stale PVE and CFS locks that prevent container deletion,
# commonly caused by NFS timeouts on shared storage.

set -euo pipefail

# Script metadata
SCRIPT_NAME="pct-force-destroy"
SCRIPT_VERSION="1.0.0"

# Colors
RD=$'\033[01;31m'
YW=$'\033[33m'
GN=$'\033[1;92m'
BL=$'\033[36m'
BD=$'\033[1m'
CL=$'\033[m'
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"
INFO="${BL}ℹ${CL}"
TAB="  "

msg_ok()    { echo -e "${TAB}${CM} ${GN}$1${CL}"; }
msg_error() { echo -e "${TAB}${CROSS} ${RD}$1${CL}"; }
msg_warn()  { echo -e "${TAB}${INFO} ${YW}$1${CL}"; }
msg_info()  { echo -ne "${TAB}- ${YW}$1...${CL}"; }
msg_done()  { echo -e "\r\033[K${TAB}${CM} ${GN}$1${CL}"; }

# Help
if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
    echo ""
    echo -e "${BD}NAME${CL}"
    echo -e "${TAB}${SCRIPT_NAME} — force destroy a Proxmox LXC with stale locks"
    echo ""
    echo -e "${BD}SYNOPSIS${CL}"
    echo -e "${TAB}${SCRIPT_NAME} <CTID>"
    echo ""
    echo -e "${BD}DESCRIPTION${CL}"
    echo -e "${TAB}Clears stale PVE config locks and CFS storage locks that"
    echo -e "${TAB}prevent container deletion, then destroys the container."
    echo -e "${TAB}This is commonly needed when NFS storage timeouts leave"
    echo -e "${TAB}orphaned lock files behind."
    echo ""
    echo -e "${BD}OPTIONS${CL}"
    echo -e "${TAB}${GN}<CTID>${CL}           Container ID to destroy (required)"
    echo -e "${TAB}${GN}-h, --help${CL}       Show this help"
    echo -e "${TAB}${GN}-V, --version${CL}    Show version"
    echo ""
    echo -e "${BD}EXAMPLES${CL}"
    echo -e "${TAB}${BL}sudo pct-force-destroy 105${CL}"
    echo ""
    echo -e "${BD}WHAT IT DOES${CL}"
    echo -e "${TAB}1. Verifies the container exists and is stopped"
    echo -e "${TAB}2. Clears stale PVE config lock (/run/lock/lxc/)"
    echo -e "${TAB}3. Clears stale CFS storage locks (/etc/pve/priv/lock/)"
    echo -e "${TAB}4. Runs pct destroy with --purge --force"
    echo ""
    exit 0
fi

# Version
if [[ "${1:-}" == "-V" ]] || [[ "${1:-}" == "--version" ]]; then
    echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"
    exit 0
fi

# Root check
if [[ $EUID -ne 0 ]]; then
    msg_error "This script must be run as root (use sudo)"
    exit 1
fi

# Argument check
CTID="${1:-}"
if [[ -z "$CTID" ]]; then
    msg_error "No container ID specified"
    echo -e "${TAB}  Usage: ${BL}${SCRIPT_NAME} <CTID>${CL}"
    exit 1
fi

# Validate CTID is a number
if ! [[ "$CTID" =~ ^[0-9]+$ ]]; then
    msg_error "Invalid container ID: ${CTID}"
    exit 1
fi

echo ""
echo -e "${TAB}${BD}Force Destroy CT ${CTID}${CL}"
echo ""

# Check container exists
if ! pct status "$CTID" &>/dev/null; then
    msg_error "Container ${CTID} does not exist"
    exit 1
fi
msg_ok "Container ${CTID} found"

# Check container is stopped
CT_STATUS=$(pct status "$CTID" 2>/dev/null | awk '{print $2}')
if [[ "$CT_STATUS" != "stopped" ]]; then
    msg_error "Container ${CTID} is ${CT_STATUS} — stop it first"
    echo -e "${TAB}  Run: ${BL}pct stop ${CTID}${CL}"
    exit 1
fi
msg_ok "Container ${CTID} is stopped"

# Clear PVE config lock
if [[ -f "/run/lock/lxc/pve-config-${CTID}.lock" ]]; then
    rm -f "/run/lock/lxc/pve-config-${CTID}.lock"
    msg_ok "Cleared PVE config lock"
else
    msg_ok "No PVE config lock found"
fi

# Clear CFS storage locks
LOCKS_CLEARED=0
for lockdir in /etc/pve/priv/lock/storage-*; do
    if [[ -e "$lockdir" ]]; then
        lockname=$(basename "$lockdir")
        rm -rf "$lockdir"
        msg_ok "Cleared CFS lock: ${lockname}"
        LOCKS_CLEARED=$((LOCKS_CLEARED + 1))
    fi
done
if [[ $LOCKS_CLEARED -eq 0 ]]; then
    msg_ok "No CFS storage locks found"
fi

# Destroy
msg_info "Destroying container ${CTID}"
if pct destroy "$CTID" --purge --force 2>&1; then
    msg_done "Container ${CTID} destroyed"
else
    msg_error "Destroy failed — check storage connectivity"
    echo -e "${TAB}  Verify NFS mount: ${BL}df -h /mnt/pve/docker${CL}"
    exit 1
fi

echo ""
