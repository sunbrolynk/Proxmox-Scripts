#!/usr/bin/env bash

# NFS Watchdog — Monitor NFS mount health on Proxmox nodes
# https://github.com/SunBroLynk/Proxmox-Scripts
# License: MIT
#
# Detects stale or unresponsive NFS mounts before they cause
# cascading lock issues. Designed to run as a cron job on every
# cluster node.

# ============================================================
# CONFIGURATION
# ============================================================
# You can configure this script two ways:
#   • Run the guided setup:  nfs-watchdog --setup   (recommended; seals secrets for you)
#   • Or edit the values below directly (power users)
# Either way works — the script detects whichever you've used.
# (NFS mounts are auto-detected from /proc/mounts — nothing to configure there.)
# ------------------------------------------------------------

# --- Tunable: sane defaults, change only if your setup differs
CHECK_TIMEOUT=5                       # Seconds before declaring a mount stale
AUTO_REMOUNT=false                    # Auto-remount stale mounts (true/false); false = alert only
LOG_FILE="/var/log/nfs-watchdog.log"  # Log file for cron mode

# --- Optional: Gotify notifications (cron mode) --------------
# Leave the token empty here and seal it instead:  nfs-watchdog --set-cred gotify-token
GOTIFY_URL=""                         # Gotify server URL (e.g. http://10.10.3.6:80)
GOTIFY_TOKEN=""                       # Gotify token (prefer --set-cred over plaintext here)
GOTIFY_PRIORITY=5                     # Notification priority (1-10)
# ============================================================

set -euo pipefail
shopt -s inherit_errexit nullglob

# Script metadata
SCRIPT_NAME="nfs-watchdog"
SCRIPT_VERSION="1.2.1"
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
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"
INFO="${BL}ℹ${CL}"
TAB="  "

# Trap CTRL+C
trap 'echo -e "\n\n${TAB}${YW}⚠  Watchdog cancelled by user.${CL}\n"; exit 0' SIGINT SIGTERM

header_info() {
    clear
    cat <<"EOF"
  ___                              
 | _ \_ _ _____ ___ __  _____ __  
 |  _/ '_/ _ \ \ / '  \/ _ \ \ / 
 |_| |_| \___/_\_\_|_|_\___/_\_\  
      ╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍
          S c r i p t s

               __       __    __          
  _    _____ _/ /______/ /   / /__  ___ _
 | |/|/ / _ `/ __/ __/ _ \ / _ / _ \/ _ `/
 |__,__/\_,_/\__/\__/_//_//_//_\___/\_, / 
    nfs watchdog                   /___/  
EOF
    echo ""
}

