# PATTERNS.md — Reusable Code Patterns

Copy-paste reference for the idioms used across all Proxmox-Scripts. When building a new script, start from `script-template.sh` and pull specific patterns from here. When updating a pattern, update it here first, then propagate to every script.

> **Reminder:** scripts are standalone. These patterns are duplicated into each script on purpose. There is no shared library at runtime.

---

## 1. Colors (always `$'...'`)

```bash
RD=$'\033[01;31m'   # Red — errors
YW=$'\033[33m'      # Yellow — warnings, in-progress
GN=$'\033[1;92m'    # Green — success
BL=$'\033[36m'      # Blue/Cyan — info, headers
BD=$'\033[1m'       # Bold — section headers
CL=$'\033[m'        # Clear
BFR=$'\r\033[K'     # Carriage return + clear line
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"
INFO="${BL}ℹ${CL}"
TAB="  "
```

**Why `$'...'` not `$(echo "\033...")`:** the `$'...'` form interprets escape sequences at parse time, so colors render correctly whether output via `echo -e`, `printf`, or `cat` heredoc. The `$(echo ...)` form outputs literal `\033` when used inside a `cat` heredoc (which is how help text is printed), showing raw escape codes to the user.

---

## 2. Message functions

```bash
msg_info()  { echo -ne "${TAB}- ${YW}$1...${CL}"; }
msg_ok()    { echo -e "${BFR}${TAB}${CM} ${GN}$1${CL}"; }
msg_error() { echo -e "${BFR}${TAB}${CROSS} ${RD}$1${CL}"; }
msg_warn()  { echo -e "${BFR}${TAB}${INFO} ${YW}$1${CL}"; }
```

Pattern: call `msg_info "Doing thing"` (no newline, trailing `...`), then `msg_ok "Did thing"` — the `${BFR}` carriage-return overwrites the in-progress line with the result.

---

## 3. Header (repo banner + script art)

```bash
header_info() {
    clear
    cat <<"EOF"
  ___                              
 | _ \_ _ _____ ___ __  _____ __  
 |  _/ '_/ _ \ \ / '  \/ _ \ \ / 
 |_| |_| \___/_\_\_|_|_\___/_\_\  
      ╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍
          S c r i p t s

<SCRIPT-SPECIFIC ART HERE>
EOF
    echo ""
}
```

The repo banner is constant. Generate script-specific art (figlet "small" or "mini" style works well) representing the script's purpose, 4-5 lines.

---

## 4. CTRL+C trap + cleanup

```bash
trap 'echo -e "\n\n${TAB}${YW}⚠  Cancelled by user. No changes made.${CL}\n"; cleanup; exit 0' SIGINT SIGTERM

TEMP_FILES=()
cleanup() {
    for f in "${TEMP_FILES[@]:-}"; do
        rm -f "$f" 2>/dev/null
    done
}
```

Add temp files to the array as you create them: `TEMP_FILES+=("$tmp")`. Tailor the cancel message per script (e.g. "Container was NOT destroyed").

---

## 5. Dynamic config help (line numbers)

The CONFIGURATION section of `show_help` prints every config variable with its current value AND the line it's on, pulled from the script at runtime:

```bash
echo -e "${TAB}${BD}Variable                    Line  Current Value${CL}"
echo -e "${TAB}──────────────────────────  ────  ─────────────────────────"
while IFS= read -r line; do
    local linenum var val
    linenum=$(echo "$line" | cut -d: -f1)
    var=$(echo "$line" | cut -d: -f2- | cut -d= -f1 | xargs)
    val=$(echo "$line" | cut -d= -f2- | tr -d '"')
    printf "${TAB}${GN}%-28s${CL}${YW}%-6s${CL}%s\n" "$var" "$linenum" "$val"
done < <(grep -n '^[A-Z_]*=' "$SCRIPT_PATH" | grep -v '^#' | grep -v 'SCRIPT_\|...exclusions...' | head -N)
```

**Adjust the `grep -v` exclusion list per script** so it shows only the user-facing CONFIG variables, not the color vars, metadata, or internal state flags. Common exclusions: `SCRIPT_`, the color vars, `TAB`, `TEMP_FILES`, and runtime flags like `INTERACTIVE`, `AUTO_YES`, `DRY_RUN`. Requires `SCRIPT_PATH="$(readlink -f "$0")"` in the metadata block.

---

## 6. Early-exit flag dispatch

Read-only/info flags exit before root checks and work begins:

```bash
for arg in "${@:-}"; do
    case "${arg:-}" in
        --help|-h) show_help ;;
        --version|-V) echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"; echo "${SCRIPT_URL}"; exit 0 ;;
        --status) show_status ;;
        --test-notify) test_gotify ;;
        --schedule) manage_cron ;;
    esac
done
```

Action flags (`--yes`, `--dry-run`, mode toggles) are parsed later in a separate loop that also sets `INTERACTIVE=false`.

---

## 7. Interactive menu (every flag is also a menu item)

```bash
if [[ "$INTERACTIVE" == true ]]; then
    echo -e "${TAB}${BL}What would you like to do?${CL}"
    echo ""
    echo -e "${TAB}  ${GN}1)${CL} Primary action"
    echo -e "${TAB}  ${GN}2)${CL} Secondary action"
    echo -e "${TAB}  ${GN}3)${CL} Test Gotify notification"
    echo -e "${TAB}  ${GN}4)${CL} Manage cron schedule"
    echo -e "${TAB}  ${RD}q)${CL} Quit"
    echo ""
    read -rp "  Select an option [1-4/q]: " choice
    case "$choice" in
        1) ;;
        2) SOME_FLAG=true ;;
        3) test_gotify ;;
        4) manage_cron ;;
        q|Q) echo ""; msg_ok "Exiting. No changes made."; echo ""; exit 0 ;;
        *) msg_error "Invalid option"; exit 1 ;;
    esac
    echo ""
fi
```

