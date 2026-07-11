#!/usr/bin/env bash

set -euo pipefail

IPA_PATH="${1:-}"
EXPECTED_CONTAINER="${CLOUDKIT_CONTAINER_ID:-iCloud.com.stockpile-manager.app}"

if [[ -z "$IPA_PATH" || ! -f "$IPA_PATH" ]]; then
  echo "Usage: verify_cloudkit_ipa.sh /path/to/Stockpile.ipa" >&2
  exit 2
fi

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/stockpile-ipa-verify.XXXXXX")"
cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

unzip -q "$IPA_PATH" -d "$TEMP_DIR"
APP_PATH="$(find "$TEMP_DIR/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
if [[ -z "$APP_PATH" ]]; then
  echo "IPA内に.app bundleが見つかりません。" >&2
  exit 1
fi

SIGNED_ENTITLEMENTS="$TEMP_DIR/signed-entitlements.plist"
PROFILE_PLIST="$TEMP_DIR/embedded-profile.plist"
PROFILE_ENTITLEMENTS="$TEMP_DIR/profile-entitlements.plist"
codesign -d --entitlements "$SIGNED_ENTITLEMENTS" "$APP_PATH" >/dev/null 2>&1

PROFILE_PATH="$APP_PATH/embedded.mobileprovision"
if [[ ! -f "$PROFILE_PATH" ]]; then
  echo "IPA内にembedded.mobileprovisionがありません。" >&2
  exit 1
fi
openssl smime -inform der -verify -noverify -in "$PROFILE_PATH" -out "$PROFILE_PLIST" >/dev/null 2>&1
plutil -extract Entitlements xml1 -o "$PROFILE_ENTITLEMENTS" "$PROFILE_PLIST"

require_raw_value() {
  local plist="$1"
  local key="$2"
  local expected="$3"
  local label="$4"
  local actual

  if ! actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null)"; then
    echo "$label に $key がありません。" >&2
    exit 1
  fi
  if [[ "$actual" != "$expected" ]]; then
    echo "$label の $key が不正です。expected=$expected actual=$actual" >&2
    exit 1
  fi
}

require_array_value() {
  local plist="$1"
  local key="$2"
  local expected="$3"
  local label="$4"
  local values

  if ! values="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null)"; then
    echo "$label に $key がありません。" >&2
    exit 1
  fi
  if [[ "$values" != *"$expected"* ]]; then
    echo "$label の $key に $expected がありません。actual=$values" >&2
    exit 1
  fi
}

require_codesign_value() {
  local key="$1"
  local value_type="$2"
  local expected="$3"
  local block

  block="$(awk -v key="$key" '
    index($0, "[Key] " key) { found = 1; next }
    found && index($0, "[Key]") { exit }
    found { print }
  ' "$SIGNED_ENTITLEMENTS")"
  if [[ -z "$block" ]]; then
    echo "署名済みapp に $key がありません。" >&2
    exit 1
  fi
  if [[ "$block" != *"[$value_type] $expected"* ]]; then
    echo "署名済みapp の $key に $expected がありません。" >&2
    exit 1
  fi
}

require_codesign_value "com.apple.developer.icloud-container-environment" "String" "Production"
require_codesign_value "aps-environment" "String" "production"
require_codesign_value "get-task-allow" "Bool" "false"
require_codesign_value "com.apple.developer.icloud-container-identifiers" "String" "$EXPECTED_CONTAINER"
require_codesign_value "com.apple.developer.icloud-services" "String" "CloudKit"
require_codesign_value "com.apple.developer.icloud-extended-share-access" "String" "InProcessOneTimeLinks"

require_raw_value "$PROFILE_ENTITLEMENTS" "aps-environment" "production" "provisioning profile"
require_raw_value "$PROFILE_ENTITLEMENTS" "get-task-allow" "false" "provisioning profile"
require_array_value "$PROFILE_ENTITLEMENTS" "com.apple.developer.icloud-container-environment" "Production" "provisioning profile"
require_array_value "$PROFILE_ENTITLEMENTS" "com.apple.developer.icloud-container-identifiers" "$EXPECTED_CONTAINER" "provisioning profile"
require_array_value "$PROFILE_ENTITLEMENTS" "com.apple.developer.icloud-extended-share-access" "InProcessOneTimeLinks" "provisioning profile"

echo "CloudKit release IPA verified: Production / $EXPECTED_CONTAINER / InProcessOneTimeLinks"