show_help() {
    header_info
    echo -e "${BD}NAME${CL}"
    echo -e "${TAB}${SCRIPT_NAME} — monitor NFS mount health on Proxmox nodes"
    echo ""
    echo -e "${BD}SYNOPSIS${CL}"
    echo -e "${TAB}${SCRIPT_NAME} [${BL}OPTIONS${CL}]"
    echo ""
    echo -e "${BD}DESCRIPTION${CL}"
    echo -e "${TAB}Tests all NFS mounts on the local Proxmox node for"
    echo -e "${TAB}responsiveness using timed stat and write tests. Detects"
    echo -e "${TAB}stale mounts before they cause lock issues and container"
    echo -e "${TAB}deletion failures. Can optionally auto-remount stale"
    echo -e "${TAB}mounts and send Gotify alerts."
    echo ""
    echo -e "${TAB}Designed to run as a cron job on every cluster node."
    echo ""
    echo -e "${BD}OPTIONS${CL}"
    echo -e "${TAB}${GN}(no arguments)${CL}"
    echo -e "${TAB}${TAB}Launch interactive mode with guided menu."
    echo ""
    echo -e "${TAB}${GN}-y, --yes${CL}"
    echo -e "${TAB}${TAB}Run checks without prompts (for cron)."
    echo ""
    echo -e "${TAB}${GN}--status${CL}"
    echo -e "${TAB}${TAB}Show all NFS mounts and their current health."
    echo ""
    echo -e "${TAB}${GN}--dry-run${CL}"
    echo -e "${TAB}${TAB}Check mounts but don't remount or notify."
    echo ""
    echo -e "${TAB}${GN}--remount${CL}"
    echo -e "${TAB}${TAB}Force remount all NFS mounts (regardless of health)."
    echo ""
    echo -e "${TAB}${GN}--setup${CL}"
    echo -e "${TAB}${TAB}Guided setup wizard — walks detection timeout, stale-action,"
    echo -e "${TAB}${TAB}Gotify notifications (sealing the token), and scheduling."
    echo -e "${TAB}${TAB}Auto-offered on first run. Re-runnable."
    echo ""
    echo -e "${TAB}${GN}--set-cred <name>${CL}"
    echo -e "${TAB}${TAB}Seal a secret (e.g. gotify-token) read from stdin via systemd-creds."
    echo ""
    echo -e "${TAB}${GN}--test-notify${CL}"
    echo -e "${TAB}${TAB}Send a test notification to Gotify."
    echo ""
    echo -e "${TAB}${GN}--schedule [\"<cron expr>\"]${CL}"
    echo -e "${TAB}${TAB}With no argument: interactive menu to set/change/remove the schedule."
    echo -e "${TAB}${TAB}With a cron expression: set it non-interactively, e.g."
    echo -e "${TAB}${TAB}  ${BL}nfs-watchdog --schedule \"*/5 * * * *\"${CL}"
    echo -e "${TAB}${TAB}Use ${BL}--schedule remove${CL} to delete the schedule."
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
    local _cfgvars="CHECK_TIMEOUT AUTO_REMOUNT LOG_FILE GOTIFY_URL GOTIFY_TOKEN GOTIFY_PRIORITY"
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

    echo ""
    echo -e "${BD}FILES${CL}"
    echo -e "${TAB}${BL}/etc/pve/storage.cfg${CL}"
    echo -e "${TAB}${TAB}Proxmox storage configuration. NFS mounts detected from here."
    echo ""
    echo -e "${TAB}${BL}${LOG_FILE}${CL}"
    echo -e "${TAB}${TAB}Log output when running in cron/automated mode."
    echo ""
    echo -e "${BD}EXIT STATUS${CL}"
    echo -e "${TAB}${GN}0${CL}  All mounts healthy"
    echo -e "${TAB}${RD}1${CL}  One or more mounts stale or unresponsive"
    echo ""
    echo -e "${BD}EXAMPLES${CL}"
    echo -e "${TAB}Interactive health check:"
    echo -e "${TAB}  ${BL}sudo ${SCRIPT_NAME}${CL}"
    echo ""
    echo -e "${TAB}Quick status overview:"
    echo -e "${TAB}  ${BL}sudo ${SCRIPT_NAME} --status${CL}"
    echo ""
    echo -e "${TAB}Automated cron check every 5 minutes:"
    echo -e "${TAB}  ${BL}sudo crontab -e${CL}"
    echo -e "${TAB}  ${BL}*/5 * * * * /usr/local/bin/${SCRIPT_NAME} -y >> ${LOG_FILE} 2>&1${CL}"
    echo ""
    echo -e "${TAB}Dry run (check only, no remount or notify):"
    echo -e "${TAB}  ${BL}sudo ${SCRIPT_NAME} --dry-run${CL}"
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
# NFS DETECTION AND TESTING
# ============================================================

get_nfs_mounts() {
    # Get all NFS mounts from /proc/mounts
    awk '$3 ~ /^nfs/ {print $1, $2, $3}' /proc/mounts 2>/dev/null
}

# ------------------------------------------------------------
# Preflight — validate environment before doing anything else.
# Runs FIRST in MAIN (before the install nudge / setup / menu),
# matching the pve-config-backup / pi-hole-sync reference flow.
# ------------------------------------------------------------
preflight_checks() {
    echo -e "${TAB}${BD}Preflight Checks${CL}"
    local ok=true

    # NFS client tooling must be present to test/remount mounts.
    if command -v mount.nfs &>/dev/null || command -v mount.nfs4 &>/dev/null; then
        msg_ok "NFS client tools found (mount.nfs)"
    else
        msg_error "mount.nfs not found — install nfs-common (Debian/Ubuntu) or nfs-utils (RHEL)"
        ok=false
    fi

    # findmnt is used for mount inspection/remount; warn (not fatal) if missing.
    if command -v findmnt &>/dev/null; then
        msg_ok "findmnt available"
    else
        msg_warn "findmnt not found (part of util-linux) — some checks may be limited"
    fi

    # Detect NFS mounts. No mounts isn't fatal (they may appear later / on other
    # nodes), but the user should know the watchdog has nothing to watch yet.
    local mount_count
    mount_count=$(get_nfs_mounts | grep -c . || true)
    if [[ "$mount_count" -gt 0 ]]; then
        msg_ok "Found ${mount_count} NFS mount(s) to monitor"
    else
        msg_warn "No NFS mounts found on this node yet — nothing to monitor until one is mounted"
    fi

    echo ""
    if [[ "$ok" != true ]]; then
        msg_error "Preflight failed — resolve the above and re-run."
        echo ""
        exit 1
    fi
    msg_ok "All preflight checks passed"
    echo ""
}

# First run = no settings file yet. nfs-watchdog has no required-identity
# config (mounts auto-detect), so the only signal is "has the user run setup".
is_first_run() { [[ ! -f "$SETTINGS_FILE" ]]; }

# ------------------------------------------------------------
# Guided setup wizard — walks every setting needed for unattended
# operation (the whole point of a watchdog: cron + alerts), seals the
# Gotify token, persists answers, optionally schedules. Re-runnable.
# ------------------------------------------------------------
run_setup() {
    header_info
    echo -e "${TAB}${BD}Guided Setup${CL}"
    echo -e "${TAB}Answer each prompt. Press Enter to keep the [current] value."
    echo ""

    # --- 1) Stale-detection behavior ---
    echo -e "${TAB}${BD}1) Detection${CL}"
    read -rp "  Seconds before a mount is declared stale [${CHECK_TIMEOUT}]: " _v
    if [[ -n "$_v" ]]; then
        if [[ "$_v" =~ ^[0-9]+$ ]] && [[ "$_v" -ge 1 ]]; then
            CHECK_TIMEOUT="$_v"; settings_set CHECK_TIMEOUT "$_v"
        else
            msg_warn "Not a positive integer — keeping ${CHECK_TIMEOUT}"
        fi
    fi
    echo ""

    # --- 2) Action on stale ---
    echo -e "${TAB}${BD}2) Action when a mount is stale${CL}"
    echo -e "${TAB}  ${GN}1)${CL} Alert only (notify, make no changes)   ${YW}[safe default]${CL}"
    echo -e "${TAB}  ${GN}2)${CL} Auto-remount (attempt to fix, then notify)"
    local _cur_label="1 (alert only)"; [[ "$AUTO_REMOUNT" == "true" ]] && _cur_label="2 (auto-remount)"
    read -rp "  Choose [current: ${_cur_label}]: " _v
    case "$_v" in
        1) AUTO_REMOUNT="false"; settings_set AUTO_REMOUNT "false" ;;
        2) AUTO_REMOUNT="true";  settings_set AUTO_REMOUNT "true" ;;
        "") : ;;  # keep current
        *) msg_warn "Unrecognized choice — keeping ${_cur_label}" ;;
    esac
    echo ""

    # --- 3) Gotify notifications (optional, token sealed) ---
    echo -e "${TAB}${BD}3) Gotify notifications (optional)${CL}"
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
        fi
        read -rp "  Notification priority (1-10) [${GOTIFY_PRIORITY}]: " _v
        [[ -n "$_v" ]] && { GOTIFY_PRIORITY="$_v"; settings_set GOTIFY_PRIORITY "$_v"; }
    elif [[ -n "$GOTIFY_URL" ]]; then
        : # keep existing
    else
        msg_info "Skipping notifications"
    fi
    echo ""

    # --- 4) Schedule (optional, gated on install) ---
    echo -e "${TAB}${BD}4) Schedule${CL}"
    echo -e "${TAB}  A watchdog is most useful on a timer so it catches stale mounts unattended."
    if installed_ok; then
        read -rp "  Set up a cron schedule now? [Y/n]: " _v
        [[ ! "$_v" =~ ^[Nn]$ ]] && manage_cron
    else
        msg_warn "Not installed to ${SCRIPT_INSTALL_DEST} yet — scheduling needs that first."
        echo -e "${TAB}  Install via the first-run prompt (or rerun without --setup), then ${BL}--schedule${CL}."
    fi
    echo ""

    msg_ok "Setup complete."
    echo -e "${TAB}Settings saved to ${BL}${SETTINGS_FILE}${CL}"
    echo ""
}

