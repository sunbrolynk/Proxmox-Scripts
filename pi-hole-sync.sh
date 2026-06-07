#!/usr/bin/env bash

# Pi-hole Sync — Teleporter-based primary → backup sync
# https://github.com/SunBroLynk/Proxmox-Scripts
# License: MIT
#
# Syncs Pi-hole configuration from a primary instance to a backup
# using the built-in Teleporter CLI. Designed for Pi-hole v6+.

# ============================================================
# CONFIGURATION — adjust these for your setup
# ============================================================
BACKUP_PIHOLE="192.168.1.2"           # IP of the backup Pi-hole
BACKUP_SSH_USER="root"                # SSH user on the backup Pi-hole
BACKUP_SSH_PORT="22"                  # SSH port on the backup Pi-hole
LOCAL_BACKUP_DIR="/var/backups/pihole" # Where to store Teleporter archives locally
RETENTION_COUNT=7                     # Number of local backups to keep
# ============================================================

set -euo pipefail
shopt -s inherit_errexit nullglob

# Script metadata
SCRIPT_NAME="pihole-sync"
SCRIPT_VERSION="1.0.0"
SCRIPT_URL="https://github.com/SunBroLynk/Proxmox-Scripts"
SCRIPT_PATH="$(readlink -f "$0")"

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
trap 'echo -e "\n\n${TAB}${YW}⚠  Sync cancelled by user. Backup Pi-hole was NOT modified.${CL}\n"; cleanup; exit 0' SIGINT SIGTERM

# Temp files tracking
TEMP_FILES=()

cleanup() {
    for f in "${TEMP_FILES[@]:-}"; do
        rm -f "$f" 2>/dev/null
    done
}

header_info() {
    clear
    cat <<"EOF"
  ___                              
 | _ \_ _ _____ ___ __  _____ __  
 |  _/ '_/ _ \ \ / '  \/ _ \ \ / 
 |_| |_| \___/_\_\_|_|_\___/_\_\  
      ╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍
          S c r i p t s

        _ __       __   
   ___ (_) /  ___ / /__ 
  / _ \/ / _ \/ _ \ / -_)
 / .__/_/_//_/\___/_/\__/ 
/_/          s y n c
EOF
    echo ""
}

