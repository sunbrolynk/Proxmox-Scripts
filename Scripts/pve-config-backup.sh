#!/usr/bin/env bash

# PVE Config Backup — back up Proxmox VE host configuration
# https://github.com/SunBroLynk/Proxmox-Scripts
# License: MIT
#
# Proxmox Backup Server and vzdump protect your guests (VMs/CTs) — but NOT the
# host itself. If a node's system disk dies, the guest backups don't bring back
# /etc/pve, your network config, storage definitions, cluster membership, users,
# or apt sources. This script captures all of that into a single dated, secured
# archive so a dead node can be rebuilt instead of reverse-engineered.
#
# Targets a Proxmox VE HOST (run on the node, as root). It backs up configuration
# only — no guest disk images — so it is safe to run live on a busy node.
#
# Offsite export: archives can be copied to one or more remote targets over
# SCP/SFTP (key-based, via REMOTE_TARGETS below) or, via the interactive target
# manager (--targets), to NFS shares and FTP/FTPS servers. Each target you add is
# verified by writing, reading back, and deleting a test file before it's saved.

# ============================================================
# CONFIGURATION — adjust these for your setup
# ============================================================
BACKUP_DEST="/var/backups/pve-config"   # Local directory to store archives
RETENTION_DAYS=30                       # Delete our own archives older than N days (0 = keep all)
REMOTE_TARGETS=""                       # Simple key-based SCP/SFTP targets, space-separated.
                                        #   No secrets — safe to keep here.
                                        #   e.g. "root@192.168.1.10:/mnt/backup root@192.168.1.11:/mnt/backup"
TARGETS_FILE="/etc/pve-config-backup/targets.conf"  # Managed (chmod 600) store for NFS/FTP targets.
                                        #   Add via --targets. Script runs fine if it doesn't exist.
SETTINGS_FILE="/etc/pve-config-backup/config.env"   # Optional managed settings written by --setup
                                        #   (e.g. GOTIFY_URL). Whitelisted keys only; never sourced.
SECRETS_DIR="/etc/pve-config-backup/secrets"        # Sealed credentials (systemd-creds, TPM-bound
                                        #   when available; chmod-600 file fallback otherwise).
INCLUDE_SHADOW=true                     # Include /etc/shadow + /etc/gshadow (password hashes)
INCLUDE_SSH_HOST_KEYS=true              # Include /etc/ssh (host keys + sshd_config)
EXTRA_PATHS=""                          # Space-separated extra files/dirs to include
                                        #   e.g. "/root/scripts /etc/systemd/system/myunit.service"
# --- Gotify (optional — leave blank to disable notifications) ---
GOTIFY_URL=""                           # Gotify server URL (e.g. http://10.0.0.5:80)
GOTIFY_TOKEN=""                         # Gotify application token
GOTIFY_PRIORITY=5                       # Notification priority (1-10)
LOG_FILE="/var/log/pve-config-backup.log"  # Log file for cron mode
# ============================================================

# Default backup manifest. These are the host-side configs PBS/vzdump don't cover.
# config.db (the pmxcfs backing store) is handled specially in run_backup().
# Edit this list to taste; missing paths are skipped silently with a note.
BACKUP_PATHS=(
    "/etc/pve"                     # Guest configs, storage.cfg, firewall, HA, replication (pmxcfs)
    "/etc/network/interfaces"      # Host networking
    "/etc/network/interfaces.d"    # SDN / additional interface snippets
    "/etc/hostname"                # Node identity (needed for cluster + pmxcfs restore)
    "/etc/hosts"                   # Hostname resolution
    "/etc/resolv.conf"             # DNS
    "/etc/passwd"                  # PAM users (PVE realm uses these)
    "/etc/group"                   # PAM groups
    "/etc/apt/sources.list"        # Repo config
    "/etc/apt/sources.list.d"      # No-subscription / Ceph / extra repos
    "/etc/vzdump.conf"             # Backup job defaults
    "/etc/lvm/lvm.conf"            # LVM tuning (if customized)
    "/etc/cron.d"                  # Host cron jobs (incl. anything these scripts added)
)

set -euo pipefail
shopt -s inherit_errexit nullglob

# Script metadata
SCRIPT_NAME="pve-config-backup"
SCRIPT_VERSION="1.2.1"
SCRIPT_URL="https://github.com/SunBroLynk/Proxmox-Scripts"
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_INSTALL_DEST="/usr/local/bin/${SCRIPT_NAME}"  # Canonical location (cron runs this path)

# Colors (always $'...' so escapes render via echo/printf/cat heredoc alike)
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

# Temp tracking — populated as we create staging dirs / mountpoints / partial
# archives so the CTRL+C trap and normal cleanup can remove them.
TEMP_FILES=()

# Runtime state: set from SETTINGS_FILE by load_settings. Initialized here so it
# is always defined under `set -u`.
INSTALL_NUDGE_DISMISSED=""

cleanup() {
    for f in "${TEMP_FILES[@]:-}"; do
        # A leftover NFS mountpoint must be unmounted before removal.
        if mountpoint -q "$f" 2>/dev/null; then
            umount "$f" 2>/dev/null || umount -l "$f" 2>/dev/null || true
        fi
        rm -rf "$f" 2>/dev/null || true
    done
}

# Tailored cancel message: make clear no partial/corrupt archive was left behind.
trap 'echo -e "\n\n${TAB}${YW}⚠  Cancelled by user. No backup was completed.${CL}\n"; cleanup; exit 0' SIGINT SIGTERM

header_info() {
    clear
    cat <<"EOF"
  ___                              
 | _ \_ _ _____ ___ __  _____ __  
 |  _/ '_/ _ \ \ / '  \/ _ \ \ / 
 |_| |_| \___/_\_\_|_|_\___/_\_\  
      ╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍
          S c r i p t s

   ___           __ _        ___          _             
  / __|___ _ _  / _(_)__ _  | _ ) __ _ __| |___ _  _ _ __ 
 | (__/ _ \ ' \|  _| / _` | | _ \/ _` / _| / / | || | '_ \
  \___\___/_||_|_| |_\__, | |___/\__,_\__|_\_\\_,_| .__/
                     |___/                        |_|   
EOF
    echo ""
}

# ---- Message functions ----
msg_info()  { echo -ne "${TAB}- ${YW}$1...${CL}"; }
msg_ok()    { echo -e "${BFR}${TAB}${CM} ${GN}$1${CL}"; }
msg_error() { echo -e "${BFR}${TAB}${CROSS} ${RD}$1${CL}"; }
msg_warn()  { echo -e "${BFR}${TAB}${INFO} ${YW}$1${CL}"; }

