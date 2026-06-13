#!/usr/bin/env bash

# <SCRIPT TITLE> — <one-line description>
# https://github.com/SunBroLynk/Proxmox-Scripts
# License: MIT
#
# <Longer description of what this does and why.>
# <Which environment it targets: inside a VM/LXC, or on a Proxmox host.>
#
# This template carries the repo's shared conventions as a correct, tested floor:
# hardened cron scheduling (no silent-fail), on-demand dependency installation
# (require_dep), and sealed Gotify credentials. Sealing/Gotify stay dormant unless
# GOTIFY_URL is set, so a script with no notifications pays nothing for them.
# Delete the subsystems a given script doesn't use.

# ============================================================
# CONFIGURATION
# ============================================================
# You can configure this script two ways:
#   • Run the guided setup:  <script-name> --setup   (recommended; seals secrets for you)
#   • Or edit the values below directly (power users)
# Either way works — the script detects whichever you've used.
# ------------------------------------------------------------

# --- Required: <identity> (if your script needs one) ---------
# If there's a value the script can't sensibly default (a target host, a path),
# ship it EMPTY here (not a fake placeholder) and treat "configured" as
# settings-file-exists OR this var non-empty. If your script auto-detects its
# target (like nfs-watchdog), delete this group entirely.
EXAMPLE_TARGET=""                    # <description> — ship empty, no fake placeholder

# --- Tunable: sane defaults, change only if your setup differs
EXAMPLE_USER="root"                  # <description>
EXAMPLE_TIMEOUT=5                    # <description>
LOG_FILE="/var/log/<script-name>.log"  # Log file for cron mode

# --- Optional: Gotify notifications (cron mode) --------------
# Leave the token empty here and seal it instead:  <script-name> --set-cred gotify-token
GOTIFY_URL=""                        # Gotify server URL (e.g. http://10.0.0.5:80)
GOTIFY_TOKEN=""                      # Gotify token (prefer --set-cred over plaintext here)
GOTIFY_PRIORITY=5                    # Notification priority (1-10)
# ============================================================

set -euo pipefail
shopt -s inherit_errexit nullglob

# Script metadata
SCRIPT_NAME="<script-name>"
SCRIPT_VERSION="2.1.0"
SCRIPT_URL="https://github.com/SunBroLynk/Proxmox-Scripts"
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_INSTALL_DEST="/usr/local/bin/${SCRIPT_NAME}"   # canonical path cron runs

# State (only used if the script schedules / seals / persists settings)
STATE_DIR="/etc/${SCRIPT_NAME}"
SECRETS_DIR="${STATE_DIR}/secrets"
SETTINGS_FILE="${STATE_DIR}/config.env"
SECRET_PREFIX="${SCRIPT_NAME}"        # namespacing for systemd-creds --name
INSTALL_NUDGE_DISMISSED=""

# --- Cron interval presets: SET THESE PER SCRIPT ---
# A label and a cron expression per line. Pick intervals that make sense for THIS
# script — a watchdog wants minutes; a backup wants daily/weekly. Keep "Custom".
CRON_PRESETS=(
    "Daily at 3:00 AM|0 3 * * *"
    "Weekly (Sunday 3:00 AM)|0 3 * * 0"
    "Every 6 hours|0 */6 * * *"
    "Every hour|0 * * * *"
    "Every 5 minutes|*/5 * * * *"
)

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

TEMP_FILES=()
cleanup() { for f in "${TEMP_FILES[@]:-}"; do rm -f "$f" 2>/dev/null; done; }

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
# SEALED CREDENTIALS (systemd-creds + chmod-600 fallback)
# Dormant unless the script actually seals/uses a secret. See PATTERNS.md #14.
# ============================================================
have_systemd_creds() { command -v systemd-creds &>/dev/null; }

