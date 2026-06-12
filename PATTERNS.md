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

**Adjust the `grep -v` exclusion list per script** so it shows only the user-facing CONFIG variables, not the color vars, metadata, or internal state flags. Common exclusions: `SCRIPT_`, the color vars, `TAB`, `TEMP_FILES`, and runtime flags like `INTERACTIVE`, `AUTO_YES`, `DRY_RUN`. Internal path/state vars that aren't meant to be edited (e.g. `SETTINGS_FILE`, `SECRETS_DIR`, `INSTALL_NUDGE_DISMISSED`) should also be excluded so the table stays focused. Requires `SCRIPT_PATH="$(readlink -f "$0")"` in the metadata block.

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

Action flags (`--yes`, `--dry-run`, mode toggles) are parsed later in a separate loop that also sets `INTERACTIVE=false`. Note: flags that need root or take an argument (e.g. `--restore <file>`, `--set-cred <name>`, `--targets`) still dispatch in this loop but do their own root check inline and read `${ARGS[$((i+1))]}` for the argument — use an indexed `while` loop over `ARGS` rather than `for arg` when you need the next token.

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

> When a script also seals secrets (pattern 14), resolve the token through the seal layer instead of reading `GOTIFY_TOKEN` directly — see the `resolve_gotify_token` note in pattern 14.

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

Cron command form: `/usr/local/bin/${SCRIPT_NAME} -y >> ${LOG_FILE} 2>&1` (or `--cron` for scripts that distinguish). Because cron runs that absolute path, a script that self-installs (pattern 17) should derive the cron command from its `SCRIPT_INSTALL_DEST` var so the scheduled path and the install target can never drift apart, and should gate scheduling on actually being installed there.

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

Document this in the script's README section. Cron (if used) must be set per-node. For host-config backups, this is not optional: each node's config is distinct, so the script must be installed and scheduled on every node independently.

---

## 14. Sealed credentials (systemd-creds + chmod-600 fallback)

When a script must store a secret it has to **replay later** (an FTP password, a Gotify token used unattended by cron), hashing is not an option — replay requires the plaintext, which means reversible storage. Seal it instead of writing it plaintext, and never put it in the script.

```bash
SECRETS_DIR="/etc/<script>/secrets"   # chmod 700

have_systemd_creds() { command -v systemd-creds &>/dev/null; }

# Seal a secret (value on stdin) under a logical name. Echoes the method used.
secret_set() {
    local name="$1" value; value="$(cat)"
    mkdir -p "$SECRETS_DIR"; chmod 700 "$SECRETS_DIR"
    if have_systemd_creds; then
        if printf '%s' "$value" | systemd-creds encrypt --name="pfx-${name}" - "${SECRETS_DIR}/${name}.cred" 2>/dev/null; then
            chmod 600 "${SECRETS_DIR}/${name}.cred"; rm -f "${SECRETS_DIR}/${name}.secret" 2>/dev/null || true
            echo "systemd-creds"; return 0
        fi
    fi
    printf '%s' "$value" > "${SECRETS_DIR}/${name}.secret"; chmod 600 "${SECRETS_DIR}/${name}.secret"
    rm -f "${SECRETS_DIR}/${name}.cred" 2>/dev/null || true
    echo "file-600"; return 0
}

# Unseal to stdout; non-zero if absent.
secret_get() {
    local name="$1"
    if [[ -f "${SECRETS_DIR}/${name}.cred" ]] && have_systemd_creds; then
        systemd-creds decrypt --name="pfx-${name}" "${SECRETS_DIR}/${name}.cred" - 2>/dev/null && return 0
    fi
    [[ -f "${SECRETS_DIR}/${name}.secret" ]] && { cat "${SECRETS_DIR}/${name}.secret"; return 0; }
    return 1
}

secret_exists() { [[ -f "${SECRETS_DIR}/$1.cred" || -f "${SECRETS_DIR}/$1.secret" ]]; }
secret_method() { [[ -f "${SECRETS_DIR}/$1.cred" ]] && echo "systemd-creds (sealed)" || { [[ -f "${SECRETS_DIR}/$1.secret" ]] && echo "file-600" || echo "none"; }; }
secret_delete() { rm -f "${SECRETS_DIR}/$1.cred" "${SECRETS_DIR}/$1.secret" 2>/dev/null || true; }
```

