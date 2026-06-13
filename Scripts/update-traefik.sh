#!/usr/bin/env bash

# Traefik & Traefik Manager Update Script
# https://github.com/SunBroLynk/Proxmox-Scripts
# License: MIT
# Styled after Proxmox VE Community Scripts

# ============================================================
# CONFIGURATION
# ============================================================
# You can configure this script two ways:
#   • Run the guided setup:  update-traefik --setup   (recommended; seals secrets for you)
#   • Or edit the values below directly (power users)
# Either way works — the script detects whichever you've used.
# ------------------------------------------------------------

# --- Traefik & Manager paths/services (defaults match a standard install) ---
TRAEFIK_BIN="/usr/local/bin/traefik"            # Traefik binary location
TRAEFIK_SERVICE="traefik-proxy"                 # systemd service name for Traefik
TRAEFIK_MANAGER_DIR="/opt/traefik-manager"      # Traefik Manager install dir (git repo)
TRAEFIK_MANAGER_USER="traefik-manager"          # User that owns/runs the Manager
TRAEFIK_MANAGER_SERVICE="traefik-manager"       # systemd service name for the Manager
TRAEFIK_MANAGER_PORT="5000"                     # Manager web port
TRAEFIK_MANAGER_REPO="chr0nzz/traefik-manager"  # GitHub repo for the Manager
TRAEFIK_DASHBOARD_PORT="8080"                   # Traefik dashboard port
TRAEFIK_ARCH="linux_amd64"                       # Release arch (linux_amd64 / linux_arm64)

# --- Tunable: minimum-resource thresholds for preflight ------
MIN_DISK_MB=500                       # Abort update if free disk below this
MIN_MEM_MB=256                        # Warn/abort if available memory below this
MIN_PYTHON="3.9"                      # Minimum Python for the Manager

# --- Optional: Gotify notifications (cron mode) --------------
# Leave the token empty here and seal it instead:  update-traefik --set-cred gotify-token
GOTIFY_URL=""                         # Gotify server URL (e.g. http://10.10.3.6:80)
GOTIFY_TOKEN=""                       # Gotify token (prefer --set-cred over plaintext here)
GOTIFY_PRIORITY=5                     # Notification priority (1-10)
LOG_FILE="/var/log/update-traefik.log"  # Log file for cron mode
# ============================================================

set -euo pipefail
shopt -s inherit_errexit nullglob

# Script metadata
SCRIPT_NAME="update-traefik"
SCRIPT_VERSION="1.3.0"
SCRIPT_URL="https://github.com/SunBroLynk/Proxmox-Scripts"
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_INSTALL_DEST="/usr/local/bin/${SCRIPT_NAME}"

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
HOLD="-"
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"
INFO="${BL}ℹ${CL}"
TAB="  "

