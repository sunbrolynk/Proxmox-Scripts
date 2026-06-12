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

### nfs-watchdog.sh
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

### pve-config-backup.sh — v1.3.4 (hardware-validated)
Backs up Proxmox VE **host** configuration — the gap PBS/vzdump leave open. A dead
node otherwise means a full reinstall, because the host config (/etc/pve, networking,
storage, cluster membership, users, apt sources) isn't covered by guest backups.
Targets a Proxmox host (root). Config only, no guest disk images — safe to run live.

**Core backup (v1.0.0):**
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
- [x] `--restore <file>` — superseded by the full restore wizard in v1.3.0 (see below)
- [x] `--status` (last backup, count, total size, targets, cron config)
- [x] Man-style help with dynamic config line numbers
- [x] Interactive menu with all options
- [x] Root check, preflight (is-PVE, deps, config.db, writable dest), CTRL+C cleanup
- [x] `--cron`/`-y` automated mode with Gotify on success/failure
- [x] `--test-notify` flag to test Gotify integration

**Export targets (v1.1.0):**
- [x] Interactive export target manager (`--targets` + menu) for NFS / SFTP / FTPS
- [x] Each target verified on-add by write → read-back → delete a canary file, per-step ✓/✗
- [x] FTP hard plaintext warning; defaults to FTPS
- [x] Targets persisted in TARGETS_FILE (chmod 600), pipe-delimited specs

**Credential sealing (v1.2.0):**
- [x] secret_set / secret_get / secret_exists / secret_method / secret_delete helpers
- [x] systemd-creds sealing (TPM-bound where available; chmod-600 file fallback)
- [x] FTP passwords sealed; targets.conf stores `@SECRET:<id>` reference, never the literal
      (also fixes the pipe-in-password parsing limitation)
- [x] Gotify token sealable; resolves sealed-first, then plaintext config var
- [x] Managed SETTINGS_FILE (config.env) — whitelist-PARSED, never sourced
- [x] `--set-cred <name>` to seal a secret from stdin/TTY (automation-friendly)
- [x] Guided `--setup` (flag + menu item + auto-offer on first run): backup always,
      then optional export target / Gotify / schedule

**On-demand dependency model (v1.2.5–v1.2.8):**
- [x] `require_dep()` helper — offer-install interactive / fail-loud cron, one consistent path
- [x] Dependencies gated on what's configured (nfs-common / curl / openssh-client), checked
      both at target-add time and at preflight
- [x] tar/gzip upgraded from hard-exit to offer-install
- [x] Dep gate moved ahead of target detail prompts (fail-fast)
- [x] Local-only offsite warning in preflight (warn loudly, still allow)

**Restore wizard + scriptable restore (v1.3.0–v1.3.4):**
- [x] Guided wizard: full / by-category (guests, storage, network, users, ssh, apt, cron) /
      single-file browser / category drill-down — places files AND offers service reloads
- [x] Full config.db restore: stop → swap → verify → **auto-rollback on unhealthy**, typed `RESTORE` gate
- [x] Restore CLI: `--what`, `--file`, `--full`, `--extract-only`, `--yes`; `--force-full`
      required for unattended full restore (—yes alone won't swap config.db)
- [x] Identity files (hostname/hosts) auto-restored under forced/—yes, prompted interactively
- [x] Fixed the `set -u` same-line-local wrong-filename bug (see SECURITY.md findings)

**Self-install awareness (v1.2.1):**
- [x] Canonical install path (SCRIPT_INSTALL_DEST = /usr/local/bin/<name>)
- [x] installed_ok() check (exists + executable at canonical path)
- [x] One-time startup install offer; dismissal remembered (INSTALL_NUDGE_DISMISSED)
- [x] Scheduling gated on being installed (require_installed_for_schedule guard on
      --schedule, menu, and guided-setup step 4)
- [x] install_self handles copy+chmod 755 and the already-at-dest (ensure +x) case
- [x] FILES help entry documents the canonical install location

**Documentation:**
- [x] README `<details>` section
- [x] CLAUDE.md Current Scripts table entry
- [x] PATTERNS.md idioms (sealed credentials, managed settings, export-target
      verification, guided setup / self-install)
- [x] SECURITY.md sealed-credentials note

**Still open:**
- [x] ~~Tested on at least one production Proxmox environment~~ — **done.** Full nested-VM
      validation on PVE 9.2 with vTPM: every path (backup, multi-target export, sealing,
      scheduling, the entire restore wizard + CLI, automated full restore with rollback,
      and the install-nudge state machine) proven on real hardware. 10 findings + 2 feature releases logged.
- [ ] Optional `sqlite3 .backup` path for a consistent config.db snapshot (decision pending —
      `cp -a` of config.db proved correct in testing; this is a nice-to-have, not a gap)
- [ ] Decide whether to propagate the sealed-credential helpers to the other three
      scripts' Gotify tokens (proving-ground first, then promote to script-template.sh)

## Planned Scripts

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
- [ ] `--dry-run` (show what would update), `--status`, interactive menu
- [ ] Gotify on per-stack success/failure, `--test-notify`, cron scheduler

### snapshot-audit.sh
Finds VM/CT snapshots that have outlived their usefulness — old snapshots silently
consume storage and degrade performance, and are easy to forget after a one-off change.
Targets a Proxmox host (root).

- [ ] Enumerate snapshots across all guests (qm/pct), with age and (where available) size
- [ ] Configurable age threshold to flag "stale" snapshots
- [ ] Highlight auto/replication snapshots vs. manual ones
- [ ] `--status` table; interactive prune with explicit per-snapshot confirmation
- [ ] Never auto-delete without confirmation; `--dry-run` default-safe
- [ ] Gotify summary of stale snapshots in cron mode

### pve-orphan-finder.sh
Finds orphaned disk volumes — guest disks left on storage after a VM/CT was removed
or migrated, quietly eating space with no config referencing them.
Targets a Proxmox host (root).

- [ ] Cross-reference storage volumes against guest configs to find unreferenced disks
- [ ] Per-storage reporting (LVM-thin, ZFS, dir, NFS)
- [ ] `--status` table; guided, confirmed cleanup; `--dry-run` default-safe
- [ ] Extra caution around shared/clustered storage (volume may belong to another node)

## Ideas (unscheduled)

- **disk-health-report.sh** — SMART summary across all node disks with Gotify alerting
  on pre-fail attributes; cron-friendly.
- **backup-restore-test.sh** — periodically restore the latest guest backup into a
  throwaway VM and verify it boots, so backups are proven, not assumed. Pairs naturally
  with pve-config-backup's "a backup you haven't restored is a hope, not a backup" ethos.