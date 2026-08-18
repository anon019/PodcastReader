# Security Policy

## Supported versions

Security fixes are applied to the current `main` branch and the latest tagged release. Older builds are not supported.

## Reporting a vulnerability

Please do not disclose a suspected vulnerability in a public issue. Use GitHub's **Report a vulnerability** action in the repository Security tab so the report and any proof of concept remain private.

Include the affected commit or version, the reachable input, the expected security boundary, reproduction steps, and impact. Do not include credentials, private Podcast data, or third-party Transcript content that you are not permitted to share.

The maintainer aims to acknowledge a report within seven days. A remediation timeline depends on severity and reproducibility; no fixed disclosure or bounty commitment is offered.

## Security boundaries

- User-entered links must be HTTPS URLs on the exact supported YouTube origins. Redirects are checked again before they are followed.
- The application must never fetch `file://`, loopback, link-local, private-network, credential-bearing, custom-port, or lookalike-domain URLs from the add-link flow.
- Transcript and analysis data remain in the user's local SQLite database. They must not be committed to this repository.
- Transcript content is sent through the locally authenticated Codex CLI for analysis and translation. Treat Podcast content as untrusted input; it must not grant new tool, filesystem, network, or credential access.
- YouTube caption extraction is disabled unless the user explicitly enables it locally after reviewing [LEGAL.md](LEGAL.md).