# ============================================================
# HELP (man-style)
# ============================================================
show_help() {
    header_info
    echo -e "${BD}NAME${CL}"
    echo -e "${TAB}${SCRIPT_NAME} — back up Proxmox VE host configuration"
    echo ""
    echo -e "${BD}SYNOPSIS${CL}"
    echo -e "${TAB}${SCRIPT_NAME} [${BL}OPTIONS${CL}]"
    echo ""
    echo -e "${BD}DESCRIPTION${CL}"
    echo -e "${TAB}Captures the host-side configuration that PBS and vzdump do NOT back up:"
    echo -e "${TAB}/etc/pve (incl. the pmxcfs backing database config.db), networking,"
    echo -e "${TAB}storage and cluster config, users, and apt sources. The result is a single"
    echo -e "${TAB}dated, ${BD}chmod 600${CL} tarball (it contains password hashes and SSH host keys)."
    echo ""
    echo -e "${TAB}Backs up configuration only — no guest disk images — so it is safe to run"
    echo -e "${TAB}live. Run it on each node; in a cluster, /etc/pve resyncs automatically when"
    echo -e "${TAB}a rebuilt node rejoins, but the per-node files here still need restoring."
    echo ""
    echo -e "${TAB}${BD}Offsite export:${CL} each archive can be copied to remote targets — SCP/SFTP"
    echo -e "${TAB}(key-based, via REMOTE_TARGETS), or NFS and FTP/FTPS added interactively with"
    echo -e "${TAB}${BL}--targets${CL}. Every target is verified (write → read → delete a test file)"
    echo -e "${TAB}before it is saved."
    echo ""
    echo -e "${BD}OPTIONS${CL}"
    echo -e "${TAB}${GN}(no arguments)${CL}"
    echo -e "${TAB}${TAB}Launch interactive mode with guided menu."
    echo ""
    echo -e "${TAB}${GN}--setup${CL}"
    echo -e "${TAB}${TAB}Guided one-time setup: first backup, optional export target, optional"
    echo -e "${TAB}${TAB}Gotify, and a cron schedule. After this, runs hands-off; only --restore"
    echo -e "${TAB}${TAB}needs you again. Auto-offered on first run."
    echo ""
    echo -e "${TAB}${GN}--set-cred ${BL}<name>${CL}"
    echo -e "${TAB}${TAB}Non-interactively seal a secret read from stdin (e.g. for automation):"
    echo -e "${TAB}${TAB}${BL}echo -n \"\$TOKEN\" | ${SCRIPT_NAME} --set-cred gotify-token${CL}"
    echo -e "${TAB}${TAB}Uses systemd-creds (TPM-bound where available), else a chmod-600 file."
    echo ""
    echo -e "${TAB}${GN}-y, --yes, --cron${CL}"
    echo -e "${TAB}${TAB}Run a backup without prompts (for cron). Fires Gotify if configured."
    echo ""
    echo -e "${TAB}${GN}--targets${CL}"
    echo -e "${TAB}${TAB}Add, test, list, or remove offsite export targets (NFS / SFTP / FTPS)."
    echo -e "${TAB}${TAB}Each add is verified by writing, reading back, and deleting a test file."
    echo ""
    echo -e "${TAB}${GN}--list${CL}"
    echo -e "${TAB}${TAB}List existing archives in the backup destination with date and size."
    echo ""
    echo -e "${TAB}${GN}--restore ${BL}<file>${CL}"
    echo -e "${TAB}${TAB}Safely extract an archive to a review directory and print step-by-step"
    echo -e "${TAB}${TAB}restore guidance. Does NOT overwrite anything in /etc automatically."
    echo ""
    echo -e "${TAB}${GN}--status${CL}"
    echo -e "${TAB}${TAB}Show last backup, archive count, total size, and configured targets."
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
    echo -e "${TAB}REMOTE_TARGETS holds simple key-based SCP/SFTP destinations (no secrets,"
    echo -e "${TAB}safe to keep here). NFS and FTP/FTPS targets — and anything with a password —"
    echo -e "${TAB}are managed via ${BL}--targets${CL} and stored in TARGETS_FILE with chmod 600, so"
    echo -e "${TAB}credentials never live in this (public-repo) script."
    echo ""
    echo -e "${TAB}${BD}Variable                    Line  Current Value${CL}"
    echo -e "${TAB}──────────────────────────  ────  ─────────────────────────"
    while IFS= read -r line; do
        local linenum var val
        linenum=$(echo "$line" | cut -d: -f1)
        var=$(echo "$line" | cut -d: -f2- | cut -d= -f1 | xargs)
        val=$(echo "$line" | cut -d= -f2- | sed 's/[[:space:]]*#.*$//' | tr -d '"' | xargs)
        printf "${TAB}${GN}%-28s${CL}${YW}%-6s${CL}%s\n" "$var" "$linenum" "$val"
    done < <(grep -n '^[A-Z_]*=' "$SCRIPT_PATH" \
        | grep -v 'SCRIPT_\|BACKUP_PATHS\|SETTINGS_FILE\|SECRETS_DIR\|INSTALL_NUDGE_DISMISSED\|ARCHIVE_PATH\|ARCHIVE_SIZE\|SKIPPED_PATHS\|^[0-9]*:ARGS=\|^[0-9]*:RD=\|^[0-9]*:YW=\|^[0-9]*:GN=\|^[0-9]*:BL=\|^[0-9]*:BD=\|^[0-9]*:CL=\|^[0-9]*:BFR=\|^[0-9]*:CM=\|^[0-9]*:CROSS=\|^[0-9]*:INFO=\|^[0-9]*:TAB=\|^[0-9]*:TEMP_FILES\|INTERACTIVE\|AUTO_YES' \
        | head -12)
    echo ""
    echo -e "${BD}FILES${CL}"
    echo -e "${TAB}${BL}${SCRIPT_INSTALL_DEST}${CL}"
    echo -e "${TAB}${TAB}Canonical install location (cron runs this path). The script offers to"
    echo -e "${TAB}${TAB}install itself here on first interactive run; scheduling needs it."
    echo -e "${TAB}${BL}${BACKUP_DEST}/${CL}"
    echo -e "${TAB}${TAB}Archive destination (pve-config-<hostname>-<date>.tar.gz)."
    echo -e "${TAB}${BL}${TARGETS_FILE}${CL}"
    echo -e "${TAB}${TAB}Managed export-target store (chmod 600). Created on first --targets add."
    echo -e "${TAB}${BL}${LOG_FILE}${CL}"
    echo -e "${TAB}${TAB}Log output when running in cron/automated mode."
    echo ""
    echo -e "${BD}EXIT STATUS${CL}"
    echo -e "${TAB}${GN}0${CL}  Success"
    echo -e "${TAB}${RD}1${CL}  Error"
    echo ""
    echo -e "${BD}EXAMPLES${CL}"
    echo -e "${TAB}Interactive:"
    echo -e "${TAB}  ${BL}sudo ${SCRIPT_NAME}${CL}"
    echo ""
    echo -e "${TAB}Add/verify an export target:"
    echo -e "${TAB}  ${BL}sudo ${SCRIPT_NAME} --targets${CL}"
    echo ""
    echo -e "${TAB}Automated via cron:"
    echo -e "${TAB}  ${BL}sudo ${SCRIPT_NAME} --cron >> ${LOG_FILE} 2>&1${CL}"
    echo ""
    echo -e "${TAB}Inspect a backup before restoring:"
    echo -e "${TAB}  ${BL}sudo ${SCRIPT_NAME} --restore ${BACKUP_DEST}/pve-config-$(hostname)-2026-01-01.tar.gz${CL}"
    echo ""
    echo -e "${BD}SEE ALSO${CL}"
    echo -e "${TAB}Project repo:  ${BL}${SCRIPT_URL}${CL}"
    echo -e "${TAB}PVE host recovery relies on /var/lib/pve-cluster/config.db (pmxcfs)."
    echo ""
    echo -e "${BD}LICENSE${CL}"
    echo -e "${TAB}MIT — ${SCRIPT_URL}/blob/main/LICENSE"
    echo ""
    exit 0
}

# ============================================================
# SECRETS (sealed) + SETTINGS (managed) — self-contained, files optional
# ------------------------------------------------------------
# Credentials are sealed with systemd-creds (TPM-bound when the host has a TPM,
# host-key-bound otherwise) and stored under SECRETS_DIR. If systemd-creds is
# unavailable, we fall back to a chmod-600 file. Either way, no plaintext secret
# is written into this (public-repo) script, and cron can still unseal it.
#
# Honest scope: this protects against leak/copy/exfil (and, with a TPM, offline
# cracking on another machine). It does NOT protect against an attacker who
# already has root on THIS host — anything that auto-unseals for cron, they can
# unseal too. The strongest option remains credential-less transports (SFTP keys,
# NFS) where there is no secret to store at all.
# ============================================================

have_systemd_creds() { command -v systemd-creds &>/dev/null; }

# Seal a secret (value on stdin) under a logical name. Echoes the method used.
secret_set() {
    local name="$1" value
    value="$(cat)"   # exact bytes from stdin (trailing newline stripped by $())
    mkdir -p "$SECRETS_DIR"; chmod 700 "$SECRETS_DIR"
    if have_systemd_creds; then
        if printf '%s' "$value" | systemd-creds encrypt --name="pcb-${name}" - "${SECRETS_DIR}/${name}.cred" 2>/dev/null; then
            chmod 600 "${SECRETS_DIR}/${name}.cred"
            rm -f "${SECRETS_DIR}/${name}.secret" 2>/dev/null || true
            echo "systemd-creds"; return 0
        fi
    fi
    # Fallback: chmod-600 file.
    printf '%s' "$value" > "${SECRETS_DIR}/${name}.secret"
    chmod 600 "${SECRETS_DIR}/${name}.secret"
    rm -f "${SECRETS_DIR}/${name}.cred" 2>/dev/null || true
    echo "file-600"; return 0
}

# Unseal a secret to stdout. Returns non-zero if not present/unsealable.
secret_get() {
    local name="$1"
    if [[ -f "${SECRETS_DIR}/${name}.cred" ]] && have_systemd_creds; then
        systemd-creds decrypt --name="pcb-${name}" "${SECRETS_DIR}/${name}.cred" - 2>/dev/null && return 0
    fi
    if [[ -f "${SECRETS_DIR}/${name}.secret" ]]; then
        cat "${SECRETS_DIR}/${name}.secret"; return 0
    fi
    return 1
}

secret_exists() { [[ -f "${SECRETS_DIR}/$1.cred" || -f "${SECRETS_DIR}/$1.secret" ]]; }
secret_method() { [[ -f "${SECRETS_DIR}/$1.cred" ]] && echo "systemd-creds (sealed)" || { [[ -f "${SECRETS_DIR}/$1.secret" ]] && echo "file-600" || echo "none"; }; }
secret_delete() { rm -f "${SECRETS_DIR}/$1.cred" "${SECRETS_DIR}/$1.secret" 2>/dev/null || true; }

# Load whitelisted non-secret settings written by --setup. Parsed, never sourced.
load_settings() {
    [[ -f "$SETTINGS_FILE" ]] || return 0
    local line key val
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        key="${line%%=*}"; val="${line#*=}"
        val="${val%\"}"; val="${val#\"}"
        case "$key" in
            GOTIFY_URL)      GOTIFY_URL="$val" ;;
            GOTIFY_PRIORITY) GOTIFY_PRIORITY="$val" ;;
            BACKUP_DEST)     BACKUP_DEST="$val" ;;
            RETENTION_DAYS)  RETENTION_DAYS="$val" ;;
            INSTALL_NUDGE_DISMISSED) INSTALL_NUDGE_DISMISSED="$val" ;;
        esac
    done < "$SETTINGS_FILE"
}

