#!/usr/bin/env bash

# Force destroy a Proxmox LXC container with stale locks
# https://github.com/SunBroLynk/Proxmox-Scripts
# License: MIT
#
# Clears stale PVE and CFS locks that prevent container deletion,
# commonly caused by NFS timeouts on shared storage.

set -euo pipefail
shopt -s inherit_errexit nullglob

# Script metadata
SCRIPT_NAME="pct-force-destroy"
SCRIPT_VERSION="1.0.0"
SCRIPT_URL="https://github.com/SunBroLynk/Proxmox-Scripts"

# Colors
RD=$'\033[01;31m'
YW=$'\033[33m'
GN=$'\033[1;92m'
BL=$'\033[36m'
BD=$'\033[1m'
CL=$'\033[m'
BFR=$'\r\033[K'
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"
INFO="${BL}ℹ${CL}"
TAB="  "

# Trap CTRL+C
trap 'echo -e "\n\n${TAB}${YW}⚠  Cancelled by user. Container was NOT destroyed.${CL}\n"; exit 0' SIGINT SIGTERM

msg_ok()    { echo -e "${TAB}${CM} ${GN}$1${CL}"; }
msg_error() { echo -e "${TAB}${CROSS} ${RD}$1${CL}"; }
msg_warn()  { echo -e "${TAB}${INFO} ${YW}$1${CL}"; }
msg_info()  { echo -ne "${TAB}- ${YW}$1...${CL}"; }
msg_done()  { echo -e "${BFR}${TAB}${CM} ${GN}$1${CL}"; }

header_info() {
    clear
    cat <<"EOF"
  ___                              
 | _ \_ _ _____ ___ __  _____ __  
 |  _/ '_/ _ \ \ / '  \/ _ \ \ / 
 |_| |_| \___/_\_\_|_|_\___/_\_\  
      ╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍
          S c r i p t s

   __              __   
  / /  ___  ____  / /__ 
 / /__/ _ \/ __/ /  '_/ 
/____/\___/\__/ /_/\_\  
   b r e a k e r
EOF
    echo ""
}

show_help() {
    header_info
    echo -e "${BD}NAME${CL}"
    echo -e "${TAB}${SCRIPT_NAME} — force destroy a Proxmox LXC with stale locks"
    echo ""
    echo -e "${BD}SYNOPSIS${CL}"
    echo -e "${TAB}${SCRIPT_NAME} <CTID>"
    echo ""
    echo -e "${BD}DESCRIPTION${CL}"
    echo -e "${TAB}Clears stale PVE config locks and CFS storage locks that"
    echo -e "${TAB}prevent container deletion, then destroys the container."
    echo -e "${TAB}This commonly happens when NFS-backed shared storage"
    echo -e "${TAB}timeouts leave orphaned lock files behind. Eliminates"
    echo -e "${TAB}the need to reboot the node just to delete a container."
    echo ""
    echo -e "${BD}OPTIONS${CL}"
    echo -e "${TAB}${GN}<CTID>${CL}"
    echo -e "${TAB}${TAB}Container ID to destroy (required)."
    echo ""
    echo -e "${TAB}${GN}-h, --help${CL}"
    echo -e "${TAB}${TAB}Display this help and exit."
    echo ""
    echo -e "${TAB}${GN}-V, --version${CL}"
    echo -e "${TAB}${TAB}Display script version and exit."
    echo ""
    echo -e "${BD}FILES${CL}"
    echo -e "${TAB}${BL}/run/lock/lxc/pve-config-<CTID>.lock${CL}"
    echo -e "${TAB}${TAB}PVE config lock file. Created during container operations."
    echo -e "${TAB}${TAB}Becomes stale if the operation is interrupted."
    echo ""
    echo -e "${TAB}${BL}/etc/pve/priv/lock/storage-*${CL}"
    echo -e "${TAB}${TAB}CFS storage locks (cluster-wide). Becomes stale when NFS"
    echo -e "${TAB}${TAB}operations hang and the holding process dies."
    echo ""
    echo -e "${BD}EXIT STATUS${CL}"
    echo -e "${TAB}${GN}0${CL}  Container destroyed successfully"
    echo -e "${TAB}${RD}1${CL}  Error (container not found, still running, or destroy failed)"
    echo ""
    echo -e "${BD}EXAMPLES${CL}"
    echo -e "${TAB}Force destroy container 105:"
    echo -e "${TAB}  ${BL}sudo ${SCRIPT_NAME} 105${CL}"
    echo ""
    echo -e "${TAB}Deploy to all cluster nodes:"
    echo -e "${TAB}  ${BL}for node in node1-ip node2-ip node3-ip; do${CL}"
    echo -e "${TAB}  ${BL}    scp /usr/local/bin/${SCRIPT_NAME} root@\${node}:/usr/local/bin/${CL}"
    echo -e "${TAB}  ${BL}done${CL}"
    echo ""
    echo -e "${BD}PREVENTION${CL}"
    echo -e "${TAB}If stale locks happen frequently, change NFS mount options"
    echo -e "${TAB}from hard to soft in /etc/pve/storage.cfg:"
    echo ""
    echo -e "${TAB}  ${BL}options soft,timeo=30,retrans=3${CL}"
    echo ""
    echo -e "${TAB}This makes NFS operations timeout cleanly instead of"
    echo -e "${TAB}hanging forever."
    echo ""
    echo -e "${BD}SEE ALSO${CL}"
    echo -e "${TAB}Proxmox NFS docs:  ${BL}https://pve.proxmox.com/wiki/Storage:_NFS${CL}"
    echo -e "${TAB}Project repo:      ${BL}${SCRIPT_URL}${CL}"
    echo ""
    echo -e "${BD}LICENSE${CL}"
    echo -e "${TAB}MIT — ${SCRIPT_URL}/blob/main/LICENSE"
    echo ""
    exit 0
}

# Early exit for help and version
case "${1:-}" in
    -h|--help) show_help ;;
    -V|--version)
        echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"
        echo "${SCRIPT_URL}"
        exit 0
        ;;
esac

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
    echo -e "${TAB}  Help:  ${BL}${SCRIPT_NAME} -h${CL}"
    exit 1
fi

# Validate CTID is a number
if ! [[ "$CTID" =~ ^[0-9]+$ ]]; then
    msg_error "Invalid container ID: ${CTID}"
    exit 1
fi

header_info
echo -e "${TAB}${BD}Force Destroy CT ${CTID}${CL}"
echo ""

# Check container exists
if ! pct status "$CTID" &>/dev/null; then
    msg_error "Container ${CTID} does not exist on this node"
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
    msg_done "Container ${CTID} destroyed successfully"
else
    msg_error "Destroy failed"
    echo -e "${TAB}  The storage backend may be unresponsive."
    echo -e "${TAB}  Check NFS mounts: ${BL}mount | grep nfs${CL}"
    echo -e "${TAB}  Check connectivity: ${BL}ping <NAS-IP>${CL}"
    exit 1
fi

echo ""
