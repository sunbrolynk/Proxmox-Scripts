#!/usr/bin/env bash

# Traefik & Traefik Manager Update Script
# https://github.com/SunBroLynk/Proxmox-Scripts
# License: MIT
# Styled after Proxmox VE Community Scripts

# ============================================================
# CONFIGURATION — adjust these for your setup
# ============================================================
TRAEFIK_BIN="/usr/local/bin/traefik"
TRAEFIK_SERVICE="traefik-proxy"
TRAEFIK_MANAGER_DIR="/opt/traefik-manager"
TRAEFIK_MANAGER_USER="traefik-manager"
TRAEFIK_MANAGER_SERVICE="traefik-manager"
TRAEFIK_MANAGER_PORT="5000"
TRAEFIK_MANAGER_REPO="chr0nzz/traefik-manager"
TRAEFIK_DASHBOARD_PORT="8080"
TRAEFIK_ARCH="linux_amd64"
MIN_DISK_MB=500
MIN_MEM_MB=256
MIN_PYTHON="3.9"
# ============================================================

set -euo pipefail
shopt -s inherit_errexit nullglob

# Script metadata
SCRIPT_NAME="update-traefik"
SCRIPT_VERSION="1.1.0"
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

${TAB}${GN}--rollback${CL}
${TAB}${TAB}Restore previous Traefik binary from backup (.bak file).

${TAB}${GN}-h, --help${CL}
${TAB}${TAB}Display this help and exit.

${TAB}${GN}-V, --version${CL}
${TAB}${TAB}Display script version and exit.

${BD}CONFIGURATION${CL}
${TAB}Edit the variables at the top of this script to match your setup.
${TAB}File: ${BL}${SCRIPT_PATH}${CL}

HELP

    # Dynamically show config variables with line numbers
    echo -e "${TAB}${BD}Variable                    Line  Current Value${CL}"
    echo -e "${TAB}──────────────────────────  ────  ─────────────────────────"
    while IFS= read -r line; do
        local linenum var val
        linenum=$(echo "$line" | cut -d: -f1)
        var=$(echo "$line" | cut -d: -f2- | cut -d= -f1 | xargs)
        val=$(echo "$line" | cut -d= -f2- | tr -d '"')
        printf "${TAB}${GN}%-28s${CL}${YW}%-6s${CL}%s\n" "$var" "$linenum" "$val"
    done < <(grep -n '^[A-Z_]*=' "$SCRIPT_PATH" | grep -v '^#' | grep -v 'SCRIPT_\|^[0-9]*:set \|^[0-9]*:shopt \|^[0-9]*:RD=\|^[0-9]*:YW=\|^[0-9]*:GN=\|^[0-9]*:BL=\|^[0-9]*:BD=\|^[0-9]*:CL=\|^[0-9]*:BFR=\|^[0-9]*:HOLD=\|^[0-9]*:CM=\|^[0-9]*:CROSS=\|^[0-9]*:INFO=\|^[0-9]*:TAB=\|^[0-9]*:TEMP_FILES\|SKIP_\|SPECIFIC_\|INTERACTIVE\|LATEST_\|CURRENT_\|VM_IP\|FINAL_\|MISSING_\|STOPPED_\|CRITICAL_\|ENV_' | head -13)

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
${TAB}  ${BL}sudo ${SCRIPT_NAME}${CL}

${TAB}Update all without prompts (good for cron):
${TAB}  ${BL}sudo ${SCRIPT_NAME} -y${CL}

${TAB}Pin Traefik to a specific version:
${TAB}  ${BL}sudo ${SCRIPT_NAME} v3.6.6${CL}