# Upsert one whitelisted setting (non-secret) into SETTINGS_FILE.
settings_set() {
    local key="$1" val="$2" tmp
    mkdir -p "$(dirname "$SETTINGS_FILE")"; chmod 700 "$(dirname "$SETTINGS_FILE")"
    touch "$SETTINGS_FILE"; chmod 600 "$SETTINGS_FILE"
    tmp=$(mktemp /tmp/.pcb-set-XXXXXX); TEMP_FILES+=("$tmp")
    grep -v "^${key}=" "$SETTINGS_FILE" > "$tmp" 2>/dev/null || true
    echo "${key}=\"${val}\"" >> "$tmp"
    cat "$tmp" > "$SETTINGS_FILE"; chmod 600 "$SETTINGS_FILE"; rm -f "$tmp"
}

# Resolve the Gotify token: prefer a sealed secret, else the plaintext config var.
resolve_gotify_token() {
    if secret_exists gotify-token; then secret_get gotify-token; else printf '%s' "$GOTIFY_TOKEN"; fi
}

# Resolve an FTP password field: @SECRET:<name> -> unsealed value; else literal.
resolve_secret_ref() {
    local field="$1"
    if [[ "$field" == @SECRET:* ]]; then secret_get "${field#@SECRET:}"; else printf '%s' "$field"; fi
}

# ============================================================
# GOTIFY (secure — token never in process args)
# ============================================================
# True if Gotify is usable: a URL plus a token (sealed secret OR plaintext var).
gotify_configured() {
    [[ -n "$GOTIFY_URL" ]] || return 1
    secret_exists gotify-token && return 0
    [[ -n "$GOTIFY_TOKEN" ]]
}

send_gotify() {
    local title="$1" message="$2" priority="${3:-$GOTIFY_PRIORITY}"
    gotify_configured || return 0

    local json_message curl_conf token
    token=$(resolve_gotify_token)
    json_message=$(echo "$message" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null || echo "\"${message}\"")
    # Token in a chmod-600 curl config header, NOT the URL — avoids ps aux leak.
    curl_conf=$(mktemp /tmp/.gotify-XXXXXX); chmod 600 "$curl_conf"
    cat > "$curl_conf" <<CURLEOF
header = "X-Gotify-Key: ${token}"
header = "Content-Type: application/json"
CURLEOF
    curl -s -K "$curl_conf" -X POST "${GOTIFY_URL}/message" \
        -d "{\"title\":\"${title}\",\"message\":${json_message},\"priority\":${priority},\"extras\":{\"client::display\":{\"contentType\":\"text/markdown\"}}}" &>/dev/null || true
    rm -f "$curl_conf"
}