show_help() {
    header_info
    echo -e "${BD}NAME${CL}"
    echo -e "${TAB}${SCRIPT_NAME} — sync Pi-hole config from primary to backup"
    echo ""
    echo -e "${BD}SYNOPSIS${CL}"
    echo -e "${TAB}${SCRIPT_NAME} [${BL}OPTIONS${CL}]"
    echo ""
    echo -e "${BD}DESCRIPTION${CL}"
    echo -e "${TAB}Uses Pi-hole's built-in Teleporter to export the primary"
    echo -e "${TAB}Pi-hole's configuration and import it on the backup. Syncs"
    echo -e "${TAB}blocklists, local DNS records, dnsmasq config, DHCP leases,"
    echo -e "${TAB}groups, clients, and all settings. Designed for Pi-hole v6+."
    echo ""
    echo -e "${TAB}Run this script on the ${BD}primary${CL} Pi-hole. It connects to the"
    echo -e "${TAB}backup via SSH to transfer and import the configuration."
    echo ""
    echo -e "${BD}OPTIONS${CL}"
    echo -e "${TAB}${GN}(no arguments)${CL}"
    echo -e "${TAB}${TAB}Run the sync."
    echo ""
    echo -e "${TAB}${GN}-y, --yes${CL}"
    echo -e "${TAB}${TAB}Skip confirmation prompt."
    echo ""
    echo -e "${TAB}${GN}--backup-only${CL}"
    echo -e "${TAB}${TAB}Create a local Teleporter backup without syncing."
    echo ""
    echo -e "${TAB}${GN}--list${CL}"
    echo -e "${TAB}${TAB}List local Teleporter backups."
    echo ""
    echo -e "${TAB}${GN}-h, --help${CL}"
    echo -e "${TAB}${TAB}Display this help and exit."
    echo ""
    echo -e "${TAB}${GN}-V, --version${CL}"
    echo -e "${TAB}${TAB}Display script version and exit."
    echo ""
    echo -e "${BD}CONFIGURATION${CL}"
    echo -e "${TAB}Edit the variables at the top of this script to match your setup."
    echo -e "${TAB}File: ${BL}${SCRIPT_PATH}${CL}"
    echo ""

    # Dynamically show config variables with line numbers
    echo -e "${TAB}${BD}Variable                    Line  Current Value${CL}"
    echo -e "${TAB}──────────────────────────  ────  ─────────────────────────"
    while IFS= read -r line; do
        local linenum var val
        linenum=$(echo "$line" | cut -d: -f1)
        var=$(echo "$line" | cut -d: -f2- | cut -d= -f1 | xargs)
        val=$(echo "$line" | cut -d= -f2- | tr -d '"')
        printf "${TAB}${GN}%-28s${CL}${YW}%-6s${CL}%s\n" "$var" "$linenum" "$val"
    done < <(grep -n '^[A-Z_]*=' "$SCRIPT_PATH" | grep -v '^#' | grep -v 'SCRIPT_\|^[0-9]*:set \|^[0-9]*:shopt \|^[0-9]*:RD=\|^[0-9]*:YW=\|^[0-9]*:GN=\|^[0-9]*:BL=\|^[0-9]*:BD=\|^[0-9]*:CL=\|^[0-9]*:BFR=\|^[0-9]*:CM=\|^[0-9]*:CROSS=\|^[0-9]*:INFO=\|^[0-9]*:TAB=\|^[0-9]*:TEMP_FILES\|SKIP_\|BACKUP_ONLY\|AUTO_YES\|BACKUP_FILE\|BACKUP_NAME\|REMOTE_\|PRIMARY_\|IMPORT_' | head -5)

    echo ""
    echo -e "${BD}PREREQUISITES${CL}"
    echo -e "${TAB}• Pi-hole v6+ on both primary and backup"
    echo -e "${TAB}• SSH key-based auth from primary to backup"
    echo -e "${TAB}  Set up with: ${BL}ssh-copy-id ${BACKUP_SSH_USER}@${BACKUP_PIHOLE}${CL}"
    echo ""
    echo -e "${BD}FILES${CL}"
    echo -e "${TAB}${BL}${LOCAL_BACKUP_DIR}/${CL}"
    echo -e "${TAB}${TAB}Local archive of Teleporter backups. Oldest files pruned"
    echo -e "${TAB}${TAB}when count exceeds RETENTION_COUNT (${RETENTION_COUNT})."
    echo ""
    echo -e "${BD}EXIT STATUS${CL}"
    echo -e "${TAB}${GN}0${CL}  Sync completed successfully"
    echo -e "${TAB}${RD}1${CL}  Error (SSH failure, Teleporter failure, etc.)"
    echo ""
    echo -e "${BD}EXAMPLES${CL}"
    echo -e "${TAB}Interactive sync:"
    echo -e "${TAB}  ${BL}sudo ${SCRIPT_NAME}${CL}"
    echo ""
    echo -e "${TAB}Automated daily sync via cron (no prompts):"
    echo -e "${TAB}  ${BL}sudo crontab -e${CL}"
    echo -e "${TAB}  ${BL}0 3 * * * /usr/local/bin/${SCRIPT_NAME} -y >> /var/log/${SCRIPT_NAME}.log 2>&1${CL}"
    echo ""
    echo -e "${TAB}Create a local backup only (no sync):"
    echo -e "${TAB}  ${BL}sudo ${SCRIPT_NAME} --backup-only${CL}"
    echo ""
    echo -e "${TAB}List stored backups:"
    echo -e "${TAB}  ${BL}sudo ${SCRIPT_NAME} --list${CL}"
    echo ""
    echo -e "${BD}SEE ALSO${CL}"
    echo -e "${TAB}Pi-hole docs:      ${BL}https://docs.pi-hole.net${CL}"
    echo -e "${TAB}Project repo:      ${BL}${SCRIPT_URL}${CL}"
    echo ""
    echo -e "${BD}LICENSE${CL}"
    echo -e "${TAB}MIT — ${SCRIPT_URL}/blob/main/LICENSE"
    echo ""
    exit 0
}

msg_info() {
    local msg="$1"
    echo -ne "${TAB}- ${YW}${msg}...${CL}"
}

msg_ok() {
    local msg="$1"
    echo -e "${BFR}${TAB}${CM} ${GN}${msg}${CL}"
}

msg_error() {
    local msg="$1"
    echo -e "${BFR}${TAB}${CROSS} ${RD}${msg}${CL}"
}

