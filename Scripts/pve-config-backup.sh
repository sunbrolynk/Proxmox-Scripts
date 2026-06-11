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

# ============================================================
# CONFIGURATION — adjust these for your setup
# ============================================================
BACKUP_DEST="/var/backups/pve-config"   # Local directory to store archives
RETENTION_DAYS=30                       # Delete our own archives older than N days (0 = keep all)
REMOTE_TARGETS=""                       # Optional space-separated scp targets, key-based auth
                                        #   e.g. "root@192.168.1.10:/mnt/backup root@192.168.1.11:/mnt/backup"
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
SCRIPT_VERSION="1.0.0"
SCRIPT_URL="https://github.com/SunBroLynk/Proxmox-Scripts"
SCRIPT_PATH="$(readlink -f "$0")"

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

# Temp tracking — populated as we create staging dirs / partial archives so the
# CTRL+C trap and normal cleanup can remove them.
TEMP_FILES=()

cleanup() {
    for f in "${TEMP_FILES[@]:-}"; do
        rm -rf "$f" 2>/dev/null
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
    echo -e "${BD}OPTIONS${CL}"
    echo -e "${TAB}${GN}(no arguments)${CL}"
    echo -e "${TAB}${TAB}Launch interactive mode with guided menu."
    echo ""
    echo -e "${TAB}${GN}-y, --yes, --cron${CL}"
    echo -e "${TAB}${TAB}Run a backup without prompts (for cron). Fires Gotify if configured."
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
    echo -e "${TAB}${BD}Variable                    Line  Current Value${CL}"
    echo -e "${TAB}──────────────────────────  ────  ─────────────────────────"
    # Dynamic config table: show only the user-facing scalar CONFIG vars, with the
    # line each lives on. Exclusions drop the manifest array, color/meta vars, and
    # internal runtime flags so the table stays focused on what's safe to edit.
    while IFS= read -r line; do
        local linenum var val
        linenum=$(echo "$line" | cut -d: -f1)
        var=$(echo "$line" | cut -d: -f2- | cut -d= -f1 | xargs)
        # Value is everything after the first '=', minus any trailing inline
        # comment and surrounding quotes/space, so the column stays clean.
        val=$(echo "$line" | cut -d= -f2- | sed 's/[[:space:]]*#.*$//' | tr -d '"' | xargs)
        printf "${TAB}${GN}%-28s${CL}${YW}%-6s${CL}%s\n" "$var" "$linenum" "$val"
    done < <(grep -n '^[A-Z_]*=' "$SCRIPT_PATH" \
        | grep -v 'SCRIPT_\|BACKUP_PATHS\|ARCHIVE_PATH\|ARCHIVE_SIZE\|SKIPPED_PATHS\|^[0-9]*:ARGS=\|^[0-9]*:RD=\|^[0-9]*:YW=\|^[0-9]*:GN=\|^[0-9]*:BL=\|^[0-9]*:BD=\|^[0-9]*:CL=\|^[0-9]*:BFR=\|^[0-9]*:CM=\|^[0-9]*:CROSS=\|^[0-9]*:INFO=\|^[0-9]*:TAB=\|^[0-9]*:TEMP_FILES\|INTERACTIVE\|AUTO_YES' \
        | head -12)
    echo ""
    echo -e "${BD}FILES${CL}"
    echo -e "${TAB}${BL}${BACKUP_DEST}/${CL}"
    echo -e "${TAB}${TAB}Archive destination (pve-config-<hostname>-<date>.tar.gz)."
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
# GOTIFY (secure — token never in process args)
# ============================================================
send_gotify() {
    local title="$1" message="$2" priority="${3:-$GOTIFY_PRIORITY}"
    [[ -z "$GOTIFY_URL" || -z "$GOTIFY_TOKEN" ]] && return 0

    local json_message curl_conf
    json_message=$(echo "$message" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null || echo "\"${message}\"")
    # Token goes in a chmod-600 curl config header, NOT the URL — a ?token= query
    # string would leak in `ps aux` to any local user.
    curl_conf=$(mktemp /tmp/.gotify-XXXXXX); chmod 600 "$curl_conf"
    cat > "$curl_conf" <<CURLEOF
header = "X-Gotify-Key: ${GOTIFY_TOKEN}"
header = "Content-Type: application/json"
CURLEOF
    curl -s -K "$curl_conf" -X POST "${GOTIFY_URL}/message" \
        -d "{\"title\":\"${title}\",\"message\":${json_message},\"priority\":${priority},\"extras\":{\"client::display\":{\"contentType\":\"text/markdown\"}}}" &>/dev/null || true
    rm -f "$curl_conf"
}

test_gotify() {
    header_info
    echo -e "${TAB}${BD}Gotify Notification Test${CL}"
    echo ""
    [[ -z "$GOTIFY_URL" ]] && { msg_error "GOTIFY_URL not configured"; echo ""; exit 1; }
    [[ -z "$GOTIFY_TOKEN" ]] && { msg_error "GOTIFY_TOKEN not configured"; echo ""; exit 1; }

    local test_message="### ✅ Connection Successful

**Script:** \`${SCRIPT_NAME}\`
**Host:** \`$(hostname)\`
**Time:** $(date '+%Y-%m-%d %H:%M:%S')

---

*${SCRIPT_NAME} is configured and ready to send alerts.*"

    msg_info "Sending test notification to ${GOTIFY_URL}"
    local curl_conf json_message response
    curl_conf=$(mktemp /tmp/.gotify-XXXXXX); chmod 600 "$curl_conf"
    cat > "$curl_conf" <<CURLEOF
header = "X-Gotify-Key: ${GOTIFY_TOKEN}"
header = "Content-Type: application/json"
CURLEOF
    json_message=$(echo "$test_message" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null)
    response=$(curl -s -o /dev/null -w "%{http_code}" -K "$curl_conf" -X POST "${GOTIFY_URL}/message" \
        -d "{\"title\":\"🔔 ${SCRIPT_NAME} — Test\",\"message\":${json_message},\"priority\":${GOTIFY_PRIORITY},\"extras\":{\"client::display\":{\"contentType\":\"text/markdown\"}}}" 2>/dev/null)
    rm -f "$curl_conf"

    if [[ "$response" == "200" ]]; then
        msg_ok "Test notification sent successfully"
    else
        msg_error "Notification failed (HTTP ${response})"
    fi
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
# ENVIRONMENT / PREFLIGHT
# ============================================================
preflight_checks() {
    echo -e "${TAB}${BL}Preflight Checks${CL}"
    echo ""
    local CRITICAL=false

    # This script is host-targeted: bail clearly if it's not a PVE node.
    if command -v pveversion &>/dev/null && [[ -d /etc/pve ]]; then
        msg_ok "Proxmox VE host detected ($(pveversion 2>/dev/null | head -1))"
    else
        msg_error "Not a Proxmox VE host (no pveversion / /etc/pve) — run this on a node"
        CRITICAL=true
    fi

    # Required tools.
    for dep in tar gzip; do
        if command -v "$dep" &>/dev/null; then
            msg_ok "${dep} installed"
        else
            msg_error "${dep} not found"
            CRITICAL=true
        fi
    done

    # The pmxcfs backing database is the single most important file for a host
    # rebuild — warn loudly if it's missing rather than silently skipping it.
    if [[ -f /var/lib/pve-cluster/config.db ]]; then
        msg_ok "pmxcfs database present (config.db)"
    else
        msg_warn "config.db not found — archive will exclude the pmxcfs database"
    fi

    # Destination must exist and be writable; offer to create it interactively.
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
            # Non-interactive (cron): create it without prompting so jobs don't stall.
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
        # nullglob (set at top) means this yields an empty array if nothing matches.
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
    if [[ -n "$REMOTE_TARGETS" ]]; then
        echo -e "${TAB}${BL}Remote:${CL}      ${REMOTE_TARGETS}"
    else
        echo -e "${TAB}${BL}Remote:${CL}      ${YW}none configured${CL}"
    fi

    local cron_line
    cron_line=$(crontab -l 2>/dev/null | grep "${SCRIPT_NAME}" || true)
    if [[ -n "$cron_line" ]]; then
        echo -e "${TAB}${BL}Schedule:${CL}    ${cron_line%% /*}"
    else
        echo -e "${TAB}${BL}Schedule:${CL}    ${YW}not scheduled${CL}"
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
    # Newest first.
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
    # Show top-level structure so the user can see what's available to restore.
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
    echo -e "${TAB}       ${BL}systemctl start pve-cluster${CL}  →  ${BL}ls /etc/pve${CL}"
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
# RETENTION (prefix-scoped — never a blind rm)
# ============================================================
apply_retention() {
    [[ "$RETENTION_DAYS" -le 0 ]] && return 0
    local removed=0
    # Only ever match OUR own archive naming pattern inside the dest dir. We never
    # recurse, follow symlinks, or touch anything not produced by this script.
    while IFS= read -r -d '' old; do
        rm -f "$old" && removed=$((removed + 1))
    done < <(find "$BACKUP_DEST" -maxdepth 1 -type f \
                -name 'pve-config-*.tar.gz' \
                -mtime +"$RETENTION_DAYS" -print0 2>/dev/null)
    [[ "$removed" -gt 0 ]] && msg_ok "Retention: removed ${removed} archive(s) older than ${RETENTION_DAYS} days"
    return 0
}

# ============================================================
# PUSH TO REMOTE TARGET(S) — parallel when more than one
# ============================================================
scp_one() {
    local archive="$1" target="$2"
    # BatchMode so a missing key fails fast instead of hanging on a password prompt.
    scp -q -o BatchMode=yes -o ConnectTimeout=10 "$archive" "$target/" 2>/dev/null
}

push_remote() {
    local archive="$1"
    [[ -z "$REMOTE_TARGETS" ]] && return 0
    echo ""
    echo -e "${TAB}${BL}Replicating to remote target(s)${CL}"
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
        # Independent destinations → fan out; all finish in the time of the slowest.
        local results pids=()
        results=$(mktemp -d /tmp/.pve-cfg-scp-XXXXXX)
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
# CORE — build the archive
# ============================================================
# Set by run_backup so the summary/notification can report results.
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

    # Stage a copy first, then tar the staging dir. Copying off the live pmxcfs
    # mount avoids "file changed as we read it" races and gives one clean archive.
    # mktemp -d is 700; cp -a preserves perms so secrets stay 600/640 inside.
    staging=$(mktemp -d /tmp/pve-config-stage-XXXXXX)
    TEMP_FILES+=("$staging")

    # Assemble the effective manifest from defaults + toggles + user extras.
    local paths=("${BACKUP_PATHS[@]}")
    [[ "$INCLUDE_SHADOW" == true ]] && paths+=("/etc/shadow" "/etc/gshadow")
    [[ "$INCLUDE_SSH_HOST_KEYS" == true ]] && paths+=("/etc/ssh")
    if [[ -f /etc/corosync/corosync.conf ]]; then
        paths+=("/etc/corosync")   # Only meaningful on clustered nodes
    fi
    [[ -n "$EXTRA_PATHS" ]] && paths+=($EXTRA_PATHS)

    msg_info "Staging configuration files"
    SKIPPED_PATHS=()
    local p dest_parent
    for p in "${paths[@]}"; do
        if [[ -e "$p" ]]; then
            dest_parent="${staging}$(dirname "$p")"
            mkdir -p "$dest_parent"
            # cp -a: archive mode preserves ownership, perms, timestamps, symlinks.
            cp -a "$p" "$dest_parent/" 2>/dev/null || SKIPPED_PATHS+=("$p")
        else
            SKIPPED_PATHS+=("$p")
        fi
    done
    msg_ok "Staged $(( ${#paths[@]} - ${#SKIPPED_PATHS[@]} )) of ${#paths[@]} path(s)"

    # The pmxcfs backing database — the single most important file for a rebuild.
    if [[ -f /var/lib/pve-cluster/config.db ]]; then
        msg_info "Capturing pmxcfs database (config.db)"
        mkdir -p "${staging}/var/lib/pve-cluster"
        cp -a /var/lib/pve-cluster/config.db "${staging}/var/lib/pve-cluster/" \
            && msg_ok "Captured config.db" \
            || msg_warn "Could not capture config.db"
    fi

    # Record what was skipped, inside the archive, so a future restore knows.
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
    # tar from the staging root. Exit 1 = "some files differed" (benign here since
    # we already copied to a static staging dir); exit 2 = fatal. Treat only 2 as error.
    local tar_rc=0
    tar czf "$ARCHIVE_PATH" -C "$staging" . 2>/dev/null || tar_rc=$?
    if [[ "$tar_rc" -ge 2 ]]; then
        msg_error "Archive creation failed (tar exit ${tar_rc})"
        rm -f "$ARCHIVE_PATH"
        cleanup
        return 1
    fi

    # The archive aggregates password hashes and SSH host keys — lock it down.
    chmod 600 "$ARCHIVE_PATH"
    ARCHIVE_SIZE=$(du -h "$ARCHIVE_PATH" | cut -f1)
    msg_ok "Archive created: $(basename "$ARCHIVE_PATH") (${ARCHIVE_SIZE}, perms 600)"

    # Clean staging immediately — no need to keep secrets in /tmp longer than necessary.
    rm -rf "$staging"

    if [[ ${#SKIPPED_PATHS[@]} -gt 0 ]]; then
        msg_warn "Skipped ${#SKIPPED_PATHS[@]} path(s) not present (see MANIFEST.txt in archive)"
    fi

    apply_retention
    push_remote "$ARCHIVE_PATH"
    return 0
}

# ============================================================
# MAIN
# ============================================================

# Early exit for help, version, and read-only / guided info flags. These run
# before the root check and any work, matching the repo flow pattern.
ARGS=("${@:-}")
i=0
while [[ $i -lt ${#ARGS[@]} ]]; do
    case "${ARGS[$i]:-}" in
        --help|-h) show_help ;;
        --version|-V) echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"; echo "${SCRIPT_URL}"; exit 0 ;;
        --status) show_status ;;
        --list) list_backups ;;
        --test-notify) test_gotify ;;
        --schedule) manage_cron ;;
        --restore)
            # restore needs root to read the archive and write to /root — defer the
            # root check to after extraction-path setup is trivial; enforce here.
            if [[ $EUID -ne 0 ]]; then header_info; msg_error "Restore must be run as root (use sudo)"; exit 1; fi
            restore_file="${ARGS[$((i+1))]:-}"
            [[ -z "$restore_file" ]] && { header_info; msg_error "--restore requires a path to an archive"; exit 1; }
            restore_backup "$restore_file"
            ;;
    esac
    i=$((i + 1))
done

header_info

# Root check — needs to read /etc/shadow, config.db, and write to system dirs.
if [[ $EUID -ne 0 ]]; then
    msg_error "This script must be run as root (use sudo)"
    exit 1
fi

# Parse action flags.
AUTO_YES=false
INTERACTIVE=true
for arg in "${ARGS[@]:-}"; do
    case "${arg:-}" in
        --yes|-y|--cron) AUTO_YES=true; INTERACTIVE=false ;;
    esac
done

preflight_checks

# Interactive menu — every flag is mirrored here, and vice versa.
if [[ "$INTERACTIVE" == true ]]; then
    echo -e "${TAB}${BL}What would you like to do?${CL}"
    echo ""
    echo -e "${TAB}  ${GN}1)${CL} Run a configuration backup now"
    echo -e "${TAB}  ${GN}2)${CL} List existing archives"
    echo -e "${TAB}  ${GN}3)${CL} Restore from an archive (guided)"
    echo -e "${TAB}  ${GN}4)${CL} Test Gotify notification"
    echo -e "${TAB}  ${GN}5)${CL} Manage cron schedule"
    echo -e "${TAB}  ${RD}q)${CL} Quit"
    echo ""
    read -rp "  Select an option [1-5/q]: " choice
    case "$choice" in
        1) ;;
        2) list_backups ;;
        3)
            read -rp "  Path to archive: " rfile
            [[ -z "$rfile" ]] && { msg_error "No path given"; exit 1; }
            restore_backup "$rfile"
            ;;
        4) test_gotify ;;
        5) manage_cron ;;
        q|Q) echo ""; msg_ok "Exiting. No changes made."; echo ""; exit 0 ;;
        *) msg_error "Invalid option"; exit 1 ;;
    esac
    echo ""
fi

# Do the backup.
if run_backup; then
    echo ""
    echo -e "${TAB}${GN}✓ Backup complete!${CL}"
    echo -e "${TAB}  ${BL}${ARCHIVE_PATH}${CL} (${ARCHIVE_SIZE})"
    echo ""

    # Notify only in automated mode, never interactively (matches repo convention).
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