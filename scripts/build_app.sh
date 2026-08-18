#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir"

export CLANG_MODULE_CACHE_PATH="${PODCAST_NOTES_CLANG_MODULE_CACHE:-$project_dir/.build/clang-module-cache-15.4}"
export SWIFTPM_MODULECACHE_OVERRIDE="${PODCAST_NOTES_SWIFTPM_MODULE_CACHE:-$project_dir/.build/swiftpm-module-cache-15.4}"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"

swift_args=(-c release)
compatible_sdk="${PODCAST_NOTES_MACOS_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk}"
if [[ -d "$compatible_sdk" ]]; then
  export SDKROOT="$compatible_sdk"
  swift_args+=(--sdk "$compatible_sdk")
fi
if [[ "${PODCAST_NOTES_DISABLE_SWIFTPM_SANDBOX:-0}" == "1" ]]; then
  swift_args+=(--disable-sandbox)
fi

swift build "${swift_args[@]}"
binary_dir="$(swift build "${swift_args[@]}" --show-bin-path)"
app_dir="$project_dir/dist/Podcast Reader.app"

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$project_dir/App/Info.plist" "$app_dir/Contents/Info.plist"
cp "$binary_dir/PodcastNotes" "$app_dir/Contents/MacOS/PodcastNotes"
cp "$project_dir/Assets/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
rm -rf "$app_dir/PodcastNotes_PodcastNotesApp.bundle" "$app_dir/Contents/Resources/PodcastNotes_PodcastNotesApp.bundle"
cp -R "$binary_dir/PodcastNotes_PodcastNotesApp.bundle" "$app_dir/Contents/Resources/PodcastNotes_PodcastNotesApp.bundle"
codesign --force --deep --sign - "$app_dir"

echo "$app_dir"
