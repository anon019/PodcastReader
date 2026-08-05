#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
source_app="$project_dir/dist/Podcast Reader.app"
target_root="$HOME/Applications"
target_app="$target_root/Podcast Reader.app"
db_path="$HOME/Library/Application Support/PodcastNotes/podcast_notes.sqlite3"

if [[ ! -d "$source_app" ]]; then
  "$project_dir/scripts/build_app.sh" >/dev/null
fi

mkdir -p "$target_root" "${db_path:h}"
ditto "$source_app" "$target_app"

echo "$target_app"
