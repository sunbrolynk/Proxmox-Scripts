# CLAUDE.md — AI Project Context

This file provides context for AI assistants (Claude, Copilot, etc.) working on this repository.

## Project Overview

**Proxmox-Scripts** is a public collection of utility scripts for managing services running on Proxmox VE (VMs and LXCs). Scripts are interactive, safe, and styled after the Proxmox VE Community Scripts aesthetic.

**This repo is NOT affiliated with [community-scripts/ProxmoxVE](https://github.com/community-scripts/ProxmoxVE).**

## Repository Owner

- GitHub: SunBroLynk
- Primary users: The owner and a small group of trusted homelab/ISP professionals
- Environment: Proxmox VE, Mikrotik RouterOS, UniFi networking, Docker, self-hosted services

## CRITICAL: Standalone Scripts

**Every script is fully standalone.** Users deploy by `wget`-ing a single `.sh` file and running it. Scripts must NEVER depend on a shared library, external file, or anything else being present on the system. All functions are inline in each script, even though this means duplication across scripts. This is intentional — it's the right tradeoff for single-file `wget`-and-run tools. Do not propose a shared library unless the repo grows to 10+ scripts AND the owner explicitly asks.

A script MAY create and manage its own runtime state files (e.g. a chmod-600 targets list, a parsed settings file, a sealed-secrets dir) as long as the script still runs correctly when none of them exist yet. The dependency rule is about *required* external files, not about a script's own optional, self-created scratch.

To keep duplicated functions consistent across scripts, use `script-template.sh` and `PATTERNS.md` (both in the repo) as the source of truth. When updating a common function, update the template/patterns first, then propagate to each script.

## Script Standards

All scripts in this repo must follow these conventions:

### Structure
- Shebang: `#!/usr/bin/env bash`
- Strict mode: `set -euo pipefail` with `shopt -s inherit_errexit nullglob`
- Configuration variables at the TOP in a clearly labeled block, with inline `# comments`
- Script metadata block: `SCRIPT_NAME`, `SCRIPT_VERSION`, `SCRIPT_URL`, `SCRIPT_PATH`
- No hardcoded IPs, domains, usernames, passwords, API keys, or secrets anywhere
- Generic placeholder defaults in config (e.g. `192.168.1.2`, `root`), never the owner's real values
- User-adjustable values must be variables, not buried in code

### Colors (ALWAYS use $'...' syntax)
```bash
RD=$'\033[01;31m'   # Red — errors
YW=$'\033[33m'      # Yellow — warnings, in-progress
GN=$'\033[1;92m'    # Green — success
BL=$'\033[36m'      # Blue/Cyan — info, headers
BD=$'\033[1m'       # Bold — section headers
CL=$'\033[m'        # Clear
BFR=$'\r\033[K'     # Carriage return + clear line (for msg_ok overwrite)
```
**Never use `$(echo "\033...")`** — it doesn't interpret escapes when output via `cat` in heredocs. The `$'...'` form interprets at parse time so colors render correctly everywhere (echo, cat, printf).

### Message Functions (standard across all scripts)
```bash
msg_info()  — yellow, trailing "...", no newline (echo -ne)
msg_ok()    — green checkmark ✓, uses ${BFR} to overwrite the msg_info line
msg_error() — red cross ✗
msg_warn()  — blue info ℹ
```

### Headers / Banners
Every script's `header_info()` shows the shared repo banner FIRST, then script-specific ASCII art below it:
```
  ___                              
 | _ \_ _ _____ ___ __  _____ __  
 |  _/ '_/ _ \ \ / '  \/ _ \ \ / 
 |_| |_| \___/_\_\_|_|_\___/_\_\  
      ╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍
          S c r i p t s
```
Generate per-script art (figlet-style) that represents the script's purpose. Keep it small (4-5 lines).

### Man-Style Help (show_help function)
Full man-page sections in this order: NAME, SYNOPSIS, DESCRIPTION, OPTIONS, CONFIGURATION, FILES, EXIT STATUS, EXAMPLES, SEE ALSO, LICENSE. The CONFIGURATION section dynamically prints each config variable WITH ITS LINE NUMBER pulled from the script at runtime (see PATTERNS.md "dynamic config help"). This lets users find exactly what to edit.

### Required Features
- **`-h`/`--help`** man-style help (early exit, before any checks)
- **`-V`/`--version`** prints name + version + URL
- **CTRL+C trap** — graceful exit, cleanup temp files, inform user no changes were made
- **Root check** — if the script needs root
- **Preflight checks** — verify dependencies BEFORE the menu or work
- **Interactive menu** — when run with no args; every flag should also be a menu option
- **Interactive prompts** — offer to fix problems (install packages, start services, install self to the canonical path)
- **Automatic backups + rollback** — before modifying binaries/configs; auto-restore on failure
- **Clear error messages** — tell the user WHAT failed and HOW to fix it manually
- **Summary on completion** — final versions, URLs, status

### Parallel by Default
When an operation runs across multiple independent targets (mounts, hosts, containers), run them in PARALLEL using background jobs + temp-file result collection, not a sequential loop. Single-target keeps live output; multi-target forks and collects. See PATTERNS.md "parallel execution". Exception: operations that must be sequential for safety (e.g. remounts, anything that competes for a shared lock).

### Scheduling & Notifications (where it makes sense)
- Scripts that benefit from automation include `--schedule` (interactive cron manager — user picks frequency, no cron knowledge needed) and `--cron`/`-y` for unattended runs.
- Optional Gotify notifications via `GOTIFY_URL`/`GOTIFY_TOKEN`/`GOTIFY_PRIORITY` config vars + `--test-notify` flag. Markdown-formatted messages with tables. Only fire in automated/cron mode, silent interactively.
- **Secure Gotify**: never put the token in the URL (`?token=`) — it leaks in `ps aux`. Use a temp curl config file (chmod 600) with an `X-Gotify-Key` header. See PATTERNS.md "secure gotify".
- Not every script needs notifications. A purely manual tool (e.g. pct-force-destroy) doesn't.

### Credentials, Settings & Self-Install (advanced; see PATTERNS.md 14–17)
Not every script needs these, but when a script must store a replayable secret, persist setup choices, or run unattended forever after, follow the established idioms rather than inventing new ones:
- **Sealed credentials** (PATTERNS.md 14): secrets that must be replayed (FTP passwords, cron-used Gotify tokens) are sealed with `systemd-creds` (TPM-bound where available; chmod-600 fallback), never written plaintext into the script. Resolve sealed-first; store `@SECRET:<id>` references, not literals. Be honest that sealing doesn't defend against an already-root attacker — prefer credential-less transports (SSH keys, NFS).
- **Managed settings** (PATTERNS.md 15): persisted non-secret choices live in a chmod-600 file that is **parsed against a key whitelist, never `source`d**.
- **Live target verification** (PATTERNS.md 16): a saved remote destination is verified at add-time by writing, reading back, and deleting a canary file.
- **Guided setup + self-install** (PATTERNS.md 17): a one-time wizard (mandatory step first, optional steps skippable) plus self-install to `/usr/local/bin`, with scheduling gated on being installed. `pve-config-backup.sh` is the reference implementation for all four.

### Flow Pattern (complex interactive scripts)
1. Early exit for `--help`/`-h`, `--version`/`-V`, and read-only info flags (`--status`, `--test-notify`, `--schedule`)
2. ASCII header (repo banner + script art)
3. Root check
4. Internet connectivity check (if it downloads anything)
5. Environment checks (OS, kernel, arch, platform, disk, memory, language runtimes)
6. Preflight dependency checks (with interactive fix)
7. Status display (current vs available versions)
8. Interactive menu (or non-interactive via flags)
9. Perform updates/changes (parallel where applicable)
10. Summary with service URLs + optional Gotify notification

### Flow Pattern (simple utility scripts)
1. Help / version flags
2. Root check
3. Input validation
4. Safety checks (does the target exist? is it in the right state?)
5. Perform the action with clear step-by-step output
6. Success or failure message with next steps

## Building a New Script

1. Copy `script-template.sh` as the starting skeleton.
2. Pull the exact idioms (dynamic config help, parallel block, secure Gotify, cron manager, interactive menu, and where relevant sealed credentials / managed settings / target verification / guided setup) from `PATTERNS.md`.
3. Fill in config block, metadata, header art, preflight, and the core logic.
4. Add a collapsible `<details>` section to README.md.
5. Add the script to the table in this file and to TODO.md with a feature checklist.
6. Sanitize: generic placeholder defaults, no owner-specific IPs/domains.
7. Run through the Code Review Checklist below before considering it done.

## Code Review Checklist

### Security (CRITICAL)
- [ ] No hardcoded credentials, tokens, keys, or secrets
- [ ] Gotify tokens never in URLs/process args (use curl config file + header)
- [ ] Replayable secrets sealed (systemd-creds / chmod-600 fallback), never plaintext in-script; references stored, not literals
- [ ] Any managed settings file is PARSED against a whitelist, never `source`d
- [ ] No obfuscated or minified code — every line readable
- [ ] No `curl | bash` or `wget | sh` from untrusted external sources
- [ ] No phone-home, telemetry, or analytics
- [ ] Downloads only from verified sources (official GitHub releases, distro repos)
- [ ] Checksum verification for downloaded binaries where the upstream publishes them
- [ ] No modification of system files outside the script's declared scope
- [ ] No privilege escalation beyond what's needed
- [ ] No background processes spawned without user knowledge (parallel jobs the script manages and waits on are fine)
- [ ] No use of `eval` with user-supplied or external input
- [ ] No shell injection vectors (quote all variables: `"$var"`)
- [ ] Input validation on user-provided paths/IDs/URLs
- [ ] Temp files in /tmp with `mktemp` unique names, cleaned up on exit (incl. CTRL+C)
- [ ] File permissions set explicitly (755 binaries, 600 secrets, 700 secret dirs, never 777)

### Known Attack Patterns to Watch For
- **Typosquatting in URLs** — verify download domains match official sources exactly
- **Unicode homoglyphs** — check raw bytes, not visual appearance, in URLs/variables
- **Conditional payloads** — code that behaves differently by hostname, IP, date, or env
- **Delayed execution** — cron/systemd timers/at jobs added without user consent
- **Exfiltration** — piping system info, env vars, or file contents to external URLs
- **Symlink attacks** — following symlinks to overwrite system files
- **Race conditions** — TOCTOU bugs in temp file handling
- **Embedded binaries** — base64 blobs decoded and executed at runtime
- **Config-file sourcing** — `source`-ing a writable settings file is code execution; parse a whitelist instead

### Quality
- [ ] `set -euo pipefail` + `shopt -s inherit_errexit nullglob`
- [ ] CTRL+C handler with cleanup
- [ ] Colors use `$'...'` syntax
- [ ] All user-facing strings use the color-coded message functions
- [ ] Config block at top with all adjustable variables, commented
- [ ] Script metadata block present (NAME/VERSION/URL/PATH)
- [ ] No magic numbers — named variables
- [ ] Functions modular and single-purpose
- [ ] Multi-target work runs in parallel
- [ ] Every flag also reachable via the interactive menu
- [ ] Comments explain WHY, not just WHAT
- [ ] Tested on at least one Proxmox environment

### Documentation
- [ ] README collapsible `<details>` section with features, install, usage, config, requirements
- [ ] Man-style `-h`/`--help` with dynamic config line numbers
- [ ] Config variables documented with inline comments
- [ ] Added to the Current Scripts table and TODO.md

## File Naming Convention
- Script files: `kebab-case.sh` (e.g. `update-traefik.sh`, `pct-force-destroy.sh`)
- Documentation: `UPPERCASE.md` (e.g. `README.md`, `CONTRIBUTING.md`)
- No spaces in filenames, ever

## Current Scripts

| Script | Purpose | Status |
|--------|---------|--------|
| update-traefik.sh | Update Traefik binary and Traefik Manager | Active |
| pct-force-destroy.sh | Force destroy LXCs with stale NFS locks | Active |
| pihole-sync.sh | Sync Pi-hole config from primary to backup(s) | Active |
| nfs-watchdog.sh | Monitor NFS mount health across cluster nodes | Active |
| pve-config-backup.sh | Back up Proxmox VE host config (the gap PBS/vzdump leave); guided restore wizard + scriptable restore CLI | Active — **v1.3.4**, hardware-validated |

## Architecture Notes

Scripts target two environments:

1. **Inside Proxmox VMs/LXCs** (e.g. update-traefik.sh) — copied into the guest OS and run locally. No Proxmox API access or host privileges needed.
2. **On Proxmox hosts** (e.g. pct-force-destroy.sh, nfs-watchdog.sh, pve-config-backup.sh) — run on the node with root. Interact with PVE tools (pct, qm), the cluster filesystem (pmxcfs), and host-level config under `/etc`.

Scripts should clearly document which environment they target. Cluster-host scripts are deployed to all nodes via an `scp` loop. For host scripts that capture or act on per-node state (e.g. `pve-config-backup.sh`, which backs up each node's distinct `/etc/pve`, networking, and cluster membership), installation and scheduling are inherently per-node — there is no single "cluster-wide" run.

`pve-config-backup.sh` is also the reference implementation for the advanced credential/settings/self-install idioms (PATTERNS.md 14–17). It was deliberately used as the proving ground for sealed credentials before any decision to promote those helpers (e.g. for sealing Gotify tokens) into `script-template.sh` and the other scripts.