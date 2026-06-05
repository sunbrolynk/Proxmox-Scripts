# Contributing to Proxmox-Scripts

Thanks for your interest in contributing! This is a personal collection of scripts that's open to the community. Contributions are welcome but reviewed carefully before merging.

## How to Contribute

### Submitting a New Script

1. **Fork** this repository
2. Create a new branch: `git checkout -b feature/my-new-script`
3. Add your script following the structure guidelines below
4. Test your script thoroughly on your own environment
5. Open a **Pull Request** with a clear description of what the script does

### Suggesting Changes to Existing Scripts

1. Open an **Issue** describing the problem or improvement
2. If you have a fix, fork and submit a **Pull Request**
3. Reference the issue in your PR

## Script Requirements

All submitted scripts **must** meet these criteria:

### Security

- **No hardcoded credentials, API keys, tokens, or passwords**
- **No phone-home or telemetry** — scripts must not send data anywhere
- **No obfuscated code** — every line must be readable and understandable
- **No curl-to-bash from untrusted sources** within the script
- All external downloads must use verified sources (official GitHub releases, package repos)

### Quality

- Scripts must include a **configuration block** at the top for user-adjustable variables
- Scripts must include **error handling** — don't let failures cascade silently
- Scripts must handle **CTRL+C gracefully** — clean up temp files, restore state
- Scripts must include **clear, colored output** indicating success, failure, and warnings
- Scripts must be **tested** on at least one Proxmox environment (VM or LXC)

### Style

- Use `#!/usr/bin/env bash` shebang
- Use `set -euo pipefail` for strict error handling
- Include a comment header with: description, license reference, and usage
- Use consistent color codes and message functions (see existing scripts for reference)
- Keep lines under 120 characters where possible
- Use meaningful variable names

### Documentation

- Include a section in the main README describing your script
- Document all configuration variables
- Include usage examples

## What Will NOT Be Accepted

- Scripts that modify Proxmox host configuration without explicit user consent
- Scripts that download or execute code from unverified third-party sources
- Scripts containing malware, backdoors, or any malicious functionality
- Scripts without error handling or graceful failure modes
- Low-effort submissions without testing or documentation

## Review Process

1. All PRs are reviewed by the repo maintainer before merging
2. Scripts are tested in a sandboxed environment before approval
3. Feedback will be provided if changes are needed
4. Approved scripts are merged into `main`

## Code of Conduct

- Be respectful and constructive
- Focus on the code, not the person
- Help others learn — this is a community resource

## Questions?

Open an Issue with the `question` label if you need help or clarification.