msg_warn() {
    local msg="$1"
    echo -e "${BFR}${TAB}${INFO} ${YW}${msg}${CL}"
}

# ============================================================
# PREFLIGHT CHECKS
# ============================================================

preflight_checks() {
    echo -e "${TAB}${BL}Preflight Checks${CL}"
    echo ""

    local CRITICAL=false

    # pihole-FTL exists
    if command -v pihole-FTL &>/dev/null; then
        local PH_VER
        PH_VER=$(pihole -v 2>/dev/null | head -1 || echo "unknown")
        msg_ok "pihole-FTL found"
    else
        msg_error "pihole-FTL not found — is Pi-hole installed?"
        CRITICAL=true
    fi

    # SSH to backup
    msg_info "Testing SSH to backup (${BACKUP_PIHOLE})"
    if ssh -p "${BACKUP_SSH_PORT}" -o ConnectTimeout=5 -o BatchMode=yes "${BACKUP_SSH_USER}@${BACKUP_PIHOLE}" "echo ok" &>/dev/null; then
        msg_ok "SSH to backup (${BACKUP_PIHOLE}) connected"
    else
        msg_error "Cannot SSH to ${BACKUP_SSH_USER}@${BACKUP_PIHOLE}:${BACKUP_SSH_PORT}"
        echo -e "${TAB}  Set up key auth: ${BL}ssh-copy-id ${BACKUP_SSH_USER}@${BACKUP_PIHOLE}${CL}"
        CRITICAL=true
    fi

    # pihole-FTL on backup
    if [[ "$CRITICAL" == false ]]; then
        msg_info "Checking pihole-FTL on backup"
        if ssh -p "${BACKUP_SSH_PORT}" -o BatchMode=yes "${BACKUP_SSH_USER}@${BACKUP_PIHOLE}" "command -v pihole-FTL" &>/dev/null; then
            msg_ok "pihole-FTL found on backup"
        else
            msg_error "pihole-FTL not found on backup Pi-hole"
            CRITICAL=true
        fi
    fi

    # Backup directory
    if [[ ! -d "${LOCAL_BACKUP_DIR}" ]]; then
        msg_info "Creating backup directory"
        mkdir -p "${LOCAL_BACKUP_DIR}"
        msg_ok "Created ${LOCAL_BACKUP_DIR}"
    else
        msg_ok "Backup directory exists (${LOCAL_BACKUP_DIR})"
    fi

    # Disk space
    local DISK_AVAIL
    DISK_AVAIL=$(df -BM "${LOCAL_BACKUP_DIR}" | tail -1 | awk '{print $4}' | tr -d 'M')
    if [[ "$DISK_AVAIL" -lt 50 ]]; then
        msg_warn "Low disk space: ${DISK_AVAIL}MB available"
    else
        msg_ok "Disk space: ${DISK_AVAIL}MB available"
    fi

    echo ""

    if [[ "$CRITICAL" == true ]]; then
        msg_error "Preflight checks failed"
        echo ""
        exit 1
    fi

    msg_ok "All preflight checks passed"
    echo ""
}

# ============================================================
# SYNC FUNCTIONS
# ============================================================

create_backup() {
    msg_info "Creating Teleporter backup on primary"

    cd /tmp
    local BEFORE_FILES
    BEFORE_FILES=$(ls pi-hole_*teleporter*.zip 2>/dev/null || true)

    if ! pihole-FTL --teleporter &>/dev/null; then
        msg_error "Teleporter export failed"
        echo -e "${TAB}  Run manually: ${BL}pihole-FTL --teleporter${CL}"
        return 1
    fi

    # Find the new file
    BACKUP_FILE=""
    for f in pi-hole_*teleporter*.zip; do
        if [[ ! " ${BEFORE_FILES} " =~ " ${f} " ]]; then
            BACKUP_FILE="/tmp/${f}"
            break
        fi
    done

    # Fallback: just get the newest one
    if [[ -z "$BACKUP_FILE" ]]; then
        BACKUP_FILE=$(ls -t /tmp/pi-hole_*teleporter*.zip 2>/dev/null | head -1)
    fi

    if [[ -z "$BACKUP_FILE" ]] || [[ ! -f "$BACKUP_FILE" ]]; then
        msg_error "Teleporter backup file not found"
        return 1
    fi

    TEMP_FILES+=("$BACKUP_FILE")
    BACKUP_NAME=$(basename "$BACKUP_FILE")
    local BACKUP_SIZE
    BACKUP_SIZE=$(du -h "$BACKUP_FILE" | awk '{print $1}')

    msg_ok "Backup created: ${BACKUP_NAME} (${BACKUP_SIZE})"

    # Store local copy
    cp "$BACKUP_FILE" "${LOCAL_BACKUP_DIR}/"
    msg_ok "Stored in ${LOCAL_BACKUP_DIR}/"
}

