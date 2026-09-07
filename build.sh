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

# An ad-hoc signature with no explicit requirement defaults to a
# "designated requirement" of `cdhash H"<exact hash of this binary>"` — so
# even with a fixed --identifier, TCC's grant is really keyed to this one
# build's hash. Every rebuild produces a different hash (Swift builds
# aren't byte-reproducible), so the very next rebuild silently invalidates
# the grant and the Desktop/Documents/Downloads prompt comes back. Passing
# an explicit requirement that checks only the identifier (no cdhash, no
# anchor) makes every build satisfy the same requirement, so a grant made
# against one build keeps matching after later rebuilds.
codesign --force --deep --sign - --identifier com.marcusbarta.dotmd \
    -r "=designated => identifier \"com.marcusbarta.dotmd\"" "$APP"

echo "Built $APP"
