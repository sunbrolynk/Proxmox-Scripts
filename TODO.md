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
- [x] Support for ARM64 architecture detection and binary selection
- [x] Add changelog display (show what changed between versions)

### pct-force-destroy.sh
- [x] Validates container exists and is stopped
- [x] Clears PVE config locks
- [x] Clears CFS storage locks
- [x] Color-coded output
- [x] Root check and input validation
- [x] Man-style help
- [x] `--all` flag to clear all stale locks without specifying a CTID
- [x] `--dry-run` flag to show what would be cleared without doing it

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

## Planned Scripts

(none currently — add ideas here)

## Ideas to Investigate

- Proxmox VM template builder — automate creating base VM templates with common packages
- SSL cert monitor — check all reverse proxy certs across multiple hosts, alert on expiry
- Bulk snapshot cleanup — age-based cleanup across VMs and LXCs