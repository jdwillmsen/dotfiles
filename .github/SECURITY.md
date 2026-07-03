# Security Policy

## Reporting a Vulnerability

Do **not** open a public issue for security vulnerabilities.

Report vulnerabilities privately via GitHub's [security advisory feature](https://github.com/jdwillmsen/dotfiles/security/advisories/new) or by emailing [jdwlabs00@gmail.com](mailto:jdwlabs00@gmail.com).

Include:
- Description of the vulnerability
- Steps to reproduce
- Affected file and version/commit
- Potential impact

You'll receive a response within **72 hours**.

## Scope

This repo contains shell configs and a Go binary. Things worth reporting:

- Command injection in `home/run_*` scripts or shell functions
- The `claude-status` binary reading or writing sensitive data unexpectedly
- Hardcoded credentials or tokens accidentally committed

## Supported Versions

Only the latest commit on `main` is supported.