test_mount_readable() {
    local mountpoint="$1"
    timeout "${CHECK_TIMEOUT}" stat "$mountpoint" &>/dev/null
    return $?
}

test_mount_writable() {
    local mountpoint="$1"
    local testfile="${mountpoint}/.nfs-watchdog-$(hostname)-$$"
    if timeout "${CHECK_TIMEOUT}" touch "$testfile" 2>/dev/null; then
        rm -f "$testfile" 2>/dev/null
        return 0
    fi
    return 1
}

test_mount_latency() {
    local mountpoint="$1"
    local start end elapsed
    start=$(date +%s%N)
    timeout "${CHECK_TIMEOUT}" stat "$mountpoint" &>/dev/null
    local rc=$?
    end=$(date +%s%N)
    if [[ $rc -eq 0 ]]; then
        elapsed=$(( (end - start) / 1000000 ))
        echo "$elapsed"
    else
        echo "timeout"
    fi
}

remount_nfs() {
    local mountpoint="$1"
    msg_info "Force remounting ${mountpoint}"

    # Try lazy unmount first (doesn't block)
    if umount -l "$mountpoint" 2>/dev/null; then
        sleep 1
        if mount "$mountpoint" 2>/dev/null; then
            sleep 1
            if test_mount_readable "$mountpoint"; then
                msg_ok "Remounted ${mountpoint} successfully"
                return 0
            fi
        fi
    fi

    # Try force unmount if lazy failed
    umount -f "$mountpoint" 2>/dev/null
    sleep 1
    if mount "$mountpoint" 2>/dev/null; then
        sleep 1
        if test_mount_readable "$mountpoint"; then
            msg_ok "Remounted ${mountpoint} successfully (force)"
            return 0
        fi
    fi

    msg_error "Failed to remount ${mountpoint}"
    echo -e "${TAB}  Manual intervention may be needed"
    return 1
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
            CHECK_TIMEOUT) CHECK_TIMEOUT="$val" ;;
            AUTO_REMOUNT) AUTO_REMOUNT="$val" ;;
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
    local token; token="$(resolve_gotify_token)"
    [[ -z "$token" ]] && { msg_error "No Gotify token — seal one: ${BL}${SCRIPT_NAME} --set-cred gotify-token${CL}"; echo ""; exit 1; }

    msg_info "Sending test notification to ${GOTIFY_URL}"
    local test_message="### ✅ Connection Successful

