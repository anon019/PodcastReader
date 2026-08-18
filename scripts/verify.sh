#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir"

export CLANG_MODULE_CACHE_PATH="${PODCAST_NOTES_CLANG_MODULE_CACHE:-$project_dir/.build/clang-module-cache-15.4}"
export SWIFTPM_MODULECACHE_OVERRIDE="${PODCAST_NOTES_SWIFTPM_MODULE_CACHE:-$project_dir/.build/swiftpm-module-cache-15.4}"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"

swift_args=()
compatible_sdk="${PODCAST_NOTES_MACOS_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk}"
if [[ -d "$compatible_sdk" ]]; then
  export SDKROOT="$compatible_sdk"
  swift_args+=(--sdk "$compatible_sdk")
fi
if [[ "${PODCAST_NOTES_DISABLE_SWIFTPM_SANDBOX:-0}" == "1" ]]; then
  swift_args+=(--disable-sandbox)
fi

swift build "${swift_args[@]}" -Xswiftc -warnings-as-errors
python3 -m py_compile Sources/PodcastNotesApp/Resources/pipeline.py
python3 -m unittest discover -s tests -p 'test_*.py'
zsh -n scripts/daily_update.sh scripts/build_app.sh scripts/install_personal_app.sh
jq -e 'length == 21 and ([.[].id] | unique | length == 21)' Sources/PodcastNotesApp/Resources/seed_sources.json >/dev/null
plutil -lint App/Info.plist >/dev/null

if [[ -d "$HOME/Applications/Podcast Reader.app" ]]; then
  codesign --verify --deep --strict "$HOME/Applications/Podcast Reader.app"
fi

echo "Podcast Reader verification passed"
