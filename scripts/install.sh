#!/usr/bin/env bash
# Builds Phone Remote with your Apple ID, installs it on your iPhone and
# Apple Vision Pro, puts the Mac app in ~/Applications, then turns on control.
#
# Usage: ./scripts/install.sh YOUR_TEAM_ID [BUNDLE_PREFIX]
#
# YOUR_TEAM_ID: Xcode > Settings > Accounts > your team (a free Personal Team
#   works; its builds expire after 7 days, then run this again).
# BUNDLE_PREFIX: any reverse-domain name you own; default "dev.<team>".
#
# Connect both devices to this Mac (cable or same Wi-Fi) with Developer Mode on.
set -euo pipefail

TEAM_ID="${1:?Usage: $0 YOUR_TEAM_ID [BUNDLE_PREFIX]}"
PREFIX="${2:-dev.$(echo "$TEAM_ID" | tr '[:upper:]' '[:lower:]')}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/.build"

device_id() {
  xcrun devicectl list devices 2>/dev/null | awk -v kind="$1" '$0 ~ kind && /(available|connected)/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) {print $i; exit}}'
}

build_and_install() { # scheme product-dir device-id
  echo "Building $1…"
  rm -rf "$BUILD/Build/Products/$2/Tether.app"
  xcodebuild -project "$ROOT/Tether/Tether.xcodeproj" -scheme "$1" \
    -destination "id=$3" -derivedDataPath "$BUILD" -allowProvisioningUpdates \
    TETHER_TEAM_ID="$TEAM_ID" DEVELOPMENT_TEAM="$TEAM_ID" TETHER_BUNDLE_PREFIX="$PREFIX" \
    build 2>&1 | grep -E " error: |BUILD (SUCCEEDED|FAILED)" || true
  local app="$BUILD/Build/Products/$2/Tether.app"
  [[ -d "$app" ]] || { echo "Build of $1 failed; open Tether/Tether.xcodeproj in Xcode to see why." >&2; exit 1; }
  echo "Installing on $3…"
  xcrun devicectl device install app --device "$3" "$app" >/dev/null
}

IPHONE=$(device_id iPhone)
VISION=$(device_id "Vision Pro")
[[ -n "$IPHONE" ]] || { echo "No iPhone found. Connect it and unlock it." >&2; exit 1; }

build_and_install Tether-iOS Debug-iphoneos "$IPHONE"
if [[ -n "$VISION" ]]; then
  build_and_install Tether-visionOS Debug-xros "$VISION"
else
  echo "No Apple Vision Pro found; skipped. Put it on, then run this again."
fi

echo "Building the Mac app…"
xcodebuild -project "$ROOT/Tether/Tether.xcodeproj" -scheme Tether-macOS -configuration Release \
  -destination "platform=macOS" -derivedDataPath "$BUILD" \
  TETHER_TEAM_ID="$TEAM_ID" TETHER_BUNDLE_PREFIX="$PREFIX" \
  build 2>&1 | grep -E " error: |BUILD (SUCCEEDED|FAILED)" || true
if [[ -d "$BUILD/Build/Products/Release/Phone Remote.app" ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Phone Remote.app"
  cp -R "$BUILD/Build/Products/Release/Phone Remote.app" "$HOME/Applications/"
  echo "Mac app: ~/Applications/Phone Remote.app"
fi

echo
echo "Phone Remote is installed. Starting control…"
exec "$ROOT/scripts/enable-control.sh" "$TEAM_ID" "$IPHONE"
