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

- **Interactive** — colored output, clear prompts, guided workflows
- **Safe** — preflight checks, automatic backups, rollback on failure, graceful CTRL+C handling
- **Configurable** — user-adjustable variables at the top of each script, no digging through code
- **Transparent** — no obfuscated code, no telemetry, fully readable

Styled after the [Proxmox VE Community Scripts](https://github.com/community-scripts/ProxmoxVE) for a familiar look and feel.

## Scripts

<details>
<summary><strong>update-traefik</strong> — Update Traefik reverse proxy and Traefik Manager</summary>

<br>

Interactive update script for [Traefik](https://traefik.io/) reverse proxy and [Traefik Manager](https://github.com/chr0nzz/traefik-manager) web UI.

**Features:**
- Auto-detects latest Traefik release from GitHub
- Updates to latest or a specific version
- Automatic backup of current binary before updating
- Automatic rollback if the new version fails to start
- Updates Traefik Manager via git pull and runs `setup-assets.sh` for vendor/CSS rebuild
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
sudo update-traefik -V               # Show version
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
TRAEFIK_MANAGER_REPO="chr0nzz/traefik-manager"  # Traefik Manager GitHub repo
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

<details>
<summary><strong>How it works</strong> (flow diagram)</summary>

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

</details>

</details>

---

<details>
<summary><strong>pct-force-destroy</strong> — Force destroy LXCs with stale NFS locks</summary>

<br>

Force destroy a Proxmox LXC container that's stuck due to stale locks. This commonly happens when NFS-backed storage timeouts leave orphaned lock files that prevent container deletion.

**The Problem:** Deleting an LXC on shared NFS storage sometimes hangs forever on "trying to acquire cfs lock 'storage-...'". The only fix is usually a node reboot — this script eliminates that.

**Features:**
- Validates container exists and is stopped before doing anything
- Clears stale PVE config locks (`/run/lock/lxc/`)
- Clears stale CFS storage locks (`/etc/pve/priv/lock/`)
- Color-coded output showing each step
- Clear error messages with suggested fixes if something fails
- Root check and input validation

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
sudo pct-force-destroy 105           # Force destroy container 105
sudo pct-force-destroy -h            # Show help
```

**What it does:**
1. Verifies the container exists and is stopped
2. Clears stale PVE config locks
3. Clears stale CFS storage locks
4. Runs `pct destroy` with `--purge --force`

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

Automates Pi-hole configuration sync from a primary instance to a backup using the built-in Teleporter CLI. Keeps both Pi-holes identical — blocklists, local DNS records, dnsmasq config, DHCP leases, groups, clients, and all settings. Designed for Pi-hole v6+.

**Features:**
- Full Teleporter export/import via CLI (no API tokens needed)
- Preflight checks — verifies Pi-hole and SSH on both sides before syncing
- Local backup archive with configurable retention (default: 7)
- Backup-only mode for local archives without syncing
- List stored backups with sizes and dates
- Confirmation prompt before overwriting backup's config
- CTRL+C safe — backup Pi-hole is not modified if cancelled
- Automated mode (`-y`) for unattended cron execution

**Prerequisites:**
- Pi-hole v6+ on both primary and backup
- SSH key-based authentication from primary → backup
- Run on the **primary** Pi-hole

**SSH key setup (one-time):**

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
sudo pihole-sync                     # Interactive sync with confirmation
sudo pihole-sync -y                  # Sync without prompts (for cron)
sudo pihole-sync --backup-only       # Local backup only, no sync
sudo pihole-sync --list              # List stored backups
sudo pihole-sync -h                  # Show help
sudo pihole-sync -V                  # Show version
```

**Configuration:**

Edit the variables at the top of the script:

```bash
BACKUP_PIHOLE="192.168.1.2"           # IP of the backup Pi-hole
BACKUP_SSH_USER="root"                # SSH user on the backup Pi-hole
BACKUP_SSH_PORT="22"                  # SSH port on the backup Pi-hole
LOCAL_BACKUP_DIR="/var/backups/pihole" # Where to store Teleporter archives locally
RETENTION_COUNT=7                     # Number of local backups to keep
```

**Automated daily sync (cron):**

```bash
sudo crontab -e
# Add this line:
0 3 * * * /usr/local/bin/pihole-sync -y >> /var/log/pihole-sync.log 2>&1
```

**What it syncs:**
- Blocklists (adlists) and group assignments
- Local DNS records and CNAME records
- Custom dnsmasq configuration (misc.dnsmasq_lines)
- Domain allow/deny lists (including regex)
- Client definitions and group memberships
- DHCP leases
- Pi-hole settings (pihole.toml)

</details>

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
