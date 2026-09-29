#!/usr/bin/env bash
# Turns on "Control from Vision Pro" for Phone Remote.
#
# Builds DeviceKit (an XCTest runner by Mobile Next, FSL-1.1 licensed, not
# part of Phone Remote) with your own Apple developer team and starts it on your
# iPhone. It listens on the iPhone's loopback interface only.
#
# Usage: ./scripts/enable-control.sh YOUR_TEAM_ID [IPHONE_UDID]
# Keep this running; press Ctrl-C to turn control off.
set -euo pipefail

TEAM_ID="${1:?Usage: $0 YOUR_TEAM_ID [IPHONE_UDID]}"
DEVICE_ID="${2:-}"
PIN=510d10e5e376221397cef7f8d7acb74603c61888
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The Mac app passes its own locations; the repo checkout is the default.
SRC="${DEVICEKIT_DIR:-$ROOT/.devicekit}"
PATCH="${DEVICEKIT_PATCH:-$ROOT/scripts/devicekit-tether.patch}"

if [[ ! -d "$SRC" ]]; then
  echo "Fetching DeviceKit…"
  mkdir -p "$(dirname "$SRC")"
  git clone --quiet https://github.com/mobile-next/devicekit-ios.git "$SRC"
  git -C "$SRC" checkout --quiet "$PIN"
  # Sign with your team and give the runner identifiers you own.
  sed -i '' \
    -e "s/DEVELOPMENT_TEAM = [^;]*;/DEVELOPMENT_TEAM = $TEAM_ID;/" \
    -e "s/\"com.mobilenext.devicekit-ios\"/\"$TEAM_ID.tether.devicekit\"/" \
    -e "s/\"com.mobilenext.devicekit-iosUITests\"/\"$TEAM_ID.tether.devicekit.uitests\"/" \
    "$SRC/devicekit-ios.xcodeproj/project.pbxproj"
fi

# Phone Remote's changes: faster taps, and a stop command for the iPhone app.
# Reapplied whenever the patch changes.
if ! cmp -s "$PATCH" "$SRC/.tether.patch"; then
  git -C "$SRC" checkout --quiet -- DeviceKitTests
  git -C "$SRC" apply "$PATCH"
  cp "$PATCH" "$SRC/.tether.patch"
fi

if [[ -z "$DEVICE_ID" ]]; then
  DEVICE_ID=$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && /(available|connected)/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) {print $i; exit}}')
  [[ -n "$DEVICE_ID" ]] || { echo "No iPhone found. Connect it or pass its UDID." >&2; exit 1; }
fi

echo "Starting control on iPhone $DEVICE_ID. Keep the iPhone unlocked for the first launch."
echo "Leave this running. Phone Remote shows 'Remote control: On' within a few seconds. Stop it from the iPhone app or with Ctrl-C."
cd "$SRC"
xcodebuild test \
  -project devicekit-ios.xcodeproj \
  -scheme devicekit-ios \
  -destination "id=$DEVICE_ID" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  IPHONEOS_DEPLOYMENT_TARGET=16.0 \
  -only-testing:devicekit-iosUITests/DeviceKitUITests/testRunAutomation \
  2>&1 | grep --line-buffered -E "Server is ready| error: |TEST FAILED" || true
