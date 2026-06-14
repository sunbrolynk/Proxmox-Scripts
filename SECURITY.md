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
- **Prefer credential-less transports.** Where a script connects to a remote (backup export, sync target), favor SSH keys or NFS — mechanisms with no password to store — over anything that requires a stored secret.
- **Seal secrets that must be replayed.** Some secrets can't be hashed because the script has to send the original later (an FTP password, a Gotify token used by cron). These must be **sealed**, not stored plaintext and not embedded in the script:
  - Use `systemd-creds` to seal (TPM-bound where the host has a TPM — the blob can't be decrypted on another machine; host-key-bound otherwise). Fall back to a `chmod 600` file only when `systemd-creds` is unavailable, so unattended cron can still unseal.
  - Store a **reference** (e.g. `@SECRET:<id>`) in any config/target file — never the literal secret. Resolve it at use time. Delete the sealed secret when its referencing entry is removed.
  - Secret files live in a `chmod 700` directory; sealed blobs and fallback files are `chmod 600`.
  - **Be honest about the threat model in user-facing docs.** Sealing protects against leak, copy, and exfiltration (and, with a TPM, against decrypting elsewhere). It does **not** protect a secret from an attacker who already has root on the host, because the script/cron must be able to auto-unseal. Plaintext-only transports like FTP must carry a hard warning before a credentialed target is saved.

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

### Supply-Chain Hardening (downloads of executable artifacts)

Any script that downloads a **runnable artifact** (a binary, archive, or installer — *not* an apt package, which apt verifies itself) must:

- **Verify a SHA256 checksum and fail closed.** A *mismatch* always aborts with no override. A *missing/unfetchable* checksum aborts under automation (cron) and prompts (default No) interactively; the only bypass is an explicit, clearly-named flag (e.g. `--insecure-skip-checksum`). Never silently install an unverified artifact — that "fail-open" downgrade is itself an attack surface (block the checksum URL → unverified install).
- **Understand what the checksum does and does not prove.** A same-origin checksum (binary and hash from the same release page) proves *integrity in transit* — it defends against a poisoned mirror or MITM. It does **not** defend against a compromised upstream (hijacked maintainer account or poisoned CI), where the malicious artifact ships *with a valid matching checksum*. This is the Shai-Hulud / npm-worm class of attack. Treat "checksum verified" as "I got what was published," not "what was published is safe."
- **Prefer version pinning over `latest`.** Auto-pulling `latest` means a malicious new upstream release is grabbed automatically with no human in the loop. Where practical, require an explicit version and/or maintain out-of-band pinned hashes for known-good versions so a swapped release fails verification even if its own checksum matches.
- Distro packages (`apt`) are exempt — apt already does GPG-signed metadata + per-package hash verification, which a wrapper script cannot improve on.

### File System Safety
- No writing outside the script's declared scope
- Temp files must be in `/tmp` with unique names
- Temp files must be cleaned up on exit (including CTRL+C)
- No following symlinks into unexpected locations
- Explicit file permissions (755 for binaries, 600 for secrets, 700 for secret dirs, never 777)
- No recursive `chmod` or `chown` on system directories
- **Never `source` a runtime/settings file.** A script may read its own managed settings file, but it must **parse a whitelist of expected keys**, never `source` it — sourcing a writable file is arbitrary code execution. Unknown keys are ignored.
- Archives that contain secrets (e.g. a host-config backup including `/etc/shadow` or SSH host keys) must be written `chmod 600`, and the docs must tell users to treat them as sensitive.

### Execution Safety
- No spawning background processes without user knowledge
- No adding cron jobs, systemd timers, or startup scripts without explicit user consent
- No modifying PATH, bashrc, profile, or other shell configs
- No killing processes outside the script's scope
- Proper quoting of all variables to prevent word splitting and globbing
- A script that installs itself to `/usr/local/bin` must do so only with explicit user consent (an interactive offer), copy verbatim, set `755`, and never re-exec silently.

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
| **Config-file sourcing** | `source`-ing a writable settings/state file → arbitrary code execution | Ensure settings files are parsed against a key whitelist, never `source`d |
| **Plaintext secret storage** | Writing tokens/passwords to disk or into the script in cleartext | Require sealing (systemd-creds / chmod-600), references not literals, credential-less transports where possible |

## Findings Log

Document any suspicious patterns or notable security findings from PR reviews here for future reference.

The entries below come from a full nested-VM hardware-validation pass of `pve-config-backup.sh` (PVE 9.2, vTPM-backed). Every one was surfaced by *running* the script against real hardware and real export targets — none were caught by the script's own self-tests, which is the central lesson: self-tests verify the paths you thought to write; only execution against real state finds the rest.

| Date | Script / Version | Finding | Resolution |
|------|------------------|---------|------------|
| 2026-06-11 | pve-config-backup 1.2.2 | A runtime-only flag (`SETUP`) leaked into the dynamically-generated `--help` config table | Added to the `grep -v` exclusion list for the help table |
| 2026-06-11 | pve-config-backup 1.2.3 | **Silent schedule failure.** `crontab -l \| grep -v "$SCRIPT_NAME"` exits non-zero when it filters out every line (empty/fresh crontab); under `pipefail` + `inherit_errexit` this aborted the cron write with no error, and `--status` honestly reported "not scheduled" | `\|\| true` on all crontab-write pipelines; `cron_write` now verifies the entry landed; failures reported loudly |
| 2026-06-11 | pve-config-backup 1.2.4 | Export targets were not de-duplicated on re-add (same target could be stored twice) | Added `target_identity()` helper (ignores credential field) + dedupe check before save |
| 2026-06-11 | pve-config-backup 1.2.5 | `nfs-common` was not checked in preflight — an NFS export could silently fail under cron on a box without it | Added a gated preflight check that fails loud under cron |
| 2026-06-11 | pve-config-backup 1.2.6 | `curl` (FTP/FTPS + Gotify, 5 call sites) and `openssh-client` (SFTP) were used with no dependency check; `tar`/`gzip` hard-exited instead of offering to install | Added a generic `require_dep()` helper; gated checks by what is actually configured |
| 2026-06-11 | pve-config-backup 1.2.7 | `verify_sftp` / `verify_ftp` did not ensure their dependency at target-add time (only `verify_nfs` did) | Made all three transports ensure their dependency symmetrically |
| 2026-06-11 | pve-config-backup 1.2.8 | Dependency gate ran *after* collecting target details (host/path) instead of before; no warning when a backup had no offsite target at all | Moved the dep gate ahead of detail prompts (fail-fast); added a loud local-only offsite warning in preflight |
| 2026-06-11 | pve-config-backup 1.3.2 | A forced/unattended full restore (`--full --force-full`) still stopped to prompt for the per-identity files (`/etc/hostname`, `/etc/hosts`), so it could hang forever in automation | Identity files auto-restore under forced/`--yes` mode; interactive still prompts |
| 2026-06-11 | pve-config-backup 1.3.3 | `--restore` with an empty shell variable produced a misleading "requires a path" error (the real cause was a flag landing where a path was expected) | Error now distinguishes none-given / got-a-flag (suggests checking the shell var) / archive-not-found (suggests `--list`) |
| 2026-06-11 | pve-config-backup 1.3.4 | **`set -u` declaration-order footgun (correctness-critical).** The restore single-file drill-down used `local pick="${files[n]}" rel_p="${pick#...}"` — referencing `pick` on its own `local` declaration line. Under `set -u` this either threw `unbound variable` or used a stale same-named variable from a prior menu action, causing the success message to report the **wrong filename**. The placed file was correct (md5-verified) but a restore tool misreporting which file it touched is unacceptable | Split the declaration onto separate lines; audited the whole script and confirmed this was the only instance of the antipattern |

> The 1.3.4 finding is the headline. It only reproduces when an earlier menu action (the single-file browser) leaves stale shell state that the later drill-down inherits — a sequence no single-path or unit test exercises. It was caught only because the wizard was driven through a realistic *sequence* of actions on real hardware.

### Cross-script convergence audit (2026-06-12)

After hardening `pve-config-backup.sh`, the proven patterns were promoted into `script-template.sh` (v2.0.0) and the other cron-worthy scripts. The audit surfaced two issues present in **all three** of `pi-hole-sync.sh`, `nfs-watchdog.sh`, and `update-traefik.sh`:

| Date | Script / Version | Finding | Resolution |
|------|------------------|---------|------------|
| 2026-06-12 | pi-hole-sync / nfs-watchdog / update-traefik → 1.1.0 | **Gotify token in the URL query string** (`/message?token=${GOTIFY_TOKEN}`). The token appears in `argv`, visible to any local user via `ps`, and is liable to land in proxy/access logs. This is a worse exposure than plaintext-in-a-config-variable | Switched all three to the chmod-600 curl config-header method (`X-Gotify-Key` header in a `-K` file, never in the URL); added sealed-credential support (`--set-cred gotify-token`, resolve-sealed-first) |
| 2026-06-12 | pi-hole-sync / nfs-watchdog / update-traefik → 1.1.0 | **The cron-write silent-fail bug** (config-backup finding #2) was present in all three: unguarded `crontab -l \| grep -v "$SCRIPT_NAME" \| crontab -` aborts under `pipefail` on an empty crontab, so scheduling silently fails on a fresh node | Applied the hardened `cron_write` (`\|\| true` + verify-it-landed) to both the add and remove pipelines in each; gated scheduling on canonical-path install |
| 2026-06-12 | script-template.sh → 2.0.0 | The template was **propagating** the cron-write silent-fail bug and a plaintext-Gotify pattern into every new script spawned from it | Template now ships hardened `cron_write`, `require_dep`, sealed-credential helpers (dormant unless a secret is used), per-script `CRON_PRESETS`, and a help-table exclusion warning |
| 2026-06-12 | update-traefik → 1.2.0 | **Checksum verification failed open.** When the SHA256 checksums file couldn't be fetched, the updater printed "skipping verification" and installed the binary anyway — so an attacker (or network condition) that blocked *only* the checksum URL silently downgraded the install to unverified | Now fails **closed**: a missing/unparseable checksum aborts under cron, or prompts (default No) interactively; only the explicit `--insecure-skip-checksum` flag overrides. A checksum *mismatch* is always fatal with no override |

### pi-hole-sync hardware test (2026-06-13, v1.3.1) — security-relevant findings

Full hardware validation on a 3-Pi-hole sandbox. Most findings were UX/correctness (see `TESTING-pi-hole-sync.md` for the complete list of 8); the security-relevant ones:

| Date | Script / Version | Finding | Resolution |
|------|------------------|---------|------------|
| 2026-06-13 | pi-hole-sync → 1.3.0 | **Targeted restore removes a safety rail.** Restore used to be hard-locked to the primary; it now lets the user restore an archive to *any* target (primary / backup / custom IP). Letting a destructive overwrite hit an arbitrary IP without a guard is a foot-gun (wrong-box overwrite) | Added a **typed-IP confirmation gate** (must type the exact target IP/host to proceed) before any overwrite — friction scaled to danger, mirroring PCB's typed-`RESTORE` gate. Verified it hard-aborts on a mistyped confirmation. |
| 2026-06-13 | pi-hole-sync → 1.3.1 | **Silent-failure masked by fallback.** `--diff` used the system `sqlite3` (absent on Pi-hole v6) and every query fell back to `?` via `\|\| echo "?"` — the feature had *never worked* but never errored, so the failure was invisible | Switched to the bundled `pihole-FTL sqlite3`. Broader lesson: a `\|\| echo <placeholder>` fallback can hide total failure — prefer surfacing the error, or at least make "all placeholders" detectable. |
| 2026-06-13 | (latent, all converged scripts) | `send_gotify`/`test_gotify` depend on `python3` for JSON encoding with the error swallowed (`2>/dev/null`); a host without python3 would emit an invalid body and get a confusing HTTP 400 with no hint | Not exploitable, but a robustness gap. Flagged for a `require_dep python3` or a shell-based JSON fallback. Affects the shared helper in all converged scripts. |

> Lesson worth keeping: a bug in the *template* is a bug multiplier — it ships silently into every future script. Auditing the template is higher-leverage than auditing any single script. The URL-token leak also shows that "we have a notification feature" is a security surface, not just a convenience. And from pi-hole-sync: a `|| echo "?"` style fallback can turn a total feature failure into something invisible — fallbacks should never silently mask "this never worked."

### nfs-watchdog hardware test (2026-06-13, v1.3.3) — safety-relevant findings

| Date | Script / Version | Finding | Resolution |
|------|------------------|---------|------------|
| 2026-06-13 | nfs-watchdog → 1.3.0 | **A failed remount destroyed the mount it was meant to protect.** The remount lazy-unmounted *before* confirming it could remount; against a down server it tore down the degraded-but-present mount and couldn't restore it. The next check then saw "no mounts" and reported HEALTHY — silently masking the outage (a monitoring blindspot far worse than the original problem). | Redesigned to a three-state model (healthy / stale-server-reachable / server-unavailable). A reachability probe classifies first; the watchdog NEVER unmounts a mount it can't restore, and a server outage leaves the mount untouched with a distinct alert. |
| 2026-06-13 | nfs-watchdog → 1.2.3 | Exited 0 even when problems were detected — a cron/monitoring wrapper keying on exit code would read "all healthy" during an actual NFS failure. | Propagate the non-zero result to the script exit code. |
| 2026-06-13 | nfs-watchdog → 1.2.2 | Readable-but-not-writable mount classified as healthy, so a downed server (writes fail, cached reads succeed) wouldn't alert. | Distinguish intentionally-`ro` (healthy) from `rw`-can't-write (degraded) via /proc/mounts options. |

> Safety lesson: a self-healing tool must never make things *worse* on failure than the problem it's fixing. "Unmount then try to remount" is unsafe when the remount can fail — always confirm you can restore before you tear down. And the most dangerous failures are the *silent* ones: destroying the mount then reporting "healthy" hid the outage entirely. Test the real failure mode (down the actual server) — that's what surfaced both issues; reading the code did not.

### update-traefik hardware test (2026-06-13, v1.3.6) — security-relevant findings

| Date | Script / Version | Finding | Resolution |
|------|------------------|---------|------------|
| 2026-06-13 | update-traefik → 1.3.1 | **A read-only status check silently mutated the manager git repo** (`git checkout main`), force-moving a pinned version to the tip of main just by viewing status — an unconsented "update" triggered by an observation. | Compare against `origin/main` without switching the working tree; confine branch changes to the actual update path, with consent. |
| 2026-06-13 | update-traefik → 1.3.4 | **The updated Traefik binary was owned by the release tarball's build UID (1001), not root.** `tar x` as root preserves archive ownership and the install only `chmod +x`'d. On a host where 1001 is a real user, that user could replace the binary a root service executes — a local-privilege / supply-chain exposure. The script reported success the whole time. | Extract with `tar --no-same-owner` and `chown root:root` after, in both update and rollback. |
| 2026-06-13 | update-traefik → 1.3.6 | **Unknown flags fell through to interactive mode and hung automation.** A typo'd or renamed flag in a cron entry was silently ignored; the script entered the interactive run and blocked forever on a prompt with no one to answer — a denial-of-update that fails *open* (job wedged) rather than closed. | Reject unknown flags before any output with a non-zero exit. Propagated repo-wide (all scripts + template lacked it). |
| 2026-06-13 | update-traefik → 1.3.0 | **Assumed `sudo` exists** for running git/pip as the manager user — but Proxmox runs as root and frequently has no sudo, so every privileged-as-another-user operation silently failed. | Use `runuser` (util-linux, always present) instead of `sudo -u`. |

> Lessons reinforced: (1) an *observation* path must never change state — this is the second script where a "detection" routine was found mutating things. (2) A green "✓ success" line is not proof of a correct result; verify the artifact on disk (ownership, contents), not the script's self-report. (3) Checksum verification must stay fail-closed: a mismatch is always fatal, a missing checksum aborts unless explicitly overridden — and the honest threat model (transit tampering, not a compromised upstream) belongs in the code.

## Best Practices for Contributors

1. **Keep it simple** — fewer lines of code means fewer places for bugs
2. **Fail loudly** — errors should be obvious and actionable
3. **Clean up after yourself** — temp files, backups, partial downloads
4. **Don't assume** — check if files exist before reading, check if commands exist before running
5. **Quote everything** — `"$variable"` not `$variable`
6. **Use official sources** — when in doubt, link to the upstream project's GitHub releases page
7. **Don't store what you don't have to** — prefer SSH keys/NFS over stored passwords; if you must store a replayable secret, seal it and be honest in the docs about what sealing does and doesn't protect against