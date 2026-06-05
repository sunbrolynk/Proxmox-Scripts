# CLAUDE.md — AI Project Context

This file provides context for AI assistants (Claude, Copilot, etc.) working on this repository.

## Project Overview

**Proxmox-Scripts** is a public collection of utility scripts for managing services running on Proxmox VE (VMs and LXCs). Scripts are interactive, safe, and styled after the Proxmox VE Community Scripts aesthetic.

**This repo is NOT affiliated with [community-scripts/ProxmoxVE](https://github.com/community-scripts/ProxmoxVE).**

## Repository Owner

- GitHub: SunBroLynk
- Primary users: The owner and a small group of trusted homelab/ISP professionals
- Environment: Proxmox VE, Mikrotik RouterOS, UniFi networking, Docker, self-hosted services

## Script Standards

All scripts in this repo must follow these conventions:

### Structure
- Shebang: `#!/usr/bin/env bash`
- Strict mode: `set -euo pipefail` with `shopt -s inherit_errexit nullglob`
- Configuration variables at the TOP of the script in a clearly labeled block
- No hardcoded IPs, domains, usernames, passwords, API keys, or secrets anywhere
- User-adjustable values must be variables, not buried in code

### Output Style (matches Proxmox Community Scripts)
```bash
# Colors
RD=$(echo "\033[01;31m")   # Red — errors
YW=$(echo "\033[33m")      # Yellow — warnings, in-progress
GN=$(echo "\033[1;92m")    # Green — success
BL=$(echo "\033[36m")      # Blue/Cyan — info, headers
CL=$(echo "\033[m")        # Clear

# Message functions
msg_info()  — yellow, with trailing "..."
msg_ok()    — green checkmark ✓
msg_error() — red cross ✗
msg_warn()  — blue info ℹ
```

### Required Features
- **CTRL+C trap** — graceful exit, cleanup temp files, inform user no changes were made
- **Preflight checks** — verify dependencies BEFORE showing menu or doing work
- **Interactive prompts** — offer to fix problems (install packages, start services)
- **Automatic backups** — before modifying binaries or configs
- **Rollback on failure** — if an update breaks a service, restore the backup automatically
- **Clear error messages** — tell the user WHAT failed and HOW to fix it manually
- **Summary on completion** — show final versions, URLs, status

### Flow Pattern
Every script should follow this order:
1. Early exit for `--help` / `-h` (before any checks)
2. ASCII art header
3. Root check
4. Internet connectivity check
5. Environment checks (OS, architecture, disk, memory)
6. Preflight dependency checks (with interactive fix)
7. Status display (current vs available versions)
8. Interactive menu (or non-interactive via flags)
9. Perform updates/changes
10. Summary with service URLs

## Code Review Checklist

When reviewing contributions or PRs, verify:

### Security (CRITICAL)
- [ ] No hardcoded credentials, tokens, keys, or secrets
- [ ] No obfuscated or minified code — every line must be readable
- [ ] No `curl | bash` or `wget | sh` from untrusted external sources
- [ ] No phone-home, telemetry, or analytics
- [ ] No unnecessary network requests
- [ ] Downloads only from verified sources (official GitHub releases, distro package repos)
- [ ] No modification of system files outside the script's declared scope
- [ ] No privilege escalation beyond what's needed
- [ ] No writing to unexpected directories
- [ ] No background processes spawned without user knowledge
- [ ] No use of `eval` with user-supplied or external input
- [ ] No shell injection vectors (unquoted variables in commands)
- [ ] Temp files created in /tmp with unique names and cleaned up on exit
- [ ] File permissions set explicitly (especially for downloaded binaries: 755, not 777)

### Known Attack Patterns to Watch For
- **Typosquatting in URLs** — verify download domains match official sources exactly
- **Hidden characters** — check for Unicode lookalikes in URLs or commands (e.g. using Cyrillic "а" instead of Latin "a")
- **Conditional payloads** — code that behaves differently based on hostname, IP, or environment
- **Delayed execution** — cron jobs, systemd timers, or at jobs added without user consent
- **Exfiltration** — piping system info, env vars, or file contents to external URLs
- **Symlink attacks** — following symlinks to overwrite system files
- **Race conditions** — TOCTOU bugs in temp file handling
- **Embedded binaries** — base64-encoded blobs decoded and executed at runtime

### Quality
- [ ] Uses `set -euo pipefail` and proper error handling
- [ ] CTRL+C handler with cleanup
- [ ] All user-facing strings use color-coded message functions
- [ ] Configuration block at top with all adjustable variables
- [ ] No magic numbers — use named variables
- [ ] Functions are modular and single-purpose
- [ ] Comments explain WHY, not just WHAT
- [ ] Tested on at least one Proxmox environment

### Documentation
- [ ] README section for the script with usage, configuration, and requirements
- [ ] Inline help via `-h` / `--help` flag
- [ ] Configuration variables are documented with comments

## File Naming Convention

- Script files: `kebab-case.sh` (e.g. `update-traefik.sh`)
- Documentation: `UPPERCASE.md` (e.g. `README.md`, `CONTRIBUTING.md`)
- No spaces in filenames, ever

## Current Scripts

| Script | Purpose | Status |
|--------|---------|--------|
| update-traefik.sh | Update Traefik binary and Traefik Manager | Active |

## Architecture Notes

Scripts in this repo target services running INSIDE Proxmox VMs/LXCs, not the Proxmox host itself. They are designed to be copied into the guest OS and run locally. They do NOT require Proxmox API access or host-level privileges.
