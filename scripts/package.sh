#!/usr/bin/env bash
set -euo pipefail
KIT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUTPUT_DIR="${1:-$KIT_DIR/dist}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(CDPATH= cd -- "$OUTPUT_DIR" && pwd)"
STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT
mkdir "$STAGING_DIR/remote-dev"
# Explicit allowlist: never package local configuration, credentials or runtime state.
for item in dev.sh setup.sh lib/ui.sh lib/compose_remote.py config/dev.env.example config/required-endpoints.conf README.md README.RU.md; do
  mkdir -p "$STAGING_DIR/remote-dev/$(dirname "$item")"
  cp "$KIT_DIR/$item" "$STAGING_DIR/remote-dev/$item"
done
printf 'config/dev.env\n.runtime/\n__pycache__/\n' > "$STAGING_DIR/remote-dev/.gitignore"
chmod +x "$STAGING_DIR/remote-dev/dev.sh" "$STAGING_DIR/remote-dev/setup.sh"
COPYFILE_DISABLE=1 tar -czf "$OUTPUT_DIR/remote-dev.tar.gz" -C "$STAGING_DIR" remote-dev
printf 'Created %s/remote-dev.tar.gz\n' "$OUTPUT_DIR"
