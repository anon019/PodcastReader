# Podcast Reader native implementation boundary

## User requirements

- Personal local macOS app, not an App Store product.
- A reader for structured extraction, never a note-taking surface.
- YouTube-first subscriptions, playlists, and manual single-episode links.
- Explicit manual refresh plus one non-resident Codex automation run every day.
- Original YouTube publication date and local organized date are always visible.
- Read/unread, processing, no-Transcript, failed, and source-health states are visible.
- Full original Transcript, Chinese translation, participant background, topics, insights, and evidence limits live together.
- Twenty-one default sources with independent, versioned extraction profiles.
- Pipeline, data, prompts, and scheduling are completely independent from Hermes.

## Selected design choices

- Three-column native SwiftUI reader with system-resizable split views.
- User-selectable System, Light, and Dark appearances persisted in `UserDefaults` through `@AppStorage`.
- Light appearance uses warm paper and sage; dark appearance uses near-black green surfaces with high-contrast ivory text and a brighter sage action color.
- High-resolution YouTube thumbnails remain the visual anchor; the title and two freshness dates sit on an adaptive surface below the image.
- Only two reading modes exist: structured extraction and original/translation.
- Source Profile, model routing, and scheduling details remain outside everyday management UI.

## Implementation boundary

Production UI is native SwiftUI. HTML concepts are historical references only. Official YouTube images are loaded remotely with high-to-low resolution fallback. UI layout and information hierarchy remain code-native.
