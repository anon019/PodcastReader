#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir"

swift build -Xswiftc -warnings-as-errors
python3 -m py_compile Sources/PodcastNotesApp/Resources/pipeline.py
python3 -m unittest discover -s tests -p 'test_*.py'
zsh -n scripts/daily_update.sh scripts/build_app.sh scripts/install_personal_app.sh
jq -e 'length == 21 and ([.[].id] | unique | length == 21)' Sources/PodcastNotesApp/Resources/seed_sources.json >/dev/null
plutil -lint App/Info.plist >/dev/null

if [[ -d "$HOME/Applications/Podcast Reader.app" ]]; then
  codesign --verify --deep --strict "$HOME/Applications/Podcast Reader.app"
fi

echo "Podcast Reader verification passed"
