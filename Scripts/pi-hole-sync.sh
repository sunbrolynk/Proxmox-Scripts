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
BACKUP_PIHOLES="192.168.1.2"          # Backup Pi-hole IP(s), space-separated for multiple
                                      # Example: "192.168.1.2 192.168.1.3 192.168.1.4"
BACKUP_SSH_USER="root"                # SSH user on the backup Pi-hole(s)
BACKUP_SSH_PORT="22"                  # SSH port on the backup Pi-hole(s)
LOCAL_BACKUP_DIR="/var/backups/pihole" # Where to store Teleporter archives locally
RETENTION_COUNT=7                     # Number of local backups to keep
GOTIFY_URL=""                         # Gotify server URL (e.g. http://10.10.3.6:80)
GOTIFY_TOKEN=""                       # Gotify application token
GOTIFY_PRIORITY=5                     # Gotify notification priority (1-10)
# ============================================================

set -euo pipefail
shopt -s inherit_errexit nullglob

# Script metadata
SCRIPT_NAME="pihole-sync"
SCRIPT_VERSION="1.2.1"
SCRIPT_URL="https://github.com/SunBroLynk/Proxmox-Scripts"
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_INSTALL_DEST="/usr/local/bin/${SCRIPT_NAME}"   # canonical path cron runs

# State (scheduling / sealed credentials / persisted settings)
STATE_DIR="/etc/${SCRIPT_NAME}"
SECRETS_DIR="${STATE_DIR}/secrets"
SETTINGS_FILE="${STATE_DIR}/config.env"
SECRET_PREFIX="${SCRIPT_NAME}"
INSTALL_NUDGE_DISMISSED=""

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
    echo -e "${TAB}${GN}--skip-settings${CL}"
    echo -e "${TAB}${TAB}Sync blocklists and DNS but preserve each backup's"
    echo -e "${TAB}${TAB}unique settings (passwords, network config, etc.)."
    echo ""
    echo -e "${TAB}${GN}--diff${CL}"
    echo -e "${TAB}${TAB}Show what differs between primary and backup(s)"
    echo -e "${TAB}${TAB}without syncing. Compares adlists, domains, clients."
    echo ""
    echo -e "${TAB}${GN}--restore [file]${CL}"
    echo -e "${TAB}${TAB}Restore a Teleporter backup to the primary Pi-hole."
    echo -e "${TAB}${TAB}If no file specified, shows a list to choose from."
    echo ""
    echo -e "${TAB}${GN}--list${CL}"
    echo -e "${TAB}${TAB}List local Teleporter backups."
    echo ""
    echo -e "${TAB}${GN}--setup${CL}"
    echo -e "${TAB}${TAB}Guided setup wizard — walks every setting, seals the Gotify token,"
    echo -e "${TAB}${TAB}saves your answers, and optionally sets a schedule. Re-runnable."
    echo ""
    echo -e "${TAB}${GN}--set-cred ${BL}<name>${CL}"
    echo -e "${TAB}${TAB}Seal a secret (e.g. gotify-token) read from stdin via systemd-creds."
    echo ""
    echo -e "${TAB}${GN}--test-notify${CL}"
    echo -e "${TAB}${TAB}Send a test notification to Gotify."
    echo ""
    echo -e "${TAB}${GN}--schedule${CL}"
    echo -e "${TAB}${TAB}Set up, change, or remove the cron schedule."
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
    echo -e "${TAB}• Pi-hole v6+ on primary and all backups"
    echo -e "${TAB}• SSH key-based auth from primary to each backup"
    echo -e "${TAB}  Set up with: ${BL}ssh-copy-id ${BACKUP_SSH_USER}@<backup-ip>${CL}"
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
# SEALED CREDENTIALS + SETTINGS + DEPS (shared conventions)
# ============================================================
have_systemd_creds() { command -v systemd-creds &>/dev/null; }

secret_set() {
    local name="$1" value; value="$(cat)"
    mkdir -p "$SECRETS_DIR"; chmod 700 "$SECRETS_DIR"
    if have_systemd_creds; then
        if printf '%s' "$value" | systemd-creds encrypt --name="${SECRET_PREFIX}-${name}" - "${SECRETS_DIR}/${name}.cred" 2>/dev/null; then
            chmod 600 "${SECRETS_DIR}/${name}.cred"; rm -f "${SECRETS_DIR}/${name}.secret" 2>/dev/null || true
            echo "systemd-creds"; return 0
        fi
    fi
    printf '%s' "$value" > "${SECRETS_DIR}/${name}.secret"; chmod 600 "${SECRETS_DIR}/${name}.secret"
    rm -f "${SECRETS_DIR}/${name}.cred" 2>/dev/null || true; echo "file-600"; return 0
}
secret_get() {
    local name="$1"
    if [[ -f "${SECRETS_DIR}/${name}.cred" ]] && have_systemd_creds; then
        systemd-creds decrypt --name="${SECRET_PREFIX}-${name}" "${SECRETS_DIR}/${name}.cred" - 2>/dev/null && return 0
    fi
    [[ -f "${SECRETS_DIR}/${name}.secret" ]] && { cat "${SECRETS_DIR}/${name}.secret"; return 0; }
    return 1
}
secret_exists() { [[ -f "${SECRETS_DIR}/$1.cred" || -f "${SECRETS_DIR}/$1.secret" ]]; }
resolve_gotify_token() { if secret_exists gotify-token; then secret_get gotify-token; else printf '%s' "$GOTIFY_TOKEN"; fi; }

