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
    echo -e "${TAB}${TAB}Container ID to destroy (required unless --all)."
    echo ""
    echo -e "${TAB}${GN}--all${CL}"
    echo -e "${TAB}${TAB}Clear all stale locks on this node without destroying"
    echo -e "${TAB}${TAB}any containers. Useful after a storage hiccup."
    echo ""
    echo -e "${TAB}${GN}--dry-run${CL}"
    echo -e "${TAB}${TAB}Show what locks would be cleared without doing anything."
    echo -e "${TAB}${TAB}Can be used with a CTID or with --all."
    echo ""
    echo -e "${TAB}${GN}--status${CL}"
    echo -e "${TAB}${TAB}Show all containers on this node with lock state and"
    echo -e "${TAB}${TAB}storage backend. No changes made."
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
    echo -e "${TAB}Clear all stale locks without destroying anything:"
    echo -e "${TAB}  ${BL}sudo ${SCRIPT_NAME} --all${CL}"
    echo ""
    echo -e "${TAB}Preview what locks would be cleared for container 105:"
    echo -e "${TAB}  ${BL}sudo ${SCRIPT_NAME} --dry-run 105${CL}"
    echo ""
    echo -e "${TAB}Preview all stale locks on this node:"
    echo -e "${TAB}  ${BL}sudo ${SCRIPT_NAME} --dry-run --all${CL}"
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

show_status() {
    header_info
    echo -e "${TAB}${BD}Container Status — $(hostname)${CL}"
    echo ""

    # Get all stale locks
    local PVE_LOCKS CFS_LOCKS
    PVE_LOCKS=$(ls /run/lock/lxc/pve-config-*.lock 2>/dev/null | sed 's/.*pve-config-\([0-9]*\)\.lock/\1/' || true)
    CFS_LOCKS=$(ls -d /etc/pve/priv/lock/storage-* 2>/dev/null | xargs -I{} basename {} || true)

    if [[ -n "$CFS_LOCKS" ]]; then
        echo -e "${TAB}  ${RD}Stale CFS storage locks:${CL}"
        for lock in $CFS_LOCKS; do
            echo -e "${TAB}    ${CROSS} ${lock}"
        done
        echo ""
    fi

    # List all containers
    printf "${TAB}  ${BD}%-8s %-10s %-12s %-20s %s${CL}\n" "CTID" "Status" "Lock" "Storage" "Name"
    printf "${TAB}  ${BD}%-8s %-10s %-12s %-20s %s${CL}\n" "────" "──────" "────" "───────" "────"

    while IFS= read -r line; do
        local ctid status name storage lock_status
        ctid=$(echo "$line" | awk '{print $1}')
        [[ "$ctid" == "VMID" ]] && continue

        status=$(echo "$line" | awk '{print $2}')
        name=$(echo "$line" | awk '{print $3}')

        # Detect storage backend
        storage=$(grep -m1 "rootfs:" "/etc/pve/lxc/${ctid}.conf" 2>/dev/null | cut -d: -f2 | cut -d, -f1 | xargs || echo "unknown")

        # Check for stale lock
        if echo "$PVE_LOCKS" | grep -qw "$ctid"; then
            lock_status="${RD}LOCKED${CL}"
        else
            lock_status="${GN}clean${CL}"
        fi

        # Color status
        local status_colored
        if [[ "$status" == "running" ]]; then
            status_colored="${GN}${status}${CL}"
        else
            status_colored="${YW}${status}${CL}"
        fi

        printf "${TAB}  %-8s %-21s %-23s %-20s %s\n" "$ctid" "$status_colored" "$lock_status" "$storage" "$name"
    done < <(pct list 2>/dev/null)

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
    --status) show_status ;;
esac

# Root check
if [[ $EUID -ne 0 ]]; then
    msg_error "This script must be run as root (use sudo)"
    exit 1
fi

# Parse arguments
DRY_RUN=false
CLEAR_ALL=false
CTID=""

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --all) CLEAR_ALL=true ;;
        --status) show_status ;;
        -h|--help|-V|--version) ;; # already handled
        *)
            if [[ "$arg" =~ ^[0-9]+$ ]]; then
                CTID="$arg"
            else
                msg_error "Invalid argument: ${arg}"
                echo -e "${TAB}  Help: ${BL}${SCRIPT_NAME} -h${CL}"
                exit 1
            fi
            ;;
    esac
done

