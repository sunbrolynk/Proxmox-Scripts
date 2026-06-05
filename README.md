# Proxmox-Scripts

A collection of utility scripts for managing services running on Proxmox VE — VMs, LXCs, and the applications inside them.

---

> [!IMPORTANT]
> **This repository is NOT affiliated with, endorsed by, or associated with [Proxmox VE Helper Scripts (community-scripts)](https://github.com/community-scripts/ProxmoxVE) in any way.** The similar name is coincidental — both repos deal with Proxmox, so the naming is naturally similar. If you're looking for the community-maintained Proxmox helper scripts originally created by tteck, visit [community-scripts.github.io/ProxmoxVE](https://community-scripts.github.io/ProxmoxVE/).

---

## About

These scripts are born out of real-world homelab and small business infrastructure management. They're designed to be:

- **Interactive** — colored output, clear prompts, guided workflows
- **Safe** — preflight checks, automatic backups, rollback on failure, graceful CTRL+C handling
- **Configurable** — user-adjustable variables at the top of each script, no digging through code
- **Transparent** — no obfuscated code, no telemetry, fully readable

Styled after the [Proxmox VE Community Scripts](https://github.com/community-scripts/ProxmoxVE) for a familiar look and feel.

## Scripts

### update-traefik

Interactive update script for [Traefik](https://traefik.io/) reverse proxy and [Traefik Manager](https://github.com/chr0nzz/traefik-manager) web UI.

**Features:**
- Auto-detects latest Traefik release from GitHub
- Updates to latest or a specific version
- Automatic backup of current binary before updating
- Automatic rollback if the new version fails to start
- Updates Traefik Manager from its git repository
- Environment checks (OS version, Python version, disk space, memory, architecture)
- Preflight dependency checks with interactive install of missing packages
- Detects and offers to start stopped services
- CTRL+C safe — cleans up temp files and exits gracefully
- Shows dashboard URLs on completion

**Install:**

```bash
# Download the script
wget -O /usr/local/bin/update-traefik https://raw.githubusercontent.com/SunBroLynk/Proxmox-Scripts/main/update-traefik.sh
chmod +x /usr/local/bin/update-traefik
```

**Usage:**

```bash
sudo update-traefik                  # Interactive mode — guided menu
sudo update-traefik -y               # Update everything without prompts
sudo update-traefik v3.7.0           # Update Traefik to a specific version
sudo update-traefik --traefik-only   # Update Traefik binary only, skip Manager
sudo update-traefik --manager-only   # Update Traefik Manager only, skip binary
sudo update-traefik -h               # Show help
```

**Configuration:**

Edit the variables at the top of the script to match your setup:

```bash
TRAEFIK_BIN="/usr/local/bin/traefik"        # Path to Traefik binary
TRAEFIK_SERVICE="traefik-proxy"             # Traefik systemd service name
TRAEFIK_MANAGER_DIR="/opt/traefik-manager"  # Traefik Manager install directory
TRAEFIK_MANAGER_USER="traefik-manager"      # Linux user running Traefik Manager
TRAEFIK_MANAGER_SERVICE="traefik-manager"   # Traefik Manager systemd service name
TRAEFIK_MANAGER_PORT="5000"                 # Traefik Manager web UI port
TRAEFIK_DASHBOARD_PORT="8080"               # Traefik dashboard port
TRAEFIK_ARCH="linux_amd64"                  # Binary architecture
MIN_DISK_MB=500                             # Minimum disk space warning threshold
MIN_MEM_MB=256                              # Minimum memory warning threshold
MIN_PYTHON="3.9"                            # Minimum Python version for Manager
```

**Requirements:**
- Root access (sudo)
- `wget`, `curl`, `git` (script offers to install if missing)
- Traefik installed as a systemd service
- Traefik Manager (optional) installed via git clone with a Python virtualenv

**How it works:**

```
┌─────────────────────────────────┐
│         Header & Root Check     │
├─────────────────────────────────┤
│      Internet Connectivity      │
├─────────────────────────────────┤
│    Environment Checks           │
│    ├── OS version               │
│    ├── Kernel & architecture    │
│    ├── Platform (VM/LXC)        │
│    ├── Python version           │
│    ├── Disk space               │
│    └── Available memory         │
├─────────────────────────────────┤
│    Preflight Checks             │
│    ├── Required packages        │
│    ├── Traefik binary           │
│    ├── Service status           │
│    └── Traefik Manager (opt.)   │
├─────────────────────────────────┤
│    Version Status               │
│    ├── Current vs Latest        │
│    └── Manager commit status    │
├─────────────────────────────────┤
│    Interactive Menu              │
│    ├── 1) Update everything     │
│    ├── 2) Traefik only          │
│    ├── 3) Manager only          │
│    ├── 4) Specific version      │
│    └── q) Quit                  │
├─────────────────────────────────┤
│    Update Process               │
│    ├── Download new version     │
│    ├── Backup current binary    │
│    ├── Stop → Install → Start   │
│    └── Rollback on failure      │
├─────────────────────────────────┤
│    Summary & Dashboard URLs     │
└─────────────────────────────────┘
```

---

## Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting a pull request.

**Key rules:**
- No hardcoded credentials or secrets
- No obfuscated code or telemetry
- Must include error handling and graceful CTRL+C
- Must be tested on Proxmox before submitting
- All PRs are reviewed before merging

## License

This project is licensed under the MIT License — see [LICENSE](LICENSE) for details.

## Disclaimer

These scripts are provided as-is with no warranty. Always test in a non-production environment first. Take snapshots before running update scripts. The authors are not responsible for any damage or data loss resulting from the use of these scripts.
