#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir"

swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
app_dir="$project_dir/dist/Podcast Reader.app"

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$project_dir/App/Info.plist" "$app_dir/Contents/Info.plist"
cp "$binary_dir/PodcastNotes" "$app_dir/Contents/MacOS/PodcastNotes"
cp "$project_dir/Assets/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
rm -rf "$app_dir/PodcastNotes_PodcastNotesApp.bundle" "$app_dir/Contents/Resources/PodcastNotes_PodcastNotesApp.bundle"
cp -R "$binary_dir/PodcastNotes_PodcastNotesApp.bundle" "$app_dir/Contents/Resources/PodcastNotes_PodcastNotesApp.bundle"
codesign --force --deep --sign - "$app_dir"

echo "$app_dir"
