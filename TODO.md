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

### pve-config-backup.sh
Backs up Proxmox VE **host** configuration — the gap PBS/vzdump leave open. A dead
node currently means a full reinstall because the host config (/etc/pve, networking,
storage, cluster membership, users, apt sources) isn't covered by guest backups.
Targets a Proxmox host (root). Config only, no guest disk images — safe to run live.

- [x] Configurable backup manifest (BACKUP_PATHS array)
- [x] Correct pmxcfs handling — readable /etc/pve tree AND /var/lib/pve-cluster/config.db
- [x] Staging-dir copy (cp -a) to avoid live-FS read races, preserves secret perms
- [x] Final archive chmod 600 (contains /etc/shadow + SSH host keys)
- [x] Sensitive-item toggles (INCLUDE_SHADOW, INCLUDE_SSH_HOST_KEYS)
- [x] EXTRA_PATHS config var for user-added files (custom scripts, systemd units)
- [x] Cluster detection (corosync) — included in manifest + restore guidance
- [x] MANIFEST.txt written inside archive (included + skipped paths)
- [x] Local dest with prefix-scoped retention (never blind rm)
- [x] Optional parallel scp to one or more remote nodes (key-based, BatchMode)
- [x] `--list` mode (archives with date/size)
- [x] `--restore <file>` guided extract-and-instruct mode (no blind clobber of /etc)
- [x] `--status` (last backup, count, total size, remote/cron config)
- [x] Man-style help with dynamic config line numbers
- [x] Interactive menu with all options
- [x] Root check, preflight (is-PVE, deps, config.db, writable dest), CTRL+C cleanup
- [x] `--cron`/`-y` automated mode with Gotify on success/failure
- [x] `--test-notify` flag to test Gotify integration
- [ ] Optional `sqlite3 .backup` path for a consistent config.db snapshot (decision pending)
- [ ] Tested on at least one production Proxmox environment
- [ ] README `<details>` section + CLAUDE.md Current Scripts table entry

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

### docker-compose-updater.sh
Pull-and-recreate updater for compose stacks with health verification and rollback.
Timely: Watchtower's repo was archived Dec 2025; the alternatives are either
notify-only (Diun) or not-yet-production-ready (Tugtainer). Applies the
update-traefik.sh philosophy (backup → update → verify → roll back) to compose.
Targets a Docker host (VM or LXC).

- [ ] Walk a configurable compose root (default /docker), one stack per dir
- [ ] Per-stack: pull, recreate, health-check each container post-update
- [ ] Roll back the compose action on a failed health check
- [ ] Exclusion list config var (stacks to skip)
- [ ] Image pruning toggle after successful update
- [ ] Parallel across independent stacks, sequential within a stack
- [ ] Gotify markdown table: updated / skipped / failed / rolled-back
- [ ] `--check` mode (report available updates, change nothing)
- [ ] `--cron`/`-y`, `--schedule`, `--test-notify`, `--status`
- [ ] Man-style help + interactive menu

### snapshot-audit.sh
Cluster-wide snapshot visibility + age-based pruning. Proxmox has no native way to
see snapshot age/volume across all nodes; forgotten snapshots silently eat storage
and complicate backups. Supersedes the old "Bulk snapshot cleanup" idea.
Targets a Proxmox host (root).

- [ ] Enumerate VM + CT snapshots across the cluster (name, date, guest, node)
- [ ] Color-coded age report (green/yellow/red by threshold)
- [ ] `--prune --older-than Nd` (dry-run by DEFAULT, explicit confirm to delete)
- [ ] Skip the "current" pseudo-snapshot; qm/pct delsnapshot per guest type
- [ ] Exclusion by tag/name pattern (preserve intentional baseline snapshots)
- [ ] Per-storage awareness (LVM-thin vs ZFS deletion caveats surfaced)
- [ ] `--status`, `--schedule`, Gotify report (cron), `--test-notify`
- [ ] Man-style help + interactive menu

### pve-orphan-finder.sh
Finds storage volumes with no owning VM/CT config — the leftovers from aborted
migrations, failed restores, and detach-without-delete. Sibling to pct-force-destroy.
Targets a Proxmox host (root).

- [ ] Cross-reference all storage contents against every VM/CT config, cluster-wide
- [ ] Report orphans with sizes and storage backend type
- [ ] `--rescan` to relink (qm/pct rescan) so they surface as "unused" in the GUI
- [ ] `--dry-run` by DEFAULT; interactive confirmed deletion for true orphans
- [ ] Backend-aware deletion (lvremove / zfs destroy / file unlink) with guardrails
- [ ] Refuse to touch volumes for VMIDs that exist on another node
- [ ] `--status`, Man-style help + interactive menu

## Gotify Integration (shared across scripts)

- [x] Markdown-formatted notifications with tables and color indicators
- [x] `--test-notify` flag on nfs-watchdog, pihole-sync, update-traefik, and pve-config-backup
- [x] nfs-watchdog: alerts on stale mounts (cron mode)
- [x] pihole-sync: alerts on sync success/failure (cron mode)
- [x] update-traefik: alerts on update results (--cron mode)
- [x] pve-config-backup: alerts on backup success/failure (--cron mode)

## Ideas to Investigate

- **disk-health-report.sh** — Sane color-coded SMART/NVMe + ZFS scrub summary across all node disks, Gotify on threshold breach. Note: PVE's smartd emails are notoriously noisy (false "failed" on SSD wear %, alerts for decommissioned drives) — the value is a clean digest with sensible filtering, not raw smartd. Medium priority (overlaps existing monitoring stacks).
- **backup-restore-test.sh** — Restore the latest vzdump/PBS backup of a guest to a scratch VMID with NIC disconnected, verify it boots via guest-agent, then destroy the scratch guest and Gotify pass/fail. Validates the "untested backup" problem everyone has. Higher complexity (needs spare storage + careful VMID handling) — investigate feasibility.
- **cert-monitor.sh** — Scan proxy confs and check cert expiry via openssl, alert on expiring. Low priority since SWAG, Cloudflare, and Traefik dashboards already show expiry dates
- Proxmox VM template builder — automate creating base VM templates with common packages
- Proxmox cluster backup report — daily summary of backup status across all nodes
- Script self-updater — scripts check for newer versions of themselves on GitHub