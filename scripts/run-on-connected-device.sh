#!/bin/sh

set -eu

if [ "${STOCKPILE_SKIP_REAL_DEVICE_RUN_ACTION:-0}" = "1" ]; then
  echo "[stockpile] Skipping real-device run action because STOCKPILE_SKIP_REAL_DEVICE_RUN_ACTION=1"
  exit 0
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

PROJECT_PATH="${PROJECT_FILE_PATH:-$PROJECT_ROOT/Stockpile.xcodeproj}"
SCHEME_NAME="${SCHEME_NAME:-Stockpile}"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="${STOCKPILE_REAL_DEVICE_DERIVED_DATA_PATH:-${TMPDIR:-/tmp}StockpileRealDeviceDerivedData}"
DEVICE_UDID="${STOCKPILE_REAL_DEVICE_UDID:-}"

if [ -z "$DEVICE_UDID" ]; then
  DEVICE_UDID="$(
    xcrun xcdevice list --timeout 5 2>/dev/null \
      | /usr/bin/jq -r '.[] | select(.available == true and .simulator == false and ((.platform // "") | endswith("iphoneos"))) | .identifier' \
      | /usr/bin/head -n 1
  )"
fi

if [ -z "$DEVICE_UDID" ]; then
  echo "[stockpile] No connected iOS device found. Set STOCKPILE_REAL_DEVICE_UDID to target a specific device."
  exit 0
fi

echo "[stockpile] Building ${SCHEME_NAME} (${CONFIGURATION}) for device ${DEVICE_UDID}"
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME_NAME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build

APP_PATH="$DERIVED_DATA_PATH/Build/Products/${CONFIGURATION}-iphoneos/Stockpile.app"
if [ ! -d "$APP_PATH" ]; then
  echo "[stockpile] Built app was not found at $APP_PATH"
  exit 1
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist")"

echo "[stockpile] Installing ${APP_PATH}"
xcrun devicectl device install app --device "$DEVICE_UDID" "$APP_PATH"

echo "[stockpile] Launching ${BUNDLE_ID}"
xcrun devicectl device process launch --device "$DEVICE_UDID" --terminate-existing "$BUNDLE_ID"