# Trap CTRL+C
trap 'echo -e "\n\n${TAB}${YW}⚠  Update cancelled by user. No changes made.${CL}\n"; cleanup; exit 0' SIGINT SIGTERM

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

   ______                _____ __
  /_  __/________ ____  / __(_) /__
   / / / ___/ __ `/ _ \/ /_/ / //_/
  / / / /  / /_/ /  __/ __/ / ,<
 /_/ /_/   \__,_/\___/_/ /_/_/|_|
     & Traefik Manager Updater
EOF
    echo ""
}

show_help() {
    header_info
    cat <<HELP
${BD}NAME${CL}
${TAB}${SCRIPT_NAME} — update Traefik reverse proxy and Traefik Manager

${BD}SYNOPSIS${CL}
${TAB}${SCRIPT_NAME} [${BL}OPTIONS${CL}] [${BL}VERSION${CL}]

${BD}DESCRIPTION${CL}
${TAB}Interactive update script for Traefik and Traefik Manager.
${TAB}Performs environment and dependency checks, downloads the latest
${TAB}stable release (or a specified version), creates a backup, and
${TAB}automatically rolls back if the update fails.
${TAB}
${TAB}Both Traefik and Traefik Manager are updated to their latest
${TAB}tagged releases, not bleeding-edge commits. This ensures
${TAB}compatibility with each application's internal version checks.

${BD}OPTIONS${CL}
${TAB}${GN}(no arguments)${CL}
${TAB}${TAB}Launch interactive mode with guided menu.

${TAB}${GN}-y, --yes${CL}
${TAB}${TAB}Update all components without prompts.

${TAB}${GN}v<VERSION>${CL}  (e.g. v3.7.0)
${TAB}${TAB}Update Traefik to a specific version.

${TAB}${GN}--traefik-only${CL}
${TAB}${TAB}Update Traefik binary only, skip Traefik Manager.

${TAB}${GN}--manager-only${CL}
${TAB}${TAB}Update Traefik Manager only, skip Traefik binary.

${TAB}${GN}--check${CL}
${TAB}${TAB}Show current vs latest versions and exit without updating.

${TAB}${GN}--insecure-skip-checksum${CL}
${TAB}${TAB}Proceed even if the SHA256 checksum can't be fetched/verified.
${TAB}${TAB}NOT recommended — only for offline mirrors or known-good environments.
${TAB}${TAB}A checksum MISMATCH still always aborts; this only bypasses a MISSING checksum.

${TAB}${GN}--rollback${CL}
${TAB}${TAB}Restore previous Traefik binary from backup (.bak file).

${TAB}${GN}--changelog${CL}
${TAB}${TAB}Show release notes for the latest (or specified) version.

${TAB}${GN}--cron${CL}
${TAB}${TAB}Automated mode for scheduled runs. Updates all components
${TAB}${TAB}without prompts and sends a Gotify notification with results.

${TAB}${GN}--setup${CL}
${TAB}${TAB}Guided setup wizard — walks Traefik/Manager paths, services, ports,
${TAB}${TAB}thresholds, Gotify (sealing the token), and scheduling. Auto-offered
${TAB}${TAB}on first run. Re-runnable.

${TAB}${GN}--set-cred ${BL}<name>${CL}
${TAB}${TAB}Seal a secret (e.g. gotify-token) read from stdin via systemd-creds.

${TAB}${GN}--test-notify${CL}
${TAB}${TAB}Send a test notification to Gotify.

${TAB}${GN}--schedule ${BL}["<cron expr>"]${CL}
${TAB}${TAB}No argument: interactive menu to set/change/remove the schedule.
${TAB}${TAB}With a cron expression: set it non-interactively, e.g.
${TAB}${TAB}  ${BL}${SCRIPT_NAME} --schedule "0 4 * * 0"${CL}
${TAB}${TAB}Use ${BL}--schedule remove${CL} to delete the schedule.

${TAB}${GN}-h, --help${CL}
${TAB}${TAB}Display this help and exit.

${TAB}${GN}-V, --version${CL}
${TAB}${TAB}Display script version and exit.

${BD}CONFIGURATION${CL}
${TAB}Edit the variables at the top of this script to match your setup.
${TAB}File: ${BL}${SCRIPT_PATH}${CL}

HELP

    # Dynamically show config variables with line numbers (allowlist — converged standard)
    echo -e "${TAB}${BD}Variable                    Line  Current Value${CL}"
    echo -e "${TAB}──────────────────────────  ────  ─────────────────────────"
    local _cfgvars="TRAEFIK_BIN TRAEFIK_SERVICE TRAEFIK_MANAGER_DIR TRAEFIK_MANAGER_USER TRAEFIK_MANAGER_SERVICE TRAEFIK_MANAGER_PORT TRAEFIK_MANAGER_REPO TRAEFIK_DASHBOARD_PORT TRAEFIK_ARCH MIN_DISK_MB MIN_MEM_MB MIN_PYTHON GOTIFY_URL GOTIFY_TOKEN GOTIFY_PRIORITY LOG_FILE"
    local cfgvar
    for cfgvar in $_cfgvars; do
        local line linenum val
        line=$(grep -n "^${cfgvar}=" "$SCRIPT_PATH" | head -1)
        [[ -z "$line" ]] && continue
        linenum=$(echo "$line" | cut -d: -f1)
        val=$(echo "$line" | cut -d= -f2- | sed 's/[[:space:]]*#.*$//' | tr -d '"' | xargs)
        [[ -z "$val" ]] && val="(unset)"
        printf "${TAB}${GN}%-28s${CL}${YW}%-6s${CL}%s\n" "$cfgvar" "$linenum" "$val"
    done

    cat <<HELP

${BD}FILES${CL}
${TAB}${BL}${TRAEFIK_BIN}${CL}
${TAB}${TAB}Traefik binary location. Backup stored at ${TRAEFIK_BIN}.bak

${TAB}${BL}${TRAEFIK_MANAGER_DIR}/${CL}
${TAB}${TAB}Traefik Manager git repository and virtualenv.

${BD}EXIT STATUS${CL}
${TAB}${GN}0${CL}  Success or user cancelled (no changes made)
${TAB}${RD}1${CL}  Error (failed preflight, download, install, or rollback)

${BD}EXAMPLES${CL}
${TAB}Update everything interactively:
${TAB}  ${BL}${SCRIPT_NAME}${CL}

${TAB}Update all without prompts (good for cron):
${TAB}  ${BL}${SCRIPT_NAME} -y${CL}

${TAB}Pin Traefik to a specific version:
${TAB}  ${BL}${SCRIPT_NAME} v3.6.6${CL}

${TAB}Update only Traefik Manager:
${TAB}  ${BL}${SCRIPT_NAME} --manager-only${CL}

${BD}SEE ALSO${CL}
${TAB}Traefik releases:  ${BL}https://github.com/traefik/traefik/releases${CL}
${TAB}Traefik Manager:   ${BL}https://github.com/${TRAEFIK_MANAGER_REPO}${CL}
${TAB}Project repo:      ${BL}${SCRIPT_URL}${CL}

${BD}LICENSE${CL}
${TAB}MIT — ${SCRIPT_URL}/blob/main/LICENSE

HELP
    exit 0
}

msg_info() {
    local msg="$1"
    echo -ne "${TAB}${HOLD} ${YW}${msg}...${CL}"
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
            TRAEFIK_BIN) TRAEFIK_BIN="$val" ;;
            TRAEFIK_SERVICE) TRAEFIK_SERVICE="$val" ;;
            TRAEFIK_MANAGER_DIR) TRAEFIK_MANAGER_DIR="$val" ;;
            TRAEFIK_MANAGER_USER) TRAEFIK_MANAGER_USER="$val" ;;
            TRAEFIK_MANAGER_SERVICE) TRAEFIK_MANAGER_SERVICE="$val" ;;
            TRAEFIK_MANAGER_PORT) TRAEFIK_MANAGER_PORT="$val" ;;
            TRAEFIK_MANAGER_REPO) TRAEFIK_MANAGER_REPO="$val" ;;
            TRAEFIK_DASHBOARD_PORT) TRAEFIK_DASHBOARD_PORT="$val" ;;
            TRAEFIK_ARCH) TRAEFIK_ARCH="$val" ;;
            MIN_DISK_MB) MIN_DISK_MB="$val" ;;
            MIN_MEM_MB) MIN_MEM_MB="$val" ;;
            MIN_PYTHON) MIN_PYTHON="$val" ;;
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
do_set_cred() {
    local name="$1"
    [[ -z "$name" ]] && { header_info; msg_error "--set-cred requires a name (e.g. gotify-token)"; exit 1; }
    local method
    if [[ -t 0 ]]; then read -rsp "Enter value for '${name}': " _v; echo "" >&2; method=$(printf '%s' "$_v" | secret_set "$name")
    else method=$(secret_set "$name"); fi
    echo "Sealed '${name}' via ${method}" >&2; exit 0
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
gotify_configured() {
    [[ -n "$GOTIFY_URL" ]] || return 1
    secret_exists gotify-token && return 0
    [[ -n "$GOTIFY_TOKEN" ]]
}

# Token in a chmod-600 curl config header — NEVER in the URL (avoids argv/ps leak).
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
    require_dep python3 python3 "python3 (for JSON encoding)" || { echo ""; exit 1; }
    local token; token="$(resolve_gotify_token)"
    [[ -z "$token" ]] && { msg_error "No Gotify token — seal one: ${BL}${SCRIPT_NAME} --set-cred gotify-token${CL}"; echo ""; exit 1; }

    local test_message="### ✅ Connection Successful

**Script:** \`${SCRIPT_NAME}\`
**Host:** \`$(hostname)\`
**Time:** $(date '+%Y-%m-%d %H:%M:%S')

*Traefik updater is configured and ready to send alerts.*"

    msg_info "Sending test notification to ${GOTIFY_URL}"
    local curl_conf json_message response
    curl_conf=$(mktemp /tmp/.gotify-XXXXXX); chmod 600 "$curl_conf"
    printf 'header = "X-Gotify-Key: %s"\nheader = "Content-Type: application/json"\n' "$token" > "$curl_conf"
    json_message=$(printf '%s' "$test_message" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null)
    response=$(curl -s -o /dev/null -w "%{http_code}" -K "$curl_conf" -X POST "${GOTIFY_URL}/message" \
        -d "{\"title\":\"🔄 Traefik Updater — Test\",\"message\":${json_message},\"priority\":${GOTIFY_PRIORITY},\"extras\":{\"client::display\":{\"contentType\":\"text/markdown\"}}}" 2>/dev/null)
    rm -f "$curl_conf"
    if [[ "$response" == "200" ]]; then
        msg_ok "Test notification sent successfully"
    else
        msg_error "Notification failed (HTTP ${response})"
    fi
    echo ""
    exit 0
}

manage_cron() {
    local CRON_CMD="${SCRIPT_INSTALL_DEST} --cron >> ${LOG_FILE} 2>&1"

    # Non-interactive form: manage_cron "<cron expr>" (from --schedule "<expr>").
    local DIRECT_EXPR="${1:-}"
    if [[ -n "$DIRECT_EXPR" ]]; then
        header_info
        echo -e "${TAB}${BD}Schedule Manager${CL}"
        echo ""
        if [[ "$DIRECT_EXPR" == "remove" ]]; then
            { crontab -l 2>/dev/null | grep -v "${SCRIPT_NAME}" || true; } | crontab -
            msg_ok "Schedule removed"; echo ""; exit 0
        fi
        local _fc; _fc=$(awk '{print NF}' <<<"$DIRECT_EXPR")
        if [[ "$_fc" -ne 5 ]]; then
            msg_error "Invalid cron expression: expected 5 fields, got ${_fc}"
            echo -e "${TAB}  Example: ${BL}\"0 4 * * 0\"${CL}  (weekly, Sunday 4am)"
            echo ""; exit 1
        fi
        require_installed_for_schedule || { echo ""; msg_warn "Not scheduled."; echo ""; exit 0; }
        local NEW_CRON="${DIRECT_EXPR} ${CRON_CMD}"
        { crontab -l 2>/dev/null | grep -v "${SCRIPT_NAME}" || true; echo "$NEW_CRON"; } | crontab -
        if crontab -l 2>/dev/null | grep -q "${SCRIPT_NAME}"; then
            msg_ok "Schedule set: ${GN}${DIRECT_EXPR}${CL}"
            echo -e "${TAB}  ${BL}${NEW_CRON}${CL}"
        else
            msg_error "Schedule write failed — is cron installed and running?"
        fi
        echo ""; exit 0
    fi

    header_info
    echo -e "${TAB}${BD}Schedule Manager${CL}"
    echo ""

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

    echo -e "${TAB}  ${BD}How often should ${SCRIPT_NAME} check for updates?${CL}"
    echo ""
    echo -e "${TAB}  ${GN}1)${CL} Daily at 3:00 AM (recommended)"
    echo -e "${TAB}  ${GN}2)${CL} Daily at custom time"
    echo -e "${TAB}  ${GN}3)${CL} Every 12 hours"
    echo -e "${TAB}  ${GN}4)${CL} Weekly (Sunday at 3:00 AM)"
    echo -e "${TAB}  ${GN}5)${CL} Custom cron expression"
    echo -e "${TAB}  ${RD}q)${CL} Cancel"
    echo ""
    read -rp "  Select [1-5/q]: " schedule_choice

    local CRON_SCHEDULE=""
    case "$schedule_choice" in
        1) CRON_SCHEDULE="0 3 * * *" ;;
        2)
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
        3) CRON_SCHEDULE="0 */12 * * *" ;;
        4) CRON_SCHEDULE="0 3 * * 0" ;;
        5)
            read -rp "  Cron expression (e.g. 0 3 * * *): " CRON_SCHEDULE
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

    # `|| true` keeps an empty grep result from tripping pipefail and aborting silently.
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

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo ""
        msg_error "This script must be run as root (use sudo)"
        echo ""
        exit 1
    fi
}

check_internet() {
    msg_info "Checking internet connectivity"
    if ! curl -s --connect-timeout 5 https://api.github.com > /dev/null 2>&1; then
        msg_error "Cannot reach GitHub API"
        echo -e "${TAB}  Check your internet connection and try again."
        echo ""
        exit 1
    fi
    msg_ok "Internet connectivity confirmed"
}

get_latest_traefik_version() {
    curl -s https://api.github.com/repos/traefik/traefik/releases/latest | grep '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/'
}

get_current_traefik_version() {
    "${TRAEFIK_BIN}" version 2>/dev/null | grep "Version:" | awk '{print $2}' || echo "unknown"
}

get_latest_manager_release() {
    curl -s "https://api.github.com/repos/${TRAEFIK_MANAGER_REPO}/releases/latest" | grep '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/'
}

get_current_manager_version() {
    if [[ -d "${TRAEFIK_MANAGER_DIR}/.git" ]]; then
        cd "${TRAEFIK_MANAGER_DIR}"
        # Try to get the current tag, fall back to commit hash
        local tag
        tag=$(runuser -u "${TRAEFIK_MANAGER_USER}" -- git describe --tags --exact-match HEAD 2>/dev/null || echo "")
        if [[ -n "$tag" ]]; then
            echo "$tag"
        else
            echo "commit-$(runuser -u "${TRAEFIK_MANAGER_USER}" -- git rev-parse --short HEAD 2>/dev/null)"
        fi
    else
        echo "unknown"
    fi
}

get_vm_ip() {
    hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown"
}

version_ge() {
    printf '%s\n%s' "$2" "$1" | sort -V -C
}

# ============================================================
# ENVIRONMENT: OS and platform compatibility checks
# ============================================================

environment_checks() {
    echo -e "${TAB}${BL}Environment${CL}"
    echo ""

    local ENV_WARNINGS=()

    # OS detection
    local OS_NAME OS_VERSION OS_PRETTY
    if [[ -f /etc/os-release ]]; then
        OS_NAME=$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
        OS_VERSION=$(grep "^VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
        OS_PRETTY=$(grep "^PRETTY_NAME=" /etc/os-release | cut -d= -f2 | tr -d '"')
    else
        OS_NAME="unknown"
        OS_VERSION="unknown"
        OS_PRETTY="Unknown OS"
    fi
    msg_ok "OS: ${GN}${OS_PRETTY}${CL}"

    # Kernel
    local KERNEL
    KERNEL=$(uname -r)
    msg_ok "Kernel: ${GN}${KERNEL}${CL}"

    # Architecture (auto-detect and adjust TRAEFIK_ARCH if needed)
    local ARCH
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        TRAEFIK_ARCH="linux_amd64"
        msg_ok "Architecture: ${GN}${ARCH} (${TRAEFIK_ARCH})${CL}"
    elif [[ "$ARCH" == "aarch64" ]] || [[ "$ARCH" == "arm64" ]]; then
        TRAEFIK_ARCH="linux_arm64"
        msg_ok "Architecture: ${GN}${ARCH} (${TRAEFIK_ARCH})${CL}"
    elif [[ "$ARCH" == "armv7l" ]]; then
        TRAEFIK_ARCH="linux_armv7"
        msg_ok "Architecture: ${GN}${ARCH} (${TRAEFIK_ARCH})${CL}"
    else
        msg_warn "Architecture: ${ARCH} — using configured ${TRAEFIK_ARCH}"
        ENV_WARNINGS+=("arch")
    fi

    # Check if running inside Proxmox VM/LXC
    local PLATFORM="Standalone"
    if [[ -f /proc/1/environ ]] && grep -qa "container=lxc" /proc/1/environ 2>/dev/null; then
        PLATFORM="Proxmox LXC"
    elif systemd-detect-virt --quiet 2>/dev/null; then
        local VIRT_TYPE
        VIRT_TYPE=$(systemd-detect-virt 2>/dev/null || echo "unknown")
        PLATFORM="VM (${VIRT_TYPE})"
    fi
    msg_ok "Platform: ${GN}${PLATFORM}${CL}"

    # Proxmox host version (if accessible)
    if command -v pveversion &>/dev/null; then
        local PVE_VER
        PVE_VER=$(pveversion | awk -F/ '{print $2}')
        msg_ok "Proxmox VE: ${GN}${PVE_VER}${CL}"
    fi

    # OS version compatibility
    case "$OS_NAME" in
        ubuntu)
            local MAJOR_VER
            MAJOR_VER=$(echo "$OS_VERSION" | cut -d. -f1)
            if [[ "$MAJOR_VER" -lt 20 ]]; then
                msg_warn "Ubuntu ${OS_VERSION} is outdated — consider upgrading to 22.04+"
                ENV_WARNINGS+=("os-old")
            fi
            ;;
        debian)
            if [[ "${OS_VERSION:-0}" -lt 11 ]]; then
                msg_warn "Debian ${OS_VERSION} is outdated — consider upgrading to 12+"
                ENV_WARNINGS+=("os-old")
            fi
            ;;
    esac

    # Python version (for Traefik Manager)
    if [[ -d "${TRAEFIK_MANAGER_DIR}" ]]; then
        if [[ -f "${TRAEFIK_MANAGER_DIR}/venv/bin/python" ]]; then
            local PY_VER
            PY_VER=$("${TRAEFIK_MANAGER_DIR}/venv/bin/python" --version 2>&1 | awk '{print $2}')
            if version_ge "$PY_VER" "$MIN_PYTHON"; then
                msg_ok "Python (venv): ${GN}${PY_VER}${CL}"
            else
                msg_warn "Python ${PY_VER} — Traefik Manager may require ${MIN_PYTHON}+"
                ENV_WARNINGS+=("python-old")
            fi
        else
            msg_warn "Python venv not found for Traefik Manager"
            ENV_WARNINGS+=("python-missing")
        fi
    fi

    # Disk space
    local DISK_AVAIL
    DISK_AVAIL=$(df -BM / | tail -1 | awk '{print $4}' | tr -d 'M')
    if [[ "$DISK_AVAIL" -lt "$MIN_DISK_MB" ]]; then
        msg_warn "Low disk space: ${DISK_AVAIL}MB available (${MIN_DISK_MB}MB+ recommended)"
        ENV_WARNINGS+=("disk-low")
    else
        msg_ok "Disk space: ${GN}${DISK_AVAIL}MB available${CL}"
    fi

    # Memory
    local MEM_AVAIL
    MEM_AVAIL=$(free -m | awk '/^Mem:/{print $7}')
    if [[ "$MEM_AVAIL" -lt "$MIN_MEM_MB" ]]; then
        msg_warn "Low available memory: ${MEM_AVAIL}MB (${MIN_MEM_MB}MB+ recommended)"
        ENV_WARNINGS+=("mem-low")
    else
        msg_ok "Available memory: ${GN}${MEM_AVAIL}MB${CL}"
    fi

    echo ""

    # Handle environment warnings
    if [[ ${#ENV_WARNINGS[@]} -gt 0 ]]; then
        if [[ " ${ENV_WARNINGS[*]} " =~ "os-old" ]] || [[ " ${ENV_WARNINGS[*]} " =~ "python-old" ]]; then
            echo -e "${TAB}${YW}⚠  Environment warnings detected. Updates may work but could${CL}"
            echo -e "${TAB}${YW}   have compatibility issues with newer versions.${CL}"
            echo ""
            read -rp "  Continue anyway? [y/N]: " env_choice
            if [[ "${env_choice,,}" != "y" ]]; then
                echo ""
                msg_ok "Exiting. No changes made."
                echo ""
                exit 0
            fi
            echo ""
        fi
    fi
}

# ============================================================
# PREFLIGHT: Dependency checks with interactive fix
# ============================================================

# First run = no settings file yet (no required-identity var; paths auto-default).
is_first_run() { [[ ! -f "$SETTINGS_FILE" ]]; }

# ============================================================
# GUIDED SETUP WIZARD
# ============================================================
guided_setup() {
    header_info
    echo -e "${TAB}${BD}Guided Setup${CL}"
    echo -e "${TAB}Answer each prompt. Press Enter to keep the [current] value."
    echo ""

    # --- 1) Traefik paths & service ---
    echo -e "${TAB}${BD}1) Traefik${CL}"
    read -rp "  Traefik binary path [${TRAEFIK_BIN}]: " _v
    [[ -n "$_v" ]] && { TRAEFIK_BIN="$_v"; settings_set TRAEFIK_BIN "$_v"; }
    read -rp "  Traefik systemd service [${TRAEFIK_SERVICE}]: " _v
    [[ -n "$_v" ]] && { TRAEFIK_SERVICE="$_v"; settings_set TRAEFIK_SERVICE "$_v"; }
    read -rp "  Traefik dashboard port [${TRAEFIK_DASHBOARD_PORT}]: " _v
    [[ -n "$_v" ]] && { TRAEFIK_DASHBOARD_PORT="$_v"; settings_set TRAEFIK_DASHBOARD_PORT "$_v"; }
    read -rp "  Release architecture (linux_amd64 / linux_arm64) [${TRAEFIK_ARCH}]: " _v
    [[ -n "$_v" ]] && { TRAEFIK_ARCH="$_v"; settings_set TRAEFIK_ARCH "$_v"; }
    echo ""

    # --- 2) Traefik Manager ---
    echo -e "${TAB}${BD}2) Traefik Manager${CL}"
    read -rp "  Manager install dir [${TRAEFIK_MANAGER_DIR}]: " _v
    [[ -n "$_v" ]] && { TRAEFIK_MANAGER_DIR="$_v"; settings_set TRAEFIK_MANAGER_DIR "$_v"; }
    read -rp "  Manager service user [${TRAEFIK_MANAGER_USER}]: " _v
    [[ -n "$_v" ]] && { TRAEFIK_MANAGER_USER="$_v"; settings_set TRAEFIK_MANAGER_USER "$_v"; }
    read -rp "  Manager systemd service [${TRAEFIK_MANAGER_SERVICE}]: " _v
    [[ -n "$_v" ]] && { TRAEFIK_MANAGER_SERVICE="$_v"; settings_set TRAEFIK_MANAGER_SERVICE "$_v"; }
    read -rp "  Manager web port [${TRAEFIK_MANAGER_PORT}]: " _v
    [[ -n "$_v" ]] && { TRAEFIK_MANAGER_PORT="$_v"; settings_set TRAEFIK_MANAGER_PORT "$_v"; }
    read -rp "  Manager GitHub repo [${TRAEFIK_MANAGER_REPO}]: " _v
    [[ -n "$_v" ]] && { TRAEFIK_MANAGER_REPO="$_v"; settings_set TRAEFIK_MANAGER_REPO "$_v"; }
    echo ""

    # --- 3) Resource thresholds ---
    echo -e "${TAB}${BD}3) Preflight thresholds${CL}"
    read -rp "  Minimum free disk (MB) [${MIN_DISK_MB}]: " _v
    [[ -n "$_v" ]] && { MIN_DISK_MB="$_v"; settings_set MIN_DISK_MB "$_v"; }
    read -rp "  Minimum available memory (MB) [${MIN_MEM_MB}]: " _v
    [[ -n "$_v" ]] && { MIN_MEM_MB="$_v"; settings_set MIN_MEM_MB "$_v"; }
    read -rp "  Minimum Python version [${MIN_PYTHON}]: " _v
    [[ -n "$_v" ]] && { MIN_PYTHON="$_v"; settings_set MIN_PYTHON "$_v"; }
    echo ""

    # --- 4) Gotify notifications (optional, token sealed) ---
    echo -e "${TAB}${BD}4) Gotify notifications (optional)${CL}"
    echo -e "${TAB}  ${INFO} An IP or hostname is fine (http is assumed). Only prefix ${BL}https://${CL} if your Gotify uses TLS."
    read -rp "  Gotify server URL (blank to skip) [${GOTIFY_URL}]: " _v
    if [[ -n "$_v" ]]; then
        GOTIFY_URL="$_v"; settings_set GOTIFY_URL "$_v"
        echo -e "${TAB}  ${INFO} The token is sealed (encrypted), never written in plaintext."
        read -rsp "  Gotify application token: " _tok; echo ""
        if [[ -n "$_tok" ]]; then
            local m; m=$(printf '%s' "$_tok" | secret_set gotify-token)
            msg_ok "Token sealed via ${m}"
            require_dep curl curl "curl" || true
            require_dep python3 python3 "python3 (for JSON encoding)" || true
        fi
        read -rp "  Notification priority (1-10) [${GOTIFY_PRIORITY}]: " _v
        [[ -n "$_v" ]] && { GOTIFY_PRIORITY="$_v"; settings_set GOTIFY_PRIORITY "$_v"; }
    else
        msg_info "Skipping notifications"
    fi
    echo ""

    # --- 5) Schedule (optional, gated on install) ---
    echo -e "${TAB}${BD}5) Schedule${CL}"
    echo -e "${TAB}  Automated update checks keep Traefik current without manual runs."
    if installed_ok; then
        read -rp "  Set up a cron schedule now? [Y/n]: " _v
        [[ ! "$_v" =~ ^[Nn]$ ]] && manage_cron
    else
        msg_warn "Not installed to ${SCRIPT_INSTALL_DEST} yet — scheduling needs that first."
        echo -e "${TAB}  Install via the first-run prompt, then ${BL}--schedule${CL}."
    fi
    echo ""

    msg_ok "Setup complete."
    echo -e "${TAB}Settings saved to ${BL}${SETTINGS_FILE}${CL}"
    echo ""
}

# ============================================================
# PREFLIGHT: Dependency checks with interactive fix
# ============================================================

preflight_checks() {
    echo -e "${TAB}${BL}Preflight Checks${CL}"
    echo ""

    local MISSING_DEPS=()
    local STOPPED_SERVICES=()
    local CRITICAL_MISSING=false

    # Required binaries
    for dep in wget curl git; do
        if command -v "$dep" &>/dev/null; then
            msg_ok "${dep} installed"
        else
            msg_error "${dep} not found"
            MISSING_DEPS+=("$dep")
        fi
    done

    # Traefik binary
    if [[ -x "${TRAEFIK_BIN}" ]]; then
        msg_ok "Traefik binary found (${TRAEFIK_BIN})"
    else
        msg_error "Traefik binary not found at ${TRAEFIK_BIN}"
        CRITICAL_MISSING=true
    fi

    # Traefik service
    if systemctl is-enabled "${TRAEFIK_SERVICE}.service" &>/dev/null; then
        if systemctl is-active --quiet "${TRAEFIK_SERVICE}.service"; then
            msg_ok "${TRAEFIK_SERVICE} service running"
        else
            msg_warn "${TRAEFIK_SERVICE} service exists but is not running"
            STOPPED_SERVICES+=("${TRAEFIK_SERVICE}")
        fi
    else
        msg_error "${TRAEFIK_SERVICE} service not found"
        CRITICAL_MISSING=true
    fi

    # Traefik Manager (optional)
    if [[ -d "${TRAEFIK_MANAGER_DIR}/.git" ]]; then
        msg_ok "Traefik Manager repo found (${TRAEFIK_MANAGER_DIR})"
        if systemctl is-enabled "${TRAEFIK_MANAGER_SERVICE}.service" &>/dev/null; then
            if systemctl is-active --quiet "${TRAEFIK_MANAGER_SERVICE}.service"; then
                msg_ok "${TRAEFIK_MANAGER_SERVICE} service running"
            else
                msg_warn "${TRAEFIK_MANAGER_SERVICE} service exists but is not running"
                STOPPED_SERVICES+=("${TRAEFIK_MANAGER_SERVICE}")
            fi
        else
            msg_warn "${TRAEFIK_MANAGER_SERVICE} service not found"
        fi
    else
        msg_warn "Traefik Manager not installed (optional, skipping)"
    fi

    echo ""

    # Handle missing packages
    if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
        echo -e "${TAB}${RD}Missing required packages: ${MISSING_DEPS[*]}${CL}"
        echo ""
        read -rp "  Install missing packages now? [y/N]: " install_choice
        if [[ "${install_choice,,}" == "y" ]]; then
            echo ""
            msg_info "Updating package lists"
            apt-get update -qq > /dev/null 2>&1
            msg_ok "Package lists updated"

            for dep in "${MISSING_DEPS[@]}"; do
                msg_info "Installing ${dep}"
                if apt-get install -y -qq "$dep" > /dev/null 2>&1; then
                    msg_ok "Installed ${dep}"
                else
                    msg_error "Failed to install ${dep}"
                    echo -e "${TAB}  Try manually: ${YW}apt install ${dep}${CL}"
                    echo ""
                    exit 1
                fi
            done
            echo ""
        else
            echo ""
            msg_error "Cannot proceed without required dependencies"
            echo ""
            exit 1
        fi
    fi

    # Handle stopped services
    if [[ ${#STOPPED_SERVICES[@]} -gt 0 ]]; then
        echo -e "${TAB}${YW}Stopped services detected: ${STOPPED_SERVICES[*]}${CL}"
        echo ""
        read -rp "  Start stopped services before continuing? [y/N]: " start_choice
        if [[ "${start_choice,,}" == "y" ]]; then
            echo ""
            for svc in "${STOPPED_SERVICES[@]}"; do
                msg_info "Starting ${svc}"
                if systemctl start "${svc}.service" 2>/dev/null; then
                    sleep 2
                    if systemctl is-active --quiet "${svc}.service"; then
                        msg_ok "Started ${svc}"
                    else
                        msg_error "Failed to start ${svc}"
                    fi
                else
                    msg_error "Failed to start ${svc}"
                fi
            done
            echo ""
        fi
    fi

    # Critical failures
    if [[ "$CRITICAL_MISSING" == true ]]; then
        msg_error "Critical components missing"
        echo -e "${TAB}  Traefik must be properly installed before using this updater."
        echo -e "${TAB}  Binary expected at: ${YW}${TRAEFIK_BIN}${CL}"
        echo -e "${TAB}  Service expected:   ${YW}${TRAEFIK_SERVICE}.service${CL}"
        echo ""
        exit 1
    fi

    msg_ok "All preflight checks passed"
    echo ""
}

# ============================================================
# UPDATE FUNCTIONS
# ============================================================

show_changelog() {
    local VERSION="${1:-}"

    echo ""
    echo -e "${TAB}${BL}▸ Traefik Changelog${CL}"
    echo ""

    # Determine which version to show
    if [[ -z "$VERSION" ]]; then
        VERSION=$(get_latest_traefik_version)
    fi
    local VERSION_CLEAN=$(echo "$VERSION" | sed 's/^v//')
    VERSION="v${VERSION_CLEAN}"

    msg_info "Fetching release notes for ${VERSION}"

    local RELEASE_JSON
    RELEASE_JSON=$(curl -s "https://api.github.com/repos/traefik/traefik/releases/tags/${VERSION}" 2>/dev/null)

    if echo "$RELEASE_JSON" | grep -q '"message": "Not Found"'; then
        msg_error "Release ${VERSION} not found"
        echo -e "${TAB}  Check: ${BL}https://github.com/traefik/traefik/releases${CL}"
        return 1
    fi

    # Extract release info
    local RELEASE_NAME RELEASE_DATE RELEASE_URL RELEASE_BODY
    RELEASE_NAME=$(echo "$RELEASE_JSON" | grep '"name"' | head -1 | sed -E 's/.*"name": *"([^"]+)".*/\1/')
    RELEASE_DATE=$(echo "$RELEASE_JSON" | grep '"published_at"' | head -1 | sed -E 's/.*"published_at": *"([^T]+)T.*/\1/')
    RELEASE_URL=$(echo "$RELEASE_JSON" | grep '"html_url"' | head -1 | sed -E 's/.*"html_url": *"([^"]+)".*/\1/')

    msg_ok "Release: ${GN}${RELEASE_NAME}${CL} (${RELEASE_DATE})"
    echo ""

    # Try to extract and display the body using Python (available on most systems)
    if command -v python3 &>/dev/null; then
        RELEASE_BODY=$(echo "$RELEASE_JSON" | python3 -c "
import json, sys, re
try:
    d = json.load(sys.stdin)
    body = d.get('body', '')
    if body:
        # Strip markdown links [text](url) -> text
        body = re.sub(r'\[([^\]]+)\]\([^\)]+\)', r'\1', body)
        # Strip bold **text** -> text
        body = re.sub(r'\*\*([^\*]+)\*\*', r'\1', body)
        # Strip HTML tags
        body = re.sub(r'<[^>]+>', '', body)
        # Limit to first 30 lines
        lines = body.strip().split('\n')[:30]
        print('\n'.join(lines))
        if len(body.strip().split('\n')) > 30:
            print('... (truncated, see full notes at URL below)')
    else:
        print('No release notes available.')
except:
    print('Could not parse release notes.')
" 2>/dev/null)
    else
        RELEASE_BODY="(Install python3 for formatted release notes)"
    fi

    # Display with indentation
    while IFS= read -r line; do
        echo -e "${TAB}  ${line}"
    done <<< "$RELEASE_BODY"

    echo ""
    echo -e "${TAB}  ${BL}Full release notes: ${RELEASE_URL}${CL}"
    echo ""

    # Manager changelog
    if [[ -d "${TRAEFIK_MANAGER_DIR}/.git" ]]; then
        echo -e "${TAB}${BL}▸ Traefik Manager Changelog${CL}"
        echo ""

        cd "${TRAEFIK_MANAGER_DIR}"
        runuser -u "${TRAEFIK_MANAGER_USER}" -- git fetch origin main --quiet 2>/dev/null

        local LOCAL_HASH REMOTE_HASH
        LOCAL_HASH=$(runuser -u "${TRAEFIK_MANAGER_USER}" -- git rev-parse HEAD 2>/dev/null)
        REMOTE_HASH=$(runuser -u "${TRAEFIK_MANAGER_USER}" -- git rev-parse origin/main 2>/dev/null)

        if [[ "$LOCAL_HASH" == "$REMOTE_HASH" ]]; then
            msg_ok "Manager is up to date — no new changes"
        else
            local COMMIT_COUNT
            COMMIT_COUNT=$(runuser -u "${TRAEFIK_MANAGER_USER}" -- git rev-list --count HEAD..origin/main 2>/dev/null || echo "?")
            msg_ok "${COMMIT_COUNT} new commit(s) available:"
            echo ""
            runuser -u "${TRAEFIK_MANAGER_USER}" -- git log --oneline HEAD..origin/main 2>/dev/null | head -15 | while IFS= read -r line; do
                echo -e "${TAB}  ${YW}•${CL} ${line}"
            done
            if [[ "$COMMIT_COUNT" -gt 15 ]] 2>/dev/null; then
                echo -e "${TAB}  ${YW}... and $((COMMIT_COUNT - 15)) more${CL}"
            fi
        fi
        echo ""
        echo -e "${TAB}  ${BL}Full history: https://github.com/${TRAEFIK_MANAGER_REPO}/commits/main${CL}"
        echo ""
    fi
}

rollback_traefik() {
    echo ""
    echo -e "${TAB}${BL}▸ Traefik Rollback${CL}"
    echo ""

    if [[ ! -f "${TRAEFIK_BIN}.bak" ]]; then
        msg_error "No backup found at ${TRAEFIK_BIN}.bak"
        echo -e "${TAB}  A backup is created automatically during updates."
        exit 1
    fi

    local current_version backup_version
    current_version=$(get_current_traefik_version)
    backup_version=$("${TRAEFIK_BIN}.bak" version 2>/dev/null | grep "Version:" | awk '{print $2}' || echo "unknown")

    echo -e "${TAB}  Current: ${YW}${current_version}${CL}"
    echo -e "${TAB}  Backup:  ${GN}${backup_version}${CL}"
    echo ""
    read -rp "  Restore backup version? [y/N]: " confirm
    if [[ "${confirm,,}" != "y" ]]; then
        echo ""
        msg_ok "Exiting. No changes made."
        echo ""
        exit 0
    fi

    echo ""
    msg_info "Stopping ${TRAEFIK_SERVICE} service"
    systemctl stop "${TRAEFIK_SERVICE}.service"
    msg_ok "Stopped ${TRAEFIK_SERVICE}"

    msg_info "Restoring backup"
    cp "${TRAEFIK_BIN}.bak" "${TRAEFIK_BIN}"
    chmod +x "${TRAEFIK_BIN}"
    msg_ok "Restored ${TRAEFIK_BIN} from backup"

    msg_info "Starting ${TRAEFIK_SERVICE} service"
    systemctl start "${TRAEFIK_SERVICE}.service"
    sleep 2

    if systemctl is-active --quiet "${TRAEFIK_SERVICE}.service"; then
        local restored_version
        restored_version=$(get_current_traefik_version)
        msg_ok "Traefik running — version ${GN}${restored_version}${CL}"
    else
        msg_error "Traefik failed to start after rollback!"
        echo -e "${TAB}  Run: ${YW}systemctl status ${TRAEFIK_SERVICE}${CL}"
        exit 1
    fi

    echo ""
    exit 0
}

update_traefik() {
    local target_version="$1"
    local current_version
    current_version=$(get_current_traefik_version)
    local current_clean target_clean
    current_clean=$(echo "$current_version" | sed 's/^v//')
    target_clean=$(echo "$target_version" | sed 's/^v//')
    target_version="v${target_clean}"

    if [[ "$current_clean" == "$target_clean" ]]; then
        msg_ok "Traefik is already at ${GN}${target_version}${CL}"
        return 0
    fi

    echo ""
    echo -e "${TAB}${BL}Traefik: ${RD}${current_version:-unknown}${CL} → ${GN}${target_version}${CL}"
    echo ""

    # Download
    local download_url="https://github.com/traefik/traefik/releases/download/${target_version}/traefik_${target_version}_${TRAEFIK_ARCH}.tar.gz"
    local checksum_url="https://github.com/traefik/traefik/releases/download/${target_version}/traefik_${target_version}_checksums.txt"
    local tmp_file="/tmp/traefik_update_${target_version}.tar.gz"
    TEMP_FILES+=("$tmp_file")

    msg_info "Downloading Traefik ${target_version}"
    if ! wget -q "${download_url}" -O "$tmp_file" 2>/dev/null; then
        msg_error "Download failed — version ${target_version} may not exist"
        echo -e "${TAB}  Check releases: ${BL}https://github.com/traefik/traefik/releases${CL}"
        return 1
    fi
    msg_ok "Downloaded Traefik ${target_version}"

    # Verify SHA256 checksum. This defends against transit tampering / a poisoned
    # mirror — NOT against a compromised upstream release (the checksum is served
    # from the same origin as the binary). We still fail CLOSED: no valid checksum
    # means no install, unless the operator explicitly opts out.
    msg_info "Verifying SHA256 checksum"
    local checksum_file="/tmp/traefik_checksums_${target_version}.txt"
    TEMP_FILES+=("$checksum_file")
    local checksum_ok=false
    if wget -q "${checksum_url}" -O "$checksum_file" 2>/dev/null; then
        local expected_hash actual_hash archive_name
        archive_name="traefik_${target_version}_${TRAEFIK_ARCH}.tar.gz"
        expected_hash=$(grep "${archive_name}" "$checksum_file" | awk '{print $1}')
        actual_hash=$(sha256sum "$tmp_file" | awk '{print $1}')
        if [[ -z "$expected_hash" ]]; then
            msg_error "No checksum entry for ${archive_name} in the published checksums file"
        elif [[ "$expected_hash" == "$actual_hash" ]]; then
            msg_ok "Checksum verified (SHA256)"
            checksum_ok=true
        else
            msg_error "Checksum MISMATCH — download may be corrupted or tampered with"
            echo -e "${TAB}  Expected: ${YW}${expected_hash}${CL}"
            echo -e "${TAB}  Got:      ${RD}${actual_hash}${CL}"
            rm -f "$tmp_file" "$checksum_file"
            return 1   # a mismatch is ALWAYS fatal — no override
        fi
        rm -f "$checksum_file"
    else
        msg_error "Could not fetch the published checksums file"
    fi

    # If we couldn't positively verify (missing file or missing entry — NOT a
    # mismatch, which already returned above), fail closed unless overridden.
    if [[ "$checksum_ok" != true ]]; then
        if [[ "${SKIP_CHECKSUM:-false}" == true ]]; then
            msg_warn "Proceeding WITHOUT checksum verification (--insecure-skip-checksum)"
        elif [[ "${INTERACTIVE:-true}" == true ]]; then
            echo -e "${TAB}${YW}The download could not be cryptographically verified.${CL}"
            echo -e "${TAB}Installing an unverified binary is a supply-chain risk."
            read -rp "  Install ANYWAY without verification? [y/N]: " _v
            if [[ ! "$_v" =~ ^[Yy]$ ]]; then
                msg_error "Aborted — binary not installed (no checksum)."
                rm -f "$tmp_file"
                return 1
            fi
            msg_warn "Proceeding without verification at user's explicit request"
        else
            msg_error "No checksum verification possible — aborting (use --insecure-skip-checksum to override in automation)."
            rm -f "$tmp_file"
            return 1
        fi
    fi

    # Backup
    msg_info "Backing up current binary"
    if [[ -f "${TRAEFIK_BIN}" ]]; then
        cp "${TRAEFIK_BIN}" "${TRAEFIK_BIN}.bak"
    fi
    msg_ok "Backup saved to ${TRAEFIK_BIN}.bak"

    # Stop
    msg_info "Stopping ${TRAEFIK_SERVICE} service"
    systemctl stop "${TRAEFIK_SERVICE}.service"
    msg_ok "Stopped ${TRAEFIK_SERVICE}"

    # Install
    msg_info "Installing new binary"
    tar xzf "$tmp_file" -C "$(dirname "${TRAEFIK_BIN}")/" traefik
    chmod +x "${TRAEFIK_BIN}"
    rm -f "$tmp_file"
    msg_ok "Installed Traefik ${target_version}"

    # Start
    msg_info "Starting ${TRAEFIK_SERVICE} service"
    systemctl start "${TRAEFIK_SERVICE}.service"
    sleep 2

    if systemctl is-active --quiet "${TRAEFIK_SERVICE}.service"; then
        local new_version
        new_version=$(get_current_traefik_version)
        msg_ok "Traefik running — version ${GN}${new_version}${CL}"
    else
        msg_error "Traefik failed to start!"
        echo ""
        msg_info "Rolling back to previous version"
        cp "${TRAEFIK_BIN}.bak" "${TRAEFIK_BIN}"
        systemctl start "${TRAEFIK_SERVICE}.service"
        sleep 2
        if systemctl is-active --quiet "${TRAEFIK_SERVICE}.service"; then
            msg_ok "Rollback successful — previous version restored"
        else
            msg_error "CRITICAL: Rollback failed! Manual intervention required"
            echo -e "${TAB}  Run: ${YW}systemctl status ${TRAEFIK_SERVICE}${CL}"
        fi
        return 1
    fi
}

update_manager() {
    if [[ ! -d "${TRAEFIK_MANAGER_DIR}/.git" ]]; then
        msg_warn "Traefik Manager not installed — skipping"
        return 0
    fi

    msg_info "Checking Traefik Manager for updates"

    cd "${TRAEFIK_MANAGER_DIR}"

    # Ensure we're on main branch (not detached HEAD)
    local current_branch
    current_branch=$(runuser -u "${TRAEFIK_MANAGER_USER}" -- git branch --show-current 2>/dev/null)
    if [[ "$current_branch" != "main" ]]; then
        msg_warn "Not on main branch (${current_branch:-detached HEAD}), switching to main"
        runuser -u "${TRAEFIK_MANAGER_USER}" -- git checkout main --quiet 2>/dev/null
    fi

    # Fetch latest from remote
    runuser -u "${TRAEFIK_MANAGER_USER}" -- git fetch origin main --tags --quiet 2>/dev/null

    # Compare local vs remote
    local local_hash remote_hash
    local_hash=$(runuser -u "${TRAEFIK_MANAGER_USER}" -- git rev-parse HEAD)
    remote_hash=$(runuser -u "${TRAEFIK_MANAGER_USER}" -- git rev-parse origin/main)

    local current_version
    current_version=$(get_current_manager_version)

    if [[ "$local_hash" == "$remote_hash" ]]; then
        msg_ok "Traefik Manager is up to date (${GN}${current_version}${CL})"
        return 0
    fi

    # Determine what we're updating to
    local remote_version
    remote_version=$(runuser -u "${TRAEFIK_MANAGER_USER}" -- git describe --tags origin/main 2>/dev/null || echo "$(runuser -u "${TRAEFIK_MANAGER_USER}" -- git rev-parse --short origin/main)")

    echo ""
    echo -e "${TAB}${BL}Manager: ${RD}${current_version}${CL} → ${GN}${remote_version}${CL}"
    echo ""

    # Pull latest on main branch
    msg_info "Pulling latest changes"
    if ! runuser -u "${TRAEFIK_MANAGER_USER}" -- git pull origin main --quiet 2>/dev/null; then
        msg_error "Failed to pull latest changes"
        echo -e "${TAB}  There may be local modifications. Check: ${YW}git status${CL}"
        return 1
    fi
    msg_ok "Pulled latest changes"

    # Update Python dependencies (always run per developer's update guide)
    msg_info "Updating Python dependencies"
    runuser -u "${TRAEFIK_MANAGER_USER}" -- "${TRAEFIK_MANAGER_DIR}/venv/bin/pip" install -r requirements.txt gunicorn --quiet 2>/dev/null
    msg_ok "Python dependencies updated"

    # Rebuild vendor assets and Tailwind CSS
    if [[ -f "${TRAEFIK_MANAGER_DIR}/scripts/setup-assets.sh" ]]; then
        msg_info "Rebuilding assets (vendor + Tailwind CSS)"
        bash "${TRAEFIK_MANAGER_DIR}/scripts/setup-assets.sh" > /dev/null 2>&1
        msg_ok "Assets rebuilt"
    else
        msg_warn "setup-assets.sh not found — vendor assets may be outdated"
    fi

    # Restart
    msg_info "Restarting ${TRAEFIK_MANAGER_SERVICE} service"
    systemctl restart "${TRAEFIK_MANAGER_SERVICE}.service"
    sleep 2

    if systemctl is-active --quiet "${TRAEFIK_MANAGER_SERVICE}.service"; then
        local new_version
        new_version=$(get_current_manager_version)
        msg_ok "Traefik Manager running — ${GN}${new_version}${CL}"
    else
        msg_error "Traefik Manager failed to start!"
        echo -e "${TAB}  Run: ${YW}systemctl status ${TRAEFIK_MANAGER_SERVICE}${CL}"
        return 1
    fi
}

# ============================================================
# MAIN
# ============================================================

# Early exit for help and version (before any checks)
load_settings
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
check_root

# Flags that need root, dispatched right after the root check.
ARGS=("${@:-}")
i=0
while [[ $i -lt ${#ARGS[@]} ]]; do
    case "${ARGS[$i]:-}" in
        --set-cred) do_set_cred "${ARGS[$((i+1))]:-}" ;;
        --setup) header_info; preflight_checks; guided_setup; exit 0 ;;
        --test-notify) test_gotify ;;
        --schedule) manage_cron "${ARGS[$((i+1))]:-}" ;;
    esac
    i=$((i+1))
done

check_internet
echo ""

# Environment
environment_checks

# Preflight
preflight_checks

# Fetch version info
LATEST_TRAEFIK=$(get_latest_traefik_version)
CURRENT_TRAEFIK=$(get_current_traefik_version)
CURRENT_MANAGER=$(get_current_manager_version)
VM_IP=$(get_vm_ip)

# Pre-fetch Manager remote info for status display
MANAGER_UP_TO_DATE=true
MANAGER_REMOTE_VERSION=""
if [[ -d "${TRAEFIK_MANAGER_DIR}/.git" ]]; then
    cd "${TRAEFIK_MANAGER_DIR}"
    # Ensure on main branch for accurate comparison
    local_branch=$(runuser -u "${TRAEFIK_MANAGER_USER}" -- git branch --show-current 2>/dev/null)
    if [[ "$local_branch" != "main" ]]; then
        runuser -u "${TRAEFIK_MANAGER_USER}" -- git checkout main --quiet 2>/dev/null
        CURRENT_MANAGER=$(get_current_manager_version)
    fi
    runuser -u "${TRAEFIK_MANAGER_USER}" -- git fetch origin main --tags --quiet 2>/dev/null
    local_hash=$(runuser -u "${TRAEFIK_MANAGER_USER}" -- git rev-parse HEAD 2>/dev/null)
    remote_hash=$(runuser -u "${TRAEFIK_MANAGER_USER}" -- git rev-parse origin/main 2>/dev/null)
    MANAGER_REMOTE_VERSION=$(runuser -u "${TRAEFIK_MANAGER_USER}" -- git describe --tags origin/main 2>/dev/null || echo "$(runuser -u "${TRAEFIK_MANAGER_USER}" -- git rev-parse --short origin/main)")
    if [[ "$local_hash" != "$remote_hash" ]]; then
        MANAGER_UP_TO_DATE=false
    fi
fi

# Status display
echo -e "${TAB}${BL}Current Status:${CL}"
CURRENT_T_CLEAN=$(echo "$CURRENT_TRAEFIK" | sed 's/^v//')
LATEST_T_CLEAN=$(echo "$LATEST_TRAEFIK" | sed 's/^v//')
if [[ "$CURRENT_T_CLEAN" == "$LATEST_T_CLEAN" ]]; then
    echo -e "${TAB}  Traefik:  ${GN}${CURRENT_TRAEFIK} (up to date)${CL}"
else
    echo -e "${TAB}  Traefik:  ${YW}${CURRENT_TRAEFIK}${CL} → ${GN}${LATEST_TRAEFIK} available${CL}"
fi

if [[ -d "${TRAEFIK_MANAGER_DIR}/.git" ]]; then
    if [[ "$MANAGER_UP_TO_DATE" == true ]]; then
        echo -e "${TAB}  Manager:  ${GN}${CURRENT_MANAGER} (up to date)${CL}"
    else
        echo -e "${TAB}  Manager:  ${YW}${CURRENT_MANAGER}${CL} → ${GN}${MANAGER_REMOTE_VERSION} available${CL}"
    fi
fi
echo ""

# Parse arguments for non-interactive mode
SKIP_TRAEFIK=false
SKIP_MANAGER=false
SPECIFIC_VERSION=""
INTERACTIVE=true
CHECK_ONLY=false
DO_ROLLBACK=false
SHOW_CHANGELOG=false
CRON_MODE=false
SKIP_CHECKSUM=false

for arg in "${@:-}"; do
    case "${arg:-}" in
        --traefik-only) SKIP_MANAGER=true; INTERACTIVE=false ;;
        --manager-only) SKIP_TRAEFIK=true; INTERACTIVE=false ;;
        --yes|-y) INTERACTIVE=false ;;
        --check) CHECK_ONLY=true ;;
        --rollback) DO_ROLLBACK=true ;;
        --changelog) SHOW_CHANGELOG=true ;;
        --cron) CRON_MODE=true; INTERACTIVE=false ;;
        --insecure-skip-checksum) SKIP_CHECKSUM=true ;;
        v*) SPECIFIC_VERSION="$arg"; INTERACTIVE=false ;;
    esac
done

# --check: show status and exit
if [[ "$CHECK_ONLY" == true ]]; then
    echo ""
    msg_ok "Check complete. No changes made."
    echo ""
    exit 0
fi

# --rollback: restore previous backup
if [[ "$DO_ROLLBACK" == true ]]; then
    rollback_traefik
fi

# --changelog: show release notes and exit
if [[ "$SHOW_CHANGELOG" == true ]]; then
    show_changelog "$SPECIFIC_VERSION"
    exit 0
fi

# One-time install nudge (interactive only) so cron can run the canonical path.
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
    if [[ ! "$_ans" =~ ^[Nn]$ ]]; then guided_setup; fi
    echo ""
fi

# Interactive menu
if [[ "$INTERACTIVE" == true ]]; then
    echo -e "${TAB}${BL}What would you like to do?${CL}"
    echo ""
    echo -e "${TAB}  ${GN}1)${CL} Update everything (Traefik + Manager)"
    echo -e "${TAB}  ${GN}2)${CL} Update Traefik binary only"
    echo -e "${TAB}  ${GN}3)${CL} Update Traefik Manager only"
    echo -e "${TAB}  ${GN}4)${CL} Update Traefik to a specific version"
    echo -e "${TAB}  ${GN}5)${CL} Check status only (no changes)"
    echo -e "${TAB}  ${GN}6)${CL} Rollback Traefik to previous version"
    echo -e "${TAB}  ${GN}7)${CL} View changelog (release notes)"
    echo -e "${TAB}  ${GN}8)${CL} Test Gotify notification"
    echo -e "${TAB}  ${GN}9)${CL} Manage cron schedule"
    echo -e "${TAB}  ${GN}10)${CL} Guided setup (reconfigure everything)"
    echo -e "${TAB}  ${RD}q)${CL} Quit"
    echo ""
    read -rp "  Select an option [1-10/q]: " choice

    case "$choice" in
        1) ;;
        2) SKIP_MANAGER=true ;;
        3) SKIP_TRAEFIK=true ;;
        10) guided_setup; exit 0 ;;
        4)
            read -rp "  Enter version (e.g. v3.7.0): " SPECIFIC_VERSION
            if [[ -z "$SPECIFIC_VERSION" ]]; then
                msg_error "No version specified"
                exit 1
            fi
            ;;
        5)
            echo ""
            msg_ok "Check complete. No changes made."
            echo ""
            exit 0
            ;;
        6) rollback_traefik ;;
        7) show_changelog; exit 0 ;;
        8) test_gotify ;;
        9) manage_cron ;;
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
fi

echo ""
echo -e "${TAB}${BL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"

# Update Traefik
if [[ "$SKIP_TRAEFIK" == false ]]; then
    echo ""
    echo -e "${TAB}${BL}▸ Traefik Binary${CL}"
    echo ""
    if [[ -n "$SPECIFIC_VERSION" ]]; then
        update_traefik "$SPECIFIC_VERSION"
    else
        update_traefik "$LATEST_TRAEFIK"
    fi
fi

# Update Manager
if [[ "$SKIP_MANAGER" == false ]]; then
    echo ""
    echo -e "${TAB}${BL}▸ Traefik Manager${CL}"
    echo ""
    update_manager
fi

# Summary
echo ""
echo -e "${TAB}${BL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
echo ""
FINAL_TRAEFIK=$(get_current_traefik_version)
FINAL_MANAGER=$(get_current_manager_version)
echo -e "${TAB}${GN}✓ Update complete!${CL}"
echo ""
echo -e "${TAB}  Traefik:          ${GN}${FINAL_TRAEFIK}${CL}"
if [[ -d "${TRAEFIK_MANAGER_DIR}/.git" ]]; then
    echo -e "${TAB}  Manager:          ${GN}${FINAL_MANAGER}${CL}"
fi
echo ""
echo -e "${TAB}${BL}Dashboards:${CL}"
echo -e "${TAB}  Traefik:  ${GN}http://${VM_IP}:${TRAEFIK_DASHBOARD_PORT}/dashboard/${CL}"
if [[ -d "${TRAEFIK_MANAGER_DIR}" ]]; then
    echo -e "${TAB}  Manager:  ${GN}http://${VM_IP}:${TRAEFIK_MANAGER_PORT}${CL}"
fi
echo ""

# Send Gotify notification (only in cron mode)
if [[ "$CRON_MODE" == true ]]; then
    manager_line=""
    if [[ -d "${TRAEFIK_MANAGER_DIR}/.git" ]]; then
        manager_line="**Manager:** \`${FINAL_MANAGER}\`"
    fi

    notify_message="### 🟢 Update Complete

**Host:** \`$(hostname)\` (${VM_IP})
**Time:** $(date '+%Y-%m-%d %H:%M:%S')
**Traefik:** \`${CURRENT_TRAEFIK}\` → \`${FINAL_TRAEFIK}\`
${manager_line}

| Dashboard | URL |
|-----------|-----|
| Traefik | http://${VM_IP}:${TRAEFIK_DASHBOARD_PORT}/dashboard/ |
| Manager | http://${VM_IP}:${TRAEFIK_MANAGER_PORT} |

*Automatic update via cron.*"

    send_gotify "🔄 Traefik Update — $(hostname)" "$notify_message"
fi

cleanup