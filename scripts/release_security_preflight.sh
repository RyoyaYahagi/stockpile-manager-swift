#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IPA_PATH="${1:-}"
FAILED=0

cd "$ROOT_DIR"

report_failure() {
  printf 'release security preflight failed: %s\n' "$1" >&2
  FAILED=1
}

is_forbidden_secret_path() {
  case "$1" in
    .env|.env.local|.env.fastlane|.env.fastlane.local|*/.env|*/.env.local|*/.env.fastlane|*/.env.fastlane.local|Secrets.plist|*/Secrets.plist|GoogleService-Info.plist|*/GoogleService-Info.plist)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

while IFS= read -r path; do
  if is_forbidden_secret_path "$path"; then
    report_failure "tracked secret file: $path"
  fi
done < <(git ls-files)

while IFS= read -r path; do
  [ -n "$path" ] || continue
  if is_forbidden_secret_path "$path"; then
    report_failure "secret file exists in Git history: $path"
  fi
done < <(git log --all --pretty=format: --name-only | sort -u)

SECRET_PATTERN='BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|sk_(live|test)_[0-9A-Za-z]{16,}|gh[pousr]_[0-9A-Za-z]{20,}|xox[baprs]-[0-9A-Za-z-]{10,}'
if git grep -I -n -E "$SECRET_PATTERN" -- . \
  ':(exclude)*.example' ':(exclude)Gemfile.lock' >/tmp/stockpile-secret-pattern-matches.txt; then
  while IFS=: read -r path line _; do
    report_failure "secret-like value in tracked file: ${path}:${line}"
  done < /tmp/stockpile-secret-pattern-matches.txt
fi

if [ -n "$IPA_PATH" ]; then
  if [ ! -f "$IPA_PATH" ]; then
    report_failure "IPA does not exist: $IPA_PATH"
  else
    TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/stockpile-security.XXXXXX")"
    trap 'rm -rf "$TEMP_DIR" /tmp/stockpile-secret-pattern-matches.txt' EXIT
    unzip -q "$IPA_PATH" -d "$TEMP_DIR"

    while IFS= read -r packaged_path; do
      relative_path="${packaged_path#"$TEMP_DIR"/}"
      if is_forbidden_secret_path "$relative_path"; then
        report_failure "forbidden file in IPA: $relative_path"
      fi
    done < <(find "$TEMP_DIR" -type f)

    for secret_file in .env .env.local .env.fastlane .env.fastlane.local Secrets.plist Stockpile/Secrets.plist GoogleService-Info.plist; do
      [ -f "$secret_file" ] || continue

      if [[ "$secret_file" == *.plist ]]; then
        while IFS=$'\t' read -r key value; do
          case "$key" in
            BackendBaseURL|BUNDLE_ID|PROJECT_ID|STORAGE_BUCKET|GOOGLE_APP_ID|GCM_SENDER_ID|PLIST_VERSION)
              continue
              ;;
          esac
          [ "${#value}" -ge 8 ] || continue
          if grep -R -a -F -q -- "$value" "$TEMP_DIR/Payload"; then
            report_failure "local secret value packaged from $secret_file key $key"
          fi
        done < <(plutil -convert json -o - "$secret_file" | jq -r 'to_entries[] | select(.value | type == "string") | [.key, .value] | @tsv')
      else
        while IFS='=' read -r key value; do
          key="${key#export }"
          case "$key" in
            ASC_KEY_CONTENT|CLOUDKIT_MANAGEMENT_TOKEN|MATCH_PASSWORD) ;;
            *) continue ;;
          esac
          [ "${#value}" -ge 8 ] || continue
          if grep -R -a -F -q -- "$value" "$TEMP_DIR/Payload"; then
            report_failure "local environment value packaged for $key"
          fi
        done < "$secret_file"
      fi
    done
  fi
fi

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi

printf 'Release security preflight passed%s\n' "${IPA_PATH:+ for $IPA_PATH}"
