<div align="center">
<pre>
  ___                              
 | _ \_ _ _____ ___ __  _____ __  
 |  _/ '_/ _ \ \ / '  \/ _ \ \ / 
 |_| |_| \___/_\_\_|_|_\___/_\_\  
      ╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍
          S c r i p t s
</pre>
</div>

A collection of utility scripts for managing services running on Proxmox VE — VMs, LXCs, and the applications inside them.

---

> [!IMPORTANT]
> **This repository is NOT affiliated with, endorsed by, or associated with [Proxmox VE Helper Scripts (community-scripts)](https://github.com/community-scripts/ProxmoxVE) in any way.** The similar name is coincidental — both repos deal with Proxmox, so the naming is naturally similar. If you're looking for the community-maintained Proxmox helper scripts originally created by tteck, visit [community-scripts.github.io/ProxmoxVE](https://community-scripts.github.io/ProxmoxVE/).

---

## About

These scripts are born out of real-world homelab and small business infrastructure management. They're designed to be:

- **Interactive** — colored output, guided menus, clear prompts — no flags to memorize
- **Safe** — preflight checks, automatic backups, rollback on failure, graceful CTRL+C handling
- **Configurable** — user-adjustable variables at the top of each script, no digging through code
- **Transparent** — no obfuscated code, no telemetry, fully readable and auditable
- **Schedulable** — scripts that benefit from automation include a built-in cron scheduler — no cron knowledge required, just pick a frequency from the menu
- **Notifiable** — optional [Gotify](https://gotify.net/) integration sends markdown-formatted alerts on success or failure when running unattended

Styled after the [Proxmox VE Community Scripts](https://github.com/community-scripts/ProxmoxVE) for a familiar look and feel. Every script includes a full man-style `--help` page with configuration line numbers so you know exactly what to edit.

## Scripts

<details>
<summary><strong>update-traefik</strong> — Update Traefik reverse proxy and Traefik Manager</summary>

<br>

Interactive update script for [Traefik](https://traefik.io/) reverse proxy and [Traefik Manager](https://github.com/chr0nzz/traefik-manager) web UI.

**Features:**
- Auto-detects latest Traefik release from GitHub
- Updates to latest or a specific version
- SHA256 checksum verification on every download (supply chain hardening)
- ARM64 and armv7 architecture auto-detection
- Automatic backup of current binary before updating
- Automatic rollback if the new version fails to start
- Updates Traefik Manager via git pull and runs `setup-assets.sh` for vendor/CSS rebuild
- View GitHub release notes / changelog for any version
- Environment checks (OS, kernel, architecture, platform, Python, disk space, memory)
- Preflight dependency checks with interactive install of missing packages
- Detects and offers to start stopped services
- Built-in cron scheduler with Gotify notifications for automated updates
- CTRL+C safe — cleans up temp files and exits gracefully
- Shows dashboard URLs on completion

**Install:**

```bash
wget -O /usr/local/bin/update-traefik https://raw.githubusercontent.com/SunBroLynk/Proxmox-Scripts/main/update-traefik.sh
chmod +x /usr/local/bin/update-traefik
```

**Usage:**

```bash
sudo update-traefik                     # Interactive mode — 9-option guided menu
sudo update-traefik -y                  # Update everything without prompts
sudo update-traefik --cron              # Automated update with Gotify notification
sudo update-traefik v3.7.0              # Update Traefik to a specific version
sudo update-traefik --traefik-only      # Update Traefik binary only, skip Manager
sudo update-traefik --manager-only      # Update Traefik Manager only, skip binary
sudo update-traefik --check             # Show current vs latest versions, no changes
sudo update-traefik --rollback          # Restore previous Traefik binary from backup
sudo update-traefik --changelog         # Show release notes for latest version
sudo update-traefik --changelog v3.7.0  # Show release notes for specific version
sudo update-traefik --test-notify       # Test Gotify notification
sudo update-traefik --schedule          # Set up, change, or remove cron schedule
sudo update-traefik -h                  # Full man-style help with config line numbers
sudo update-traefik -V                  # Show version
```

**Configuration:**

Edit the variables at the top of the script to match your setup:

```bash
TRAEFIK_BIN="/usr/local/bin/traefik"             # Path to Traefik binary
TRAEFIK_SERVICE="traefik-proxy"                  # Traefik systemd service name
TRAEFIK_MANAGER_DIR="/opt/traefik-manager"       # Traefik Manager install directory
TRAEFIK_MANAGER_USER="traefik-manager"           # Linux user running Traefik Manager
TRAEFIK_MANAGER_SERVICE="traefik-manager"        # Traefik Manager systemd service name
TRAEFIK_MANAGER_PORT="5000"                      # Traefik Manager web UI port
TRAEFIK_MANAGER_REPO="chr0nzz/traefik-manager"   # Traefik Manager GitHub repo
TRAEFIK_DASHBOARD_PORT="8080"                    # Traefik dashboard port
TRAEFIK_ARCH="linux_amd64"                       # Binary architecture (auto-detected)
MIN_DISK_MB=500                                  # Minimum disk space warning threshold
MIN_MEM_MB=256                                   # Minimum memory warning threshold
MIN_PYTHON="3.9"                                 # Minimum Python version for Manager
GOTIFY_URL=""                                    # Gotify server URL (optional)
GOTIFY_TOKEN=""                                  # Gotify application token (optional)
GOTIFY_PRIORITY=5                                # Notification priority (1-10)
LOG_FILE="/var/log/update-traefik.log"            # Log file for cron mode
```

**Requirements:**
- Root access (sudo)
- `wget`, `curl`, `git` (script offers to install if missing)
- Traefik installed as a systemd service
- Traefik Manager (optional) installed via git clone with a Python virtualenv

</details>

---

<details>
<summary><strong>pct-force-destroy</strong> — Force destroy LXCs with stale NFS locks</summary>

<br>

Force destroy a Proxmox LXC container that's stuck due to stale locks. This commonly happens when NFS-backed storage timeouts leave orphaned lock files that prevent container deletion.

**The Problem:** Deleting an LXC on shared NFS storage sometimes hangs forever on "trying to acquire cfs lock 'storage-...'". The only fix is usually a node reboot — this script eliminates that.

**Features:**
- Interactive menu when run with no arguments — no flags to memorize
- Validates container exists and is stopped before doing anything
- Clears stale PVE config locks (`/run/lock/lxc/`)
- Clears stale CFS storage locks (`/etc/pve/priv/lock/`)
- `--all` mode to clear every stale lock on the node without destroying anything
- `--dry-run` mode to preview what would happen without making changes
- `--status` to show all containers with their status, lock state, storage backend, and name
- Auto-detects storage backend type per container (NFS, local-lvm, ZFS, etc.)
- Color-coded output showing each step
- Clear error messages with suggested fixes if something fails
- CTRL+C safe

**Install:**

```bash
wget -O /usr/local/bin/pct-force-destroy https://raw.githubusercontent.com/SunBroLynk/Proxmox-Scripts/main/pct-force-destroy.sh
chmod +x /usr/local/bin/pct-force-destroy
```

For clusters, deploy to all nodes:

```bash
for node in node1-ip node2-ip node3-ip; do
    scp /usr/local/bin/pct-force-destroy root@${node}:/usr/local/bin/
done
```

**Usage:**

```bash
sudo pct-force-destroy                  # Interactive menu
sudo pct-force-destroy 105              # Force destroy container 105
sudo pct-force-destroy --all            # Clear all stale locks (no destroy)
sudo pct-force-destroy --status         # Show all containers and lock state
sudo pct-force-destroy --dry-run 105    # Preview what would happen
sudo pct-force-destroy --dry-run --all  # Preview all stale locks
sudo pct-force-destroy -h               # Full man-style help
```

**Preventing the root cause:**

If you frequently hit stale NFS locks, change your NFS mount options from `hard` to `soft` with a timeout. In Proxmox, edit `/etc/pve/storage.cfg` and add:

```
options soft,timeo=30,retrans=3
```

This makes NFS operations timeout cleanly instead of hanging forever. See [Proxmox NFS documentation](https://pve.proxmox.com/wiki/Storage:_NFS) for details.

</details>

---

<details>
<summary><strong>pihole-sync</strong> — Sync Pi-hole config from primary to backup via Teleporter</summary>

<br>

Automates Pi-hole configuration sync from a primary instance to one or more backups using the built-in Teleporter CLI. Keeps all Pi-holes identical. Designed for Pi-hole v6+.

**Features:**
- Full Teleporter export/import via CLI (no API tokens needed)
- Sync to multiple backup Pi-holes simultaneously (space-separated IP list)
- Selective sync with `--skip-settings` to preserve each backup's unique passwords, network config, and web interface settings
- Diff display (`--diff`) to compare adlists, domains, clients, and groups between primary and backups before syncing
- Restore mode (`--restore`) to restore a specific backup to the primary with interactive file picker
- Automatic gravity update (`pihole -g`) on backups after every sync
- Preflight checks — verifies Pi-hole and SSH on all targets before syncing
- Local backup archive with configurable retention (default: 7)
- Gotify notifications on sync success or failure (cron mode only)
- Built-in cron scheduler — set up automated syncs without cron knowledge
- CTRL+C safe — backup Pi-holes are not modified if cancelled

**Prerequisites:**
- Pi-hole v6+ on primary and all backups
- SSH key-based authentication from primary → each backup
- Run on the **primary** Pi-hole

**SSH key setup (one-time per backup):**

```bash
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
ssh-copy-id root@<backup-pihole-ip>
```

**Install (on the primary Pi-hole):**

```bash
wget -O /usr/local/bin/pihole-sync https://raw.githubusercontent.com/SunBroLynk/Proxmox-Scripts/main/pihole-sync.sh
chmod +x /usr/local/bin/pihole-sync
```

**Usage:**

```bash
sudo pihole-sync                          # Interactive menu — 8 options
sudo pihole-sync -y                       # Sync without prompts (for cron)
sudo pihole-sync --skip-settings          # Sync but keep backup's passwords/network
sudo pihole-sync --diff                   # Compare primary vs backups, no changes
sudo pihole-sync --restore                # Restore backup to primary (interactive picker)
sudo pihole-sync --restore /path/to/file  # Restore specific backup file
sudo pihole-sync --backup-only            # Local backup only, no sync
sudo pihole-sync --list                   # List stored backups with sizes and dates
sudo pihole-sync --test-notify            # Test Gotify notification
sudo pihole-sync --schedule               # Set up, change, or remove cron schedule
sudo pihole-sync -h                       # Full man-style help with config line numbers
sudo pihole-sync -V                       # Show version
```

**Configuration:**

```bash
BACKUP_PIHOLES="192.168.1.2"          # Backup IP(s), space-separated for multiple
                                      # Example: "192.168.1.2 192.168.1.3"
BACKUP_SSH_USER="root"                # SSH user on the backup Pi-hole(s)
BACKUP_SSH_PORT="22"                  # SSH port on the backup Pi-hole(s)
LOCAL_BACKUP_DIR="/var/backups/pihole" # Where to store Teleporter archives
RETENTION_COUNT=7                     # Number of local backups to keep
GOTIFY_URL=""                         # Gotify server URL (optional)
GOTIFY_TOKEN=""                       # Gotify application token (optional)
GOTIFY_PRIORITY=5                     # Notification priority (1-10)
```

**What it syncs:**
- Blocklists (adlists) and group assignments
- Local DNS records and CNAME records
- Custom dnsmasq configuration (misc.dnsmasq_lines)
- Domain allow/deny lists (including regex)
- Client definitions and group memberships
- DHCP leases
- Pi-hole settings (pihole.toml) — skippable with `--skip-settings`

</details>

---

<details>
<summary><strong>nfs-watchdog</strong> — Monitor NFS mount health across Proxmox cluster nodes</summary>

<br>

Detects stale or unresponsive NFS mounts before they cause cascading lock issues and container deletion failures. Tests read, write, and latency on every NFS mount.

**Features:**
- Auto-detects all NFS mounts on the node (no manual configuration)
- Three-phase health test per mount: read, write, and latency
- Latency measurement with color-coded thresholds (green/yellow/red)
- Detects stale mounts before they cause lock problems
- Optional auto-remount of stale mounts (lazy first, force fallback)
- Force remount all mounts on demand
- Detailed status table with mount options (detects hard vs soft)
- Gotify notifications with markdown-formatted alerts when stale mounts are found
- Built-in cron scheduler — set up automated checks without cron knowledge
- CTRL+C safe
- Designed to run on every cluster node

**Install:**

```bash
wget -O /usr/local/bin/nfs-watchdog https://raw.githubusercontent.com/SunBroLynk/Proxmox-Scripts/main/nfs-watchdog.sh
chmod +x /usr/local/bin/nfs-watchdog
```

For clusters, deploy to all nodes:

```bash
for node in node1-ip node2-ip node3-ip; do
    scp /usr/local/bin/nfs-watchdog root@${node}:/usr/local/bin/
done
```

**Usage:**

```bash
sudo nfs-watchdog                    # Interactive menu — 6 options
sudo nfs-watchdog -y                 # Run checks without prompts (for cron)
sudo nfs-watchdog --status           # Detailed status of all NFS mounts
sudo nfs-watchdog --dry-run          # Check only, no remount or notify
sudo nfs-watchdog --remount          # Force remount all NFS mounts
sudo nfs-watchdog --test-notify      # Test Gotify notification
sudo nfs-watchdog --schedule         # Set up, change, or remove cron schedule
sudo nfs-watchdog -h                 # Full man-style help with config line numbers
```

**Configuration:**

```bash
CHECK_TIMEOUT=5                       # Seconds before declaring a mount stale
AUTO_REMOUNT=false                    # Auto-remount stale mounts (true/false)
LOG_FILE="/var/log/nfs-watchdog.log"  # Log file for cron mode
GOTIFY_URL=""                         # Gotify server URL (optional)
GOTIFY_TOKEN=""                       # Gotify application token (optional)
GOTIFY_PRIORITY=5                     # Notification priority (1-10)
```

</details>

---

## Scheduling

Scripts that benefit from automation (update-traefik, pihole-sync, nfs-watchdog) include a **built-in cron scheduler**. You don't need to know cron syntax — just run:

```bash
sudo <script-name> --schedule
```

Or select **"Manage cron schedule"** from the interactive menu. Pick a frequency (every 5 minutes, hourly, daily, weekly, or custom), and the script writes the crontab entry for you. Come back anytime to change or remove it.

## Notifications

Scripts with scheduling support optional [Gotify](https://gotify.net/) push notifications. When running unattended via cron, they send markdown-formatted alerts on success or failure — complete with tables, status indicators, and host details. Set `GOTIFY_URL` and `GOTIFY_TOKEN` in the script's config block, then verify with:

```bash
sudo <script-name> --test-notify
```

Notifications are only sent in automated/cron mode. Interactive use shows results directly in the terminal.

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