load_settings() {
    [[ -f "$SETTINGS_FILE" ]] || return 0
    local line key val
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        key="${line%%=*}"; val="${line#*=}"; val="${val%\"}"; val="${val#\"}"
        case "$key" in
            BACKUP_PIHOLES) BACKUP_PIHOLES="$val" ;;
            BACKUP_SSH_USER) BACKUP_SSH_USER="$val" ;;
            BACKUP_SSH_PORT) BACKUP_SSH_PORT="$val" ;;
            LOCAL_BACKUP_DIR) LOCAL_BACKUP_DIR="$val" ;;
            RETENTION_COUNT) RETENTION_COUNT="$val" ;;
            GOTIFY_URL) GOTIFY_URL="$val" ;;
            GOTIFY_PRIORITY) GOTIFY_PRIORITY="$val" ;;
            INSTALL_NUDGE_DISMISSED) INSTALL_NUDGE_DISMISSED="$val" ;;
        esac
    done < "$SETTINGS_FILE"
}
settings_set() {
    local key="$1" val="$2" tmp
    mkdir -p "$(dirname "$SETTINGS_FILE")"; chmod 700 "$(dirname "$SETTINGS_FILE")"
    touch "$SETTINGS_FILE"; chmod 600 "$SETTINGS_FILE"
    tmp=$(mktemp /tmp/.cfg-set-XXXXXX)
    grep -v "^${key}=" "$SETTINGS_FILE" > "$tmp" 2>/dev/null || true
    echo "${key}=\"${val}\"" >> "$tmp"; cat "$tmp" > "$SETTINGS_FILE"; chmod 600 "$SETTINGS_FILE"; rm -f "$tmp"
}

require_dep() {
    local cmd="$1" pkg="$2" label="${3:-$2}"
    command -v "$cmd" &>/dev/null && { msg_ok "${label} present"; return 0; }
    if [[ "${INTERACTIVE:-true}" == true ]]; then
        msg_warn "${label} not installed (package: ${pkg})"
        read -rp "  Install ${pkg} now? [Y/n]: " a
        if [[ ! "$a" =~ ^[Nn]$ ]]; then
            apt-get update -qq >/dev/null 2>&1 && apt-get install -y "$pkg" >/dev/null 2>&1 \
                && { msg_ok "${pkg} installed"; return 0; }
            msg_error "Install failed — apt-get install -y ${pkg}"; return 1
        fi
        return 1
    fi
    msg_error "${label} missing — install it: apt-get install -y ${pkg}"; return 1
}

gotify_configured() {
    [[ -n "$GOTIFY_URL" ]] || return 1
    secret_exists gotify-token && return 0
    [[ -n "$GOTIFY_TOKEN" ]]
}

# Token goes in a chmod-600 curl config header — NEVER in the URL (avoids argv/ps leak).
send_gotify() {
    local title="$1" message="$2" priority="${3:-$GOTIFY_PRIORITY}"
    gotify_configured || return 0
    local token curl_conf json_message
    token="$(resolve_gotify_token)"; [[ -z "$token" ]] && return 0
    json_message=$(printf '%s' "$message" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null || printf '"%s"' "$message")
    curl_conf=$(mktemp /tmp/.gotify-XXXXXX); chmod 600 "$curl_conf"
    printf 'header = "X-Gotify-Key: %s"\nheader = "Content-Type: application/json"\n' "$token" > "$curl_conf"
    curl -s -K "$curl_conf" -X POST "${GOTIFY_URL}/message" \
        -d "{\"title\":\"${title}\",\"message\":${json_message},\"priority\":${priority},\"extras\":{\"client::display\":{\"contentType\":\"text/markdown\"}}}" &>/dev/null || true
    rm -f "$curl_conf"
}

