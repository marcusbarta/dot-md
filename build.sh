#!/bin/bash
# Builds dotMD.app in the project's build/ directory.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/dotMD.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/dotMD "$APP/Contents/MacOS/dotMD"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
chmod +x "$APP/Contents/MacOS/dotMD"

# Finder (or iCloud/Spotlight file-provider indexing) tends to tag bundles
# with extended attributes like com.apple.FinderInfo just from being seen
# in a Finder window. codesign's strict verification refuses to consider a
# bundle carrying any of these "detritus" attributes properly signed — and
# TCC's own runtime signature check appears to rely on that same strict
# validation, so a tainted bundle silently fails to match a stored consent
# grant and macOS re-prompts on every launch. Stripping them before signing
# keeps the signed bundle clean.
xattr -cr "$APP"

# Sign with a real (stable) certificate identity, not ad-hoc. Ad-hoc
# signatures (even with a hand-written identifier-only requirement) never
# gave TCC a durable thing to pin the Desktop/Documents/Downloads grant to,
# so the prompt came back on every launch. A cert-signed app's designated
# requirement is identifier + certificate leaf, identical across rebuilds,
# so one grant sticks forever.
IDENTITY="Apple Development: marcusbarta@icloud.com (SBMBXDN76G)"
codesign --force --deep --sign "$IDENTITY" --identifier com.marcusbarta.dotmd "$APP"

echo "Built $APP"