# Seal a secret (value on stdin) under a logical name. Echoes the method used.
secret_set() {
    local name="$1" value
    value="$(cat)"
    mkdir -p "$SECRETS_DIR"; chmod 700 "$SECRETS_DIR"
    if have_systemd_creds; then
        if printf '%s' "$value" | systemd-creds encrypt --name="${SECRET_PREFIX}-${name}" - "${SECRETS_DIR}/${name}.cred" 2>/dev/null; then
            chmod 600 "${SECRETS_DIR}/${name}.cred"
            rm -f "${SECRETS_DIR}/${name}.secret" 2>/dev/null || true
            echo "systemd-creds"; return 0
        fi
    fi
    printf '%s' "$value" > "${SECRETS_DIR}/${name}.secret"
    chmod 600 "${SECRETS_DIR}/${name}.secret"
    rm -f "${SECRETS_DIR}/${name}.cred" 2>/dev/null || true
    echo "file-600"; return 0
}

secret_get() {
    local name="$1"
    if [[ -f "${SECRETS_DIR}/${name}.cred" ]] && have_systemd_creds; then
        systemd-creds decrypt --name="${SECRET_PREFIX}-${name}" "${SECRETS_DIR}/${name}.cred" - 2>/dev/null && return 0
    fi
    if [[ -f "${SECRETS_DIR}/${name}.secret" ]]; then cat "${SECRETS_DIR}/${name}.secret"; return 0; fi
    return 1
}

secret_exists() { [[ -f "${SECRETS_DIR}/$1.cred" || -f "${SECRETS_DIR}/$1.secret" ]]; }
secret_method() { [[ -f "${SECRETS_DIR}/$1.cred" ]] && echo "systemd-creds (sealed)" || { [[ -f "${SECRETS_DIR}/$1.secret" ]] && echo "file-600" || echo "none"; }; }

# Resolve the Gotify token: prefer a sealed secret, else the plaintext config var.
resolve_gotify_token() {
    if secret_exists gotify-token; then secret_get gotify-token; else printf '%s' "$GOTIFY_TOKEN"; fi
}

# ============================================================
# SETTINGS FILE (whitelist-parsed, never sourced). See PATTERNS.md #15.
# ============================================================
load_settings() {
    [[ -f "$SETTINGS_FILE" ]] || return 0
    local line key val
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        key="${line%%=*}"; val="${line#*=}"; val="${val%\"}"; val="${val#\"}"
        case "$key" in
            GOTIFY_URL)              GOTIFY_URL="$val" ;;
            GOTIFY_PRIORITY)         GOTIFY_PRIORITY="$val" ;;
            INSTALL_NUDGE_DISMISSED) INSTALL_NUDGE_DISMISSED="$val" ;;
        esac
    done < "$SETTINGS_FILE"
}

settings_set() {
    local key="$1" val="$2" tmp
    mkdir -p "$(dirname "$SETTINGS_FILE")"; chmod 700 "$(dirname "$SETTINGS_FILE")"
    touch "$SETTINGS_FILE"; chmod 600 "$SETTINGS_FILE"
    tmp=$(mktemp /tmp/.cfg-set-XXXXXX); TEMP_FILES+=("$tmp")
    grep -v "^${key}=" "$SETTINGS_FILE" > "$tmp" 2>/dev/null || true
    echo "${key}=\"${val}\"" >> "$tmp"
    cat "$tmp" > "$SETTINGS_FILE"; chmod 600 "$SETTINGS_FILE"; rm -f "$tmp"
}

# ============================================================
# GOTIFY (secure — token in a chmod-600 curl config header, never in argv)
# ============================================================
gotify_configured() {
    [[ -n "$GOTIFY_URL" ]] || return 1
    secret_exists gotify-token && return 0
    [[ -n "$GOTIFY_TOKEN" ]]
}