transfer_backup() {
    msg_info "Transferring backup to ${BACKUP_PIHOLE}"

    if ! scp -P "${BACKUP_SSH_PORT}" -o BatchMode=yes "$BACKUP_FILE" "${BACKUP_SSH_USER}@${BACKUP_PIHOLE}:/tmp/${BACKUP_NAME}" &>/dev/null; then
        msg_error "Transfer failed"
        echo -e "${TAB}  Check SSH connection: ${BL}ssh ${BACKUP_SSH_USER}@${BACKUP_PIHOLE}${CL}"
        return 1
    fi

    msg_ok "Transferred to ${BACKUP_PIHOLE}:/tmp/${BACKUP_NAME}"
}

import_backup() {
    msg_info "Importing configuration on backup Pi-hole"

    local IMPORT_OUTPUT
    IMPORT_OUTPUT=$(ssh -p "${BACKUP_SSH_PORT}" -o BatchMode=yes "${BACKUP_SSH_USER}@${BACKUP_PIHOLE}" \
        "pihole-FTL --teleporter /tmp/${BACKUP_NAME} 2>&1")

    if [[ $? -ne 0 ]]; then
        msg_error "Import failed on backup Pi-hole"
        echo -e "${TAB}  Output: ${IMPORT_OUTPUT}"
        return 1
    fi

    # Count imported items
    local IMPORT_COUNT
    IMPORT_COUNT=$(echo "$IMPORT_OUTPUT" | grep -c "^Imported" || echo "0")

    msg_ok "Imported ${IMPORT_COUNT} items on backup Pi-hole"
}

reload_backup_dns() {
    msg_info "Reloading DNS on backup Pi-hole"

    if ssh -p "${BACKUP_SSH_PORT}" -o BatchMode=yes "${BACKUP_SSH_USER}@${BACKUP_PIHOLE}" \
        "pihole reloaddns" &>/dev/null; then
        msg_ok "DNS reloaded on backup Pi-hole"
    else
        msg_warn "DNS reload returned non-zero — may need manual restart"
        echo -e "${TAB}  Run: ${BL}ssh ${BACKUP_SSH_USER}@${BACKUP_PIHOLE} 'pihole reloaddns'${CL}"
    fi
}

cleanup_remote() {
    # Clean up temp file on backup
    ssh -p "${BACKUP_SSH_PORT}" -o BatchMode=yes "${BACKUP_SSH_USER}@${BACKUP_PIHOLE}" \
        "rm -f /tmp/${BACKUP_NAME}" &>/dev/null || true
}

prune_backups() {
    local COUNT
    COUNT=$(ls -1 "${LOCAL_BACKUP_DIR}"/pi-hole_*teleporter*.zip 2>/dev/null | wc -l)

    if [[ "$COUNT" -gt "$RETENTION_COUNT" ]]; then
        local TO_DELETE=$((COUNT - RETENTION_COUNT))
        msg_info "Pruning old backups (keeping ${RETENTION_COUNT})"
        ls -1t "${LOCAL_BACKUP_DIR}"/pi-hole_*teleporter*.zip | tail -n "$TO_DELETE" | xargs rm -f
        msg_ok "Pruned ${TO_DELETE} old backup(s)"
    else
        msg_ok "Backups within retention limit (${COUNT}/${RETENTION_COUNT})"
    fi
}