- `systemd-creds` seals TPM-bound where a TPM exists (the blob can't be decrypted on another machine), host-key-bound otherwise. Both fall back to a `chmod 600` file when `systemd-creds` is absent, so cron can still auto-unseal.
- **Resolve sealed-first.** Where a value could be sealed or set as a plaintext config var, prefer the seal: `resolve_gotify_token() { secret_exists gotify-token && secret_get gotify-token || printf '%s' "$GOTIFY_TOKEN"; }`. The Gotify sender (pattern 8) then uses the resolved value.
- **Store references, not literals.** For per-item secrets (e.g. one FTP password per export target), seal under a generated id and store `@SECRET:<id>` in the target spec — never the password. Resolve at use time: `[[ "$field" == @SECRET:* ]] && secret_get "${field#@SECRET:}" || printf '%s' "$field"`. Bonus: this sidesteps delimiter-in-password parsing bugs, since the literal never enters the delimited file.
- **Honest scope (document it):** sealing protects against leak/copy/exfil and (with a TPM) offline cracking elsewhere. It does **not** protect a secret from an attacker who already has root on the host, because cron must auto-unseal. The strongest option is credential-*less* transports (SSH keys, NFS) where there is no secret to store. Warn hard on plaintext-only transports like FTP.
- `--set-cred <name>` provides a non-interactive path: read the value from stdin (pipe) or a hidden TTY prompt, seal it, report the method. Lets users provision without the wizard.

---

## 15. Managed settings file (parsed, not sourced)

A guided setup (pattern 17) needs to persist non-secret choices (a Gotify URL, a dismissal flag) so the script is "set up once." Keep the script standalone — the file is optional and the script runs fine without it — but **parse a whitelist of keys; never `source` it.** Sourcing an attacker-writable file is code execution; parsing is not.

```bash
SETTINGS_FILE="/etc/<script>/config.env"   # chmod 600, optional

load_settings() {
    [[ -f "$SETTINGS_FILE" ]] || return 0
    local line key val
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        key="${line%%=*}"; val="${line#*=}"; val="${val%\"}"; val="${val#\"}"
        case "$key" in
            GOTIFY_URL) GOTIFY_URL="$val" ;;
            RETENTION_DAYS) RETENTION_DAYS="$val" ;;
            INSTALL_NUDGE_DISMISSED) INSTALL_NUDGE_DISMISSED="$val" ;;
            # ...only the keys you explicitly expect...
        esac
    done < "$SETTINGS_FILE"
}

settings_set() {   # upsert one whitelisted key
    local key="$1" val="$2" tmp
    mkdir -p "$(dirname "$SETTINGS_FILE")"; chmod 700 "$(dirname "$SETTINGS_FILE")"
    touch "$SETTINGS_FILE"; chmod 600 "$SETTINGS_FILE"
    tmp=$(mktemp /tmp/.set-XXXXXX); TEMP_FILES+=("$tmp")
    grep -v "^${key}=" "$SETTINGS_FILE" > "$tmp" 2>/dev/null || true
    echo "${key}=\"${val}\"" >> "$tmp"; cat "$tmp" > "$SETTINGS_FILE"; chmod 600 "$SETTINGS_FILE"; rm -f "$tmp"
}
```

Call `load_settings` early in MAIN (after defaults are defined, before they're used). Any key not in the `case` whitelist is silently ignored — a planted `EVIL=...` line does nothing. Initialize whitelisted runtime vars (e.g. `INSTALL_NUDGE_DISMISSED=""`) before `load_settings` so they're defined under `set -u`, and exclude them from the dynamic config table (pattern 5).

---

## 16. Export target with live verification (write → read → delete)

When a script saves a remote destination (NFS export, SFTP/FTPS server), verify it the moment it's added by actually round-tripping a canary file, with per-step feedback. A target that can't be written/read/deleted is never saved — the user finds out at add-time, not at 3 AM when the backup silently fails.

```bash
verify_target() {           # dispatch on type prefix in the pipe-delimited spec
    local spec="$1" canary; canary="/tmp/.canary-$$-$RANDOM"
    echo "verify-$(date +%s)" > "$canary"; TEMP_FILES+=("$canary")
    case "${spec%%|*}" in
        nfs)  verify_nfs  ... "$canary" ;;
        sftp) verify_sftp ... "$canary" ;;
        ftp)  verify_ftp  ... "$canary" ;;
    esac
}
# Each verify_* does, with a ✓/✗ per step:
#   1) write the canary to the remote
#   2) read it back and compare contents
#   3) delete it from the remote
# Return non-zero on any failure so the caller refuses to save the target.
```

- Store verified targets in a `chmod 600` `TARGETS_FILE`, one pipe-delimited spec per line (`nfs|host:/export|subdir`, `sftp|user@host|port|path`, `ftp|host|port|user|@SECRET:<id>|path|tls`).
- For credentialed transports, seal the secret (pattern 14) and store only the `@SECRET:<id>` reference in the spec.
- On removal, also `secret_delete` any referenced credential so nothing is orphaned.
- Prefer key-based/credential-less transports; if offering FTP, default to FTPS and warn hard before saving a plaintext-FTP target.

---

## 17. Guided setup + self-install (run-once UX)

For a script meant to run unattended forever after, give it a one-time wizard and let it install itself to the canonical path so cron resolves.

```bash
SCRIPT_INSTALL_DEST="/usr/local/bin/${SCRIPT_NAME}"   # metadata block; cron runs THIS path

installed_ok() { [[ -f "$SCRIPT_INSTALL_DEST" && -x "$SCRIPT_INSTALL_DEST" ]]; }

install_self() {   # copy + chmod 755; handle the already-at-dest case
    if [[ "$SCRIPT_PATH" == "$SCRIPT_INSTALL_DEST" ]]; then chmod 755 "$SCRIPT_INSTALL_DEST" 2>/dev/null || true; return 0; fi
    cp "$SCRIPT_PATH" "$SCRIPT_INSTALL_DEST" 2>/dev/null && chmod 755 "$SCRIPT_INSTALL_DEST"
}

# Offer once at startup (interactive). Decline is remembered via settings (pattern 15)
# so it never nags again; scheduling stays disabled until installed.
offer_install_at_startup() {
    installed_ok && return 0
    [[ "$INSTALL_NUDGE_DISMISSED" == "1" ]] && return 0
    read -rp "  Install to ${SCRIPT_INSTALL_DEST} now? [Y/n]: " a
    if [[ ! "$a" =~ ^[Nn]$ ]]; then install_self || true
    else settings_set INSTALL_NUDGE_DISMISSED "1"; INSTALL_NUDGE_DISMISSED="1"; fi
}

# Gate every scheduling entry point (--schedule, menu, setup step) on being installed,
# re-offering inline (the user actively chose to schedule = they want it installed).
require_installed_for_schedule() {
    installed_ok && return 0
    read -rp "  Scheduling needs the script at ${SCRIPT_INSTALL_DEST}. Install now? [Y/n]: " a
    [[ ! "$a" =~ ^[Nn]$ ]] && install_self
}
```

Guided setup (`--setup`, a menu item, and auto-offered when `is_first_run` detects nothing configured) runs the **mandatory** step first (the actual backup/sync), then walks **optional** steps (export target, notifications, schedule) each individually skippable. Do **not** re-exec after self-install — the running instance finishes from wherever it launched; the installed copy is what cron uses going forward. Re-execing into the new path is the kind of cleverness that causes subtle bugs.

---

## 18. On-demand, configuration-gated dependencies (`require_dep`)

Don't demand every tool a script *could* use; demand the tool a given run *will* use. A single helper keeps the behavior identical everywhere — offer to install when interactive, fail loud (never silently skip) when not:

```bash
require_dep() {                       # require_dep <cmd> <apt-pkg> <label>
    local cmd="$1" pkg="$2" label="${3:-$2}"
    command -v "$cmd" &>/dev/null && { msg_ok "${label} present"; return 0; }
    if [[ "${INTERACTIVE:-true}" == true ]]; then
        read -rp "  Install ${pkg} now? [Y/n]: " a
        [[ "$a" =~ ^[Nn]$ ]] && return 1
        apt-get update -qq >/dev/null 2>&1 && apt-get install -y "$pkg" >/dev/null 2>&1 \
            && { msg_ok "${pkg} installed"; return 0; }
        msg_error "Install failed — apt-get install -y ${pkg}"; return 1
    fi
    msg_error "${label} missing — install it: apt-get install -y ${pkg}"; return 1   # cron: loud
}
```

Gate the call on what's configured, and check at **both** the opt-in moment and at run time:

```bash
# at target-add time (verify_sftp): you just declared you need this
require_dep scp openssh-client "openssh-client" || return 1
# at preflight: safety net for a rebuilt node / target deployed elsewhere
grep -q '^ftp|' "$TARGETS_FILE" || [[ -n "$GOTIFY_URL" ]] && require_dep curl curl "curl" || CRITICAL=true
```

A local-only user is never nagged about export tooling they'll never touch. Environment facts that *can't* be installed (is-this-a-PVE-host, is-`config.db`-present) stay detect-and-refuse, not `require_dep`.

---

## 19. The `set -u` same-line `local` self-reference footgun

This is a correctness bug, not a style nit. Under `set -u`, **do not reference a variable on the same `local` line that first declares it:**

```bash
# WRONG — rel references pick on its own declaration line.
# Throws 'unbound variable', or silently uses a stale same-named var from earlier.
local pick="${files[$((n-1))]}" rel="${pick#$prefix/}"

# RIGHT — declare, then assign on separate lines.
local pick rel
pick="${files[$((n-1))]}"
rel="${pick#$prefix/}"
```

Bash evaluates a combined `local a=… b=…` left to right, but `a` is not reliably "set" for `${a…}` expansion within the same statement. The insidious part: if a variable of the same name exists from an earlier code path (a prior menu iteration in a long-lived interactive process), the broken line picks up the **stale** value instead of erroring — so the bug hides until a specific *sequence* of actions triggers it. Referencing **positional parameters** (`local src="$1/$2"`) on the declaration line is safe — they're always already set. Grep new scripts for `local [a-z_]+=.*\$\{?[a-z_]+` and eyeball every hit.

---

## 20. Guarded destructive operation with automatic rollback

For an operation that can leave a system worse than it started (swapping a live database, replacing a bootloader), the pattern is: **save current → act → verify health → auto-rollback on failure**, behind a typed confirmation. Never a bare `y`.

```bash
[[ "${ASSUME_FORCED:-false}" == true ]] || { read -rp "  Type 'RESTORE' to proceed: " c; [[ "$c" == RESTORE ]] || return 1; }
cp -a "$live_db" "$backup_db"            # 1. save the current state FIRST
systemctl stop pve-cluster
cp -a "$archived_db" "$live_db"          # 2. act
systemctl start pve-cluster; sleep 3
if systemctl is-active --quiet pve-cluster && ls /etc/pve/.version &>/dev/null; then
    msg_ok "healthy"                     # 3a. verify BOTH service active AND mount populated
else
    systemctl stop pve-cluster           # 3b. unhealthy → roll back to the saved copy
    cp -a "$backup_db" "$live_db"; systemctl start pve-cluster
fi
```

Health verification must check the *real* success condition (the FUSE mount is populated), not just that the service reports active. Keep the pre-op backup on disk afterward — it's the user's manual escape hatch if even the rollback misbehaves. A forced/unattended mode may bypass the *typed prompt*, but never the *rollback net*.

---

## 21. Restore wizard: extract to a review dir, then act on request

A restore feature should mirror the backup wizard's "ask, then do the hard parts for you" model — not dump instructions. Always extract to a throwaway review directory first (never straight over `/etc`), show contents, then offer: full restore / by-category / single-file drill-down. Each category handler places the file(s) **and** offers the matching service reload (`ifreload -a` for networking, `systemctl restart ssh` for SSH). Provide flag equivalents for every menu action (`--what`, `--file`, `--full`, `--extract-only`, `--yes`) so automation never has to drive a menu — exactly as every backup flag is also a menu item (pattern 7). The single most dangerous path gets the extra `--force-full` guard (pattern 20).

---

## Checklist when adding a pattern to a new script

- [ ] Colors + message functions (1, 2)
- [ ] header_info with repo banner + new art (3)
- [ ] CTRL+C trap + cleanup if temp files are used (4)
- [ ] Man-style help with dynamic config table (5), exclusions tuned
- [ ] Early-exit dispatch for info flags (6)
- [ ] Interactive menu mirroring all flags (7)
- [ ] Secure Gotify + test_gotify if notifications apply (8); resolve sealed-first if sealing (14)
- [ ] Cron manager if scheduling applies (9); gate on install if self-installing (17)
- [ ] Parallel for independent multi-target work (10)
- [ ] Checksum verification for downloads (11)
- [ ] Backup + rollback for destructive changes (12)
- [ ] Cluster deployment documented for host scripts (13)
- [ ] Sealed credentials instead of plaintext where a secret must be replayed (14)
- [ ] Managed settings parsed-not-sourced if persisting choices (15)
- [ ] Live write/read/delete verification for saved remote targets (16)
- [ ] Guided setup + self-install for run-once unattended tools (17)
- [ ] README `<details>` section + CLAUDE.md table + TODO.md entry