send_gotify() {
    local title="$1" message="$2" priority="${3:-$GOTIFY_PRIORITY}"
    gotify_configured || return 0
    local token curl_conf json_message
    token="$(resolve_gotify_token)"; [[ -z "$token" ]] && return 0
    json_message=$(printf '%s' "$message" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null || printf '"%s"' "$message")
    curl_conf=$(mktemp /tmp/.gotify-XXXXXX); chmod 600 "$curl_conf"; TEMP_FILES+=("$curl_conf")
    printf 'header = "X-Gotify-Key: %s"\nheader = "Content-Type: application/json"\n' "$token" > "$curl_conf"
    curl -s -K "$curl_conf" -X POST "${GOTIFY_URL}/message" \
        -d "{\"title\":\"${title}\",\"message\":${json_message},\"priority\":${priority},\"extras\":{\"client::display\":{\"contentType\":\"text/markdown\"}}}" &>/dev/null || true
    rm -f "$curl_conf"
}

test_gotify() {
    header_info
    echo -e "${TAB}${BD}Gotify Notification Test${CL}"
    echo ""
    [[ -z "$GOTIFY_URL" ]] && { msg_error "GOTIFY_URL not configured"; echo ""; exit 1; }
    require_dep curl curl "curl" || { echo ""; exit 1; }
    require_dep python3 python3 "python3 (for JSON encoding)" || { echo ""; exit 1; }
    local token; token="$(resolve_gotify_token)"
    [[ -z "$token" ]] && { msg_error "No Gotify token (set one with: ${SCRIPT_NAME} --set-cred gotify-token)"; echo ""; exit 1; }

    msg_info "Sending test notification to ${GOTIFY_URL}"
    local curl_conf json_message response test_message
    test_message="### ✅ Connection Successful

**Script:** \`${SCRIPT_NAME}\`
**Host:** \`$(hostname)\`
**Time:** $(date '+%Y-%m-%d %H:%M:%S')

*${SCRIPT_NAME} is configured and ready to send alerts.*"
    curl_conf=$(mktemp /tmp/.gotify-XXXXXX); chmod 600 "$curl_conf"; TEMP_FILES+=("$curl_conf")
    printf 'header = "X-Gotify-Key: %s"\nheader = "Content-Type: application/json"\n' "$token" > "$curl_conf"
    json_message=$(printf '%s' "$test_message" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null)
    response=$(curl -s -o /dev/null -w "%{http_code}" -K "$curl_conf" -X POST "${GOTIFY_URL}/message" \
        -d "{\"title\":\"🔔 ${SCRIPT_NAME} — Test\",\"message\":${json_message},\"priority\":${GOTIFY_PRIORITY},\"extras\":{\"client::display\":{\"contentType\":\"text/markdown\"}}}" 2>/dev/null)
    rm -f "$curl_conf"
    [[ "$response" == "200" ]] && msg_ok "Test notification sent successfully" || msg_error "Notification failed (HTTP ${response})"
    echo ""
    exit 0
}

# ============================================================
# DEPENDENCIES (on-demand). See PATTERNS.md #18.
# require_dep <command> <apt-package> <friendly-label>
# Offers install when interactive; fails loud (returns 1) under cron.
# ============================================================
require_dep() {
    local cmd="$1" pkg="$2" label="${3:-$2}"
    if command -v "$cmd" &>/dev/null; then msg_ok "${label} present"; return 0; fi
    if [[ "${INTERACTIVE:-true}" == true ]]; then
        msg_warn "${label} not installed (package: ${pkg})"
        read -rp "  Install ${pkg} now? [Y/n]: " a
        if [[ ! "$a" =~ ^[Nn]$ ]]; then
            if apt-get update -qq >/dev/null 2>&1 && apt-get install -y "$pkg" >/dev/null 2>&1; then
                msg_ok "${pkg} installed"; return 0
            fi
            msg_error "Install failed — install ${pkg} manually (apt-get install -y ${pkg})"; return 1
        fi
        return 1
    fi
    msg_error "${label} missing — install it: apt-get install -y ${pkg}"
    return 1
}

# ============================================================
# CRON SCHEDULE MANAGER (hardened — no silent-fail). See PATTERNS.md #9.
# ============================================================
# Write/replace this script's cron entry, then VERIFY it landed.
# `|| true` keeps an empty grep result from tripping pipefail and aborting silently.
cron_write() {
    local expr="$1"
    local cmd="${SCRIPT_INSTALL_DEST} -y >> ${LOG_FILE} 2>&1"
    { crontab -l 2>/dev/null | grep -v "${SCRIPT_NAME}" || true; echo "${expr} ${cmd}"; } | crontab -
    crontab -l 2>/dev/null | grep -q "${SCRIPT_NAME}"   # verify, never assume success
}

cron_remove() {
    { crontab -l 2>/dev/null | grep -v "${SCRIPT_NAME}" || true; } | crontab -
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

# Scheduling needs the script at the canonical path (cron runs that exact path).
require_installed_for_schedule() {
    installed_ok && return 0
    echo ""
    msg_warn "Scheduling needs the script at ${SCRIPT_INSTALL_DEST} — cron runs that exact path."
    read -rp "  Install it there now? [Y/n]: " a
    if [[ ! "$a" =~ ^[Nn]$ ]]; then
        install_self && { settings_set INSTALL_NUDGE_DISMISSED ""; INSTALL_NUDGE_DISMISSED=""; return 0; }
        return 1
    fi
    msg_warn "Cannot schedule without installing first."
    return 1
}

manage_cron() {
    # Non-interactive form: manage_cron "<cron expr>" (from --schedule "<expr>").
    # One-shot scheduling for power users; "remove" deletes the schedule.
    local DIRECT_EXPR="${1:-}"
    if [[ -n "$DIRECT_EXPR" ]]; then
        header_info
        echo -e "${TAB}${BD}Schedule Manager${CL}"
        echo ""
        if [[ "$DIRECT_EXPR" == "remove" ]]; then
            cron_remove; msg_ok "Schedule removed"; echo ""; exit 0
        fi
        local _fc; _fc=$(awk '{print NF}' <<<"$DIRECT_EXPR")
        if [[ "$_fc" -ne 5 ]]; then
            msg_error "Invalid cron expression: expected 5 fields, got ${_fc}"
            echo -e "${TAB}  Example: ${BL}\"0 3 * * *\"${CL}"
            echo ""; exit 1
        fi
        require_installed_for_schedule || { echo ""; msg_warn "Not scheduled."; echo ""; exit 0; }
        if cron_write "$DIRECT_EXPR"; then
            msg_ok "Schedule set: ${GN}${DIRECT_EXPR}${CL}"
            echo -e "${TAB}  ${BL}${DIRECT_EXPR} ${SCRIPT_INSTALL_DEST} -y >> ${LOG_FILE} 2>&1${CL}"
        else
            msg_error "Schedule write failed — is cron installed and running?"
        fi
        echo ""; exit 0
    fi

    header_info
    echo -e "${TAB}${BD}Schedule Manager${CL}"
    echo ""
    local current
    current=$(crontab -l 2>/dev/null | grep "${SCRIPT_NAME}" || true)
    if [[ -n "$current" ]]; then
        echo -e "${TAB}  ${GN}Current:${CL} ${BL}${current}${CL}"
        echo ""
        echo -e "${TAB}  ${GN}1)${CL} Change schedule    ${GN}2)${CL} Remove schedule    ${RD}q)${CL} Back"
        echo ""
        read -rp "  Select [1-2/q]: " c
        case "$c" in
            1) ;;
            2) cron_remove; echo ""; msg_ok "Schedule removed"; echo ""; exit 0 ;;
            *) echo ""; exit 0 ;;
        esac
        echo ""
    else
        echo -e "${TAB}  ${YW}No schedule configured${CL}"; echo ""
    fi

    # Gate on being installed at the canonical path.
    require_installed_for_schedule || { echo ""; msg_warn "Not scheduled."; echo ""; exit 0; }

    echo -e "${TAB}  ${BD}How often should ${SCRIPT_NAME} run?${CL}"
    echo ""
    local i=1 label expr
    for entry in "${CRON_PRESETS[@]}"; do
        label="${entry%%|*}"
        echo -e "${TAB}  ${GN}${i})${CL} ${label}"
        i=$((i+1))
    done
    echo -e "${TAB}  ${GN}${i})${CL} Custom cron expression"
    echo -e "${TAB}  ${RD}q)${CL} Cancel"
    echo ""
    read -rp "  Select [1-${i}/q]: " choice
    local cron_expr=""
    if [[ "$choice" == "q" || "$choice" == "Q" ]]; then echo ""; exit 0; fi
    if [[ "$choice" == "$i" ]]; then
        read -rp "  Cron expression (e.g. '0 3 * * *'): " cron_expr
        [[ -z "$cron_expr" ]] && { msg_error "No expression"; exit 1; }
    elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<i )); then
        cron_expr="${CRON_PRESETS[$((choice-1))]#*|}"
    else
        msg_error "Invalid selection"; exit 1
    fi

    echo ""
    if cron_write "$cron_expr"; then
        msg_ok "Schedule set: ${GN}${cron_expr}${CL}"
        echo -e "${TAB}  ${BL}${cron_expr} ${SCRIPT_INSTALL_DEST} -y >> ${LOG_FILE} 2>&1${CL}"
    else
        msg_error "Schedule write failed — could not update crontab. Is cron installed and running?"
    fi
    echo ""
    exit 0
}

# ============================================================
# CRED-SET (seal a secret from stdin/TTY — automation-friendly)
# ============================================================
do_set_cred() {
    local name="$1"
    [[ -z "$name" ]] && { header_info; msg_error "--set-cred requires a name (e.g. gotify-token)"; exit 1; }
    local method
    if [[ -t 0 ]]; then
        read -rsp "Enter value for '${name}': " _v; echo "" >&2
        method=$(printf '%s' "$_v" | secret_set "$name")
    else
        method=$(secret_set "$name")
    fi
    echo "Sealed '${name}' via ${method}" >&2
    exit 0
}

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
    echo -e "${BD}OPTIONS${CL}"
    echo -e "${TAB}${GN}(no arguments)${CL}  Launch interactive mode with guided menu."
    echo -e "${TAB}${GN}-y, --yes${CL}        Run without prompts (for cron)."
    echo -e "${TAB}${GN}--setup${CL}          Guided setup wizard (auto-offered on first run; re-runnable)."
    echo -e "${TAB}${GN}--schedule ${BL}[\"<cron>\"]${CL}  Interactive scheduler, or set non-interactively:"
    echo -e "${TAB}                 ${BL}${SCRIPT_NAME} --schedule \"0 3 * * *\"${CL} (or ${BL}--schedule remove${CL})."
    echo -e "${TAB}${GN}--test-notify${CL}    Send a test notification to Gotify."
    echo -e "${TAB}${GN}--set-cred ${BL}<name>${CL}  Seal a secret (e.g. gotify-token) via systemd-creds."
    echo -e "${TAB}${GN}-h, --help${CL}       Display this help and exit."
    echo -e "${TAB}${GN}-V, --version${CL}    Display script version and exit."
    echo ""
    echo -e "${BD}CONFIGURATION${CL}"
    echo -e "${TAB}Edit the variables at the top of this script. File: ${BL}${SCRIPT_PATH}${CL}"
    echo ""
    echo -e "${TAB}${BD}Variable                    Line  Current Value${CL}"
    echo -e "${TAB}──────────────────────────  ────  ─────────────────────────"
    # Allowlist of YOUR real config vars (not a blocklist of everything else).
    # This is the converged standard: an allowlist can't leak runtime/state vars
    # no matter where they sit, and the comment-strip keeps values clean.
    local _cfgvars="EXAMPLE_TARGET EXAMPLE_USER EXAMPLE_TIMEOUT LOG_FILE GOTIFY_URL GOTIFY_TOKEN GOTIFY_PRIORITY"
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
    echo -e "${TAB}${BL}${SCRIPT_INSTALL_DEST}${CL}   Canonical install location (what cron runs)."
    echo -e "${TAB}${BL}${LOG_FILE}${CL}   Log output in cron/automated mode."
    echo -e "${TAB}${BL}${SECRETS_DIR}/${CL}   Sealed credentials (chmod 600)."
    echo ""
    echo -e "${BD}EXIT STATUS${CL}"
    echo -e "${TAB}${GN}0${CL}  Success    ${RD}1${CL}  Error"
    echo ""
    echo -e "${BD}EXAMPLES${CL}"
    echo -e "${TAB}Interactive:        ${BL}sudo ${SCRIPT_NAME}${CL}"
    echo -e "${TAB}Automated via cron: ${BL}sudo ${SCRIPT_NAME} -y >> ${LOG_FILE} 2>&1${CL}"
    echo -e "${TAB}Seal Gotify token:  ${BL}sudo ${SCRIPT_NAME} --set-cred gotify-token${CL}"
    echo ""
    echo -e "${BD}LICENSE${CL}"
    echo -e "${TAB}MIT — ${SCRIPT_URL}/blob/main/LICENSE"
    echo ""
    exit 0
}

# ============================================================
# PREFLIGHT CHECKS (on-demand deps; gate by what's configured)
# ============================================================
preflight_checks() {
    echo -e "${TAB}${BL}Preflight Checks${CL}"
    echo ""
    local CRITICAL=false

    # Example: a dependency this script ALWAYS needs.
    # require_dep curl curl "curl" || CRITICAL=true

    # Example: a dependency needed ONLY when a feature is configured.
    # if [[ -n "$GOTIFY_URL" ]]; then require_dep curl curl "curl (Gotify configured)" || CRITICAL=true; fi

    echo ""
    if [[ "$CRITICAL" == true ]]; then
        msg_error "Preflight checks failed"; echo ""; exit 1
    fi
    msg_ok "All preflight checks passed"
    echo ""
}

# First run = no settings file yet. If your script has a REQUIRED identity var,
# also treat a non-empty config-block value as "configured" (so power users who
# fill the block aren't nagged):  [[ ! -f "$SETTINGS_FILE" && -z "${EXAMPLE_TARGET// }" ]]
is_first_run() { [[ ! -f "$SETTINGS_FILE" ]]; }

# ============================================================
# GUIDED SETUP WIZARD
# ============================================================
# House standard: any script with settings, secrets, or scheduling has a wizard
# that walks every knob needed for unattended operation, seals secrets, persists
# answers, and optionally schedules. It's auto-offered on first run, available via
# --setup, and as a menu item. The config block is the power-user fallback; the
# settings file is the source of truth (load_settings overrides the block).
guided_setup() {
    header_info
    echo -e "${TAB}${BD}Guided Setup${CL}"
    echo -e "${TAB}Answer each prompt. Press Enter to keep the [current] value."
    echo ""

    # --- 1) Required identity (delete this group if the script auto-detects) ---
    echo -e "${TAB}${BD}1) <Identity>${CL}"
    read -rp "  <Target> [${EXAMPLE_TARGET}]: " _v
    [[ -n "$_v" ]] && { EXAMPLE_TARGET="$_v"; settings_set EXAMPLE_TARGET "$_v"; }
    echo ""

    # --- 2) Tunables ---
    echo -e "${TAB}${BD}2) Behavior${CL}"
    read -rp "  <Timeout> seconds [${EXAMPLE_TIMEOUT}]: " _v
    [[ -n "$_v" ]] && { EXAMPLE_TIMEOUT="$_v"; settings_set EXAMPLE_TIMEOUT "$_v"; }
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
            require_dep python3 python3 "python3 (for JSON encoding)" || true
        fi
        read -rp "  Notification priority (1-10) [${GOTIFY_PRIORITY}]: " _v
        [[ -n "$_v" ]] && { GOTIFY_PRIORITY="$_v"; settings_set GOTIFY_PRIORITY "$_v"; }
    else
        msg_info "Skipping notifications"
    fi
    echo ""

    # --- 4) Schedule (optional, gated on install) ---
    echo -e "${TAB}${BD}4) Schedule${CL}"
    if installed_ok; then
        read -rp "  Set up a cron schedule now? [Y/n]: " _v
        [[ ! "$_v" =~ ^[Nn]$ ]] && manage_cron
    else
        msg_warn "Not installed to ${SCRIPT_INSTALL_DEST} yet — scheduling needs that first."
    fi
    echo ""

    msg_ok "Setup complete."
    echo -e "${TAB}Settings saved to ${BL}${SETTINGS_FILE}${CL}"
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
load_settings   # pull GOTIFY_URL etc. from SETTINGS_FILE if present

# Early exit for help, version, and read-only / one-shot flags
ARGS=("${@:-}")
for arg in "${ARGS[@]}"; do
    case "${arg:-}" in
        --help|-h) show_help ;;
        --version|-V) echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"; echo "${SCRIPT_URL}"; exit 0 ;;
    esac
done

# Root check (remove if the script doesn't need root)
if [[ $EUID -ne 0 ]]; then
    header_info; msg_error "This script must be run as root (use sudo)"; exit 1
fi

# These flags need root, so they come after the root check.
i=0
while [[ $i -lt ${#ARGS[@]} ]]; do
    case "${ARGS[$i]:-}" in
        --setup) header_info; preflight_checks; guided_setup; exit 0 ;;
        --test-notify) test_gotify ;;
        --schedule) manage_cron "${ARGS[$((i+1))]:-}" ;;
        --set-cred) do_set_cred "${ARGS[$((i+1))]:-}" ;;
    esac
    i=$((i+1))
done

header_info

# Parse run-mode flags
AUTO_YES=false
INTERACTIVE=true
for arg in "${ARGS[@]}"; do
    case "${arg:-}" in
        --yes|-y) AUTO_YES=true; INTERACTIVE=false ;;
    esac
done

# Preflight — validate the environment FIRST, before prompting for anything.
preflight_checks

# One-time install nudge (interactive only) — offer the canonical path so cron works.
# Runs AFTER preflight (matches the reference flow; never nudge before validating).
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

# First-run: auto-offer the guided setup when nothing is configured yet.
if [[ "$INTERACTIVE" == true ]] && is_first_run; then
    echo -e "${TAB}${YW}Looks like a fresh setup — nothing is configured yet.${CL}"
    read -rp "  Run the guided setup now? [Y/n]: " _ans
    if [[ ! "$_ans" =~ ^[Nn]$ ]]; then guided_setup; fi
    echo ""
fi

# Interactive menu (every flag is also a menu item)
if [[ "$INTERACTIVE" == true ]]; then
    echo -e "${TAB}${BL}What would you like to do?${CL}"
    echo ""
    echo -e "${TAB}  ${GN}1)${CL} Run the main action"
    echo -e "${TAB}  ${GN}2)${CL} Manage cron schedule"
    echo -e "${TAB}  ${GN}3)${CL} Test Gotify notification"
    echo -e "${TAB}  ${GN}4)${CL} Guided setup (reconfigure everything)"
    echo -e "${TAB}  ${RD}q)${CL} Quit"
    echo ""
    read -rp "  Select an option [1-4/q]: " choice
    case "$choice" in
        1) ;;
        2) manage_cron ;;
        3) test_gotify ;;
        4) guided_setup; exit 0 ;;
        q|Q) echo ""; msg_ok "Exiting. No changes made."; echo ""; exit 0 ;;
        *) msg_error "Invalid option"; exit 1 ;;
    esac
    echo ""
fi

echo -e "${TAB}${BL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
echo ""

do_work

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