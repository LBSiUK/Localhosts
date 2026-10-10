#!/bin/bash
# Builds Localhosts and packages it as a drag-to-install DMG in build/.
#
# Notarising (optional, needs a paid Apple Developer account):
#   1. Install a "Developer ID Application" certificate in your keychain.
#   2. Save notary credentials once:
#        xcrun notarytool store-credentials LocalhostsNotary --apple-id you@example.com --team-id TEAMID
#   3. Run:  DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=LocalhostsNotary ./make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")"

NAME="Localhosts"
VERSION=$(grep -m1 'MARKETING_VERSION' project.yml | sed -E 's/.*"(.*)".*/\1/')
BUILD=build/dmg
APP="$BUILD/stage/$NAME.app"
DMG="build/Localhosts-$VERSION.dmg"

rm -rf "$BUILD" "$DMG"
mkdir -p "$BUILD/stage"

echo "Building $NAME $VERSION..."
xcodegen generate --quiet
xcodebuild -project Localhosts.xcodeproj -scheme Localhosts -configuration Release \
  -derivedDataPath build/DerivedData build -quiet
cp -R "build/DerivedData/Build/Products/Release/$NAME.app" "$APP"
# Keep build copies out of Launchpad and Spotlight so only the installed app shows up.
"/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister" -u "build/DerivedData/Build/Products/Release/$NAME.app" 2>/dev/null || true

if [ -n "${DEVELOPER_ID:-}" ]; then
  echo "Signing with $DEVELOPER_ID..."
  codesign --force --deep --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
fi
codesign --verify --strict "$APP"

ln -s /Applications "$BUILD/stage/Applications"

# Make a writable image first so the window can be laid out, then compress it.
hdiutil create -quiet -volname "$NAME" -srcfolder "$BUILD/stage" -fs HFS+ -format UDRW -ov "$BUILD/rw.dmg"
MOUNT=$(hdiutil attach -readwrite -noverify -noautoopen "$BUILD/rw.dmg" | awk -F'\t' '/\/Volumes\//{print $NF}')
VOLUME=$(basename "$MOUNT")
sleep 2

osascript <<EOF || echo "Couldn't lay out the window (Finder automation not allowed); the DMG still works."
tell application "Finder"
  tell disk "$VOLUME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 200, 760, 520}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set position of item "$NAME.app" of container window to {150, 150}
    set position of item "Applications" of container window to {410, 150}
    update without registering applications
    delay 2
    close
    -- Reopen once so Finder writes the icon positions as well as the window size.
    open
    delay 2
    close
  end tell
end tell
EOF

# Finder saves the layout to .DS_Store lazily; give it a moment before sealing the image.
for _ in $(seq 1 10); do [ -f "$MOUNT/.DS_Store" ] && break; sleep 1; done
sleep 4
rm -rf "$MOUNT/.fseventsd"
sync
hdiutil detach -quiet "$MOUNT"
hdiutil convert -quiet "$BUILD/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -f "$BUILD/rw.dmg"

if [ -n "${DEVELOPER_ID:-}" ]; then
  codesign --sign "$DEVELOPER_ID" --timestamp "$DMG"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "Sending to Apple for notarisation (this usually takes a few minutes)..."
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
fi

"/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister" -u "$APP" 2>/dev/null || true
rm -rf "$BUILD"  # drop the staging copy so Spotlight only finds the real app
echo "Made $DMG ($(du -h "$DMG" | cut -f1))"
