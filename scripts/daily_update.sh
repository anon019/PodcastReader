#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
resources="$project_dir/Sources/PodcastNotesApp/Resources"
database="${PODCAST_NOTES_DB:-$HOME/Library/Application Support/PodcastNotes/podcast_notes.sqlite3}"

# The worker owns one OS-released lock for the entire update, including source
# profiles and translation repair. Manual and scheduled commands use this lock.
exec python3 "$resources/pipeline.py" --db "$database" --resources "$resources" update \
  --trigger codex_schedule --lookback-days 30 --per-source 5 --retry-failed