# Send a test push. Returns 0 on HTTP 200. Does NOT exit (callable from setup).
do_gotify_test() {
    local token curl_conf json_message response test_message
    token=$(resolve_gotify_token)
    test_message="### ✅ Connection Successful

**Script:** \`${SCRIPT_NAME}\`
**Host:** \`$(hostname)\`
**Time:** $(date '+%Y-%m-%d %H:%M:%S')

---

*${SCRIPT_NAME} is configured and ready to send alerts.*"
    curl_conf=$(mktemp /tmp/.gotify-XXXXXX); chmod 600 "$curl_conf"
    cat > "$curl_conf" <<CURLEOF
header = "X-Gotify-Key: ${token}"
header = "Content-Type: application/json"
CURLEOF
    json_message=$(echo "$test_message" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null)
    response=$(curl -s -o /dev/null -w "%{http_code}" -K "$curl_conf" -X POST "${GOTIFY_URL}/message" \
        -d "{\"title\":\"🔔 ${SCRIPT_NAME} — Test\",\"message\":${json_message},\"priority\":${GOTIFY_PRIORITY},\"extras\":{\"client::display\":{\"contentType\":\"text/markdown\"}}}" 2>/dev/null)
    rm -f "$curl_conf"
    [[ "$response" == "200" ]]
}

test_gotify() {
    header_info
    echo -e "${TAB}${BD}Gotify Notification Test${CL}"
    echo ""
    [[ -z "$GOTIFY_URL" ]] && { msg_error "GOTIFY_URL not configured"; echo ""; exit 1; }
    gotify_configured || { msg_error "Gotify token not configured (set GOTIFY_TOKEN or seal one with --set-cred gotify-token)"; echo ""; exit 1; }
    msg_info "Sending test notification to ${GOTIFY_URL}"
    if do_gotify_test; then msg_ok "Test notification sent successfully"; else msg_error "Notification failed"; fi
    echo ""
    exit 0
}

# ============================================================
# CRON SCHEDULE MANAGER (daily-flavor — config backups are a day-level concern)
# ============================================================
manage_cron() {
    header_info
    echo -e "${TAB}${BD}Schedule Manager${CL}"
    echo ""
    local CRON_CMD="/usr/local/bin/${SCRIPT_NAME} --cron >> ${LOG_FILE} 2>&1"
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
            1) ;;
            2) crontab -l 2>/dev/null | grep -v "${SCRIPT_NAME}" | crontab -; echo ""; msg_ok "Schedule removed"; echo ""; exit 0 ;;
            *) echo ""; exit 0 ;;
        esac
        echo ""
    else
        echo -e "${TAB}  ${YW}No schedule configured${CL}"
        echo ""
    fi

    # Scheduling is disabled until the script is installed at the canonical path.
    require_installed_for_schedule || { echo ""; exit 0; }

    echo -e "${TAB}  ${BD}How often should ${SCRIPT_NAME} run?${CL}"
    echo ""
    echo -e "${TAB}  ${GN}1)${CL} Daily at 3:00 AM"
    echo -e "${TAB}  ${GN}2)${CL} Daily at custom time"
    echo -e "${TAB}  ${GN}3)${CL} Weekly (Sunday 3:00 AM)"
    echo -e "${TAB}  ${GN}4)${CL} Custom cron expression"
    echo -e "${TAB}  ${RD}q)${CL} Cancel"
    echo ""
    read -rp "  Select [1-4/q]: " schedule_choice
    local CRON_SCHEDULE=""
    case "$schedule_choice" in
        1) CRON_SCHEDULE="0 3 * * *" ;;
        2)
            read -rp "  Hour (0-23): " cron_hour
            read -rp "  Minute (0-59): " cron_min
            [[ "$cron_hour" =~ ^[0-9]+$ && "$cron_hour" -le 23 ]] || { msg_error "Invalid hour"; exit 1; }
            [[ "$cron_min" =~ ^[0-9]+$ && "$cron_min" -le 59 ]] || { msg_error "Invalid minute"; exit 1; }
            CRON_SCHEDULE="${cron_min} ${cron_hour} * * *" ;;
        3) CRON_SCHEDULE="0 3 * * 0" ;;
        4) read -rp "  Cron expression: " CRON_SCHEDULE; [[ -z "$CRON_SCHEDULE" ]] && { msg_error "No expression"; exit 1; } ;;
        *) echo ""; exit 0 ;;
    esac
    local NEW_CRON="${CRON_SCHEDULE} ${CRON_CMD}"
    (crontab -l 2>/dev/null | grep -v "${SCRIPT_NAME}"; echo "$NEW_CRON") | crontab -
    echo ""
    msg_ok "Schedule set: ${GN}${CRON_SCHEDULE}${CL}"
    echo -e "${TAB}  ${BL}${NEW_CRON}${CL}"
    echo ""
    exit 0
}

# ============================================================
# EXPORT TARGETS — NFS / SFTP / FTP(S)
# ------------------------------------------------------------
# Stored one-per-line in TARGETS_FILE (chmod 600), pipe-delimited:
#   nfs|<host>:/<export>|<optional-subdir>
#   sftp|<user@host>|<port>|<remote-path>
#   ftp|<host>|<port>|<user>|<password>|<remote-path>|<tls 0|1>
# REMOTE_TARGETS entries (user@host:/path) are folded in as sftp targets at load.
# ============================================================

# Populate TARGETS[] (specs) and TARGET_SRC[] (remote|file) in parallel.
load_targets() {
    TARGETS=(); TARGET_SRC=()
    if [[ -n "$REMOTE_TARGETS" ]]; then
        local t
        for t in $REMOTE_TARGETS; do
            TARGETS+=("sftp|${t%%:*}|22|${t#*:}"); TARGET_SRC+=("remote")
        done
    fi
    if [[ -f "$TARGETS_FILE" ]]; then
        local line
        while IFS= read -r line; do
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
            TARGETS+=("$line"); TARGET_SRC+=("file")
        done < "$TARGETS_FILE"
    fi
}

# Human-readable, password-masked label for a target spec.
target_label() {
    local spec="$1" type
    type="${spec%%|*}"
    case "$type" in
        nfs)  local _t he sub; IFS='|' read -r _t he sub <<<"$spec"; echo "NFS    ${he}${sub:+/$sub}" ;;
        sftp) local _t uh port path; IFS='|' read -r _t uh port path <<<"$spec"; echo "SFTP   ${uh}:${path} (port ${port})" ;;
        ftp)  local _t host port user pass path tls; IFS='|' read -r _t host port user pass path tls <<<"$spec"
              local p="FTP "; [[ "$tls" == "1" ]] && p="FTPS"
              echo "${p}   ${user}@${host}:${path} (port ${port})" ;;
        *) echo "UNKNOWN ${spec}" ;;
    esac
}

# Create a small local canary file with unique content; return its path.
make_canary() {
    local f
    f=$(mktemp /tmp/.pcb-canary-XXXXXX)
    TEMP_FILES+=("$f")
    echo "pve-config-backup canary | host=$(hostname) | $(date +%s) | $RANDOM" > "$f"
    echo "$f"
}

# Ensure NFS client tooling is present; offer to install interactively.
nfs_check_deps() {
    command -v mount.nfs &>/dev/null && return 0
    msg_warn "nfs-common not installed (required for NFS targets)"
    if [[ "${INTERACTIVE:-true}" == true ]]; then
        read -rp "  Install nfs-common now? [Y/n]: " a
        if [[ ! "$a" =~ ^[Nn]$ ]]; then
            if apt-get update -qq >/dev/null 2>&1 && apt-get install -y nfs-common >/dev/null 2>&1; then
                msg_ok "nfs-common installed"; return 0
            fi
            msg_error "Install failed — install nfs-common manually"; return 1
        fi
    fi
    return 1
}

# ---- Per-type verify (write -> read back -> delete a canary) ----

verify_nfs() {
    local he="$1" sub="$2" canary="$3"
    nfs_check_deps || return 1
    local ok=true cname mp dest
    cname=$(basename "$canary")
    mp=$(mktemp -d /tmp/.pcb-nfs-XXXXXX); TEMP_FILES+=("$mp")
    msg_info "Mounting ${he}"
    if mount -t nfs -o soft,timeo=50,retrans=2 "$he" "$mp" 2>/dev/null; then
        msg_ok "Mounted ${he}"
    else
        msg_error "Mount failed (export path, firewall, or nfs-common?)"
        rmdir "$mp" 2>/dev/null || true
        return 1
    fi
    dest="$mp${sub:+/$sub}"
    mkdir -p "$dest" 2>/dev/null || true
    msg_info "Writing test file"
    if cp "$canary" "$dest/$cname" 2>/dev/null; then msg_ok "Wrote ${cname}"; else msg_error "Write failed (permissions on export?)"; ok=false; fi
    if [[ "$ok" == true ]]; then
        msg_info "Reading it back"
        if [[ -f "$dest/$cname" ]] && diff -q "$canary" "$dest/$cname" >/dev/null 2>&1; then msg_ok "Verified contents match"; else msg_error "Read-back/verify failed"; ok=false; fi
    fi
    if [[ -f "$dest/$cname" ]]; then
        msg_info "Removing test file"
        if rm -f "$dest/$cname" 2>/dev/null && [[ ! -f "$dest/$cname" ]]; then msg_ok "Removed ${cname}"; else msg_error "Delete failed"; ok=false; fi
    fi
    umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
    rmdir "$mp" 2>/dev/null || true
    [[ "$ok" == true ]]
}

verify_sftp() {
    local uh="$1" port="$2" path="$3" canary="$4"
    local ok=true cname
    cname=$(basename "$canary")
    msg_info "Connecting to ${uh}"
    if ssh -o BatchMode=yes -o ConnectTimeout=10 -p "$port" "$uh" "true" 2>/dev/null; then
        msg_ok "SSH connection OK (${uh})"
    else
        msg_error "SSH failed — key-based auth not set up? (try: ssh-copy-id -p ${port} ${uh})"
        return 1
    fi
    msg_info "Writing test file"
    if scp -q -o BatchMode=yes -o ConnectTimeout=10 -P "$port" "$canary" "${uh}:${path}/${cname}" 2>/dev/null; then msg_ok "Uploaded ${cname}"; else msg_error "Upload failed (is ${path} writable?)"; ok=false; fi
    if [[ "$ok" == true ]]; then
        msg_info "Confirming it landed"
        if ssh -o BatchMode=yes -p "$port" "$uh" "test -f '${path}/${cname}'" 2>/dev/null; then msg_ok "Confirmed on remote"; else msg_error "Not found after upload"; ok=false; fi
        msg_info "Removing test file"
        if ssh -o BatchMode=yes -p "$port" "$uh" "rm -f '${path}/${cname}'" 2>/dev/null; then msg_ok "Removed ${cname}"; else msg_error "Delete failed"; ok=false; fi
    fi
    [[ "$ok" == true ]]
}

verify_ftp() {
    local host="$1" port="$2" user="$3" pass="$4" path="$5" tls="$6" canary="$7"
    local ok=true cname proto_opt="" conf back base
    cname=$(basename "$canary")
    # Password may be a literal (new, pre-seal) or an @SECRET:<name> reference.
    pass=$(resolve_secret_ref "$pass") || { msg_error "Could not unseal stored credential"; return 1; }
    [[ "$tls" == "1" ]] && proto_opt="--ssl-reqd"
    conf=$(mktemp /tmp/.pcb-ftp-XXXXXX); chmod 600 "$conf"; TEMP_FILES+=("$conf")
    printf 'user = "%s:%s"\n' "$user" "$pass" > "$conf"
    base="ftp://${host}:${port}/${path#/}"; base="${base%/}/"
    msg_info "Uploading test file"
    if curl -s --connect-timeout 15 $proto_opt -K "$conf" -T "$canary" "${base}${cname}" 2>/dev/null; then msg_ok "Uploaded ${cname}"; else msg_error "Upload failed (host / creds / path / TLS?)"; ok=false; fi
    if [[ "$ok" == true ]]; then
        back=$(mktemp /tmp/.pcb-ftpback-XXXXXX); TEMP_FILES+=("$back")
        msg_info "Downloading it back"
        if curl -s --connect-timeout 15 $proto_opt -K "$conf" -o "$back" "${base}${cname}" 2>/dev/null && diff -q "$canary" "$back" >/dev/null 2>&1; then msg_ok "Verified contents match"; else msg_error "Read-back/verify failed"; ok=false; fi
        msg_info "Removing test file"
        if curl -s --connect-timeout 15 $proto_opt -K "$conf" -Q "DELE ${cname}" "$base" 2>/dev/null; then msg_ok "Removed ${cname}"; else msg_error "Delete failed (DELE not permitted?)"; ok=false; fi
    fi
    rm -f "$conf"
    [[ "$ok" == true ]]
}

# Dispatch verification by target type. Returns 0 on full pass.
verify_target() {
    local spec="$1" type rc=1 canary
    type="${spec%%|*}"
    canary=$(make_canary)
    case "$type" in
        nfs)  local _t he sub;        IFS='|' read -r _t he sub <<<"$spec";       verify_nfs  "$he" "$sub" "$canary" && rc=0 || rc=1 ;;
        sftp) local _t uh port path;  IFS='|' read -r _t uh port path <<<"$spec"; verify_sftp "$uh" "$port" "$path" "$canary" && rc=0 || rc=1 ;;
        ftp)  local _t h p u pw pa t; IFS='|' read -r _t h p u pw pa t <<<"$spec"; verify_ftp  "$h" "$p" "$u" "$pw" "$pa" "$t" "$canary" && rc=0 || rc=1 ;;
        *) msg_error "Unknown target type: ${type}"; rc=1 ;;
    esac
    rm -f "$canary" 2>/dev/null || true
    return $rc
}

# ---- Per-type push of the real archive (no read-back/delete) ----
push_typed_target() {
    local spec="$1" archive="$2" type aname
    type="${spec%%|*}"
    aname=$(basename "$archive")
    case "$type" in
        nfs)
            local _t he sub; IFS='|' read -r _t he sub <<<"$spec"
            command -v mount.nfs &>/dev/null || return 1
            local mp dest rc=0
            mp=$(mktemp -d /tmp/.pcb-nfs-XXXXXX); TEMP_FILES+=("$mp")
            mount -t nfs -o soft,timeo=50,retrans=2 "$he" "$mp" 2>/dev/null || { rmdir "$mp" 2>/dev/null || true; return 1; }
            dest="$mp${sub:+/$sub}"; mkdir -p "$dest" 2>/dev/null || true
            cp "$archive" "$dest/$aname" 2>/dev/null || rc=1
            umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
            rmdir "$mp" 2>/dev/null || true
            return $rc ;;
        sftp)
            local _t uh port path; IFS='|' read -r _t uh port path <<<"$spec"
            scp -q -o BatchMode=yes -o ConnectTimeout=10 -P "$port" "$archive" "${uh}:${path}/" 2>/dev/null ;;
        ftp)
            local _t host port user pass path tls; IFS='|' read -r _t host port user pass path tls <<<"$spec"
            local proto_opt="" conf base rc=0
            pass=$(resolve_secret_ref "$pass") || return 1
            [[ "$tls" == "1" ]] && proto_opt="--ssl-reqd"
            conf=$(mktemp /tmp/.pcb-ftp-XXXXXX); chmod 600 "$conf"; TEMP_FILES+=("$conf")
            printf 'user = "%s:%s"\n' "$user" "$pass" > "$conf"
            base="ftp://${host}:${port}/${path#/}"; base="${base%/}/"
            curl -s --connect-timeout 30 $proto_opt -K "$conf" -T "$archive" "${base}${aname}" 2>/dev/null || rc=1
            rm -f "$conf"
            return $rc ;;
        *) return 1 ;;
    esac
}

# Export to every target in TARGETS_FILE (sequential — mounts/uploads are
# stateful; counts are small). REMOTE_TARGETS (scp) is handled by push_remote.
export_typed_targets() {
    local archive="$1" line label
    [[ -f "$TARGETS_FILE" ]] || return 0
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        label=$(target_label "$line")
        msg_info "Exporting to ${label}"
        if push_typed_target "$line" "$archive"; then
            msg_ok "Exported to ${label}"
        else
            msg_error "Export FAILED: ${label}"
        fi
    done < "$TARGETS_FILE"
}

# ---- Interactive target manager ----
targets_add() {
    echo ""
    echo -e "${TAB}${BD}Add Export Target${CL}"
    echo -e "${TAB}  ${GN}1)${CL} NFS share"
    echo -e "${TAB}  ${GN}2)${CL} SFTP / SCP (over SSH, key-based)"
    echo -e "${TAB}  ${GN}3)${CL} FTP / FTPS"
    echo -e "${TAB}  ${RD}q)${CL} Cancel"
    echo ""
    read -rp "  Type [1-3/q]: " ty
    local spec="" ftp_plain_pass=""
    case "$ty" in
        1)
            read -rp "  NFS host:export (e.g. 192.168.1.10:/export/backups): " he
            [[ -z "$he" ]] && { msg_error "Nothing entered"; return; }
            read -rp "  Sub-directory under the export (optional, blank = root): " sub
            spec="nfs|${he}|${sub}" ;;
        2)
            read -rp "  user@host (e.g. root@192.168.1.11): " uh
            [[ -z "$uh" ]] && { msg_error "Nothing entered"; return; }
            read -rp "  SSH port [22]: " port; port="${port:-22}"
            read -rp "  Remote path (e.g. /root/pve-backups): " path
            [[ -z "$path" ]] && { msg_error "No path entered"; return; }
            spec="sftp|${uh}|${port}|${path}" ;;
        3)
            read -rp "  FTP host: " host
            [[ -z "$host" ]] && { msg_error "No host entered"; return; }
            read -rp "  Port [21]: " port; port="${port:-21}"
            read -rp "  Username: " user
            read -rsp "  Password: " pass; echo ""
            read -rp "  Remote path (e.g. /pve-backups): " path
            read -rp "  Use TLS (FTPS — strongly recommended)? [Y/n]: " usetls
            local tls=1; [[ "$usetls" =~ ^[Nn]$ ]] && tls=0
            if [[ "$tls" == "0" ]]; then
                echo ""
                msg_warn "Plain FTP sends credentials AND the backup in cleartext."
                echo -e "${TAB}  ${YW}This archive contains /etc/shadow hashes and SSH host keys —${CL}"
                echo -e "${TAB}  ${YW}anyone on the network path could capture them. Prefer FTPS or SFTP.${CL}"
                echo ""
                read -rp "  Continue with plaintext FTP anyway? [y/N]: " c
                [[ ! "$c" =~ ^[Yy]$ ]] && { echo ""; msg_ok "Cancelled — good call."; echo ""; return; }
            fi
            spec="ftp|${host}|${port}|${user}|${pass}|${path}|${tls}"
            ftp_plain_pass="$pass" ;;
        *) return ;;
    esac

    echo ""
    echo -e "${TAB}${BL}Verifying target — writing, reading back, and deleting a test file${CL}"
    echo ""
    if verify_target "$spec"; then
        echo ""
        msg_ok "Target verified successfully"
        read -rp "  Save this target? [Y/n]: " s
        if [[ ! "$s" =~ ^[Nn]$ ]]; then
            mkdir -p "$(dirname "$TARGETS_FILE")"; chmod 700 "$(dirname "$TARGETS_FILE")"
            touch "$TARGETS_FILE"; chmod 600 "$TARGETS_FILE"
            # For FTP, seal the password and store a reference — never the literal.
            if [[ "$spec" == ftp\|* ]]; then
                local cid method
                cid="ftpcred-$(date +%s)-$RANDOM"
                method=$(printf '%s' "$ftp_plain_pass" | secret_set "$cid")
                spec="ftp|${host}|${port}|${user}|@SECRET:${cid}|${path}|${tls}"
                msg_ok "Credential sealed via ${method}"
            fi
            echo "$spec" >> "$TARGETS_FILE"
            msg_ok "Saved to ${TARGETS_FILE} (chmod 600)"
        else
            msg_warn "Not saved"
        fi
    else
        echo ""
        msg_error "Verification FAILED — target NOT saved. Fix the issue and try again."
    fi
    echo ""
}

targets_test_all() {
    load_targets
    echo ""
    if [[ ${#TARGETS[@]} -eq 0 ]]; then msg_warn "No targets configured"; echo ""; return; fi
    local i
    for i in "${!TARGETS[@]}"; do
        echo -e "${TAB}${BD}$(target_label "${TARGETS[$i]}")${CL}"
        if verify_target "${TARGETS[$i]}"; then msg_ok "PASS"; else msg_error "FAIL"; fi
        echo ""
    done
}

targets_remove() {
    load_targets
    echo ""
    if [[ ${#TARGETS[@]} -eq 0 ]]; then msg_warn "No targets to remove"; echo ""; return; fi
    read -rp "  Number to remove (from the list above): " n
    [[ "$n" =~ ^[0-9]+$ ]] || { msg_error "Invalid number"; echo ""; return; }
    local idx=$((n - 1))
    [[ $idx -lt 0 || $idx -ge ${#TARGETS[@]} ]] && { msg_error "Out of range"; echo ""; return; }
    if [[ "${TARGET_SRC[$idx]}" == "remote" ]]; then
        msg_warn "That target comes from REMOTE_TARGETS in the script config."
        echo -e "${TAB}  Edit the REMOTE_TARGETS line near the top of ${SCRIPT_PATH} to change it."
        echo ""
        return
    fi
    local spec="${TARGETS[$idx]}" tmp removed=false l
    tmp=$(mktemp /tmp/.pcb-targets-XXXXXX); TEMP_FILES+=("$tmp")
    while IFS= read -r l; do
        if [[ "$removed" == false && "$l" == "$spec" ]]; then removed=true; continue; fi
        echo "$l" >> "$tmp"
    done < "$TARGETS_FILE"
    cat "$tmp" > "$TARGETS_FILE"; chmod 600 "$TARGETS_FILE"; rm -f "$tmp"
    # If this was an FTP target referencing a sealed credential, delete it too.
    if [[ "$spec" == ftp\|* ]]; then
        local _t _h _p _u _pw _pa _tls; IFS='|' read -r _t _h _p _u _pw _pa _tls <<<"$spec"
        [[ "$_pw" == @SECRET:* ]] && secret_delete "${_pw#@SECRET:}"
    fi
    msg_ok "Removed: $(target_label "$spec")"
    echo ""
}

manage_targets() {
    header_info
    echo -e "${TAB}${BD}Export Target Manager${CL}"
    echo -e "${TAB}Archives are copied to every configured target after each backup."
    echo ""
    while true; do
        load_targets
        echo -e "${TAB}${BD}Configured targets:${CL}"
        if [[ ${#TARGETS[@]} -eq 0 ]]; then
            echo -e "${TAB}  ${YW}none${CL}"
        else
            local idx=1 t
            for t in "${TARGETS[@]}"; do
                echo -e "${TAB}  ${GN}${idx})${CL} $(target_label "$t")"
                idx=$((idx + 1))
            done
        fi
        echo ""
        echo -e "${TAB}  ${GN}a)${CL} Add a target (with live verification)"
        echo -e "${TAB}  ${GN}t)${CL} Test all targets"
        echo -e "${TAB}  ${GN}r)${CL} Remove a target"
        echo -e "${TAB}  ${RD}q)${CL} Back"
        echo ""
        read -rp "  Select [a/t/r/q]: " m
        case "$m" in
            a|A) targets_add ;;
            t|T) targets_test_all ;;
            r|R) targets_remove ;;
            q|Q) echo ""; return 0 ;;
            *) msg_error "Invalid option"; echo "" ;;
        esac
    done
}

# ============================================================
# RETENTION (prefix-scoped — never a blind rm)
# ============================================================
apply_retention() {
    [[ "$RETENTION_DAYS" -le 0 ]] && return 0
    local removed=0
    while IFS= read -r -d '' old; do
        rm -f "$old" && removed=$((removed + 1))
    done < <(find "$BACKUP_DEST" -maxdepth 1 -type f \
                -name 'pve-config-*.tar.gz' \
                -mtime +"$RETENTION_DAYS" -print0 2>/dev/null)
    [[ "$removed" -gt 0 ]] && msg_ok "Retention: removed ${removed} archive(s) older than ${RETENTION_DAYS} days"
    return 0
}

# ============================================================
# PUSH TO SCP/SFTP TARGET(S) (REMOTE_TARGETS) — parallel when more than one
# ============================================================
scp_one() {
    local archive="$1" target="$2"
    scp -q -o BatchMode=yes -o ConnectTimeout=10 "$archive" "$target/" 2>/dev/null
}

push_remote() {
    local archive="$1"
    [[ -z "$REMOTE_TARGETS" ]] && return 0
    echo ""
    echo -e "${TAB}${BL}Replicating to SCP/SFTP target(s)${CL}"
    echo ""

    local targets=($REMOTE_TARGETS)
    local count=${#targets[@]}

    if [[ "$count" -eq 1 ]]; then
        msg_info "Copying to ${targets[0]}"
        if scp_one "$archive" "${targets[0]}"; then
            msg_ok "Replicated to ${targets[0]}"
        else
            msg_error "Failed to replicate to ${targets[0]} (check SSH key + path)"
        fi
    else
        local results pids=()
        results=$(mktemp -d /tmp/.pcb-scp-XXXXXX)
        TEMP_FILES+=("$results")
        local i=0
        for t in "${targets[@]}"; do
            ( if scp_one "$archive" "$t"; then echo 0; else echo 1; fi > "${results}/${i}" ) &
            pids+=($!)
            i=$((i + 1))
        done
        for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
        i=0
        for t in "${targets[@]}"; do
            if [[ -f "${results}/${i}" && "$(cat "${results}/${i}")" == "0" ]]; then
                msg_ok "Replicated to ${t}"
            else
                msg_error "Failed to replicate to ${t} (check SSH key + path)"
            fi
            i=$((i + 1))
        done
        rm -rf "$results"
    fi
}

# ============================================================
# ENVIRONMENT / PREFLIGHT
# ============================================================
preflight_checks() {
    echo -e "${TAB}${BL}Preflight Checks${CL}"
    echo ""
    local CRITICAL=false

    if command -v pveversion &>/dev/null && [[ -d /etc/pve ]]; then
        msg_ok "Proxmox VE host detected ($(pveversion 2>/dev/null | head -1))"
    else
        msg_error "Not a Proxmox VE host (no pveversion / /etc/pve) — run this on a node"
        CRITICAL=true
    fi

    for dep in tar gzip; do
        if command -v "$dep" &>/dev/null; then
            msg_ok "${dep} installed"
        else
            msg_error "${dep} not found"
            CRITICAL=true
        fi
    done

    if [[ -f /var/lib/pve-cluster/config.db ]]; then
        msg_ok "pmxcfs database present (config.db)"
    else
        msg_warn "config.db not found — archive will exclude the pmxcfs database"
    fi

    if [[ -d "$BACKUP_DEST" ]]; then
        if [[ -w "$BACKUP_DEST" ]]; then
            msg_ok "Destination writable (${BACKUP_DEST})"
        else
            msg_error "Destination not writable (${BACKUP_DEST})"
            CRITICAL=true
        fi
    else
        if [[ "${INTERACTIVE:-true}" == true ]]; then
            msg_warn "Destination ${BACKUP_DEST} does not exist"
            read -rp "  Create it now? [Y/n]: " mk
            if [[ ! "$mk" =~ ^[Nn]$ ]]; then
                mkdir -p "$BACKUP_DEST" && chmod 700 "$BACKUP_DEST" \
                    && msg_ok "Created ${BACKUP_DEST}" || { msg_error "Could not create ${BACKUP_DEST}"; CRITICAL=true; }
            else
                CRITICAL=true
            fi
        else
            mkdir -p "$BACKUP_DEST" && chmod 700 "$BACKUP_DEST" \
                && msg_ok "Created ${BACKUP_DEST}" || { msg_error "Could not create ${BACKUP_DEST}"; CRITICAL=true; }
        fi
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
# STATUS
# ============================================================
show_status() {
    header_info
    echo -e "${TAB}${BD}Backup Status${CL}"
    echo ""
    echo -e "${TAB}${BL}Host:${CL}        $(hostname)"
    echo -e "${TAB}${BL}Destination:${CL} ${BACKUP_DEST}"

    local archives=()
    if [[ -d "$BACKUP_DEST" ]]; then
        archives=("$BACKUP_DEST"/pve-config-"$(hostname)"-*.tar.gz)
    fi

    if [[ ${#archives[@]} -gt 0 ]]; then
        local latest total
        latest=$(ls -t "${archives[@]}" 2>/dev/null | head -1)
        total=$(du -ch "${archives[@]}" 2>/dev/null | tail -1 | cut -f1)
        echo -e "${TAB}${BL}Archives:${CL}    ${#archives[@]} (total ${total})"
        echo -e "${TAB}${BL}Latest:${CL}      $(basename "$latest") ($(date -r "$latest" '+%Y-%m-%d %H:%M'))"
    else
        echo -e "${TAB}${YW}No archives found for this host yet${CL}"
    fi

    echo -e "${TAB}${BL}Retention:${CL}   ${RETENTION_DAYS} days"

    load_targets
    if [[ ${#TARGETS[@]} -gt 0 ]]; then
        echo -e "${TAB}${BL}Export tgts:${CL} ${#TARGETS[@]}"
        local t
        for t in "${TARGETS[@]}"; do
            echo -e "${TAB}             $(target_label "$t")"
        done
    else
        echo -e "${TAB}${BL}Export tgts:${CL} ${YW}none configured${CL}"
    fi

    local cron_line
    cron_line=$(crontab -l 2>/dev/null | grep "${SCRIPT_NAME}" || true)
    if [[ -n "$cron_line" ]]; then
        echo -e "${TAB}${BL}Schedule:${CL}    ${cron_line%% /*}"
    else
        echo -e "${TAB}${BL}Schedule:${CL}    ${YW}not scheduled${CL}"
    fi
    if secret_exists gotify-token; then
        echo -e "${TAB}${BL}Gotify cred:${CL} $(secret_method gotify-token)"
    fi
    echo ""
    exit 0
}

# ============================================================
# LIST
# ============================================================
list_backups() {
    header_info
    echo -e "${TAB}${BD}Archives in ${BACKUP_DEST}${CL}"
    echo ""
    local archives=()
    if [[ -d "$BACKUP_DEST" ]]; then
        archives=("$BACKUP_DEST"/pve-config-*.tar.gz)
    fi
    if [[ ${#archives[@]} -eq 0 ]]; then
        msg_warn "No archives found"
        echo ""
        exit 0
    fi
    printf "${TAB}${BD}%-44s %8s  %s${CL}\n" "Archive" "Size" "Date"
    echo -e "${TAB}────────────────────────────────────────────  ────────  ─────────────────"
    while IFS= read -r f; do
        printf "${TAB}${GN}%-44s${CL} %8s  %s\n" \
            "$(basename "$f")" \
            "$(du -h "$f" | cut -f1)" \
            "$(date -r "$f" '+%Y-%m-%d %H:%M')"
    done < <(ls -t "${archives[@]}")
    echo ""
    exit 0
}

# ============================================================
# RESTORE (guided — never clobbers /etc automatically)
# ============================================================
restore_backup() {
    local archive="$1"
    header_info
    echo -e "${TAB}${BD}Guided Restore${CL}"
    echo ""

    [[ -f "$archive" ]] || { msg_error "Archive not found: ${archive}"; echo ""; exit 1; }

    local review_dir="/root/pve-config-restore-$(date +%Y%m%d-%H%M%S)"
    msg_info "Extracting to review directory"
    mkdir -p "$review_dir"; chmod 700 "$review_dir"
    if tar xzf "$archive" -C "$review_dir" 2>/dev/null; then
        msg_ok "Extracted to ${review_dir}"
    else
        msg_error "Extraction failed — archive may be corrupt"
        rm -rf "$review_dir"
        echo ""
        exit 1
    fi
    echo ""

    echo -e "${TAB}${BD}Contents:${CL}"
    find "$review_dir" -maxdepth 3 -type f 2>/dev/null | sed "s|${review_dir}|  ${TAB}|" | head -40
    echo ""

    echo -e "${TAB}${YW}${BD}⚠  Read before restoring — do NOT blindly copy everything back.${CL}"
    echo ""
    echo -e "${TAB}${BD}For individual configs${CL} (e.g. a single VM/CT, storage.cfg, interfaces):"
    echo -e "${TAB}  Copy the specific file from ${BL}${review_dir}${CL} into place and reload"
    echo -e "${TAB}  the relevant service (e.g. ${BL}ifreload -a${CL} for networking)."
    echo ""
    echo -e "${TAB}${BD}For a full pmxcfs (/etc/pve) restore on a rebuilt node:${CL}"
    echo -e "${TAB}  /etc/pve is a live FUSE mount — you cannot just copy files over it."
    echo -e "${TAB}  The authoritative state lives in config.db. Procedure:"
    echo ""
    echo -e "${TAB}    1) Stop the cluster filesystem service:"
    echo -e "${TAB}       ${BL}systemctl stop pve-cluster${CL}"
    echo -e "${TAB}    2) Replace the database with the backed-up copy:"
    echo -e "${TAB}       ${BL}cp ${review_dir}/var/lib/pve-cluster/config.db /var/lib/pve-cluster/config.db${CL}"
    echo -e "${TAB}       ${BL}chmod 600 /var/lib/pve-cluster/config.db${CL}"
    echo -e "${TAB}    3) Restore identity files: ${BL}/etc/hostname${CL}, ${BL}/etc/hosts${CL}"
    echo -e "${TAB}    4) Start the service and verify:"
    echo -e "${TAB}       ${BL}systemctl start pve-cluster${CL}  ->  ${BL}ls /etc/pve${CL}"
    echo ""
    if [[ -f "$review_dir/etc/corosync/corosync.conf" ]]; then
        echo -e "${TAB}${YW}This archive contains corosync config — node was clustered.${CL}"
        echo -e "${TAB}  In a cluster, a rebuilt node normally resyncs /etc/pve from peers"
        echo -e "${TAB}  once it rejoins. Restore config.db only for a single-node rebuild,"
        echo -e "${TAB}  or when recovering the whole cluster from scratch."
        echo ""
    fi
    echo -e "${TAB}${INFO} Review the files first. Remove ${BL}${review_dir}${CL} when done."
    echo ""
    exit 0
}

# ============================================================
# CORE — build the archive
# ============================================================
ARCHIVE_PATH=""
ARCHIVE_SIZE=""
SKIPPED_PATHS=()

run_backup() {
    echo -e "${TAB}${BL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
    echo ""

    local hostname_s date_s staging
    hostname_s=$(hostname)
    date_s=$(date +%Y-%m-%d-%H%M%S)
    ARCHIVE_PATH="${BACKUP_DEST}/pve-config-${hostname_s}-${date_s}.tar.gz"

    staging=$(mktemp -d /tmp/pve-config-stage-XXXXXX)
    TEMP_FILES+=("$staging")

    local paths=("${BACKUP_PATHS[@]}")
    [[ "$INCLUDE_SHADOW" == true ]] && paths+=("/etc/shadow" "/etc/gshadow")
    [[ "$INCLUDE_SSH_HOST_KEYS" == true ]] && paths+=("/etc/ssh")
    if [[ -f /etc/corosync/corosync.conf ]]; then
        paths+=("/etc/corosync")
    fi
    [[ -n "$EXTRA_PATHS" ]] && paths+=($EXTRA_PATHS)

    msg_info "Staging configuration files"
    SKIPPED_PATHS=()
    local p dest_parent
    for p in "${paths[@]}"; do
        if [[ -e "$p" ]]; then
            dest_parent="${staging}$(dirname "$p")"
            mkdir -p "$dest_parent"
            cp -a "$p" "$dest_parent/" 2>/dev/null || SKIPPED_PATHS+=("$p")
        else
            SKIPPED_PATHS+=("$p")
        fi
    done
    msg_ok "Staged $(( ${#paths[@]} - ${#SKIPPED_PATHS[@]} )) of ${#paths[@]} path(s)"

    if [[ -f /var/lib/pve-cluster/config.db ]]; then
        msg_info "Capturing pmxcfs database (config.db)"
        mkdir -p "${staging}/var/lib/pve-cluster"
        cp -a /var/lib/pve-cluster/config.db "${staging}/var/lib/pve-cluster/" \
            && msg_ok "Captured config.db" \
            || msg_warn "Could not capture config.db"
    fi

    {
        echo "# pve-config-backup manifest — ${hostname_s} — ${date_s}"
        echo "# Generated by ${SCRIPT_NAME} ${SCRIPT_VERSION}"
        echo ""
        echo "## Included paths:"
        for p in "${paths[@]}"; do [[ -e "$p" ]] && echo "  $p"; done
        [[ -f /var/lib/pve-cluster/config.db ]] && echo "  /var/lib/pve-cluster/config.db"
        if [[ ${#SKIPPED_PATHS[@]} -gt 0 ]]; then
            echo ""
            echo "## Skipped (not present on this host):"
            for p in "${SKIPPED_PATHS[@]}"; do echo "  $p"; done
        fi
    } > "${staging}/MANIFEST.txt"

    msg_info "Creating archive"
    local tar_rc=0
    tar czf "$ARCHIVE_PATH" -C "$staging" . 2>/dev/null || tar_rc=$?
    if [[ "$tar_rc" -ge 2 ]]; then
        msg_error "Archive creation failed (tar exit ${tar_rc})"
        rm -f "$ARCHIVE_PATH"
        cleanup
        return 1
    fi

    chmod 600 "$ARCHIVE_PATH"
    ARCHIVE_SIZE=$(du -h "$ARCHIVE_PATH" | cut -f1)
    msg_ok "Archive created: $(basename "$ARCHIVE_PATH") (${ARCHIVE_SIZE}, perms 600)"

    rm -rf "$staging"

    if [[ ${#SKIPPED_PATHS[@]} -gt 0 ]]; then
        msg_warn "Skipped ${#SKIPPED_PATHS[@]} path(s) not present (see MANIFEST.txt in archive)"
    fi

    apply_retention

    push_remote "$ARCHIVE_PATH"
    if [[ -f "$TARGETS_FILE" ]]; then
        echo ""
        echo -e "${TAB}${BL}Exporting to configured targets${CL}"
        echo ""
        export_typed_targets "$ARCHIVE_PATH"
    fi
    return 0
}

# ============================================================
# GUIDED SETUP — one-time, hands-off configuration
# ============================================================

# Write the cron entry for this script with the given schedule expression.
cron_write() {
    local expr="$1"
    local cmd="${SCRIPT_INSTALL_DEST} --cron >> ${LOG_FILE} 2>&1"
    (crontab -l 2>/dev/null | grep -v "${SCRIPT_NAME}"; echo "${expr} ${cmd}") | crontab -
}

# True when an executable copy exists at the canonical path (what cron will run).
installed_ok() { [[ -f "$SCRIPT_INSTALL_DEST" && -x "$SCRIPT_INSTALL_DEST" ]]; }

# Copy this script to the canonical path (chmod 755) so the cron command resolves.
install_self() {
    if [[ "$SCRIPT_PATH" == "$SCRIPT_INSTALL_DEST" ]]; then
        chmod 755 "$SCRIPT_INSTALL_DEST" 2>/dev/null || true
        msg_ok "Already at ${SCRIPT_INSTALL_DEST} (ensured executable)"
        return 0
    fi
    if cp "$SCRIPT_PATH" "$SCRIPT_INSTALL_DEST" 2>/dev/null && chmod 755 "$SCRIPT_INSTALL_DEST"; then
        msg_ok "Installed to ${SCRIPT_INSTALL_DEST} (chmod 755)"
        return 0
    fi
    msg_warn "Could not install to ${SCRIPT_INSTALL_DEST}"
    return 1
}

# One-time startup nudge: if not installed at the canonical path, offer to do it.
# Declining is remembered (won't ask again) and leaves scheduling disabled.
offer_install_at_startup() {
    installed_ok && return 0
    [[ "$INSTALL_NUDGE_DISMISSED" == "1" ]] && return 0
    echo -e "${TAB}${YW}Heads up: this script isn't installed at ${SCRIPT_INSTALL_DEST}.${CL}"
    echo -e "${TAB}Installing it there (the repo's standard location) is what lets the"
    echo -e "${TAB}cron / --schedule feature run unattended. It's a copy + chmod 755."
    echo ""
    read -rp "  Install it there now? [Y/n]: " ans
    if [[ ! "$ans" =~ ^[Nn]$ ]]; then
        install_self || true
    else
        msg_warn "Skipped — scheduling stays disabled until installed. I won't ask again."
        settings_set INSTALL_NUDGE_DISMISSED "1"; INSTALL_NUDGE_DISMISSED="1"
    fi
    echo ""
}

# Guard for scheduling actions: scheduling is disabled until the script is
# installed at the canonical path. Offer to install inline; return non-zero if
# the user declines (caller then skips scheduling).
require_installed_for_schedule() {
    installed_ok && return 0
    echo ""
    msg_warn "Scheduling needs the script at ${SCRIPT_INSTALL_DEST} — cron runs that exact path."
    read -rp "  Install it there now? [Y/n]: " a
    if [[ ! "$a" =~ ^[Nn]$ ]]; then
        if install_self; then
            # Now installed — clear any earlier dismissal so it's a clean state.
            settings_set INSTALL_NUDGE_DISMISSED ""; INSTALL_NUDGE_DISMISSED=""
            return 0
        fi
        return 1
    fi
    msg_warn "Cannot schedule without installing first."
    return 1
}

# First run = nothing configured yet (no targets, no schedule, no archives).
is_first_run() {
    load_targets
    [[ ${#TARGETS[@]} -gt 0 ]] && return 1
    crontab -l 2>/dev/null | grep -q "${SCRIPT_NAME}" && return 1
    local a=("$BACKUP_DEST"/pve-config-*.tar.gz)
    [[ ${#a[@]} -gt 0 ]] && return 1
    return 0
}

guided_setup() {
    header_info
    echo -e "${TAB}${BD}Guided Setup${CL}"
    echo -e "${TAB}A one-time walkthrough. After this, ${SCRIPT_NAME} runs on its own —"
    echo -e "${TAB}the only thing you'll come back for is a restore."
    echo ""
    echo -e "${TAB}${BL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
    echo ""

    # --- Step 1: first backup (always) ---
    echo -e "${TAB}${BD}Step 1 of 4 — Take the first backup${CL}"
    echo ""
    if ! run_backup; then
        msg_error "First backup failed — resolve the issue above, then re-run --setup"
        echo ""
        return 1
    fi
    echo ""

    # --- Step 2: export target (optional) ---
    echo -e "${TAB}${BD}Step 2 of 4 — Offsite copy (optional)${CL}"
    echo -e "${TAB}Copy each backup to an NFS share or SFTP/FTPS server."
    echo ""
    read -rp "  Add an export target now? [y/N]: " a2
    if [[ "$a2" =~ ^[Yy]$ ]]; then
        targets_add
        while true; do
            read -rp "  Add another target? [y/N]: " more
            [[ "$more" =~ ^[Yy]$ ]] || break
            targets_add
        done
    else
        msg_warn "Skipped — you can add targets later with --targets"
    fi
    echo ""

    # --- Step 3: Gotify (optional) ---
    echo -e "${TAB}${BD}Step 3 of 4 — Push notifications (optional)${CL}"
    echo -e "${TAB}Get a Gotify push on each automated run (success/failure)."
    echo ""
    read -rp "  Set up Gotify notifications? [y/N]: " a3
    if [[ "$a3" =~ ^[Yy]$ ]]; then
        local g_url g_tok method
        read -rp "  Gotify server URL (e.g. http://10.0.0.5): " g_url
        read -rsp "  Gotify application token: " g_tok; echo ""
        if [[ -n "$g_url" && -n "$g_tok" ]]; then
            method=$(printf '%s' "$g_tok" | secret_set gotify-token)
            settings_set GOTIFY_URL "$g_url"
            GOTIFY_URL="$g_url"   # for the immediate test
            msg_ok "Token sealed via ${method}; URL saved to ${SETTINGS_FILE}"
            msg_info "Sending a test notification"
            if do_gotify_test; then msg_ok "Test notification delivered"; else msg_error "Test failed — check URL/token; re-run later with --test-notify"; fi
        else
            msg_warn "URL or token blank — skipped"
        fi
    else
        msg_warn "Skipped — set up later with --setup or --set-cred gotify-token"
    fi
    echo ""

    # --- Step 4: schedule (optional) ---
    echo -e "${TAB}${BD}Step 4 of 4 — Automatic schedule (optional)${CL}"
    echo -e "${TAB}  ${GN}1)${CL} Daily at 3:00 AM"
    echo -e "${TAB}  ${GN}2)${CL} Weekly (Sunday 3:00 AM)"
    echo -e "${TAB}  ${GN}3)${CL} Daily at a custom time"
    echo -e "${TAB}  ${RD}s)${CL} Skip scheduling"
    echo ""
    read -rp "  Select [1-3/s]: " a4
    local expr=""
    case "$a4" in
        1) expr="0 3 * * *" ;;
        2) expr="0 3 * * 0" ;;
        3)
            local hh mm
            read -rp "  Hour (0-23): " hh
            read -rp "  Minute (0-59): " mm
            if [[ "$hh" =~ ^[0-9]+$ && "$hh" -le 23 && "$mm" =~ ^[0-9]+$ && "$mm" -le 59 ]]; then
                expr="${mm} ${hh} * * *"
            else
                msg_error "Invalid time — skipping schedule"
            fi ;;
        *) msg_warn "Skipped — schedule later with --schedule" ;;
    esac
    if [[ -n "$expr" ]]; then
        if require_installed_for_schedule; then
            cron_write "$expr"
            msg_ok "Scheduled: ${GN}${expr}${CL}"
        else
            msg_warn "Not scheduled — install the script first, then run --schedule."
        fi
    fi
    echo ""

    # --- Summary ---
    echo -e "${TAB}${BL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
    echo ""
    echo -e "${TAB}${GN}${BD}✓ Setup complete${CL}"
    echo ""
    load_targets
    echo -e "${TAB}${BL}Backups:${CL}      ${BACKUP_DEST} (retention ${RETENTION_DAYS}d)"
    echo -e "${TAB}${BL}Export tgts:${CL}  ${#TARGETS[@]}"
    if gotify_configured; then
        echo -e "${TAB}${BL}Gotify:${CL}       on ($(secret_method gotify-token))"
    else
        echo -e "${TAB}${BL}Gotify:${CL}       off"
    fi
    local cl; cl=$(crontab -l 2>/dev/null | grep "${SCRIPT_NAME}" || true)
    if [[ -n "$cl" ]]; then
        echo -e "${TAB}${BL}Schedule:${CL}     ${cl%% /*} (automatic)"
        echo ""
        echo -e "${TAB}${GN}You're done — it runs on its own from here.${CL}"
        echo -e "${TAB}The only thing you'll need again is ${BL}${SCRIPT_NAME} --restore <file>${CL}."
    else
        echo -e "${TAB}${BL}Schedule:${CL}     ${YW}not scheduled${CL} (run manually or add later with --schedule)"
    fi
    echo ""
    return 0
}

# ============================================================
# MAIN
# ============================================================
ARGS=("${@:-}")

# Apply any whitelisted settings written by --setup (e.g. GOTIFY_URL) before use.
load_settings

i=0
while [[ $i -lt ${#ARGS[@]} ]]; do
    case "${ARGS[$i]:-}" in
        --help|-h) show_help ;;
        --version|-V) echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"; echo "${SCRIPT_URL}"; exit 0 ;;
        --status) show_status ;;
        --list) list_backups ;;
        --test-notify) test_gotify ;;
        --schedule) manage_cron ;;
        --set-cred)
            if [[ $EUID -ne 0 ]]; then header_info; msg_error "Sealing a credential must be run as root (use sudo)"; exit 1; fi
            cred_name="${ARGS[$((i+1))]:-}"
            [[ -z "$cred_name" ]] && { header_info; msg_error "--set-cred requires a name (e.g. gotify-token)"; exit 1; }
            # Read from stdin (pipe/automation) or prompt hidden if attached to a TTY.
            if [[ -t 0 ]]; then
                read -rsp "Enter value for '${cred_name}': " _v; echo "" >&2
                method=$(printf '%s' "$_v" | secret_set "$cred_name")
            else
                method=$(secret_set "$cred_name")
            fi
            echo "Sealed '${cred_name}' via ${method}" >&2
            exit 0 ;;
        --targets)
            if [[ $EUID -ne 0 ]]; then header_info; msg_error "Managing targets must be run as root (use sudo)"; exit 1; fi
            INTERACTIVE=true
            manage_targets
            echo ""
            exit 0 ;;
        --restore)
            if [[ $EUID -ne 0 ]]; then header_info; msg_error "Restore must be run as root (use sudo)"; exit 1; fi
            restore_file="${ARGS[$((i+1))]:-}"
            [[ -z "$restore_file" ]] && { header_info; msg_error "--restore requires a path to an archive"; exit 1; }
            restore_backup "$restore_file"
            ;;
    esac
    i=$((i + 1))
done

header_info

if [[ $EUID -ne 0 ]]; then
    msg_error "This script must be run as root (use sudo)"
    exit 1
fi

AUTO_YES=false
INTERACTIVE=true
SETUP=false
for arg in "${ARGS[@]:-}"; do
    case "${arg:-}" in
        --yes|-y|--cron) AUTO_YES=true; INTERACTIVE=false ;;
        --setup) SETUP=true ;;
    esac
done

preflight_checks

# One-time nudge to install at the canonical path (interactive runs only).
if [[ "$INTERACTIVE" == true ]]; then
    offer_install_at_startup
fi

# Explicit --setup, or auto-offer on a clean first run.
if [[ "$SETUP" == true ]]; then
    guided_setup
    exit $?
fi
if [[ "$INTERACTIVE" == true ]] && is_first_run; then
    echo -e "${TAB}${YW}Looks like a fresh setup — nothing is configured yet.${CL}"
    read -rp "  Run the guided one-time setup now? [Y/n]: " fr
    if [[ ! "$fr" =~ ^[Nn]$ ]]; then
        guided_setup
        exit $?
    fi
    echo ""
fi

if [[ "$INTERACTIVE" == true ]]; then
    echo -e "${TAB}${BL}What would you like to do?${CL}"
    echo ""
    echo -e "${TAB}  ${GN}1)${CL} Run a configuration backup now"
    echo -e "${TAB}  ${GN}2)${CL} List existing archives"
    echo -e "${TAB}  ${GN}3)${CL} Restore from an archive (guided)"
    echo -e "${TAB}  ${GN}4)${CL} Manage export targets (NFS / SFTP / FTPS)"
    echo -e "${TAB}  ${GN}5)${CL} Test Gotify notification"
    echo -e "${TAB}  ${GN}6)${CL} Manage cron schedule"
    echo -e "${TAB}  ${GN}7)${CL} Guided setup (backup + export + Gotify + schedule)"
    echo -e "${TAB}  ${RD}q)${CL} Quit"
    echo ""
    read -rp "  Select an option [1-7/q]: " choice
    case "$choice" in
        1) ;;
        2) list_backups ;;
        3)
            read -rp "  Path to archive: " rfile
            [[ -z "$rfile" ]] && { msg_error "No path given"; exit 1; }
            restore_backup "$rfile"
            ;;
        4) manage_targets; echo ""; exit 0 ;;
        5) test_gotify ;;
        6) manage_cron ;;
        7) guided_setup; exit $? ;;
        q|Q) echo ""; msg_ok "Exiting. No changes made."; echo ""; exit 0 ;;
        *) msg_error "Invalid option"; exit 1 ;;
    esac
    echo ""
fi

if run_backup; then
    echo ""
    echo -e "${TAB}${GN}✓ Backup complete!${CL}"
    echo -e "${TAB}  ${BL}${ARCHIVE_PATH}${CL} (${ARCHIVE_SIZE})"
    echo ""

    if [[ "$AUTO_YES" == true ]]; then
        skipped_note=""
        [[ ${#SKIPPED_PATHS[@]} -gt 0 ]] && skipped_note="**Skipped:** ${#SKIPPED_PATHS[@]} path(s) not present
"
        send_gotify "🔔 ${SCRIPT_NAME} — $(hostname)" "### 🟢 Config Backup Complete

**Host:** \`$(hostname)\`
**Archive:** \`$(basename "$ARCHIVE_PATH")\`
**Size:** ${ARCHIVE_SIZE}
**Time:** $(date '+%Y-%m-%d %H:%M:%S')
${skipped_note}
*Host configuration captured (perms 600).*"
    fi
    cleanup
    exit 0
else
    echo ""
    msg_error "Backup failed — see output above"
    echo ""
    if [[ "$AUTO_YES" == true ]]; then
        send_gotify "🔔 ${SCRIPT_NAME} — $(hostname)" "### 🔴 Config Backup FAILED

**Host:** \`$(hostname)\`
**Time:** $(date '+%Y-%m-%d %H:%M:%S')

*The host configuration backup did not complete. Check \`${LOG_FILE}\`.*" 8
    fi
    cleanup
    exit 1
fi