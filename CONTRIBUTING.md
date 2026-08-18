# Contributing

Contributions are welcome when they preserve the reader's local-first, non-resident architecture and the security boundaries in `SECURITY.md`.

## Before opening a pull request

1. Create a focused branch from `main`.
2. Do not add credentials, local databases, private paths, cookies, account exports, Podcast Transcripts, or copyrighted fixtures.
3. Add regression coverage for behavior changes.
4. Run `scripts/verify.sh` on macOS.
5. Explain user-visible behavior, privacy impact, and any new network or model boundary in the pull request.

The 21 default sources and their source-specific prompts are intentionally public product configuration. Changes to them should explain the editorial reason and avoid embedding private user preferences.
