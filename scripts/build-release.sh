#!/usr/bin/env bash
# Builds the downloadable release in dist/:
#   PhoneRemote-iOS.ipa       iPhone app + broadcast extension (sideload it)
#   PhoneRemote-visionOS.ipa  Apple Vision Pro app (sideload it)
#   PhoneRemote-macOS.dmg     Mac app
#   SHA256SUMS
#
# Everything is ad-hoc signed: no certificate, no team, nothing tied to an
# Apple account. Sideloading tools re-sign the IPAs with the user's Apple ID.
# Build paths are rewritten and debug information is stripped so the binaries
# carry no file paths from the build machine; a final scan checks for that.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/.build-release"
DIST="$ROOT/dist"
GROUP="group.app.phoneremote.tether"

rm -rf "${BUILD:?}" "${DIST:?}"
mkdir -p "$BUILD" "$DIST"

cd "$ROOT/Tether"
if command -v xcodegen >/dev/null; then xcodegen generate --quiet; fi

build() { # scheme destination
  echo "Building $1…"
  xcodebuild -project "$ROOT/Tether/Tether.xcodeproj" -scheme "$1" -configuration Release \
    -destination "$2" -derivedDataPath "$BUILD/dd" \
    CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM= TETHER_TEAM_ID= \
    OTHER_SWIFT_FLAGS="\$(inherited) -file-prefix-map $ROOT=/src -file-prefix-map $BUILD=/build" \
    DEBUG_INFORMATION_FORMAT=dwarf-with-dsym DEPLOYMENT_POSTPROCESSING=YES \
    STRIP_INSTALLED_PRODUCT=YES STRIP_STYLE=non-global COPY_PHASE_STRIP=YES \
    build 2>&1 | grep -E " error: |BUILD (SUCCEEDED|FAILED)"
}

entitlements() { # file with-group
  if [[ "$2" == yes ]]; then
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>com.apple.security.application-groups</key><array><string>%s</string></array></dict></plist>\n' "$GROUP" > "$1"
  else
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict/></plist>\n' > "$1"
  fi
}

sign() { # bundle entitlements-file
  # Strip any remaining debug symbols, then sign inside-out, ad hoc.
  find "$1" -type f -perm +111 -exec sh -c 'file "$1" | grep -q Mach-O && strip -S -x "$1" 2>/dev/null || true' _ {} \;
  for appex in "$1"/PlugIns/*.appex "$1"/Contents/PlugIns/*.appex; do
    [[ -e "$appex" ]] && codesign --force --sign - --entitlements "$2" "$appex"
  done
  codesign --force --sign - --entitlements "$2" "$1"
}

ipa() { # app output with-group
  entitlements "$BUILD/ent.plist" "$3"
  sign "$1" "$BUILD/ent.plist"
  rm -rf "$BUILD/Payload" && mkdir "$BUILD/Payload" && cp -R "$1" "$BUILD/Payload/"
  # -X: no owner or extended attributes in the archive.
  (cd "$BUILD" && zip -qryX "$DIST/$2" Payload)
  echo "  → dist/$2"
}

build Tether-iOS "generic/platform=iOS"
ipa "$BUILD/dd/Build/Products/Release-iphoneos/Tether.app" PhoneRemote-iOS.ipa yes

build Tether-visionOS "generic/platform=visionOS"
ipa "$BUILD/dd/Build/Products/Release-xros/Tether.app" PhoneRemote-visionOS.ipa no

build Tether-macOS "platform=macOS"
MAC="$BUILD/dd/Build/Products/Release/Phone Remote.app"
entitlements "$BUILD/ent-mac.plist" no
sign "$MAC" "$BUILD/ent-mac.plist"
mkdir -p "$BUILD/dmg" && cp -R "$MAC" "$BUILD/dmg/" && ln -s /Applications "$BUILD/dmg/Applications"
hdiutil create -quiet -volname "Phone Remote" -srcfolder "$BUILD/dmg" -fs HFS+ -format UDZO "$DIST/PhoneRemote-macOS.dmg"
echo "  → dist/PhoneRemote-macOS.dmg"

# Nothing from this machine may end up in the release.
echo "Checking for personal traces…"
LEAKS=$(mktemp)
for pattern in "$HOME" "/Users/" "$(id -un)" "$(scutil --get ComputerName 2>/dev/null || hostname)"; do
  grep -rlaF "$pattern" "$BUILD"/dd/Build/Products/Release-*/Tether.app "$MAC" >> "$LEAKS" 2>/dev/null || true
done
if [[ -s "$LEAKS" ]]; then
  echo "Personal traces found in:" >&2; sort -u "$LEAKS" >&2; exit 1
fi
for f in "$BUILD"/dd/Build/Products/Release-*/Tether.app "$MAC"; do
  codesign -dv "$f" 2>&1 | grep -q "TeamIdentifier=not set" || { echo "Unexpected signing identity in $f" >&2; exit 1; }
done
echo "  none found."

(cd "$DIST" && shasum -a 256 *.ipa *.dmg > SHA256SUMS)
echo "Done. Upload the files in dist/ to a GitHub release."
