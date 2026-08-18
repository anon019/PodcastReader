# Privacy

Podcast Reader is local-first, but it is not fully offline.

## Data stored locally

The application stores subscriptions, episode metadata, Transcript text, Chinese translations, structured analyses, read state, and reading positions in:

`~/Library/Application Support/PodcastNotes/podcast_notes.sqlite3`

The repository does not contain a production database, user account, API key, or Podcast Transcript. Database, WAL, log, and build artifacts are excluded by `.gitignore`.

## Network and model processing

- The pipeline contacts supported YouTube HTTPS origins to discover public metadata and, only after explicit local opt-in, invokes user-installed caption tooling.
- Structured analysis, participant research, and translation are performed by the locally authenticated Codex CLI. The relevant Transcript or prompt content is therefore sent to the model provider under the user's Codex account and applicable provider terms.
- The application has no analytics SDK, advertising SDK, crash-reporting service, API server, login item, or resident background service.
- A user-configured Codex scheduled task may launch the one-shot pipeline; this repository does not install that schedule automatically.

## Deletion

Removing the application does not automatically remove its library. To erase local Podcast Reader data, quit the app and remove the `PodcastNotes` directory under the user's Application Support folder. Backups created by macOS or the user may retain copies.

## Third-party content

Podcast titles, thumbnails, descriptions, captions, and Transcripts remain subject to the rights and terms of their respective owners. Do not publish a local database or generated Transcript unless you have permission.
