#!/bin/bash
# Builds a Release copy of Localhosts, installs it to /Applications and restarts it. When the
# installed app opens it links the `localhosts` command into ~/.local/bin and installs the
# Claude Code skill.
set -euo pipefail
cd "$(dirname "$0")"
xcodegen generate --quiet
xcodebuild -project Localhosts.xcodeproj -scheme Localhosts -configuration Release \
  -derivedDataPath build/DerivedData build | grep -E "error|warning: |BUILD" || true
APP="build/DerivedData/Build/Products/Release/Localhosts.app"
[ -d "$APP" ] || { echo "Build failed"; exit 1; }

pkill -x Localhosts 2>/dev/null || true
rm -rf "/Applications/Localhosts.app"
cp -R "$APP" /Applications/
# Keep the build copy out of Launchpad and Spotlight so only the installed app shows up.
"/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister" -u "$APP" 2>/dev/null || true

open "/Applications/Localhosts.app"
echo "Installed to /Applications/Localhosts.app"
