#!/usr/bin/env bash

# <SCRIPT TITLE> — <one-line description>
# https://github.com/SunBroLynk/Proxmox-Scripts
# License: MIT
#
# <Longer description of what this does and why.>
# <Which environment it targets: inside a VM/LXC, or on a Proxmox host.>

# ============================================================
# CONFIGURATION — adjust these for your setup
# ============================================================
EXAMPLE_TARGET="192.168.1.2"          # <description> (generic placeholder, never real values)
EXAMPLE_USER="root"                   # <description>
EXAMPLE_TIMEOUT=5                     # <description>
# --- Gotify (optional — leave blank to disable notifications) ---
GOTIFY_URL=""                         # Gotify server URL (e.g. http://10.0.0.5:80)
GOTIFY_TOKEN=""                       # Gotify application token
GOTIFY_PRIORITY=5                     # Notification priority (1-10)
LOG_FILE="/var/log/<script-name>.log"  # Log file for cron mode
# ============================================================

set -euo pipefail
shopt -s inherit_errexit nullglob

# Script metadata
SCRIPT_NAME="<script-name>"
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
trap 'echo -e "\n\n${TAB}${YW}⚠  Cancelled by user. No changes made.${CL}\n"; cleanup; exit 0' SIGINT SIGTERM

# Temp files tracking (if the script creates any)
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

<REPLACE WITH SCRIPT-SPECIFIC ASCII ART (4-5 lines)>
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
    echo -e "${TAB}${SCRIPT_NAME} — <one-line description>"
    echo ""
    echo -e "${BD}SYNOPSIS${CL}"
    echo -e "${TAB}${SCRIPT_NAME} [${BL}OPTIONS${CL}]"
    echo ""
    echo -e "${BD}DESCRIPTION${CL}"
    echo -e "${TAB}<What it does, multiple lines as needed.>"
    echo ""
    echo -e "${BD}OPTIONS${CL}"
    echo -e "${TAB}${GN}(no arguments)${CL}"
    echo -e "${TAB}${TAB}Launch interactive mode with guided menu."
    echo ""
    echo -e "${TAB}${GN}-y, --yes${CL}"
    echo -e "${TAB}${TAB}Run without prompts (for cron)."
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
    # Dynamic config table with line numbers (see PATTERNS.md). Adjust the
    # grep -v exclusion list to match the non-config UPPERCASE vars in YOUR script.
    echo -e "${TAB}${BD}Variable                    Line  Current Value${CL}"
    echo -e "${TAB}──────────────────────────  ────  ─────────────────────────"
    while IFS= read -r line; do
        local linenum var val
        linenum=$(echo "$line" | cut -d: -f1)
        var=$(echo "$line" | cut -d: -f2- | cut -d= -f1 | xargs)
        val=$(echo "$line" | cut -d= -f2- | tr -d '"')
        printf "${TAB}${GN}%-28s${CL}${YW}%-6s${CL}%s\n" "$var" "$linenum" "$val"
    done < <(grep -n '^[A-Z_]*=' "$SCRIPT_PATH" | grep -v '^#' | grep -v 'SCRIPT_\|^[0-9]*:set \|^[0-9]*:shopt \|^[0-9]*:RD=\|^[0-9]*:YW=\|^[0-9]*:GN=\|^[0-9]*:BL=\|^[0-9]*:BD=\|^[0-9]*:CL=\|^[0-9]*:BFR=\|^[0-9]*:CM=\|^[0-9]*:CROSS=\|^[0-9]*:INFO=\|^[0-9]*:TAB=\|^[0-9]*:TEMP_FILES\|INTERACTIVE\|AUTO_YES\|DRY_RUN' | head -10)
    echo ""
    echo -e "${BD}FILES${CL}"
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
    echo -e "${TAB}  ${BL}sudo ${SCRIPT_NAME} -y >> ${LOG_FILE} 2>&1${CL}"
    echo ""
    echo -e "${BD}SEE ALSO${CL}"
    echo -e "${TAB}Project repo:  ${BL}${SCRIPT_URL}${CL}"
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
# CRON SCHEDULE MANAGER
# ============================================================
manage_cron() {
    header_info
    echo -e "${TAB}${BD}Schedule Manager${CL}"
    echo ""
    local CRON_CMD="/usr/local/bin/${SCRIPT_NAME} -y >> ${LOG_FILE} 2>&1"
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
    echo -e "${TAB}  ${GN}3)${CL} Every 6 hours"
    echo -e "${TAB}  ${GN}4)${CL} Every hour"
    echo -e "${TAB}  ${GN}5)${CL} Every 5 minutes"
    echo -e "${TAB}  ${GN}6)${CL} Custom cron expression"
    echo -e "${TAB}  ${RD}q)${CL} Cancel"
    echo ""
    read -rp "  Select [1-6/q]: " schedule_choice
    local CRON_SCHEDULE=""
    case "$schedule_choice" in
        1) CRON_SCHEDULE="0 3 * * *" ;;
        2)
            read -rp "  Hour (0-23): " cron_hour
            read -rp "  Minute (0-59): " cron_min
            [[ "$cron_hour" =~ ^[0-9]+$ && "$cron_hour" -le 23 ]] || { msg_error "Invalid hour"; exit 1; }
            [[ "$cron_min" =~ ^[0-9]+$ && "$cron_min" -le 59 ]] || { msg_error "Invalid minute"; exit 1; }
            CRON_SCHEDULE="${cron_min} ${cron_hour} * * *" ;;
        3) CRON_SCHEDULE="0 */6 * * *" ;;
        4) CRON_SCHEDULE="0 * * * *" ;;
        5) CRON_SCHEDULE="*/5 * * * *" ;;
        6) read -rp "  Cron expression: " CRON_SCHEDULE; [[ -z "$CRON_SCHEDULE" ]] && { msg_error "No expression"; exit 1; } ;;
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
# PREFLIGHT CHECKS
# ============================================================
preflight_checks() {
    echo -e "${TAB}${BL}Preflight Checks${CL}"
    echo ""
    local CRITICAL=false

    # Example: check required commands exist
    for dep in curl; do
        if command -v "$dep" &>/dev/null; then
            msg_ok "${dep} installed"
        else
            msg_error "${dep} not found"
            CRITICAL=true
        fi
    done

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
# CORE LOGIC — replace with the script's actual work
# ============================================================
do_work() {
    msg_info "Doing the thing"
    # ... actual logic here ...
    msg_ok "Done"
}

# ============================================================
# MAIN
# ============================================================

# Early exit for help, version, and read-only info flags
for arg in "${@:-}"; do
    case "${arg:-}" in
        --help|-h) show_help ;;
        --version|-V) echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"; echo "${SCRIPT_URL}"; exit 0 ;;
        --test-notify) test_gotify ;;
        --schedule) manage_cron ;;
    esac