Rule: anything reachable by a flag must also be reachable from the menu, and vice versa.

---

## 8. Secure Gotify (token never in process args)

Putting the token in the URL (`?token=xxx`) leaks it in `ps aux`. Use a temp curl config file with a header instead:

```bash
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
```

Messages are markdown — use `###` headers, `**bold**`, `` `code` ``, and tables. Only send in automated/cron mode, never interactively. Priority 8 for failures/alerts, default (5) for success.

---

## 9. Cron schedule manager

Lets users schedule without knowing cron syntax. Two flavors of frequency menu: "frequent" (minute-level, for monitors) and "daily" (day-level, for updates/syncs). See `script-template.sh` for the full function. Key mechanics:

```bash
# Detect existing entry
CURRENT_CRON=$(crontab -l 2>/dev/null | grep "${SCRIPT_NAME}" || true)
# Offer change/remove if present, else go straight to frequency picker
# Write: replace any existing entry, then append the new one
(crontab -l 2>/dev/null | grep -v "${SCRIPT_NAME}"; echo "$NEW_CRON") | crontab -
```

Cron command form: `/usr/local/bin/${SCRIPT_NAME} -y >> ${LOG_FILE} 2>&1` (or `--cron` for scripts that distinguish).

---

## 10. Parallel execution (multi-target)

Single target → run directly with live output. Multiple targets → fork background jobs, collect results via temp files, display after. All targets finish in the time of the slowest, not the sum.

```bash
SUCCESS=(); FAILED=()
TARGETS=(${TARGET_LIST})   # space-separated config var → array
COUNT=${#TARGETS[@]}

if [[ "$COUNT" -eq 1 ]]; then
    if do_one "${TARGETS[0]}"; then SUCCESS+=("${TARGETS[0]}"); else FAILED+=("${TARGETS[0]}"); fi
else
    RESULTS=$(mktemp -d /tmp/.parallel-XXXXXX)
    PIDS=()
    for t in "${TARGETS[@]}"; do
        ( if do_one "$t" &>/dev/null; then echo 0; else echo 1; fi > "${RESULTS}/${t}" ) &
        PIDS+=($!)
    done
    for pid in "${PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
    for t in "${TARGETS[@]}"; do
        if [[ -f "${RESULTS}/${t}" && "$(cat "${RESULTS}/${t}")" == "0" ]]; then
            msg_ok "${t} — done"; SUCCESS+=("$t")
        else
            msg_error "${t} — failed"; FAILED+=("$t")
        fi
    done
    rm -rf "$RESULTS"
fi
```

**Keep sequential** when operations compete for a shared resource or lock (e.g. NFS remounts, anything writing the same file). Parallelize only genuinely independent work.

---

## 11. Download + checksum verification

For binaries where upstream publishes checksums:

```bash
wget -q "$download_url" -O "$tmp_file" || { msg_error "Download failed"; return 1; }
if wget -q "$checksum_url" -O "$checksum_file" 2>/dev/null; then
    expected=$(grep "$archive_name" "$checksum_file" | awk '{print $1}')
    actual=$(sha256sum "$tmp_file" | awk '{print $1}')
    if [[ -n "$expected" && "$expected" == "$actual" ]]; then
        msg_ok "Checksum verified (SHA256)"
    else
        msg_error "Checksum mismatch! Aborting"; rm -f "$tmp_file"; return 1
    fi
fi
```

Note: GPG signature verification is stronger but only possible if upstream signs releases. Traefik does not (upstream issue #6757), so SHA256 is the ceiling there.

---

## 12. Backup + rollback

```bash
# Before modifying:
cp "$TARGET_BIN" "${TARGET_BIN}.bak"
# After install, verify the service starts:
systemctl start "$SERVICE"; sleep 2
if systemctl is-active --quiet "$SERVICE"; then
    msg_ok "Running"
else
    msg_error "Failed to start! Rolling back"
    cp "${TARGET_BIN}.bak" "$TARGET_BIN"
    systemctl start "$SERVICE"
    # re-verify, escalate to manual if rollback also fails
fi
```

---

## 13. Cluster deployment (host scripts)

Scripts that run on Proxmox nodes get deployed to every node:

```bash
for node in node1-ip node2-ip node3-ip; do
    scp /usr/local/bin/<script> root@${node}:/usr/local/bin/
done
```

Document this in the script's README section. Cron (if used) must be set per-node.

---

## Checklist when adding a pattern to a new script

- [ ] Colors + message functions (1, 2)
- [ ] header_info with repo banner + new art (3)
- [ ] CTRL+C trap + cleanup if temp files are used (4)
- [ ] Man-style help with dynamic config table (5), exclusions tuned
- [ ] Early-exit dispatch for info flags (6)
- [ ] Interactive menu mirroring all flags (7)
- [ ] Secure Gotify + test_gotify if notifications apply (8)
- [ ] Cron manager if scheduling applies (9)
- [ ] Parallel for independent multi-target work (10)
- [ ] Checksum verification for downloads (11)
- [ ] Backup + rollback for destructive changes (12)
- [ ] README `<details>` section + CLAUDE.md table + TODO.md entry
