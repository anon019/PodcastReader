# Podcast Reader

Open-source, local-first macOS reader for structured Podcast extraction. It is a reader, not a note-taking app.

The app ships with 21 public YouTube Podcast sources and their source-specific editorial prompts. It is designed for personal use and does not redistribute Podcast Transcripts or analysis databases.

## Installed app

- App: `~/Applications/Podcast Reader.app`
- Database: `~/Library/Application Support/PodcastNotes/podcast_notes.sqlite3`
- Schedule: Codex automation `Podcast Reader 每日增量更新`, every day at 07:30 local time
- Runtime: one scheduled run starts, updates the local library, and exits; there is no LaunchAgent, login item, helper, API server, or resident process

The toolbar provides optional one-shot manual update and add-link actions. Supported links are YouTube channels, playlists, and individual episodes. On launch, an existing library is read directly from SQLite, so a completed scheduled run is already visible without clicking refresh. Appearance can follow macOS or be pinned to light/dark mode. While open, the reader observes lightweight SQLite changes every ten seconds so scheduled content and progress appear without restarting.

## Runtime contract

- YouTube RSS and channel pages discover episodes.
- YouTube caption extraction is disabled in a fresh public checkout. After reviewing [LEGAL.md](LEGAL.md), an authorized user may explicitly enable the user-installed `/opt/homebrew/bin/summarize` path; its Homebrew `yt-dlp` dependency provides the transcript-only fallback.
- Audio is never downloaded and no ASR backend is called. Caption extraction first uses YouTube's low-cost web transcript, then falls back to `yt-dlp` for YouTube's own subtitle track; missing or incomplete captions become `no_transcript` with a visible reason.
- A newly published episode with no caption track is shown as `字幕生成中` for 72 hours. The reader immediately presents the official description, guest card, and Show Notes chapters as a clearly labeled preview; daily retries replace that preview with the full Transcript, translation, and structured analysis once captions appear.
- `/opt/homebrew/bin/codex exec -m gpt-5.6-luna` performs source-specific extraction and bilingual translation. Content calls use Luna's default reasoning configuration; a separately configured Codex automation may use `max` reasoning effort.
- Original Transcript, Chinese translation, participant research, topic map, core insights, evidence limits, and source links are saved in local SQLite.
- The reading order is one-sentence takeaway, one-paragraph core summary, participants, topic map, core insights, evidence, and bilingual Transcript. Original publication and local organization timestamps are shown to the second in the Mac's current time zone.
- The sidebar keeps a compact receipt for the 07:30 Codex schedule, including current status, exact completion time, and run counts. Each episode and reader mode persists its own exact scroll offset across selection changes and App launches.
- Every manual or scheduled update completes discovery, extraction, and any missing translation before the one-shot worker exits.
- Daily discovery looks back 30 days but only accepts items newer than each source's local publish-time watermark, deduplicates by YouTube video ID, retries failed/missing-caption items, and records source-level failures in the run receipt.
- New subscriptions automatically receive a Luna-generated source profile; users never manage prompts.

The code and installed runtime do not read or write Hermes files, databases, prompts, jobs, logs, Notion state, or Telegram state.

## Public-repository boundaries

- MIT covers the source and original App Icon. See [LICENSE](LICENSE) and [ASSETS.md](ASSETS.md).
- Podcast content remains owned by its publishers. Review [LEGAL.md](LEGAL.md) before enabling caption extraction.
- “Local-first” does not mean fully offline: Transcript content is sent through the user's authenticated Codex CLI. See [PRIVACY.md](PRIVACY.md).
- Report vulnerabilities privately according to [SECURITY.md](SECURITY.md).
- Runtime dependencies and licenses are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Build and install

```zsh
scripts/build_app.sh
scripts/install_personal_app.sh
```

## One-shot update

```zsh
/bin/zsh scripts/daily_update.sh
```

## Verify

```zsh
scripts/verify.sh
```

This runs the Swift build with warnings treated as errors, Python syntax checks, isolated pipeline tests, shell syntax validation, source-catalog validation, plist validation, and installed-app signature verification when present.

## Main source files

- `Sources/PodcastNotesApp/ContentView.swift`: native three-column reader UI.
- `Sources/PodcastNotesApp/Resources/pipeline.py`: independent one-shot discovery, Transcript, extraction, and translation pipeline.
- `Sources/PodcastNotesApp/Resources/seed_sources.json`: independent 21-source catalog and source-specific profiles.
- `Assets/AppIcon-master-v2.png` and `Assets/AppIcon.icns`: transparent, borderless production macOS icon.
- `PRODUCT_SPEC.md`: current product, data, automation, and acceptance contract.
- `SOURCE_PROFILES.md`: research rationale behind the 21 source-specific extraction profiles; the executable profile text lives in `seed_sources.json`.