test_gotify() {
    header_info
    echo -e "${TAB}${BD}Gotify Notification Test${CL}"
    echo ""
    [[ -z "$GOTIFY_URL" ]] && { msg_error "GOTIFY_URL not configured"; echo -e "${TAB}  Set GOTIFY_URL, then seal the token: ${BL}${SCRIPT_NAME} --set-cred gotify-token${CL}"; echo ""; exit 1; }
    require_dep curl curl "curl" || { echo ""; exit 1; }
    local token; token="$(resolve_gotify_token)"
    [[ -z "$token" ]] && { msg_error "No Gotify token — seal one: ${BL}${SCRIPT_NAME} --set-cred gotify-token${CL}"; echo ""; exit 1; }

    local test_message="### ✅ Connection Successful

**Script:** \`${SCRIPT_NAME}\`
**Host:** \`$(hostname)\`
**Time:** $(date '+%Y-%m-%d %H:%M:%S')

*Pi-hole Sync is configured and ready to send alerts.*"

    msg_info "Sending test notification to ${GOTIFY_URL}"
    local curl_conf json_message response
    curl_conf=$(mktemp /tmp/.gotify-XXXXXX); chmod 600 "$curl_conf"
    printf 'header = "X-Gotify-Key: %s"\nheader = "Content-Type: application/json"\n' "$token" > "$curl_conf"
    json_message=$(printf '%s' "$test_message" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null)
    response=$(curl -s -o /dev/null -w "%{http_code}" -K "$curl_conf" -X POST "${GOTIFY_URL}/message" \
        -d "{\"title\":\"🔄 Pi-hole Sync — Test\",\"message\":${json_message},\"priority\":${GOTIFY_PRIORITY},\"extras\":{\"client::display\":{\"contentType\":\"text/markdown\"}}}" 2>/dev/null)
    rm -f "$curl_conf"
    [[ "$response" == "200" ]] && msg_ok "Test notification sent successfully" || msg_error "Notification failed (HTTP ${response})"
    echo ""
    exit 0
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

    # SSH to backup(s)
    for TARGET in ${BACKUP_PIHOLES}; do
        msg_info "Testing SSH to backup (${TARGET})"
        if ssh -p "${BACKUP_SSH_PORT}" -o ConnectTimeout=5 -o BatchMode=yes "${BACKUP_SSH_USER}@${TARGET}" "echo ok" &>/dev/null; then
            msg_ok "SSH to backup (${TARGET}) connected"
        else
            msg_error "Cannot SSH to ${BACKUP_SSH_USER}@${TARGET}:${BACKUP_SSH_PORT}"
            echo -e "${TAB}  Set up key auth: ${BL}ssh-copy-id ${BACKUP_SSH_USER}@${TARGET}${CL}"
            CRITICAL=true
        fi

        # pihole-FTL on backup
        if [[ "$CRITICAL" == false ]]; then
            msg_info "Checking pihole-FTL on ${TARGET}"
            if ssh -p "${BACKUP_SSH_PORT}" -o BatchMode=yes "${BACKUP_SSH_USER}@${TARGET}" "command -v pihole-FTL" &>/dev/null; then
                msg_ok "pihole-FTL found on ${TARGET}"
            else
                msg_error "pihole-FTL not found on ${TARGET}"
                CRITICAL=true
            fi
        fi
    done

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
    local TARGET="$1"
    msg_info "Transferring backup to ${TARGET}"

    if ! scp -P "${BACKUP_SSH_PORT}" -o BatchMode=yes "$BACKUP_FILE" "${BACKUP_SSH_USER}@${TARGET}:/tmp/${BACKUP_NAME}" &>/dev/null; then
        msg_error "Transfer failed to ${TARGET}"
        echo -e "${TAB}  Check SSH connection: ${BL}ssh ${BACKUP_SSH_USER}@${TARGET}${CL}"
        return 1
    fi

    msg_ok "Transferred to ${TARGET}:/tmp/${BACKUP_NAME}"
}

import_backup() {
    local TARGET="$1"
    local IMPORT_FILE="${BACKUP_NAME}"

    # If --skip-settings, strip pihole.toml from the archive
    if [[ "$SKIP_SETTINGS" == true ]]; then
        msg_info "Preparing archive (skipping settings)"
        local STRIPPED_NAME="stripped_${BACKUP_NAME}"
        ssh -p "${BACKUP_SSH_PORT}" -o BatchMode=yes "${BACKUP_SSH_USER}@${TARGET}" \
            "cd /tmp && cp '${BACKUP_NAME}' '${STRIPPED_NAME}' && zip -d '${STRIPPED_NAME}' 'etc/pihole/pihole.toml' 2>/dev/null; true" &>/dev/null
        IMPORT_FILE="${STRIPPED_NAME}"
        msg_ok "Settings excluded from import"
    fi

    msg_info "Importing configuration on ${TARGET}"

    local IMPORT_OUTPUT
    IMPORT_OUTPUT=$(ssh -p "${BACKUP_SSH_PORT}" -o BatchMode=yes "${BACKUP_SSH_USER}@${TARGET}" \
        "pihole-FTL --teleporter /tmp/${IMPORT_FILE} 2>&1")

    if [[ $? -ne 0 ]]; then
        msg_error "Import failed on ${TARGET}"
        echo -e "${TAB}  Output: ${IMPORT_OUTPUT}"
        return 1
    fi

    # Count imported items
    local IMPORT_COUNT
    IMPORT_COUNT=$(echo "$IMPORT_OUTPUT" | grep -c "^Imported" || echo "0")

    msg_ok "Imported ${IMPORT_COUNT} items on ${TARGET}"
}

reload_backup_dns() {
    local TARGET="$1"
    msg_info "Reloading DNS on ${TARGET}"

    if ssh -p "${BACKUP_SSH_PORT}" -o BatchMode=yes "${BACKUP_SSH_USER}@${TARGET}" \
        "pihole reloaddns" &>/dev/null; then
        msg_ok "DNS reloaded on ${TARGET}"
    else
        msg_warn "DNS reload returned non-zero on ${TARGET}"
        echo -e "${TAB}  Run: ${BL}ssh ${BACKUP_SSH_USER}@${TARGET} 'pihole reloaddns'${CL}"
    fi
}

update_gravity() {
    local TARGET="$1"
    msg_info "Updating gravity on ${TARGET} (this may take a moment)"

    if ssh -p "${BACKUP_SSH_PORT}" -o BatchMode=yes "${BACKUP_SSH_USER}@${TARGET}" \
        "pihole -g" &>/dev/null; then
        msg_ok "Gravity updated on ${TARGET}"
    else
        msg_warn "Gravity update returned non-zero on ${TARGET}"
        echo -e "${TAB}  Run manually: ${BL}ssh ${BACKUP_SSH_USER}@${TARGET} 'pihole -g'${CL}"
    fi
}

cleanup_remote() {
    local TARGET="$1"
    ssh -p "${BACKUP_SSH_PORT}" -o BatchMode=yes "${BACKUP_SSH_USER}@${TARGET}" \
        "rm -f /tmp/${BACKUP_NAME} /tmp/stripped_${BACKUP_NAME}" &>/dev/null || true
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

restore_backup() {
    local RESTORE_FILE="${1:-}"

    header_info
    echo -e "${TAB}${BD}Restore Teleporter Backup to Primary${CL}"
    echo ""

    # If no file specified, show list and prompt
    if [[ -z "$RESTORE_FILE" ]]; then
        if [[ ! -d "${LOCAL_BACKUP_DIR}" ]] || [[ -z "$(ls "${LOCAL_BACKUP_DIR}"/pi-hole_*teleporter*.zip 2>/dev/null)" ]]; then
            msg_error "No backups found in ${LOCAL_BACKUP_DIR}"
            exit 1
        fi

        echo -e "${TAB}${BL}Available backups:${CL}"
        echo ""
        local FILES=()
        local COUNT=0
        while IFS= read -r file; do
            COUNT=$((COUNT + 1))
            FILES+=("$file")
            local fname fsize fdate
            fname=$(basename "$file")
            fsize=$(du -h "$file" | awk '{print $1}')
            fdate=$(stat -c '%y' "$file" | cut -d. -f1)
            echo -e "${TAB}  ${GN}${COUNT})${CL} ${fname}"
            echo -e "${TAB}     ${YW}${fsize}${CL} — ${fdate}"
        done < <(ls -1t "${LOCAL_BACKUP_DIR}"/pi-hole_*teleporter*.zip)

        echo ""
        read -rp "  Select backup to restore [1-${COUNT}/q]: " selection
        if [[ "${selection,,}" == "q" ]]; then
            echo ""
            msg_ok "Exiting. No changes made."
            echo ""
            exit 0
        fi
        if ! [[ "$selection" =~ ^[0-9]+$ ]] || [[ "$selection" -lt 1 ]] || [[ "$selection" -gt "$COUNT" ]]; then
            msg_error "Invalid selection"
            exit 1
        fi
        RESTORE_FILE="${FILES[$((selection - 1))]}"
    fi

    # Validate file exists
    if [[ ! -f "$RESTORE_FILE" ]]; then
        msg_error "File not found: ${RESTORE_FILE}"
        exit 1
    fi

    local RESTORE_NAME
    RESTORE_NAME=$(basename "$RESTORE_FILE")
    echo -e "${TAB}  Restoring: ${GN}${RESTORE_NAME}${CL}"
    echo ""
    read -rp "  This will overwrite the primary Pi-hole's config. Continue? [y/N]: " confirm
    if [[ "${confirm,,}" != "y" ]]; then
        echo ""
        msg_ok "Exiting. No changes made."
        echo ""
        exit 0
    fi
    echo ""

    # Import
    msg_info "Importing backup on primary"
    local IMPORT_OUTPUT
    IMPORT_OUTPUT=$(pihole-FTL --teleporter "$RESTORE_FILE" 2>&1)
    if [[ $? -ne 0 ]]; then
        msg_error "Import failed"
        echo -e "${TAB}  Output: ${IMPORT_OUTPUT}"
        exit 1
    fi
    local IMPORT_COUNT
    IMPORT_COUNT=$(echo "$IMPORT_OUTPUT" | grep -c "^Imported" || echo "0")
    msg_ok "Imported ${IMPORT_COUNT} items"

    # Reload DNS
    msg_info "Reloading DNS"
    pihole reloaddns &>/dev/null
    msg_ok "DNS reloaded"

    # Update gravity
    msg_info "Updating gravity (this may take a moment)"
    pihole -g &>/dev/null && msg_ok "Gravity updated" || msg_warn "Gravity update returned non-zero"

    echo ""
    msg_ok "Restore complete!"
    echo ""
    exit 0
}

show_diff() {
    header_info
    echo -e "${TAB}${BL}Configuration Diff: Primary vs Backup(s)${CL}"
    echo ""

    # Query primary counts
    local P_ADLISTS P_DOMAINS P_CLIENTS P_GROUPS
    P_ADLISTS=$(sqlite3 /etc/pihole/gravity.db "SELECT COUNT(*) FROM adlist" 2>/dev/null || echo "?")
    P_DOMAINS=$(sqlite3 /etc/pihole/gravity.db "SELECT COUNT(*) FROM domainlist" 2>/dev/null || echo "?")
    P_CLIENTS=$(sqlite3 /etc/pihole/gravity.db "SELECT COUNT(*) FROM client" 2>/dev/null || echo "?")
    P_GROUPS=$(sqlite3 /etc/pihole/gravity.db "SELECT COUNT(*) FROM 'group'" 2>/dev/null || echo "?")

    PRIMARY_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo -e "${TAB}${BD}Primary (${PRIMARY_IP}):${CL}"
    echo -e "${TAB}  Adlists:    ${GN}${P_ADLISTS}${CL}"
    echo -e "${TAB}  Domains:    ${GN}${P_DOMAINS}${CL}"
    echo -e "${TAB}  Clients:    ${GN}${P_CLIENTS}${CL}"
    echo -e "${TAB}  Groups:     ${GN}${P_GROUPS}${CL}"
    echo ""

    for TARGET in ${BACKUP_PIHOLES}; do
        # Query backup counts via SSH
        local B_ADLISTS B_DOMAINS B_CLIENTS B_GROUPS
        B_ADLISTS=$(ssh -p "${BACKUP_SSH_PORT}" -o BatchMode=yes -o ConnectTimeout=5 "${BACKUP_SSH_USER}@${TARGET}" \
            "sqlite3 /etc/pihole/gravity.db 'SELECT COUNT(*) FROM adlist'" 2>/dev/null || echo "?")
        B_DOMAINS=$(ssh -p "${BACKUP_SSH_PORT}" -o BatchMode=yes "${BACKUP_SSH_USER}@${TARGET}" \
            "sqlite3 /etc/pihole/gravity.db 'SELECT COUNT(*) FROM domainlist'" 2>/dev/null || echo "?")
        B_CLIENTS=$(ssh -p "${BACKUP_SSH_PORT}" -o BatchMode=yes "${BACKUP_SSH_USER}@${TARGET}" \
            "sqlite3 /etc/pihole/gravity.db 'SELECT COUNT(*) FROM client'" 2>/dev/null || echo "?")
        B_GROUPS=$(ssh -p "${BACKUP_SSH_PORT}" -o BatchMode=yes "${BACKUP_SSH_USER}@${TARGET}" \
            "sqlite3 /etc/pihole/gravity.db \"SELECT COUNT(*) FROM 'group'\"" 2>/dev/null || echo "?")

        echo -e "${TAB}${BD}Backup (${TARGET}):${CL}"

        # Compare and colorize
        for label_var in "Adlists:P_ADLISTS:B_ADLISTS" "Domains:P_DOMAINS:B_DOMAINS" "Clients:P_CLIENTS:B_CLIENTS" "Groups:P_GROUPS:B_GROUPS"; do
            IFS=: read -r label pvar bvar <<< "$label_var"
            local pval="${!pvar}"
            local bval="${!bvar}"
            if [[ "$pval" == "$bval" ]]; then
                echo -e "${TAB}  ${label}$(printf '%*s' $((12 - ${#label})) '')${GN}${bval} (in sync)${CL}"
            else
                echo -e "${TAB}  ${label}$(printf '%*s' $((12 - ${#label})) '')${RD}${bval}${CL} (primary: ${GN}${pval}${CL})"
            fi
        done
        echo ""
    done

    exit 0
}

installed_ok() { [[ -f "$SCRIPT_INSTALL_DEST" && -x "$SCRIPT_INSTALL_DEST" ]]; }
install_self() {
    if [[ "$SCRIPT_PATH" == "$SCRIPT_INSTALL_DEST" ]]; then
        chmod 755 "$SCRIPT_INSTALL_DEST" 2>/dev/null || true
        msg_ok "Already at ${SCRIPT_INSTALL_DEST} (ensured executable)"; return 0
    fi
    if cp "$SCRIPT_PATH" "$SCRIPT_INSTALL_DEST" 2>/dev/null && chmod 755 "$SCRIPT_INSTALL_DEST"; then
        msg_ok "Installed to ${SCRIPT_INSTALL_DEST} (chmod 755)"; return 0
    fi
    msg_warn "Could not install to ${SCRIPT_INSTALL_DEST}"; return 1
}
require_installed_for_schedule() {
    installed_ok && return 0
    echo ""
    msg_warn "Scheduling needs the script at ${SCRIPT_INSTALL_DEST} — cron runs that exact path."
    read -rp "  Install it there now? [Y/n]: " a
    if [[ ! "$a" =~ ^[Nn]$ ]]; then
        install_self && { settings_set INSTALL_NUDGE_DISMISSED ""; INSTALL_NUDGE_DISMISSED=""; return 0; }
        return 1
    fi
    msg_warn "Cannot schedule without installing first."; return 1
}
do_set_cred() {
    local name="$1"
    [[ -z "$name" ]] && { header_info; msg_error "--set-cred requires a name (e.g. gotify-token)"; exit 1; }
    local method
    if [[ -t 0 ]]; then read -rsp "Enter value for '${name}': " _v; echo "" >&2; method=$(printf '%s' "$_v" | secret_set "$name")
    else method=$(secret_set "$name"); fi
    echo "Sealed '${name}' via ${method}" >&2; exit 0
}

is_first_run() { [[ ! -f "$SETTINGS_FILE" ]]; }

# Guided setup wizard — walks every setting, seals the token, persists the rest.
# Settings file becomes the source of truth (config-block vars are fallback defaults).
run_setup() {
    header_info
    echo -e "${TAB}${BD}Guided Setup${CL}"
    echo -e "${TAB}Answer each prompt. Press Enter to keep the ${BL}[current]${CL} value."
    echo ""

    # --- Backup Pi-hole targets ---
    echo -e "${TAB}${BD}1) Backup Pi-hole(s)${CL}"
    read -rp "  Backup Pi-hole IP(s), space-separated [${BACKUP_PIHOLES}]: " _v
    [[ -n "$_v" ]] && { BACKUP_PIHOLES="$_v"; settings_set BACKUP_PIHOLES "$_v"; }
    read -rp "  SSH user on the backup(s) [${BACKUP_SSH_USER}]: " _v
    [[ -n "$_v" ]] && { BACKUP_SSH_USER="$_v"; settings_set BACKUP_SSH_USER "$_v"; }
    read -rp "  SSH port [${BACKUP_SSH_PORT}]: " _v
    [[ -n "$_v" ]] && { BACKUP_SSH_PORT="$_v"; settings_set BACKUP_SSH_PORT "$_v"; }
    echo ""

    # --- Local backups ---
    echo -e "${TAB}${BD}2) Local backups${CL}"
    read -rp "  Local archive directory [${LOCAL_BACKUP_DIR}]: " _v
    [[ -n "$_v" ]] && { LOCAL_BACKUP_DIR="$_v"; settings_set LOCAL_BACKUP_DIR "$_v"; }
    read -rp "  How many local backups to keep [${RETENTION_COUNT}]: " _v
    [[ -n "$_v" ]] && { RETENTION_COUNT="$_v"; settings_set RETENTION_COUNT "$_v"; }
    echo ""

    # --- SSH key check ---
    echo -e "${TAB}${BD}3) SSH connectivity${CL}"
    local first_target; first_target="${BACKUP_PIHOLES%% *}"
    if [[ -n "$first_target" ]]; then
        msg_info "Testing SSH to ${first_target}"
        if ssh -p "${BACKUP_SSH_PORT}" -o ConnectTimeout=5 -o BatchMode=yes "${BACKUP_SSH_USER}@${first_target}" "echo ok" &>/dev/null; then
            msg_ok "SSH to ${first_target} works (key-based)"
        else
            msg_warn "Could not SSH to ${BACKUP_SSH_USER}@${first_target}:${BACKUP_SSH_PORT} with a key"
            echo -e "${TAB}  Set up key auth first: ${BL}ssh-copy-id -p ${BACKUP_SSH_PORT} ${BACKUP_SSH_USER}@${first_target}${CL}"
            echo -e "${TAB}  (You can finish setup now and fix this before the first sync.)"
        fi
    fi
    echo ""

    # --- Notifications (optional, secret sealed) ---
    echo -e "${TAB}${BD}4) Gotify notifications (optional)${CL}"
    read -rp "  Gotify server URL (blank to skip) [${GOTIFY_URL}]: " _v
    if [[ -n "$_v" ]]; then
        GOTIFY_URL="$_v"; settings_set GOTIFY_URL "$_v"
        echo -e "${TAB}  ${INFO} The token is sealed (encrypted), never written in plaintext."
        read -rsp "  Gotify application token: " _tok; echo ""
        if [[ -n "$_tok" ]]; then
            local m; m=$(printf '%s' "$_tok" | secret_set gotify-token)
            msg_ok "Token sealed via ${m}"
            require_dep curl curl "curl" || true
        fi
        read -rp "  Notification priority (1-10) [${GOTIFY_PRIORITY}]: " _v
        [[ -n "$_v" ]] && { GOTIFY_PRIORITY="$_v"; settings_set GOTIFY_PRIORITY "$_v"; }
    elif [[ -n "$GOTIFY_URL" ]]; then
        : # keep existing
    else
        msg_info "Skipping notifications"
    fi
    echo ""

    # --- Schedule (optional, gated on install) ---
    echo -e "${TAB}${BD}5) Automatic sync schedule (optional)${CL}"
    read -rp "  Set up a recurring schedule now? [y/N]: " _v
    if [[ "$_v" =~ ^[Yy]$ ]]; then
        manage_cron   # handles install-gate + frequency picker + verified write; exits after
    fi

    echo ""
    msg_ok "Setup complete. Settings saved to ${BL}${SETTINGS_FILE}${CL}"
    echo -e "${TAB}Re-run anytime with ${BL}${SCRIPT_NAME} --setup${CL} to change anything."
    echo ""
}

manage_cron() {
    header_info
    echo -e "${TAB}${BD}Schedule Manager${CL}"
    echo ""

    local CRON_CMD="${SCRIPT_INSTALL_DEST} -y >> ${LOCAL_BACKUP_DIR}/${SCRIPT_NAME}.log 2>&1"
    local CURRENT_CRON
    CURRENT_CRON=$(crontab -l 2>/dev/null | grep "${SCRIPT_NAME}" || true)

    if [[ -n "$CURRENT_CRON" ]]; then
        echo -e "${TAB}  ${GN}Current schedule:${CL}"
        echo -e "${TAB}  ${BL}${CURRENT_CRON}${CL}"
        echo ""
        echo -e "${TAB}  ${GN}1)${CL} Change schedule"
        echo -e "${TAB}  ${GN}2)${CL} Remove schedule"
        echo -e "${TAB}  ${RD}q)${CL} Back"
        echo ""
        read -rp "  Select [1-2/q]: " cron_choice
        case "$cron_choice" in
            1) ;; # fall through to schedule picker
            2)
                { crontab -l 2>/dev/null | grep -v "${SCRIPT_NAME}" || true; } | crontab -
                echo ""
                msg_ok "Schedule removed"
                echo ""
                exit 0
                ;;
            *)
                echo ""
                exit 0
                ;;
        esac
        echo ""
    else
        echo -e "${TAB}  ${YW}No schedule configured${CL}"
        echo ""
    fi

    echo -e "${TAB}  ${BD}How often should ${SCRIPT_NAME} run?${CL}"
    echo ""
    echo -e "${TAB}  ${GN}1)${CL} Every 5 minutes"
    echo -e "${TAB}  ${GN}2)${CL} Every 15 minutes"
    echo -e "${TAB}  ${GN}3)${CL} Every hour"
    echo -e "${TAB}  ${GN}4)${CL} Every 6 hours"
    echo -e "${TAB}  ${GN}5)${CL} Daily at 3:00 AM"
    echo -e "${TAB}  ${GN}6)${CL} Daily at custom time"
    echo -e "${TAB}  ${GN}7)${CL} Custom cron expression"
    echo -e "${TAB}  ${RD}q)${CL} Cancel"
    echo ""
    read -rp "  Select [1-7/q]: " schedule_choice

    local CRON_SCHEDULE=""
    case "$schedule_choice" in
        1) CRON_SCHEDULE="*/5 * * * *" ;;
        2) CRON_SCHEDULE="*/15 * * * *" ;;
        3) CRON_SCHEDULE="0 * * * *" ;;
        4) CRON_SCHEDULE="0 */6 * * *" ;;
        5) CRON_SCHEDULE="0 3 * * *" ;;
        6)
            read -rp "  Hour (0-23): " cron_hour
            read -rp "  Minute (0-59): " cron_min
            if ! [[ "$cron_hour" =~ ^[0-9]+$ ]] || [[ "$cron_hour" -gt 23 ]]; then
                msg_error "Invalid hour"
                exit 1
            fi
            if ! [[ "$cron_min" =~ ^[0-9]+$ ]] || [[ "$cron_min" -gt 59 ]]; then
                msg_error "Invalid minute"
                exit 1
            fi
            CRON_SCHEDULE="${cron_min} ${cron_hour} * * *"
            ;;
        7)
            read -rp "  Cron expression (e.g. */10 * * * *): " CRON_SCHEDULE
            if [[ -z "$CRON_SCHEDULE" ]]; then
                msg_error "No expression entered"
                exit 1
            fi
            ;;
        *)
            echo ""
            exit 0
            ;;
    esac

    # Gate on being installed at the canonical path (cron runs that exact path).
    require_installed_for_schedule || { echo ""; msg_warn "Not scheduled."; echo ""; exit 0; }

    # Remove existing entry and add new one. `|| true` keeps an empty grep result
    # from tripping pipefail/inherit_errexit and silently aborting the write.
    local NEW_CRON="${CRON_SCHEDULE} ${CRON_CMD}"
    { crontab -l 2>/dev/null | grep -v "${SCRIPT_NAME}" || true; echo "$NEW_CRON"; } | crontab -

    echo ""
    if crontab -l 2>/dev/null | grep -q "${SCRIPT_NAME}"; then
        msg_ok "Schedule set: ${GN}${CRON_SCHEDULE}${CL}"
        echo -e "${TAB}  ${BL}${NEW_CRON}${CL}"
    else
        msg_error "Schedule write failed — could not update crontab. Is cron installed and running?"
    fi
    echo ""
    exit 0
}

# ============================================================
# MAIN
# ============================================================

# Early exit for help, version, list, diff, restore
load_settings   # pull GOTIFY_URL etc. from SETTINGS_FILE if present
for arg in "${@:-}"; do
    case "${arg:-}" in
        --help|-h) show_help ;;
        --version|-V)
            echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"
            echo "${SCRIPT_URL}"
            exit 0
            ;;
    esac
done

header_info

# Root check
if [[ $EUID -ne 0 ]]; then
    msg_error "This script must be run as root (use sudo)"
    exit 1
fi

# Flags that need root, dispatched before the main run.
ARGS=("${@:-}")
i=0
while [[ $i -lt ${#ARGS[@]} ]]; do
    case "${ARGS[$i]:-}" in
        --set-cred) do_set_cred "${ARGS[$((i+1))]:-}" ;;
        --setup) header_info; run_setup; exit 0 ;;
        --test-notify) test_gotify ;;
        --schedule) manage_cron ;;
        --list) list_backups ;;
        --diff) show_diff ;;
        --restore)
            restore_file="${ARGS[$((i+1))]:-}"
            [[ "$restore_file" == --* ]] && restore_file=""
            restore_backup "$restore_file"
            ;;
    esac
    i=$((i+1))
done

# Parse flags
AUTO_YES=false
BACKUP_ONLY=false
SKIP_SETTINGS=false
INTERACTIVE=true

for arg in "${@:-}"; do
    case "${arg:-}" in
        --yes|-y) AUTO_YES=true; INTERACTIVE=false ;;
        --backup-only) BACKUP_ONLY=true; INTERACTIVE=false ;;
        --skip-settings) SKIP_SETTINGS=true; INTERACTIVE=false ;;
    esac
done

# Preflight
preflight_checks

# One-time install nudge (interactive only) so cron can run the canonical path.
# Runs AFTER preflight — validate the environment before prompting to install
# (matches the pve-config-backup reference flow).
if [[ "$INTERACTIVE" == true ]] && ! installed_ok && [[ "$INSTALL_NUDGE_DISMISSED" != "1" ]]; then
    echo -e "${TAB}${YW}Heads up: this script isn't installed at ${SCRIPT_INSTALL_DEST}.${CL}"
    echo -e "${TAB}Installing it there is what lets the cron / --schedule feature run unattended."
    echo ""
    read -rp "  Install it there now? [Y/n]: " _ans
    if [[ ! "$_ans" =~ ^[Nn]$ ]]; then install_self || true
    else msg_warn "Skipped — scheduling stays disabled until installed. I won't ask again."
         settings_set INSTALL_NUDGE_DISMISSED "1"; INSTALL_NUDGE_DISMISSED="1"; fi
    echo ""
fi

# First-run: auto-offer guided setup when nothing is configured yet.
if [[ "$INTERACTIVE" == true ]] && is_first_run; then
    echo -e "${TAB}${YW}Looks like a fresh setup — nothing is configured yet.${CL}"
    read -rp "  Run the guided setup now? [Y/n]: " _ans
    if [[ ! "$_ans" =~ ^[Nn]$ ]]; then run_setup; fi
    echo ""
fi

# Interactive menu
if [[ "$INTERACTIVE" == true ]]; then
    PRIMARY_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo -e "${TAB}${BL}Primary:${CL}  ${GN}${PRIMARY_IP}${CL} (this machine)"
    for TARGET in ${BACKUP_PIHOLES}; do
        echo -e "${TAB}${BL}Backup:${CL}   ${GN}${TARGET}${CL}"
    done
    echo ""
    echo -e "${TAB}${BL}What would you like to do?${CL}"
    echo ""
    echo -e "${TAB}  ${GN}1)${CL} Full sync (overwrite backup config entirely)"
    echo -e "${TAB}  ${GN}2)${CL} Sync but keep backup's settings (skip passwords/network)"
    echo -e "${TAB}  ${GN}3)${CL} Show diff (compare primary vs backup, no changes)"
    echo -e "${TAB}  ${GN}4)${CL} Backup only (local archive, no sync)"
    echo -e "${TAB}  ${GN}5)${CL} Restore a backup to primary"
    echo -e "${TAB}  ${GN}6)${CL} List stored backups"
    echo -e "${TAB}  ${GN}7)${CL} Test Gotify notification"
    echo -e "${TAB}  ${GN}8)${CL} Manage cron schedule"
    echo -e "${TAB}  ${GN}9)${CL} Guided setup (reconfigure everything)"
    echo -e "${TAB}  ${RD}q)${CL} Quit"
    echo ""
    read -rp "  Select an option [1-9/q]: " choice

    case "$choice" in
        1) ;;
        2) SKIP_SETTINGS=true ;;
        3) show_diff ;;
        4) BACKUP_ONLY=true ;;
        5) restore_backup ;;
        6) list_backups ;;
        7) test_gotify ;;
        8) manage_cron ;;
        9) run_setup; exit 0 ;;
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

# Show what we're about to do
PRIMARY_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
if [[ "$INTERACTIVE" == false ]]; then
    echo -e "${TAB}${BL}Sync Plan:${CL}"
    echo -e "${TAB}  Primary:  ${GN}${PRIMARY_IP}${CL} (this machine)"
    if [[ "$BACKUP_ONLY" == true ]]; then
        echo -e "${TAB}  Mode:     ${YW}Backup only (no sync)${CL}"
    else
        for TARGET in ${BACKUP_PIHOLES}; do
            echo -e "${TAB}  Backup:   ${GN}${TARGET}${CL}"
        done
        if [[ "$SKIP_SETTINGS" == true ]]; then
            echo -e "${TAB}  Mode:     ${GN}Sync (skip settings)${CL}"
        else
            echo -e "${TAB}  Mode:     ${GN}Full sync${CL}"
        fi
    fi
    echo ""
fi

# Confirm (skip if -y or interactive menu already chose)
if [[ "$AUTO_YES" == false ]] && [[ "$INTERACTIVE" == false ]]; then
    if [[ "$BACKUP_ONLY" == true ]]; then
        read -rp "  Create Teleporter backup? [y/N]: " confirm
    else
        read -rp "  Sync primary → backup(s)? This overwrites backup config. [y/N]: " confirm
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

# Sync to each backup target (parallel when multiple targets)
SYNC_SUCCESS=()
SYNC_FAILED=()

sync_single_target() {
    local TARGET="$1"
    transfer_backup "$TARGET" \
        && import_backup "$TARGET" \
        && reload_backup_dns "$TARGET" \
        && update_gravity "$TARGET" \
        && cleanup_remote "$TARGET"
}

TARGET_LIST=(${BACKUP_PIHOLES})
TARGET_COUNT=${#TARGET_LIST[@]}

if [[ "$TARGET_COUNT" -eq 1 ]]; then
    # Single target — run directly with live output
    echo -e "${TAB}${BL}▸ Syncing to ${TARGET_LIST[0]}${CL}"
    echo ""
    if sync_single_target "${TARGET_LIST[0]}"; then
        SYNC_SUCCESS+=("${TARGET_LIST[0]}")
    else
        SYNC_FAILED+=("${TARGET_LIST[0]}")
    fi
    echo ""
else
    # Multiple targets — run in parallel
    echo -e "${TAB}${BL}▸ Syncing to ${TARGET_COUNT} targets in parallel${CL}"
    echo ""

    PARALLEL_PIDS=()
    PARALLEL_RESULTS=$(mktemp -d /tmp/.pihole-sync-XXXXXX)

    for TARGET in "${TARGET_LIST[@]}"; do
        (
            if sync_single_target "$TARGET" &>/dev/null; then
                echo "0" > "${PARALLEL_RESULTS}/${TARGET}"
            else
                echo "1" > "${PARALLEL_RESULTS}/${TARGET}"
            fi
        ) &
        PARALLEL_PIDS+=($!)
    done

    # Wait for all targets
    for pid in "${PARALLEL_PIDS[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # Collect results
    for TARGET in "${TARGET_LIST[@]}"; do
        if [[ -f "${PARALLEL_RESULTS}/${TARGET}" ]] && [[ "$(cat "${PARALLEL_RESULTS}/${TARGET}")" == "0" ]]; then
            msg_ok "${TARGET} — synced"
            SYNC_SUCCESS+=("$TARGET")
        else
            msg_error "${TARGET} — failed"
            SYNC_FAILED+=("$TARGET")
        fi
    done

    rm -rf "$PARALLEL_RESULTS"
    echo ""
fi

# Prune old local backups
prune_backups

# Summary
echo ""
echo -e "${TAB}${BL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
echo ""
echo -e "${TAB}${GN}✓ Sync complete!${CL}"
echo ""
echo -e "${TAB}  Primary:    ${GN}${PRIMARY_IP}${CL}"
echo -e "${TAB}  Archive:    ${GN}${BACKUP_NAME}${CL}"
if [[ "$SKIP_SETTINGS" == true ]]; then
    echo -e "${TAB}  Mode:       ${GN}Skip settings${CL}"
fi
echo ""

if [[ ${#SYNC_SUCCESS[@]} -gt 0 ]]; then
    for TARGET in "${SYNC_SUCCESS[@]}"; do
        echo -e "${TAB}  ${CM} ${TARGET}"
    done
fi
if [[ ${#SYNC_FAILED[@]} -gt 0 ]]; then
    for TARGET in "${SYNC_FAILED[@]}"; do
        echo -e "${TAB}  ${CROSS} ${TARGET}"
    done
fi

echo ""
echo -e "${TAB}${BL}Pi-hole Dashboards:${CL}"
echo -e "${TAB}  Primary:  ${GN}http://${PRIMARY_IP}/admin${CL}"
for TARGET in ${BACKUP_PIHOLES}; do
    echo -e "${TAB}  Backup:   ${GN}http://${TARGET}/admin${CL}"
done
echo ""

# Send Gotify notification (only in automated/cron mode)
if [[ "$AUTO_YES" == true ]]; then
    success_list="" 
    fail_list=""
    for t in "${SYNC_SUCCESS[@]:-}"; do
        [[ -n "$t" ]] && success_list="${success_list}| \`${t}\` | 🟢 Synced |\n"
    done
    for t in "${SYNC_FAILED[@]:-}"; do
        [[ -n "$t" ]] && fail_list="${fail_list}| \`${t}\` | 🔴 **Failed** |\n"
    done

    if [[ ${#SYNC_FAILED[@]} -eq 0 ]]; then
        notify_message="### 🟢 Sync Successful

**Primary:** \`${PRIMARY_IP}\`
**Time:** $(date '+%Y-%m-%d %H:%M:%S')
**Archive:** \`${BACKUP_NAME}\`

| Target | Status |
|--------|--------|
${success_list}
*All backup Pi-holes are in sync.*"

        send_gotify "🔄 Pi-hole Sync — Success" "$notify_message"
    else
        notify_message="### 🔴 Sync Failed

**Primary:** \`${PRIMARY_IP}\`
**Time:** $(date '+%Y-%m-%d %H:%M:%S')

| Target | Status |
|--------|--------|
${success_list}${fail_list}
**⚠️ Check the log for details.**"

        send_gotify "🔄 Pi-hole Sync — Failed" "$notify_message" 8
    fi
fi

cleanup