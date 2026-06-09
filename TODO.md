# TODO — Future Scripts & Improvements

## Active Scripts

### update-traefik.sh
- [x] Auto-detect latest version from GitHub
- [x] Specific version support
- [x] Automatic backup and rollback
- [x] Traefik Manager update support
- [x] Environment checks (OS, disk, memory, Python)
- [x] Preflight dependency checks with interactive fix
- [x] Configurable variables at top
- [x] Dashboard URLs in summary
- [x] Man-style help with dynamic config line numbers
- [x] Version flag (-V)
- [x] Calls setup-assets.sh for vendor/CSS rebuild (v1.4.1+)
- [x] `--check` flag to show status without updating
- [x] `--rollback` flag to restore previous backup manually
- [x] `--changelog` flag to show release notes
- [x] Support for ARM64 architecture detection and binary selection
- [x] Interactive menu with all options
- [x] SHA256 checksum verification of downloaded binary against GitHub release
- [ ] ~~GPG signature verification~~ — blocked, Traefik doesn't sign binary releases ([upstream issue #6757](https://github.com/traefik/traefik/issues/6757))
- [x] `--cron` mode with file logging and Gotify notification on success/failure
- [x] `--test-notify` flag to test Gotify integration (add with --cron mode)

### pct-force-destroy.sh
- [x] Validates container exists and is stopped
- [x] Clears PVE config locks
- [x] Clears CFS storage locks
- [x] Color-coded output
- [x] Root check and input validation
- [x] Man-style help
- [x] `--all` flag to clear all stale locks without specifying a CTID
- [x] `--dry-run` flag to show what would be cleared without doing it
- [x] Interactive menu when run with no args
- [x] `--status` flag to show all containers and their lock state on this node
- [x] Auto-detect storage backend type per container (NFS, local-lvm, ZFS)

### pihole-sync.sh
- [x] Teleporter-based backup and sync
- [x] SSH key-based auth to backup Pi-hole
- [x] Preflight checks (pihole-FTL, SSH, disk space)
- [x] Local backup archive with retention
- [x] Backup-only mode
- [x] List backups mode
- [x] Automated mode (-y) for cron
- [x] CTRL+C safe
- [x] Man-style help with dynamic config line numbers
- [x] Support for multiple backup targets (sync to 2+ Pi-holes)
- [x] Selective sync (--skip-settings preserves backup's unique config)
- [x] Diff display (--diff compares adlists, domains, clients, groups)
- [x] Interactive menu with all options
- [x] `--restore <file>` mode to restore a specific backup to the primary
- [x] Trigger gravity update on backup after import (`pihole -g`)
- [x] Gotify notification on sync success/failure
- [x] `--test-notify` flag to test Gotify integration

## Planned Scripts

### nfs-watchdog.sh
Monitors NFS mount health across Proxmox cluster nodes. Detects stale or unresponsive mounts before they cause cascading lock issues.

- [x] Lightweight read/write test on each NFS mount
- [x] Configurable check interval and timeout threshold
- [x] Auto-detect NFS mounts from /proc/mounts
- [x] Stale mount detection (stat/touch test with timeout)
- [x] Auto-remount option for stale mounts
- [x] Alert via Gotify when a mount is unhealthy
- [x] `--test-notify` flag to test Gotify integration
- [x] `--status` flag to show all NFS mounts and their health
- [x] `--dry-run` flag to show what would be checked without acting
- [x] `--remount` flag to force remount all NFS mounts
- [x] Designed to run as a cron job on every cluster node
- [x] Log output for cron mode
- [x] Man-style help and interactive menu
- [x] Latency measurement with color-coded thresholds
- [x] Mount options display (hard vs soft detection)

## Gotify Integration (shared across scripts)

- [x] Markdown-formatted notifications with tables and color indicators
- [x] `--test-notify` flag on nfs-watchdog, pihole-sync, and update-traefik
- [x] nfs-watchdog: alerts on stale mounts (cron mode)
- [x] pihole-sync: alerts on sync success/failure (cron mode)
- [x] update-traefik: alerts on update results (--cron mode)
- [ ] Consider extracting Gotify functions into a shared library (source-able file) to avoid duplication

## Ideas to Investigate

- **cert-monitor.sh** — Scan proxy confs and check cert expiry via openssl, alert on expiring. Low priority since SWAG, Cloudflare, and Traefik dashboards already show expiry dates
- Proxmox VM template builder — automate creating base VM templates with common packages
- Bulk snapshot cleanup — age-based cleanup across VMs and LXCs
- Docker compose updater — pull latest images, recreate containers, verify health
- Proxmox cluster backup report — daily summary of backup status across all nodes
- Script self-updater — scripts check for newer versions of themselves on GitHub