# Validate: need either CTID or --all
if [[ -z "$CTID" ]] && [[ "$CLEAR_ALL" == false ]]; then
    header_info
    echo -e "${TAB}${BL}What would you like to do?${CL}"
    echo ""
    echo -e "${TAB}  ${GN}1)${CL} Force destroy a specific container"
    echo -e "${TAB}  ${GN}2)${CL} Clear all stale locks (no destroy)"
    echo -e "${TAB}  ${GN}3)${CL} Dry run — preview locks for a container"
    echo -e "${TAB}  ${GN}4)${CL} Dry run — preview all stale locks"
    echo -e "${TAB}  ${GN}5)${CL} Show container status and lock state"
    echo -e "${TAB}  ${RD}q)${CL} Quit"
    echo ""
    read -rp "  Select an option [1-5/q]: " choice

    case "$choice" in
        1)
            read -rp "  Enter container ID: " CTID
            if [[ -z "$CTID" ]] || ! [[ "$CTID" =~ ^[0-9]+$ ]]; then
                msg_error "Invalid container ID"
                exit 1
            fi
            ;;
        2) CLEAR_ALL=true ;;
        3)
            DRY_RUN=true
            read -rp "  Enter container ID: " CTID
            if [[ -z "$CTID" ]] || ! [[ "$CTID" =~ ^[0-9]+$ ]]; then
                msg_error "Invalid container ID"
                exit 1
            fi
            ;;
        4) DRY_RUN=true; CLEAR_ALL=true ;;
        5) show_status ;;
        q|Q)
            echo ""
            msg_ok "Exiting. No changes made."
            echo ""
            exit 0
            ;;
        *)
            msg_error "Invalid option"
            exit 1
            ;;
    esac
    echo ""
fi

# ============================================================
# MODE: --all (clear all stale locks, no destroy)
# ============================================================

if [[ "$CLEAR_ALL" == true ]]; then
    header_info
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${TAB}${BD}Dry Run — Clear All Stale Locks${CL}"
    else
        echo -e "${TAB}${BD}Clear All Stale Locks${CL}"
    fi
    echo ""

    # PVE config locks
    PVE_LOCKS=(/run/lock/lxc/pve-config-*.lock)
    if [[ ${#PVE_LOCKS[@]} -gt 0 ]]; then
        for lockfile in "${PVE_LOCKS[@]}"; do
            lockname=$(basename "$lockfile")
            if [[ "$DRY_RUN" == true ]]; then
                msg_warn "Would clear: ${lockname}"
            else
                rm -f "$lockfile"
                msg_ok "Cleared: ${lockname}"
            fi
        done
    else
        msg_ok "No stale PVE config locks found"
    fi

    # CFS storage locks
    CFS_LOCKS=(/etc/pve/priv/lock/storage-*)
    if [[ ${#CFS_LOCKS[@]} -gt 0 ]]; then
        for lockdir in "${CFS_LOCKS[@]}"; do
            if [[ -e "$lockdir" ]]; then
                lockname=$(basename "$lockdir")
                if [[ "$DRY_RUN" == true ]]; then
                    msg_warn "Would clear: ${lockname}"
                else
                    rm -rf "$lockdir"
                    msg_ok "Cleared: ${lockname}"
                fi
            fi
        done
    else
        msg_ok "No stale CFS storage locks found"
    fi

    echo ""
    if [[ "$DRY_RUN" == true ]]; then
        msg_ok "Dry run complete. No changes made."
    else
        msg_ok "All stale locks cleared"
    fi
    echo ""
    exit 0
fi

# ============================================================
# MODE: Standard destroy (with optional --dry-run)
# ============================================================

header_info
if [[ "$DRY_RUN" == true ]]; then
    echo -e "${TAB}${BD}Dry Run — Force Destroy CT ${CTID}${CL}"
else
    echo -e "${TAB}${BD}Force Destroy CT ${CTID}${CL}"
fi
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
    if [[ "$DRY_RUN" == true ]]; then
        msg_warn "Would clear PVE config lock"
    else
        rm -f "/run/lock/lxc/pve-config-${CTID}.lock"
        msg_ok "Cleared PVE config lock"
    fi
else
    msg_ok "No PVE config lock found"
fi

# Clear CFS storage locks
LOCKS_CLEARED=0
for lockdir in /etc/pve/priv/lock/storage-*; do
    if [[ -e "$lockdir" ]]; then
        lockname=$(basename "$lockdir")
        if [[ "$DRY_RUN" == true ]]; then
            msg_warn "Would clear CFS lock: ${lockname}"
        else
            rm -rf "$lockdir"
            msg_ok "Cleared CFS lock: ${lockname}"
        fi
        LOCKS_CLEARED=$((LOCKS_CLEARED + 1))
    fi
done
if [[ $LOCKS_CLEARED -eq 0 ]]; then
    msg_ok "No CFS storage locks found"
fi

# Destroy (skip in dry-run)
if [[ "$DRY_RUN" == true ]]; then
    echo ""
    msg_warn "Would run: pct destroy ${CTID} --purge --force"
    echo ""
    msg_ok "Dry run complete. No changes made."
else
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
fi

echo ""