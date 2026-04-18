#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/Stockpile.xcodeproj"
SCHEME="Stockpile"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/Stockpile-DD}"
BUNDLE_ID="${BUNDLE_ID:-com.stockpile-manager.app}"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/${CONFIGURATION}-iphonesimulator/Stockpile.app"
DEVICE1_QUERY="${1:-iPhone 17}"
DEVICE2_QUERY="${2:-iPhone 17 Pro Max}"

uuid_regex='^[A-F0-9-]{36}$'

resolve_device_id() {
  local query="$1"

  if [[ "$query" =~ $uuid_regex ]]; then
    echo "$query"
    return 0
  fi

  local line
  line="$(xcrun simctl list devices available | grep -F "    ${query} (" | head -n 1 || true)"

  if [[ -z "$line" ]]; then
    echo "利用可能なシミュレーター '${query}' が見つかりません。" >&2
    exit 1
  fi

  echo "$line" | sed -E 's/.*\(([A-F0-9-]{36})\).*/\1/'
}

device_name_for_id() {
  local id="$1"
  xcrun simctl list devices available | grep -F "(${id})" | head -n 1 | sed -E 's/^[[:space:]]*([^()]+) \(.*/\1/'
}

run_with_retry() {
  local label="$1"
  shift

  local attempt=1
  while (( attempt <= 3 )); do
    if "$@"; then
      return 0
    fi
    echo "[retry ${attempt}/3] ${label} に失敗しました。再試行します。" >&2
    attempt=$((attempt + 1))
    sleep 2
  done

  echo "${label} に 3 回失敗しました。" >&2
  exit 1
}

boot_if_needed() {
  local id="$1"

  if xcrun simctl list devices | grep -F "(${id}) (Booted)" > /dev/null; then
    return 0
  fi

  xcrun simctl boot "$id"
}

DEVICE1_ID="$(resolve_device_id "$DEVICE1_QUERY")"
DEVICE2_ID="$(resolve_device_id "$DEVICE2_QUERY")"

if [[ "$DEVICE1_ID" == "$DEVICE2_ID" ]]; then
  echo "同じシミュレーターが 2 回指定されています。" >&2
  exit 1
fi

DEVICE1_NAME="$(device_name_for_id "$DEVICE1_ID")"
DEVICE2_NAME="$(device_name_for_id "$DEVICE2_ID")"

echo "Device 1: ${DEVICE1_NAME} (${DEVICE1_ID})"
echo "Device 2: ${DEVICE2_NAME} (${DEVICE2_ID})"
echo "DerivedData: ${DERIVED_DATA_PATH}"

echo
echo "== Build =="
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "platform=iOS Simulator,id=${DEVICE1_ID}" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build

if [[ ! -d "$APP_PATH" ]]; then
  echo "ビルド成果物が見つかりません: $APP_PATH" >&2
  exit 1
fi

echo
echo "== Boot Simulators =="
run_with_retry "Device 1 の起動" boot_if_needed "$DEVICE1_ID"
run_with_retry "Device 2 の起動" boot_if_needed "$DEVICE2_ID"
run_with_retry "Device 1 の bootstatus 待機" xcrun simctl bootstatus "$DEVICE1_ID" -b
run_with_retry "Device 2 の bootstatus 待機" xcrun simctl bootstatus "$DEVICE2_ID" -b

echo
echo "== Install App =="
run_with_retry "Device 1 へのインストール" xcrun simctl install "$DEVICE1_ID" "$APP_PATH"
run_with_retry "Device 2 へのインストール" xcrun simctl install "$DEVICE2_ID" "$APP_PATH"

echo
echo "== Launch App =="
run_with_retry "Device 1 での起動" xcrun simctl launch "$DEVICE1_ID" "$BUNDLE_ID"
run_with_retry "Device 2 での起動" xcrun simctl launch "$DEVICE2_ID" "$BUNDLE_ID"

open -a Simulator >/dev/null 2>&1 || true

cat <<EOF

準備完了です。

次に手動で行うこと:
1. 両方のシミュレーターで Settings を開き、別々の Apple Account で iCloud にサインインする
2. iCloud Drive が ON になっていることを確認する
3. Stockpile を再起動して、家族共有テストを開始する

詳しい検証フロー:
  docs/cloudkit-family-sharing-simulator-test.md
EOF
