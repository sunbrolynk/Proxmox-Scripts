#!/usr/bin/env bash

# NFS Watchdog — Monitor NFS mount health on Proxmox nodes
# https://github.com/SunBroLynk/Proxmox-Scripts
# License: MIT
#
# Detects stale or unresponsive NFS mounts before they cause
# cascading lock issues. Designed to run as a cron job on every
# cluster node.

# ============================================================
# CONFIGURATION — adjust these for your setup
# ============================================================
CHECK_TIMEOUT=5                       # Seconds before declaring a mount stale
AUTO_REMOUNT=false                    # Auto-remount stale mounts (true/false)
LOG_FILE="/var/log/nfs-watchdog.log"  # Log file for cron mode
GOTIFY_URL=""                         # Gotify server URL (e.g. http://10.10.3.6:80)
GOTIFY_TOKEN=""                       # Gotify application token
GOTIFY_PRIORITY=5                     # Gotify notification priority (1-10)
# ============================================================

set -euo pipefail
shopt -s inherit_errexit nullglob

# Script metadata
SCRIPT_NAME="nfs-watchdog"
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
    done < <(grep -n '^[A-Z_]*=' "$SCRIPT_PATH" | grep -v '^#' | grep -v 'SCRIPT_\|^[0-9]*:set \|^[0-9]*:shopt \|^[0-9]*:RD=\|^[0-9]*:YW=\|^[0-9]*:GN=\|^[0-9]*:BL=\|^[0-9]*:BD=\|^[0-9]*:CL=\|^[0-9]*:BFR=\|^[0-9]*:CM=\|^[0-9]*:CROSS=\|^[0-9]*:INFO=\|^[0-9]*:TAB=\|INTERACTIVE\|DRY_RUN\|AUTO_YES\|DO_\|STALE_\|HEALTHY_\|MOUNT_' | head -6)

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

send_gotify() {
    local title="$1"
    local message="$2"
    local priority="${3:-$GOTIFY_PRIORITY}"

    if [[ -z "$GOTIFY_URL" ]] || [[ -z "$GOTIFY_TOKEN" ]]; then
        return 0
    fi

    # Send with markdown support
    curl -s -X POST "${GOTIFY_URL}/message?token=${GOTIFY_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{
            \"title\": \"${title}\",
            \"message\": $(echo "$message" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null || echo "\"${message}\""),
            \"priority\": ${priority},
            \"extras\": {
                \"client::display\": {
                    \"contentType\": \"text/markdown\"
                }
            }
        }" &>/dev/null || true
}

test_gotify() {
    header_info
    echo -e "${TAB}${BD}Gotify Notification Test${CL}"
    echo ""

    if [[ -z "$GOTIFY_URL" ]]; then
        msg_error "GOTIFY_URL not configured"
        echo -e "${TAB}  Edit the script and set GOTIFY_URL and GOTIFY_TOKEN"
        echo ""
        exit 1
    fi

    if [[ -z "$GOTIFY_TOKEN" ]]; then
        msg_error "GOTIFY_TOKEN not configured"
        echo -e "${TAB}  Edit the script and set GOTIFY_TOKEN"
        echo ""
        exit 1
    fi

    msg_info "Sending test notification to ${GOTIFY_URL}"

    local test_message="### ✅ Connection Successful

**Script:** \`${SCRIPT_NAME}\`
**Node:** \`$(hostname)\`
**Time:** $(date '+%Y-%m-%d %H:%M:%S')

---

*NFS Watchdog is configured and ready to send alerts.*"

    local response
    response=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        "${GOTIFY_URL}/message?token=${GOTIFY_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{
            \"title\": \"🐕 NFS Watchdog — Test\",
            \"message\": $(echo "$test_message" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null),
            \"priority\": ${GOTIFY_PRIORITY},
            \"extras\": {
                \"client::display\": {
                    \"contentType\": \"text/markdown\"
                }
            }
        }" 2>/dev/null)

    if [[ "$response" == "200" ]]; then
        msg_ok "Test notification sent successfully"
    else
        msg_error "Notification failed (HTTP ${response})"
        echo -e "${TAB}  Check GOTIFY_URL and GOTIFY_TOKEN"
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
            1) ;; # fall through to schedule picker
            2)
                crontab -l 2>/dev/null | grep -v "${SCRIPT_NAME}" | crontab -
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

    # Remove existing entry and add new one
    local NEW_CRON="${CRON_SCHEDULE} ${CRON_CMD}"
    (crontab -l 2>/dev/null | grep -v "${SCRIPT_NAME}"; echo "$NEW_CRON") | crontab -

    echo ""
    msg_ok "Schedule set: ${GN}${CRON_SCHEDULE}${CL}"
    echo -e "${TAB}  ${BL}${NEW_CRON}${CL}"
    echo ""
    exit 0
}

# ============================================================
# MAIN
# ============================================================

# Early exit for help, version, status, test-notify
for arg in "${@:-}"; do
    case "${arg:-}" in
        --help|-h) show_help ;;
        --version|-V)
            echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"
            echo "${SCRIPT_URL}"
            exit 0
            ;;
        --status) show_status ;;
        --test-notify) test_gotify ;;
        --schedule) manage_cron ;;
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
    echo -e "${TAB}  ${RD}q)${CL} Quit"
    echo ""
    read -rp "  Select an option [1-6/q]: " choice

    case "$choice" in
        1) ;;
        2) show_status ;;
        3) DRY_RUN=true ;;
        4) DO_REMOUNT_ALL=true ;;
        5) test_gotify ;;
        6) manage_cron ;;
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