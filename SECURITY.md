# Security Policy

## Reporting Vulnerabilities

If you discover a security vulnerability in any script in this repository, please **do not** open a public issue. Instead, contact the maintainer directly:

- Open a **private security advisory** via GitHub's Security tab
- Or email the maintainer through their GitHub profile

## Security Review Process

Every script and PR is reviewed against the checklist below before being merged.

## Mandatory Security Checklist

### Credentials & Secrets
- No hardcoded passwords, API keys, tokens, or secrets
- No credentials in comments, even as examples with real-looking values
- Sensitive values must be in configurable variables with placeholder text
- `.env` files, key files, and certificates are covered by `.gitignore`

### Code Transparency
- No obfuscated, minified, or encoded code
- No base64-encoded payloads decoded and executed at runtime
- No `eval` with external or user-supplied input
- Every line of code must be human-readable and auditable

### Network Safety
- No telemetry, analytics, or phone-home behavior
- No unnecessary network requests
- Downloads only from verified official sources:
  - Official GitHub release pages
  - Distro package repositories (apt, apk)
  - No third-party mirrors, pastebins, or URL shorteners
- All download URLs must be deterministic and auditable (no redirects through unknown services)

### File System Safety
- No writing outside the script's declared scope
- Temp files must be in `/tmp` with unique names
- Temp files must be cleaned up on exit (including CTRL+C)
- No following symlinks into unexpected locations
- Explicit file permissions (755 for binaries, 600 for secrets, never 777)
- No recursive `chmod` or `chown` on system directories

### Execution Safety
- No spawning background processes without user knowledge
- No adding cron jobs, systemd timers, or startup scripts without explicit user consent
- No modifying PATH, bashrc, profile, or other shell configs
- No killing processes outside the script's scope
- Proper quoting of all variables to prevent word splitting and globbing

### Privilege Safety
- Scripts requiring root must check and declare it upfront
- No unnecessary privilege escalation
- Drop privileges where possible (use `sudo -u` for non-root operations)
- No SUID/SGID modifications

## Known Attack Patterns

These are patterns that have been seen in malicious scripts submitted to open-source repos. All contributions are checked for these:

| Pattern | Description | How We Check |
|---------|-------------|--------------|
| **Typosquatting URLs** | Download domains that look official but aren't (e.g. `githuh.com`) | Verify every URL against known official domains |
| **Unicode homoglyphs** | Using lookalike characters (Cyrillic "а" vs Latin "a") in URLs or variable names | Check raw bytes, not just visual appearance |
| **Conditional payloads** | Code that only activates on specific hostnames, IPs, dates, or environments | Review all conditional logic for suspicious triggers |
| **Delayed execution** | Adding cron jobs, timers, or at jobs that run later | Search for `crontab`, `at`, `systemd-run`, timer units |
| **Data exfiltration** | Piping env vars, SSH keys, or system info to external URLs | Search for `curl`, `wget`, `nc` combined with system info commands |
| **Dependency confusion** | Installing packages from unofficial repos or PPAs | Verify all `apt` sources and `pip` packages |
| **Symlink races** | Creating symlinks in `/tmp` pointing to system files | Check temp file creation patterns |
| **Hidden processes** | Forking to background with `&`, `nohup`, `disown`, `screen`, `tmux` | Search for backgrounding commands |
| **Reverse shells** | Establishing outbound connections for remote access | Search for `/dev/tcp`, `nc -e`, `bash -i`, `python -c` socket patterns |
| **Crypto miners** | Downloading and running mining software | Check all downloaded binaries against expected checksums |

## Findings Log

Document any suspicious patterns or notable security findings from PR reviews here for future reference.

| Date | PR/Script | Finding | Resolution |
|------|-----------|---------|------------|
| — | — | No findings yet | — |

## Best Practices for Contributors

1. **Keep it simple** — fewer lines of code means fewer places for bugs
2. **Fail loudly** — errors should be obvious and actionable
3. **Clean up after yourself** — temp files, backups, partial downloads
4. **Don't assume** — check if files exist before reading, check if commands exist before running
5. **Quote everything** — `"$variable"` not `$variable`
6. **Use official sources** — when in doubt, link to the upstream project's GitHub releases page
