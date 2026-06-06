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
- [ ] Add `--check` flag to show status without updating
- [ ] Add `--rollback` flag to restore previous backup manually
- [ ] Add changelog display (show what changed between versions)
- [ ] Support for ARM64 architecture detection and binary selection

### pct-force-destroy.sh
- [x] Validates container exists and is stopped
- [x] Clears PVE config locks
- [x] Clears CFS storage locks
- [x] Color-coded output
- [x] Root check and input validation
- [x] Man-style help
- [ ] Add `--all` flag to clear all stale locks without specifying a CTID
- [ ] Add `--dry-run` flag to show what would be cleared without doing it

## Planned Scripts

(none currently — add ideas here)

## Ideas to Investigate

- Proxmox VM template builder — automate creating base VM templates with common packages
- SSL cert monitor — check all reverse proxy certs across multiple hosts, alert on expiry
- Bulk snapshot cleanup — age-based cleanup across VMs and LXCs