**Script:** \`${SCRIPT_NAME}\`
**Node:** \`$(hostname)\`
**Time:** $(date '+%Y-%m-%d %H:%M:%S')

*NFS Watchdog is configured and ready to send alerts.*"

    local curl_conf json_message response
    curl_conf=$(mktemp /tmp/.gotify-XXXXXX); chmod 600 "$curl_conf"
    printf 'header = "X-Gotify-Key: %s"\nheader = "Content-Type: application/json"\n' "$token" > "$curl_conf"
    json_message=$(printf '%s' "$test_message" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null)
    response=$(curl -s -o /dev/null -w "%{http_code}" -K "$curl_conf" -X POST "${GOTIFY_URL}/message" \
        -d "{\"title\":\"🐕 NFS Watchdog — Test\",\"message\":${json_message},\"priority\":${GOTIFY_PRIORITY},\"extras\":{\"client::display\":{\"contentType\":\"text/markdown\"}}}" 2>/dev/null)
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
# DISPLAY FUNCTIONS
# ============================================================

show_status() {
    header_info
    echo -e "${TAB}${BD}NFS Mount Status — $(hostname)${CL}"
    echo ""

    local mounts
    mounts=$(get_nfs_mounts)

    if [[ -z "$mounts" ]]; then
        msg_warn "No NFS mounts found on this node"
        echo ""
        exit 0
    fi

    printf "${TAB}  ${BD}%-35s %-8s %-10s %-10s %s${CL}\n" "Mount" "Type" "Read" "Write" "Latency"
    printf "${TAB}  ${BD}%-35s %-8s %-10s %-10s %s${CL}\n" "─────" "────" "────" "─────" "───────"

    while IFS=' ' read -r source mountpoint fstype; do
        local read_status write_status latency read_color write_color latency_color

        # Test read
        if test_mount_readable "$mountpoint"; then
            read_status="OK"
            read_color="${GN}"
        else
            read_status="STALE"
            read_color="${RD}"
        fi

        # Test write (only if readable)
        if [[ "$read_status" == "OK" ]]; then
            if test_mount_writable "$mountpoint"; then
                write_status="OK"
                write_color="${GN}"
            else
                write_status="DENIED"
                write_color="${YW}"
            fi
        else
            write_status="N/A"
            write_color="${RD}"
        fi

        # Test latency (only if readable)
        if [[ "$read_status" == "OK" ]]; then
            latency=$(test_mount_latency "$mountpoint")
            if [[ "$latency" == "timeout" ]]; then
                latency_color="${RD}"
                latency="TIMEOUT"
            elif [[ "$latency" -gt 1000 ]]; then
                latency_color="${RD}"
                latency="${latency}ms"
            elif [[ "$latency" -gt 200 ]]; then
                latency_color="${YW}"
                latency="${latency}ms"
            else
                latency_color="${GN}"
                latency="${latency}ms"
            fi
        else
            latency="N/A"
            latency_color="${RD}"
        fi

        printf "${TAB}  %-35s %-8s ${read_color}%-10s${CL} ${write_color}%-10s${CL} ${latency_color}%s${CL}\n" \
            "$mountpoint" "$fstype" "$read_status" "$write_status" "$latency"
    done <<< "$mounts"

    echo ""

    # Show mount options
    echo -e "${TAB}${BL}Mount Options:${CL}"
    while IFS=' ' read -r source mountpoint fstype; do
        local opts
        opts=$(grep "$mountpoint" /proc/mounts | awk '{print $4}' | head -1)
        local mount_mode
        if echo "$opts" | grep -q "hard"; then
            mount_mode="${RD}hard${CL}"
        elif echo "$opts" | grep -q "soft"; then
            mount_mode="${GN}soft${CL}"
        else
            mount_mode="${YW}unknown${CL}"
        fi
        echo -e "${TAB}  ${mountpoint}: ${mount_mode} (${opts})"
    done <<< "$mounts"

    echo ""
    exit 0
}

run_checks() {
    local DRY_RUN_MODE="$1"
    local STALE_MOUNTS=()
    local HEALTHY_MOUNTS=()
    local REMOUNTED_MOUNTS=()
    local FAILED_REMOUNTS=()

    echo -e "${TAB}${BL}NFS Health Check — $(hostname)${CL}"
    echo ""

    local mounts
    mounts=$(get_nfs_mounts)

    if [[ -z "$mounts" ]]; then
        msg_warn "No NFS mounts found on this node"
        return 0
    fi

    # Count mounts
    local MOUNT_COUNT
    MOUNT_COUNT=$(echo "$mounts" | wc -l)

    if [[ "$MOUNT_COUNT" -gt 1 ]]; then
        # Multiple mounts — check in parallel
        msg_info "Checking ${MOUNT_COUNT} mounts in parallel"
        echo ""

        local CHECK_RESULTS
        CHECK_RESULTS=$(mktemp -d /tmp/.nfs-check-XXXXXX)
        local CHECK_PIDS=()

        while IFS=' ' read -r source mountpoint fstype; do
            (
                local result="healthy"
                local latency="0"

                if ! test_mount_readable "$mountpoint"; then
                    result="stale"
                else
                    if ! test_mount_writable "$mountpoint"; then
                        result="readonly"
                    fi
                    latency=$(test_mount_latency "$mountpoint")
                    if [[ "$latency" == "timeout" ]]; then
                        result="stale"
                    elif [[ "$latency" -gt 1000 ]]; then
                        result="slow"
                    fi
                fi
                echo "${result}|${latency}" > "${CHECK_RESULTS}/$(echo "$mountpoint" | tr '/' '_')"
            ) &
            CHECK_PIDS+=($!)
        done <<< "$mounts"

        # Wait for all checks
        for pid in "${CHECK_PIDS[@]}"; do
            wait "$pid" 2>/dev/null || true
        done

        # Process results
        while IFS=' ' read -r source mountpoint fstype; do
            local result_file="${CHECK_RESULTS}/$(echo "$mountpoint" | tr '/' '_')"
            if [[ -f "$result_file" ]]; then
                local result latency
                IFS='|' read -r result latency < "$result_file"

                case "$result" in
                    stale)
                        msg_error "${mountpoint} — STALE (timed out after ${CHECK_TIMEOUT}s)"
                        STALE_MOUNTS+=("$mountpoint")
                        if [[ "$DRY_RUN_MODE" == true ]] && [[ "$AUTO_REMOUNT" == true ]]; then
                            msg_warn "Would auto-remount ${mountpoint}"
                        elif [[ "$DRY_RUN_MODE" != true ]] && [[ "$AUTO_REMOUNT" == true ]]; then
                            if remount_nfs "$mountpoint"; then
                                REMOUNTED_MOUNTS+=("$mountpoint")
                            else
                                FAILED_REMOUNTS+=("$mountpoint")
                            fi
                        fi
                        ;;
                    readonly)
                        msg_warn "${mountpoint} — readable but NOT writable"
                        HEALTHY_MOUNTS+=("$mountpoint")
                        ;;
                    slow)
                        msg_warn "${mountpoint} — healthy but slow (${latency}ms)"
                        HEALTHY_MOUNTS+=("$mountpoint")
                        ;;
                    healthy)
                        msg_ok "${mountpoint} — healthy (${latency}ms)"
                        HEALTHY_MOUNTS+=("$mountpoint")
                        ;;
                esac
            fi
        done <<< "$mounts"

        rm -rf "$CHECK_RESULTS"
    else
        # Single mount — check directly with live output
        while IFS=' ' read -r source mountpoint fstype; do
            msg_info "Checking ${mountpoint}"

            if ! test_mount_readable "$mountpoint"; then
                msg_error "${mountpoint} — STALE (read timed out after ${CHECK_TIMEOUT}s)"
                STALE_MOUNTS+=("$mountpoint")

                if [[ "$DRY_RUN_MODE" == true ]]; then
                    if [[ "$AUTO_REMOUNT" == true ]]; then
                        msg_warn "Would auto-remount ${mountpoint}"
                    fi
                    continue
                fi

                if [[ "$AUTO_REMOUNT" == true ]]; then
                    if remount_nfs "$mountpoint"; then
                        REMOUNTED_MOUNTS+=("$mountpoint")
                    else
                        FAILED_REMOUNTS+=("$mountpoint")
                    fi
                fi
                continue
            fi

            if ! test_mount_writable "$mountpoint"; then
                msg_warn "${mountpoint} — readable but NOT writable"
                HEALTHY_MOUNTS+=("$mountpoint")
                continue
            fi

            local latency
            latency=$(test_mount_latency "$mountpoint")
            if [[ "$latency" != "timeout" ]] && [[ "$latency" -gt 1000 ]]; then
                msg_warn "${mountpoint} — healthy but slow (${latency}ms)"
            else
                msg_ok "${mountpoint} — healthy (${latency}ms)"
            fi
            HEALTHY_MOUNTS+=("$mountpoint")
        done <<< "$mounts"
    fi

    echo ""

    # Summary
    echo -e "${TAB}${BL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
    echo ""
    echo -e "${TAB}  Healthy:    ${GN}${#HEALTHY_MOUNTS[@]}${CL}"
    echo -e "${TAB}  Stale:      ${RD}${#STALE_MOUNTS[@]}${CL}"
    if [[ ${#REMOUNTED_MOUNTS[@]} -gt 0 ]]; then
        echo -e "${TAB}  Remounted:  ${GN}${#REMOUNTED_MOUNTS[@]}${CL}"
    fi
    if [[ ${#FAILED_REMOUNTS[@]} -gt 0 ]]; then
        echo -e "${TAB}  Failed:     ${RD}${#FAILED_REMOUNTS[@]}${CL}"
    fi
    echo ""

    # Send Gotify alert if stale mounts found (not in dry run)
    if [[ ${#STALE_MOUNTS[@]} -gt 0 ]] && [[ "$DRY_RUN_MODE" != true ]]; then
        local stale_rows healthy_rows node_ip
        node_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
        stale_rows=""
        for m in "${STALE_MOUNTS[@]}"; do
            stale_rows="${stale_rows}| \`${m}\` | 🔴 **STALE** |\n"
        done
        healthy_rows=""
        for m in "${HEALTHY_MOUNTS[@]}"; do
            healthy_rows="${healthy_rows}| \`${m}\` | 🟢 Healthy |\n"
        done

        local alert_message="### 🔴 Stale NFS Mount Detected

**Node:** \`$(hostname)\` (${node_ip})
**Time:** $(date '+%Y-%m-%d %H:%M:%S')
**Timeout:** ${CHECK_TIMEOUT}s

| Mount | Status |
|-------|--------|
${stale_rows}${healthy_rows}
**Auto-remount:** ${AUTO_REMOUNT}"

        if [[ ${#REMOUNTED_MOUNTS[@]} -gt 0 ]]; then
            alert_message="${alert_message}
**Remounted:** ${#REMOUNTED_MOUNTS[@]} mount(s) recovered"
        fi

        if [[ ${#FAILED_REMOUNTS[@]} -gt 0 ]]; then
            alert_message="${alert_message}
**⚠️ Failed remounts:** ${#FAILED_REMOUNTS[@]} — manual intervention needed"
        fi

        send_gotify "🐕 NFS Watchdog — $(hostname)" "$alert_message" 8

        if [[ -n "$GOTIFY_URL" ]] && [[ -n "$GOTIFY_TOKEN" ]]; then
            msg_ok "Gotify alert sent"
        fi
    fi

    # Return non-zero if any mounts are stale
    if [[ ${#STALE_MOUNTS[@]} -gt 0 ]]; then
        return 1
    fi
    return 0
}

force_remount_all() {
    echo -e "${TAB}${BL}Force Remount All NFS Mounts — $(hostname)${CL}"
    echo ""

    local mounts
    mounts=$(get_nfs_mounts)

    if [[ -z "$mounts" ]]; then
        msg_warn "No NFS mounts found on this node"
        return 0
    fi

    while IFS=' ' read -r source mountpoint fstype; do
        remount_nfs "$mountpoint"
    done <<< "$mounts"

    echo ""
}

manage_cron() {
    local CRON_CMD="${SCRIPT_INSTALL_DEST} -y >> ${LOG_FILE} 2>&1"

    # Non-interactive form: manage_cron "<cron expr>" (from --schedule "<expr>").
    # Lets power users set the schedule in one shot, e.g.:
    #   nfs-watchdog --schedule "*/5 * * * *"
    # Use the literal word "remove" to delete the schedule non-interactively.
    local DIRECT_EXPR="${1:-}"
    if [[ -n "$DIRECT_EXPR" ]]; then
        header_info
        echo -e "${TAB}${BD}Schedule Manager${CL}"
        echo ""
        if [[ "$DIRECT_EXPR" == "remove" ]]; then
            { crontab -l 2>/dev/null | grep -v "${SCRIPT_NAME}" || true; } | crontab -
            msg_ok "Schedule removed"; echo ""; exit 0
        fi
        # Validate: a cron expression must have exactly 5 fields.
        local _fieldcount; _fieldcount=$(awk '{print NF}' <<<"$DIRECT_EXPR")
        if [[ "$_fieldcount" -ne 5 ]]; then
            msg_error "Invalid cron expression: expected 5 fields, got ${_fieldcount}"
            echo -e "${TAB}  Example: ${BL}\"*/5 * * * *\"${CL}  (every 5 minutes)"
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
    echo -e "${TAB}  ${GN}1)${CL} Every 5 minutes (recommended)"
    echo -e "${TAB}  ${GN}2)${CL} Every 10 minutes"
    echo -e "${TAB}  ${GN}3)${CL} Every 15 minutes"
    echo -e "${TAB}  ${GN}4)${CL} Every 30 minutes"
    echo -e "${TAB}  ${GN}5)${CL} Every hour"
    echo -e "${TAB}  ${GN}6)${CL} Custom cron expression"
    echo -e "${TAB}  ${RD}q)${CL} Cancel"
    echo ""
    read -rp "  Select [1-6/q]: " schedule_choice

    local CRON_SCHEDULE=""
    case "$schedule_choice" in
        1) CRON_SCHEDULE="*/5 * * * *" ;;
        2) CRON_SCHEDULE="*/10 * * * *" ;;
        3) CRON_SCHEDULE="*/15 * * * *" ;;
        4) CRON_SCHEDULE="*/30 * * * *" ;;
        5) CRON_SCHEDULE="0 * * * *" ;;
        6)
            read -rp "  Cron expression (e.g. */5 * * * *): " CRON_SCHEDULE
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

# Early exit for help, version, status (read-only)
load_settings
for arg in "${@:-}"; do
    case "${arg:-}" in
        --help|-h) show_help ;;
        --version|-V)
            echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"
            echo "${SCRIPT_URL}"
            exit 0
            ;;
        --status) show_status ;;
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
        --setup) header_info; preflight_checks; run_setup; exit 0 ;;
        --test-notify) test_gotify ;;
        --schedule) manage_cron "${ARGS[$((i+1))]:-}" ;;
    esac
    i=$((i+1))
done

# Parse flags
AUTO_YES=false
DRY_RUN=false
DO_REMOUNT_ALL=false
INTERACTIVE=true

for arg in "${@:-}"; do
    case "${arg:-}" in
        --yes|-y) AUTO_YES=true; INTERACTIVE=false ;;
        --dry-run) DRY_RUN=true; INTERACTIVE=false ;;
        --remount) DO_REMOUNT_ALL=true; INTERACTIVE=false ;;
    esac
done

# Preflight — validate the environment before prompting for anything.
preflight_checks

# One-time install nudge (interactive only) so cron can run the canonical path.
# Runs AFTER preflight — validate the environment before prompting to install
# (matches the pve-config-backup / pi-hole-sync reference flow).
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

# First-run: auto-offer guided setup when nothing is configured yet. A watchdog
# needs schedule + notifications to be useful, so we walk the user through it.
if [[ "$INTERACTIVE" == true ]] && is_first_run; then
    echo -e "${TAB}${YW}Looks like a fresh setup — nothing is configured yet.${CL}"
    read -rp "  Run the guided setup now? [Y/n]: " _ans
    if [[ ! "$_ans" =~ ^[Nn]$ ]]; then run_setup; fi
    echo ""
fi

# Interactive menu
if [[ "$INTERACTIVE" == true ]]; then
    echo -e "${TAB}${BL}What would you like to do?${CL}"
    echo ""
    echo -e "${TAB}  ${GN}1)${CL} Run NFS health check"
    echo -e "${TAB}  ${GN}2)${CL} Show mount status (detailed)"
    echo -e "${TAB}  ${GN}3)${CL} Dry run (check only, no remount)"
    echo -e "${TAB}  ${GN}4)${CL} Force remount all NFS mounts"
    echo -e "${TAB}  ${GN}5)${CL} Test Gotify notification"
    echo -e "${TAB}  ${GN}6)${CL} Manage cron schedule"
    echo -e "${TAB}  ${GN}7)${CL} Guided setup (reconfigure everything)"
    echo -e "${TAB}  ${RD}q)${CL} Quit"
    echo ""
    read -rp "  Select an option [1-7/q]: " choice

    case "$choice" in
        1) ;;
        2) show_status ;;
        3) DRY_RUN=true ;;
        4) DO_REMOUNT_ALL=true ;;
        5) test_gotify ;;
        6) manage_cron ;;
        7) run_setup; exit 0 ;;
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

echo -e "${TAB}${BL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
echo ""

# Force remount all
if [[ "$DO_REMOUNT_ALL" == true ]]; then
    force_remount_all
    exit 0
fi

# Run health checks
if run_checks "$DRY_RUN"; then
    msg_ok "All NFS mounts healthy"
else
    if [[ "$DRY_RUN" == true ]]; then
        msg_warn "Stale mounts detected (dry run — no action taken)"
    else
        msg_error "Stale mount(s) detected — check output above"
    fi
fi
echo ""