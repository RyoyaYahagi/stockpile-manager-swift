#!/usr/bin/env bash
#
# App Store提出用スクリーンショットをシミュレータで撮影する。
# ダッシュボード / 備蓄品追加 / 収納場所一覧 / 家族共有設定 / 通知設定 の5画面を
# アプリのスクリーンショットモード（--screenshot-mode）で撮影し、raw画像として保存する。

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/Stockpile.xcodeproj"
SCHEME="Stockpile"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/Stockpile-Screenshots-DD}"
BUNDLE_ID="${BUNDLE_ID:-com.stockpile-manager.app}"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/${CONFIGURATION}-iphonesimulator/Stockpile.app"
DEVICE_QUERY="${1:-iPhone 17 Pro Max}"
LOCALE="${LOCALE:-ja_JP}"
LANGUAGE="${LANGUAGE:-ja}"
OUTPUT_DIR="$ROOT_DIR/screenshots/raw/${LANGUAGE}"

SCREENS=(
  "01_dashboard:dashboard"
  "02_add-item:add-item"
  "03_bags:bags"
  "04_family:family"
  "05_notifications:notifications"
)

resolve_device_id() {
  local query="$1"
  local line
  line="$(xcrun simctl list devices available | grep -F "    ${query} (" | head -n 1 || true)"

  if [[ -z "$line" ]]; then
    echo "利用可能なシミュレーター '${query}' が見つかりません。" >&2
    exit 1
  fi

  echo "$line" | sed -E 's/.*\(([A-F0-9-]{36})\).*/\1/'
}

boot_if_needed() {
  local id="$1"
  if xcrun simctl list devices | grep -F "(${id}) (Booted)" > /dev/null; then
    return 0
  fi
  xcrun simctl boot "$id"
}

DEVICE_ID="$(resolve_device_id "$DEVICE_QUERY")"
echo "Device: ${DEVICE_QUERY} (${DEVICE_ID})"
echo "DerivedData: ${DERIVED_DATA_PATH}"
echo "Output: ${OUTPUT_DIR}"

echo
echo "== Build =="
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "platform=iOS Simulator,id=${DEVICE_ID}" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build

if [[ ! -d "$APP_PATH" ]]; then
  echo "ビルド成果物が見つかりません: $APP_PATH" >&2
  exit 1
fi

echo
echo "== Reset Simulator =="
xcrun simctl shutdown "$DEVICE_ID" >/dev/null 2>&1 || true
xcrun simctl erase "$DEVICE_ID"

echo
echo "== Boot Simulator =="
boot_if_needed "$DEVICE_ID"
xcrun simctl bootstatus "$DEVICE_ID" -b

echo
echo "== Install App =="
xcrun simctl install "$DEVICE_ID" "$APP_PATH"

echo
echo "== Warm-up Launch (settle first-boot system banners) =="
xcrun simctl launch "$DEVICE_ID" "$BUNDLE_ID" --screenshot-mode dashboard >/dev/null
sleep 8
xcrun simctl terminate "$DEVICE_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
sleep 2

echo
echo "== Configure Status Bar =="
xcrun simctl status_bar "$DEVICE_ID" override \
  --time "9:41" \
  --batteryState charged \
  --batteryLevel 100 \
  --cellularMode active \
  --cellularBars 4 \
  --wifiMode active \
  --wifiBars 3

mkdir -p "$OUTPUT_DIR"

echo
echo "== Capture Screenshots =="
for entry in "${SCREENS[@]}"; do
  filename="${entry%%:*}"
  screen="${entry##*:}"

  echo "-- ${screen} --"
  xcrun simctl terminate "$DEVICE_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl launch "$DEVICE_ID" "$BUNDLE_ID" \
    --screenshot-mode "$screen" \
    -AppleLanguages "(${LANGUAGE})" \
    -AppleLocale "$LOCALE" \
    >/dev/null
  sleep 3
  xcrun simctl io "$DEVICE_ID" screenshot "${OUTPUT_DIR}/${filename}.png"
  echo "  -> ${OUTPUT_DIR}/${filename}.png"
done

xcrun simctl terminate "$DEVICE_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl status_bar "$DEVICE_ID" clear

echo
echo "完了しました。${OUTPUT_DIR} に ${#SCREENS[@]} 枚の画像を保存しました。"
