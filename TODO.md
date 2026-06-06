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
- [ ] Add `--check` flag to show status without updating
- [ ] Add `--rollback` flag to restore previous backup manually
- [ ] Add changelog display (show what changed between versions)
- [ ] Add automatic Proxmox snapshot before update (if running in VM and `qm` is accessible)
- [ ] Support for ARM64 architecture detection and binary selection

## Planned Scripts