${TAB}Update only Traefik Manager:
${TAB}  ${BL}sudo ${SCRIPT_NAME} --manager-only${CL}

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
        tag=$(sudo -u "${TRAEFIK_MANAGER_USER}" git describe --tags --exact-match HEAD 2>/dev/null || echo "")
        if [[ -n "$tag" ]]; then
            echo "$tag"
        else
            echo "commit-$(sudo -u "${TRAEFIK_MANAGER_USER}" git rev-parse --short HEAD 2>/dev/null)"
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
                    echo -e "${TAB}  Try manually: ${YW}sudo apt install ${dep}${CL}"
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
        echo -e "${TAB}  Run: ${YW}sudo systemctl status ${TRAEFIK_SERVICE}${CL}"
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
    local tmp_file="/tmp/traefik_update_${target_version}.tar.gz"
    TEMP_FILES+=("$tmp_file")

    msg_info "Downloading Traefik ${target_version}"
    if ! wget -q "${download_url}" -O "$tmp_file" 2>/dev/null; then
        msg_error "Download failed — version ${target_version} may not exist"
        echo -e "${TAB}  Check releases: ${BL}https://github.com/traefik/traefik/releases${CL}"
        return 1
    fi
    msg_ok "Downloaded Traefik ${target_version}"

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
            echo -e "${TAB}  Run: ${YW}sudo systemctl status ${TRAEFIK_SERVICE}${CL}"
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
    current_branch=$(sudo -u "${TRAEFIK_MANAGER_USER}" git branch --show-current 2>/dev/null)
    if [[ "$current_branch" != "main" ]]; then
        msg_warn "Not on main branch (${current_branch:-detached HEAD}), switching to main"
        sudo -u "${TRAEFIK_MANAGER_USER}" git checkout main --quiet 2>/dev/null
    fi

    # Fetch latest from remote
    sudo -u "${TRAEFIK_MANAGER_USER}" git fetch origin main --tags --quiet 2>/dev/null

    # Compare local vs remote
    local local_hash remote_hash
    local_hash=$(sudo -u "${TRAEFIK_MANAGER_USER}" git rev-parse HEAD)
    remote_hash=$(sudo -u "${TRAEFIK_MANAGER_USER}" git rev-parse origin/main)

    local current_version
    current_version=$(get_current_manager_version)

    if [[ "$local_hash" == "$remote_hash" ]]; then
        msg_ok "Traefik Manager is up to date (${GN}${current_version}${CL})"
        return 0
    fi

    # Determine what we're updating to
    local remote_version
    remote_version=$(sudo -u "${TRAEFIK_MANAGER_USER}" git describe --tags origin/main 2>/dev/null || echo "$(sudo -u "${TRAEFIK_MANAGER_USER}" git rev-parse --short origin/main)")

    echo ""
    echo -e "${TAB}${BL}Manager: ${RD}${current_version}${CL} → ${GN}${remote_version}${CL}"
    echo ""

    # Pull latest on main branch
    msg_info "Pulling latest changes"
    if ! sudo -u "${TRAEFIK_MANAGER_USER}" git pull origin main --quiet 2>/dev/null; then
        msg_error "Failed to pull latest changes"
        echo -e "${TAB}  There may be local modifications. Check: ${YW}git status${CL}"
        return 1
    fi
    msg_ok "Pulled latest changes"

    # Update Python dependencies (always run per developer's update guide)
    msg_info "Updating Python dependencies"
    sudo -u "${TRAEFIK_MANAGER_USER}" "${TRAEFIK_MANAGER_DIR}/venv/bin/pip" install -r requirements.txt gunicorn --quiet 2>/dev/null
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
        echo -e "${TAB}  Run: ${YW}sudo systemctl status ${TRAEFIK_MANAGER_SERVICE}${CL}"
        return 1
    fi
}

# ============================================================
# MAIN
# ============================================================

# Early exit for help and version (before any checks)
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
    local_branch=$(sudo -u "${TRAEFIK_MANAGER_USER}" git branch --show-current 2>/dev/null)
    if [[ "$local_branch" != "main" ]]; then
        sudo -u "${TRAEFIK_MANAGER_USER}" git checkout main --quiet 2>/dev/null
        CURRENT_MANAGER=$(get_current_manager_version)
    fi
    sudo -u "${TRAEFIK_MANAGER_USER}" git fetch origin main --tags --quiet 2>/dev/null
    local_hash=$(sudo -u "${TRAEFIK_MANAGER_USER}" git rev-parse HEAD 2>/dev/null)
    remote_hash=$(sudo -u "${TRAEFIK_MANAGER_USER}" git rev-parse origin/main 2>/dev/null)
    MANAGER_REMOTE_VERSION=$(sudo -u "${TRAEFIK_MANAGER_USER}" git describe --tags origin/main 2>/dev/null || echo "$(sudo -u "${TRAEFIK_MANAGER_USER}" git rev-parse --short origin/main)")
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

for arg in "${@:-}"; do
    case "${arg:-}" in
        --traefik-only) SKIP_MANAGER=true; INTERACTIVE=false ;;
        --manager-only) SKIP_TRAEFIK=true; INTERACTIVE=false ;;
        --yes|-y) INTERACTIVE=false ;;
        --check) CHECK_ONLY=true ;;
        --rollback) DO_ROLLBACK=true ;;
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
    echo -e "${TAB}  ${RD}q)${CL} Quit"
    echo ""
    read -rp "  Select an option [1-6/q]: " choice

    case "$choice" in
        1) ;;
        2) SKIP_MANAGER=true ;;
        3) SKIP_TRAEFIK=true ;;
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

cleanup