list_backups() {
    header_info
    echo -e "${TAB}${BL}Stored Teleporter Backups${CL}"
    echo -e "${TAB}${BL}Directory: ${LOCAL_BACKUP_DIR}${CL}"
    echo ""

    if [[ ! -d "${LOCAL_BACKUP_DIR}" ]] || [[ -z "$(ls "${LOCAL_BACKUP_DIR}"/pi-hole_*teleporter*.zip 2>/dev/null)" ]]; then
        msg_warn "No backups found"
        echo ""
        exit 0
    fi

    local COUNT=0
    while IFS= read -r file; do
        COUNT=$((COUNT + 1))
        local fname fsize fdate
        fname=$(basename "$file")
        fsize=$(du -h "$file" | awk '{print $1}')
        fdate=$(stat -c '%y' "$file" | cut -d. -f1)
        echo -e "${TAB}  ${GN}${COUNT})${CL} ${fname}"
        echo -e "${TAB}     ${YW}${fsize}${CL} — ${fdate}"
    done < <(ls -1t "${LOCAL_BACKUP_DIR}"/pi-hole_*teleporter*.zip)

    echo ""
    echo -e "${TAB}Total: ${BD}${COUNT}${CL} backup(s), retention: ${BD}${RETENTION_COUNT}${CL}"
    echo ""
    exit 0
}

# ============================================================
# MAIN
# ============================================================

# Early exit for help, version, list
for arg in "${@:-}"; do
    case "${arg:-}" in
        --help|-h) show_help ;;
        --version|-V)
            echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"
            echo "${SCRIPT_URL}"
            exit 0
            ;;
        --list) list_backups ;;
    esac
done

header_info

# Root check
if [[ $EUID -ne 0 ]]; then
    msg_error "This script must be run as root (use sudo)"
    exit 1
fi

# Parse flags
AUTO_YES=false
BACKUP_ONLY=false

for arg in "${@:-}"; do
    case "${arg:-}" in
        --yes|-y) AUTO_YES=true ;;
        --backup-only) BACKUP_ONLY=true ;;
    esac
done

# Preflight
preflight_checks

# Show what we're about to do
PRIMARY_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo -e "${TAB}${BL}Sync Plan:${CL}"
echo -e "${TAB}  Primary:  ${GN}${PRIMARY_IP}${CL} (this machine)"
if [[ "$BACKUP_ONLY" == true ]]; then
    echo -e "${TAB}  Mode:     ${YW}Backup only (no sync)${CL}"
else
    echo -e "${TAB}  Backup:   ${GN}${BACKUP_PIHOLE}${CL}"
    echo -e "${TAB}  Mode:     ${GN}Full sync${CL}"
fi
echo ""

# Confirm
if [[ "$AUTO_YES" == false ]]; then
    if [[ "$BACKUP_ONLY" == true ]]; then
        read -rp "  Create Teleporter backup? [y/N]: " confirm
    else
        read -rp "  Sync primary → backup? This overwrites the backup's config. [y/N]: " confirm
    fi
    if [[ "${confirm,,}" != "y" ]]; then
        echo ""
        msg_ok "Exiting. No changes made."
        echo ""
        exit 0
    fi
    echo ""
fi

echo -e "${TAB}${BL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
echo ""

# Create backup
BACKUP_FILE=""
BACKUP_NAME=""
create_backup

if [[ "$BACKUP_ONLY" == true ]]; then
    echo ""
    prune_backups
    echo ""
    echo -e "${TAB}${BL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
    echo ""
    echo -e "${TAB}${GN}✓ Backup complete!${CL}"
    echo -e "${TAB}  File: ${GN}${LOCAL_BACKUP_DIR}/${BACKUP_NAME}${CL}"
    echo ""
    cleanup
    exit 0
fi

# Transfer
transfer_backup

# Import
import_backup

# Reload DNS
reload_backup_dns

# Cleanup remote temp file
cleanup_remote

# Prune old local backups
echo ""
prune_backups

# Summary
echo ""
echo -e "${TAB}${BL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
echo ""
echo -e "${TAB}${GN}✓ Sync complete!${CL}"
echo ""
echo -e "${TAB}  Primary:    ${GN}${PRIMARY_IP}${CL}"
echo -e "${TAB}  Backup:     ${GN}${BACKUP_PIHOLE}${CL}"
echo -e "${TAB}  Archive:    ${GN}${BACKUP_NAME}${CL}"
echo ""
echo -e "${TAB}${BL}Pi-hole Dashboards:${CL}"
echo -e "${TAB}  Primary:  ${GN}http://${PRIMARY_IP}/admin${CL}"
echo -e "${TAB}  Backup:   ${GN}http://${BACKUP_PIHOLE}/admin${CL}"
echo ""

cleanup