done

header_info

# Root check (remove if the script doesn't need root)
if [[ $EUID -ne 0 ]]; then
    msg_error "This script must be run as root (use sudo)"
    exit 1
fi

# Parse flags
AUTO_YES=false
INTERACTIVE=true
for arg in "${@:-}"; do
    case "${arg:-}" in
        --yes|-y) AUTO_YES=true; INTERACTIVE=false ;;
    esac
done

# Preflight
preflight_checks

# Interactive menu
if [[ "$INTERACTIVE" == true ]]; then
    echo -e "${TAB}${BL}What would you like to do?${CL}"
    echo ""
    echo -e "${TAB}  ${GN}1)${CL} Run the main action"
    echo -e "${TAB}  ${GN}2)${CL} Test Gotify notification"
    echo -e "${TAB}  ${GN}3)${CL} Manage cron schedule"
    echo -e "${TAB}  ${RD}q)${CL} Quit"
    echo ""
    read -rp "  Select an option [1-3/q]: " choice
    case "$choice" in
        1) ;;
        2) test_gotify ;;
        3) manage_cron ;;
        q|Q) echo ""; msg_ok "Exiting. No changes made."; echo ""; exit 0 ;;
        *) msg_error "Invalid option"; exit 1 ;;
    esac
    echo ""
fi

echo -e "${TAB}${BL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
echo ""

# Do the work
do_work

# Summary + optional notification (only in automated mode)
echo ""
echo -e "${TAB}${GN}✓ Complete!${CL}"
echo ""

if [[ "$AUTO_YES" == true ]]; then
    send_gotify "🔔 ${SCRIPT_NAME} — $(hostname)" "### 🟢 Run Complete

**Host:** \`$(hostname)\`
**Time:** $(date '+%Y-%m-%d %H:%M:%S')

*Automated run via cron.*"
fi

cleanup
