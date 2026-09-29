#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-}"
OUTPUT_IPA="${2:-VideoTargetFinder-unsigned.ipa}"

if [[ -z "$APP_PATH" || ! -d "$APP_PATH" || "${APP_PATH##*.}" != "app" ]]; then
  echo "Usage: $0 /path/to/VideoTargetFinder.app [output.ipa]" >&2
  exit 2
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/Payload"
cp -R "$APP_PATH" "$WORK_DIR/Payload/"
(
  cd "$WORK_DIR"
  /usr/bin/zip -qry "$OLDPWD/$OUTPUT_IPA" Payload
)

echo "Created $OUTPUT_IPA"
