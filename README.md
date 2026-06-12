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
- **Guided** — scripts walk you through setup one question at a time, seal any secrets for you, and remember your answers — no Linux knowledge or config-file editing required (you *can* edit the config block if you prefer, but you never have to)
- **Safe** — preflight checks, automatic backups, rollback on failure, graceful CTRL+C handling
- **Configurable** — non-secret settings (paths, IPs, timeouts) live in a labeled block at the top of each script; edit only what you need, no digging through code
- **Secret-safe** — never put a Gotify token or password in the script. Seal it instead with `--set-cred` (or, where available, the guided setup) so it's encrypted on disk and never stored in plaintext or sent in a URL
- **Transparent** — no obfuscated code, no telemetry, fully readable and auditable
- **Schedulable** — scripts that benefit from automation include a built-in cron scheduler — no cron knowledge required, just pick a frequency from the menu
- **Notifiable** — optional [Gotify](https://gotify.net/) integration sends markdown-formatted alerts on success or failure when running unattended

Styled after the [Proxmox VE Community Scripts](https://github.com/community-scripts/ProxmoxVE) for a familiar look and feel. Every script includes a full man-style `--help` page with configuration line numbers so you know exactly what to edit.

## Scripts

<details>
<summary><strong>Update Traefik</strong> — Update Traefik reverse proxy and Traefik Manager</summary>

<br>

<div align="center">
<pre>
   ______                _____ __
  /_  __/________ ____  / __(_) /__
   / / / ___/ __ `/ _ \/ /_/ / //_/
  / / / /  / /_/ /  __/ __/ / ,&lt;
 /_/ /_/   \__,_/\___/_/ /_/_/|_|
     &amp; Traefik Manager Updater
</pre>
</div>

Interactive update script for [Traefik](https://traefik.io/) reverse proxy and [Traefik Manager](https://github.com/chr0nzz/traefik-manager) web UI.

**Features:**
- Auto-detects latest Traefik release from GitHub
- Updates to latest or a specific version
- SHA256 checksum verification on every download — **fail-closed**: a checksum mismatch always aborts, and a *missing* checksum aborts too (in cron) or prompts (interactively) rather than silently installing unverified. Override only with the explicit `--insecure-skip-checksum` flag
- ARM64 and armv7 architecture auto-detection
- Automatic backup of current binary before updating
- Automatic rollback if the new version fails to start
- Updates Traefik Manager via git pull and runs `setup-assets.sh` for vendor/CSS rebuild
- View GitHub release notes / changelog for any version
- Environment checks (OS, kernel, architecture, platform, Python, disk space, memory)
- Preflight dependency checks with interactive install of missing packages
- Detects and offers to start stopped services
- Built-in cron scheduler with Gotify notifications for automated updates
- **Sealed Gotify credentials** — the notification token is sealed with `systemd-creds` (or a `chmod 600` fallback) and sent in a request header, never in the URL; seal it with `--set-cred gotify-token`
- Scheduling is gated on being installed at `/usr/local/bin` (cron runs that exact path), and the cron write is verified rather than assumed
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
sudo update-traefik --insecure-skip-checksum   # Proceed if checksum can't be fetched (NOT recommended)
sudo update-traefik --rollback          # Restore previous Traefik binary from backup
sudo update-traefik --changelog         # Show release notes for latest version
sudo update-traefik --changelog v3.7.0  # Show release notes for specific version
sudo update-traefik --test-notify       # Test Gotify notification
sudo update-traefik --set-cred gotify-token  # Seal the Gotify token (reads value from stdin)
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
GOTIFY_TOKEN=""                                  # Gotify token (optional; prefer sealing via --set-cred gotify-token)
GOTIFY_PRIORITY=5                                # Notification priority (1-10)
LOG_FILE="/var/log/update-traefik.log"            # Log file for cron mode
```

**Requirements:**
- Root access (sudo)
- `wget`, `curl`, `git` (script offers to install if missing)
- `systemd-creds` for a sealed Gotify token (present on PVE 8/9; falls back to a `chmod 600` file)
- Traefik installed as a systemd service
- Traefik Manager (optional) installed via git clone with a Python virtualenv

</details>

---

<details>
<summary><strong>PCT Force Destroy</strong> — Force destroy LXCs with stale NFS locks</summary>

<br>

<div align="center">
<pre>
   __              __
  / /  ___  ____  / /__
 / /__/ _ \/ __/ /  '_/
/____/\___/\__/ /_/\_\
   b r e a k e r
</pre>
</div>

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
<summary><strong>Pi-hole Sync</strong> — Sync Pi-hole config from primary to backup via Teleporter</summary>

<br>

<div align="center">
<pre>
        _ __       __
   ___ (_) /  ___ / /__
  / _ \/ / _ \/ _ \ / -_)
 / .__/_/_//_/\___/_/\__/
/_/          s y n c
</pre>
</div>

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
- **Sealed Gotify credentials** — the token is sealed with `systemd-creds` (or a `chmod 600` fallback) and sent in a request header, never in the URL; seal it with `--set-cred gotify-token`
- Built-in cron scheduler — set up automated syncs without cron knowledge; scheduling is gated on canonical-path install and the cron write is verified
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
sudo pihole-sync --set-cred gotify-token  # Seal the Gotify token (reads value from stdin)
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
GOTIFY_TOKEN=""                       # Gotify token (optional; prefer sealing via --set-cred gotify-token)
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
<summary><strong>NFS Watchdog</strong> — Monitor NFS mount health across Proxmox cluster nodes</summary>

<br>

<div align="center">
<pre>
               __       __    __
  _    _____ _/ /______/ /   / /__  ___ _
 | |/|/ / _ `/ __/ __/ _ \ / _ / _ \/ _ `/
 |__,__/\_,_/\__/\__/_//_//_//_\___/\_, /
    nfs watchdog                   /___/
</pre>
</div>

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
- **Sealed Gotify credentials** — the token is sealed with `systemd-creds` (or a `chmod 600` fallback) and sent in a request header, never in the URL; seal it with `--set-cred gotify-token`
- Built-in cron scheduler — set up automated checks without cron knowledge; scheduling is gated on canonical-path install and the cron write is verified
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
sudo nfs-watchdog --set-cred gotify-token  # Seal the Gotify token (reads value from stdin)
sudo nfs-watchdog --schedule         # Set up, change, or remove cron schedule
sudo nfs-watchdog -h                 # Full man-style help with config line numbers
```

**Configuration:**

```bash
CHECK_TIMEOUT=5                       # Seconds before declaring a mount stale
AUTO_REMOUNT=false                    # Auto-remount stale mounts (true/false)
LOG_FILE="/var/log/nfs-watchdog.log"  # Log file for cron mode
GOTIFY_URL=""                         # Gotify server URL (optional)
GOTIFY_TOKEN=""                       # Gotify token (optional; prefer sealing via --set-cred gotify-token)
GOTIFY_PRIORITY=5                     # Notification priority (1-10)
```

</details>

---

<details>
<summary><strong>PVE Config Backup</strong> — Back up Proxmox VE host configuration (the gap PBS/vzdump leave)</summary>

<br>

<div align="center">
<pre>
   ___           __ _        ___          _
  / __|___ _ _  / _(_)__ _  | _ ) __ _ __| |___ _  _ _ __
 | (__/ _ \ ' \|  _| / _` | | _ \/ _` / _| / / | || | '_ \
  \___\___/_||_|_| |_\__, | |___/\__,_\__|_\_\\_,_| .__/
                     |___/                        |_|
</pre>
</div>

Proxmox Backup Server and vzdump protect your **guests** (VMs/CTs) — not the **host** itself. If a node's system disk dies, those guest backups don't bring back `/etc/pve`, your networking, storage definitions, cluster membership, users, or apt sources, so recovery means a full reinstall and rebuild from memory. This script captures all of that host-side config into a single dated, `chmod 600` archive so a dead node is a restore, not a reverse-engineering project. It backs up **configuration only — no guest disk images** — so it's safe to run live on a busy node. Runs on a **Proxmox host** (root).

**Features:**
- Captures `/etc/pve` plus the pmxcfs backing database (`/var/lib/pve-cluster/config.db`), networking, storage and cluster config, users, apt sources, host cron, and anything you add via `EXTRA_PATHS`
- Staging-copy approach (`cp -a`) avoids live-FS read races and preserves permissions; the final archive is `chmod 600` because it contains `/etc/shadow` hashes and SSH host keys
- `MANIFEST.txt` written inside every archive listing included and skipped paths
- Prefix-scoped retention — only ever prunes its own archives, never a blind `rm`
- **Offsite export** to SCP/SFTP (key-based), NFS, and FTP/FTPS. Each target is verified the moment you add it by **writing, reading back, and deleting a test file**, with per-step pass/fail feedback — a bad target is never saved
- **Sealed credentials** — FTP passwords and the Gotify token are sealed with `systemd-creds` (TPM-bound where the host has a TPM, host-key-bound otherwise), falling back to a `chmod 600` file when `systemd-creds` is unavailable. No plaintext secret is written to disk, and credentials never live in the script
- **Guided one-time setup** (`--setup`, a menu item, or auto-offered on first run): takes the first backup, then optionally walks you through an export target, Gotify, and a schedule — after that it runs hands-off and the only thing you return for is a restore
- **Self-installs** to `/usr/local/bin` (offered once at startup if you ran it from elsewhere) so the cron path resolves; scheduling is gated on being installed
- **Guided restore wizard** (`--restore <file>`) extracts to a review directory, then lets you choose what to bring back — the whole config, a category (guests, storage, network, users, SSH, apt, cron), or a single file — and **does the placement and service reloads for you**. The full-node path (`config.db` swap) stops `pve-cluster`, swaps the database, restarts, verifies `/etc/pve` mounts, and **automatically rolls back** if the service doesn't come up healthy. It is gated behind typing `RESTORE` and never touches anything until you confirm.
- **Scriptable restore** for power users and automation: `--what <category>`, `--file <path>`, `--full`, and `--extract-only`, with `--yes` to skip prompts. The invasive full restore additionally requires `--force-full` to run unattended — `--yes` alone won't trigger a config.db swap, so a cron typo can't silently re-identify a node.
- Cluster-aware — detects corosync config and tailors restore guidance for single-node rebuild vs. cluster rejoin
- Gotify notification on backup success/failure (cron mode), `--test-notify`
- Non-interactive credential provisioning (`--set-cred`) for automation — seal a secret from stdin with no plaintext on disk
- CTRL+C safe — no partial/corrupt archive left behind

**Install:**

```bash
wget -O /usr/local/bin/pve-config-backup https://raw.githubusercontent.com/SunBroLynk/Proxmox-Scripts/main/pve-config-backup.sh
chmod +x /usr/local/bin/pve-config-backup
```

Each node's host config is separate, so for clusters run it (and schedule it) on every node:

```bash
for node in node1-ip node2-ip node3-ip; do
    scp /usr/local/bin/pve-config-backup root@${node}:/usr/local/bin/
done
```

**Usage:**

```bash
sudo pve-config-backup                    # Interactive menu (auto-offers guided setup on first run)
sudo pve-config-backup --setup            # Guided one-time setup (backup + export + Gotify + schedule)
sudo pve-config-backup -y                 # Back up without prompts (for cron)
sudo pve-config-backup --cron             # Same as -y; fires Gotify if configured
sudo pve-config-backup --targets          # Add / test / remove export targets (NFS/SFTP/FTPS)
sudo pve-config-backup --list             # List archives with sizes and dates
sudo pve-config-backup --restore <file>   # Guided restore wizard (choose full / category / single file)
sudo pve-config-backup --restore <file> --what storage --yes      # scripted: restore a category
sudo pve-config-backup --restore <file> --file etc/pve/storage.cfg  # scripted: one file
sudo pve-config-backup --restore <file> --full --force-full       # automated full config.db restore
sudo pve-config-backup --restore <file> --extract-only            # extract to review dir, change nothing
sudo pve-config-backup --status           # Last backup, configured targets, schedule
sudo pve-config-backup --set-cred <name>  # Seal a secret read from stdin (automation)
sudo pve-config-backup --test-notify      # Test Gotify notification
sudo pve-config-backup --schedule         # Set up, change, or remove cron schedule
sudo pve-config-backup -h                 # Full man-style help with config line numbers
sudo pve-config-backup -V                 # Show version
```

Seal a credential non-interactively (e.g. for provisioning):

```bash
echo -n "$GOTIFY_TOKEN" | sudo pve-config-backup --set-cred gotify-token
```

**Configuration:**

```bash
BACKUP_DEST="/var/backups/pve-config"                # Local directory to store archives
RETENTION_DAYS=30                                    # Prune our own archives older than N days (0 = keep all)
REMOTE_TARGETS=""                                    # Simple key-based SCP/SFTP targets, space-separated
                                                     #   e.g. "root@192.168.1.10:/mnt/backup"
TARGETS_FILE="/etc/pve-config-backup/targets.conf"   # Managed (chmod 600) NFS/FTP target store (--targets)
INCLUDE_SHADOW=true                                  # Include /etc/shadow + /etc/gshadow (password hashes)
INCLUDE_SSH_HOST_KEYS=true                           # Include /etc/ssh (host keys + sshd_config)
EXTRA_PATHS=""                                        # Extra files/dirs to include, space-separated
GOTIFY_URL=""                                        # Gotify server URL (optional)
GOTIFY_TOKEN=""                                      # Gotify application token (optional; or seal via --set-cred)
GOTIFY_PRIORITY=5                                    # Notification priority (1-10)
LOG_FILE="/var/log/pve-config-backup.log"             # Log file for cron mode
```

NFS and FTP/FTPS targets (and any credentials) are managed via `--targets` and stored in `TARGETS_FILE` (chmod 600) with passwords sealed — never in this script.

**Requirements:**
- Proxmox VE host, root access (sudo)
- `tar`, `gzip` (present on Proxmox; the script offers to install if somehow missing)
- Dependencies are checked **on demand based on what you configure** — `nfs-common` only if you add an NFS target, `curl` only for FTP/FTPS or Gotify, `openssh-client` only for SFTP/SCP. Each is checked the moment you add that export type (and re-checked at backup time), offered for install interactively, and fails loudly under cron rather than silently skipping the offsite copy. A purely local-only user is never prompted for tools they don't need.
- `systemd-creds` for sealed credentials (present on Proxmox VE 8/9; falls back to a `chmod 600` file if absent)

> [!TIP]
> A config backup that only lives on the node it backs up dies with that node's disk. If you run with no export target, the script warns on every run that the backup is **local-only**. Add an offsite copy with `--targets` — SFTP (SSH keys) or NFS need no stored secret and are the recommended choice.

**What it captures:**
`/etc/pve` (guest configs, `storage.cfg`, firewall, HA, replication) and `config.db`, `/etc/network/interfaces` (+ `interfaces.d`), `/etc/hostname`, `/etc/hosts`, `/etc/resolv.conf`, `/etc/passwd`, `/etc/group`, apt sources, `/etc/vzdump.conf`, `/etc/lvm/lvm.conf`, `/etc/cron.d`, `/etc/corosync` (clustered nodes), `/etc/shadow` + `/etc/ssh` (toggleable), and anything in `EXTRA_PATHS`.

> [!NOTE]
> Archives contain secrets (password hashes, SSH host keys) and are written `chmod 600` — treat them as sensitive. Credential sealing protects against leak/copy/exfil (and, with a TPM, against decrypting the secret on another machine); it does **not** protect a secret from an attacker who already has root on the host, since cron must auto-unseal it. The strongest option is to prefer SFTP (SSH keys) or NFS for export, where there's no password to store at all.

</details>

---

## Scheduling

Scripts that benefit from automation (update-traefik, pihole-sync, nfs-watchdog, pve-config-backup) include a **built-in cron scheduler**. You don't need to know cron syntax — just run:

```bash
sudo <script-name> --schedule
```

Or select **"Manage cron schedule"** from the interactive menu. Pick a frequency (every 5 minutes, hourly, daily, weekly, or custom), and the script writes the crontab entry for you. Come back anytime to change or remove it.

`pve-config-backup` goes a step further with a **guided one-time setup** (`sudo pve-config-backup --setup`, or auto-offered on first run) that chains the first backup, an optional export target, optional Gotify, and the schedule into a single pass — so a fresh install can be made fully hands-off in one sitting.

## Notifications

Scripts with scheduling support optional [Gotify](https://gotify.net/) push notifications. When running unattended via cron, they send markdown-formatted alerts on success or failure — complete with tables, status indicators, and host details. Notifications are only sent in automated/cron mode; interactive use shows results directly in the terminal.

### Setting it up (the secret-safe way)

Set the **server URL** in the config block (it isn't sensitive), but **seal the token** rather than typing it into the script:

```bash
# 1. set GOTIFY_URL="http://your-gotify:80" in the config block (URL only — leave GOTIFY_TOKEN="")
# 2. seal the token (it's read from stdin, encrypted with systemd-creds, never written in plaintext):
echo -n "YOUR_GOTIFY_TOKEN" | sudo <script-name> --set-cred gotify-token
# 3. verify:
sudo <script-name> --test-notify
```

This works on **all notification-capable scripts** (`update-traefik`, `pihole-sync`, `nfs-watchdog`, `pve-config-backup`). The token is sealed with `systemd-creds` (TPM-bound where available, host-key-bound otherwise) and falls back to a `chmod 600` file when `systemd-creds` is unavailable. At send time it's passed in a request **header via a `chmod 600` curl config file — never in the URL** (which would leak it into `ps`/process args and proxy logs).

> [!IMPORTANT]
> Leave `GOTIFY_TOKEN=""` blank in the config block and use `--set-cred` instead. A plaintext token in a script file is the exact leak the sealing system exists to prevent. The config block still accepts a plaintext token as a fallback for quick testing, but it is **not recommended** for anything persistent.

`pve-config-backup` additionally seals FTP export passwords the same way and offers a guided `--setup` that walks you through URL + token sealing interactively. See [`SECURITY.md`](SECURITY.md) for the threat model and what sealing does (and does not) protect against.

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