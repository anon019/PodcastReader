#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
worker="$project_dir/Sources/PodcastNotesApp/Resources/pipeline.py"
resources="$project_dir/Sources/PodcastNotesApp/Resources"
database="$HOME/Library/Application Support/PodcastNotes/podcast_notes.sqlite3"
log_root="$HOME/Library/Logs/PodcastNotes/backfill-latest"
selection_file="$log_root/latest-selection.json"
analysis_workers="${PODCAST_NOTES_ANALYSIS_WORKERS:-3}"
translation_workers="${PODCAST_NOTES_TRANSLATION_WORKERS:-3}"

mkdir -p "$log_root"

echo "[1/4] Selecting the newest full episode defined by every source profile"
python3 "$worker" --db "$database" --resources "$resources" latest-each-source --feed-limit 15 | tee "$selection_file"

echo "[2/4] Fetching Transcript and running source-specific Luna analysis"
jq -r '.targets[].episodeId' "$selection_file" | \
  xargs -n 1 -P "$analysis_workers" /bin/zsh -c '
    worker="$1"; database="$2"; resources="$3"; log_root="$4"; id="$5"
    echo "START analysis $id"
    if python3 "$worker" --db "$database" --resources "$resources" process "$id" >"$log_root/$id.analysis.log" 2>&1; then
      echo "DONE  analysis $id"
    else
      echo "FAIL  analysis $id (see $log_root/$id.analysis.log)"
    fi
  ' _ "$worker" "$database" "$resources" "$log_root"

echo "[3/4] Filling and caching Chinese Transcript comparison"
jq -r '.targets[].episodeId' "$selection_file" | while IFS= read -r id; do
  sqlite3 -noheader "$database" "SELECT '$id' WHERE EXISTS (SELECT 1 FROM episodes e WHERE e.id='$id' AND e.status='complete') AND EXISTS (SELECT 1 FROM transcript_segments t WHERE t.episode_id='$id' AND t.translated_text IS NULL);"
done | \
  xargs -n 1 -P "$translation_workers" /bin/zsh -c '
    worker="$1"; database="$2"; resources="$3"; log_root="$4"; id="$5"
    echo "START translate $id"
    if python3 "$worker" --db "$database" --resources "$resources" translate "$id" >"$log_root/$id.translation.log" 2>&1; then
      echo "DONE  translate $id"
    else
      echo "FAIL  translate $id (see $log_root/$id.translation.log)"
    fi
  ' _ "$worker" "$database" "$resources" "$log_root"

echo "[4/4] Acceptance summary"
sqlite3 -header -column "$database" "
WITH ranked AS (
  SELECT e.*,s.name AS source_name,
         ROW_NUMBER() OVER (PARTITION BY e.source_id ORDER BY e.published_at DESC) AS row_number
  FROM episodes e JOIN sources s ON s.id=e.source_id
  WHERE s.enabled=1 AND s.archived=0 AND s.kind='channel'
    AND (e.duration_seconds IS NULL OR e.duration_seconds >= s.min_duration)
)
SELECT source_name,title,status,
       CASE WHEN transcript_text IS NOT NULL THEN length(transcript_text) ELSE 0 END AS transcript_chars,
       CASE WHEN analysis_json IS NOT NULL THEN 1 ELSE 0 END AS analyzed,
       (SELECT count(*) FROM transcript_segments t WHERE t.episode_id=ranked.id) AS segments,
       (SELECT count(*) FROM transcript_segments t WHERE t.episode_id=ranked.id AND t.translated_text IS NOT NULL) AS translated
FROM ranked WHERE row_number=1 ORDER BY source_name;
"
