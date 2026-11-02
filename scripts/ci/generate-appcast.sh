#!/bin/bash
set -euo pipefail

: "${SPARKLE_KEY:?SPARKLE_KEY is required}"
: "${VERSION:?VERSION is required}"
: "${BUILD_NUMBER:?BUILD_NUMBER is required}"
if [[ ! "$VERSION" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: only stable semver releases can publish the update feed" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPARKLE_BIN="${SPARKLE_BIN:-output/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin}"
APP_PATH="${APP_PATH:-output/output.xcarchive/Products/Applications/Lumik.app}"
ARCHIVE="${ARCHIVE:-Lumik.dmg}"
PAGES_DIR="${PAGES_DIR:-output/pages}"
DOWNLOAD_PREFIX="https://update.lumik.dev/$VERSION/"
mkdir -p "$PAGES_DIR"

# Work in an isolated directory so CI leftovers cannot leak into the feed.
WORK_DIR=$(mktemp -d "${RUNNER_TEMP:-/tmp}/summary-appcast.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT
cp "$ARCHIVE" "$WORK_DIR/Lumik.dmg"
printf '%s' "${RELEASE_NOTE:-}" > "$WORK_DIR/notes.txt"
python3 - "$WORK_DIR" <<'PY'
import pathlib, sys
import markdown
p = pathlib.Path(sys.argv[1])
# GitHub release bodies are Markdown; Sparkle's release notes view renders HTML.
notes = markdown.markdown((p / "notes.txt").read_text(), extensions=["extra", "sane_lists"])
style = """
:root { color-scheme: light dark; }
body { font: 13px -apple-system, BlinkMacSystemFont, sans-serif; line-height: 1.5; margin: 12px 16px; }
h1 { font-size: 1.3em; } h2, h3 { font-size: 1.1em; margin-top: 1.2em; }
a { color: -apple-system-control-accent; text-decoration: none; }
ul { padding-left: 1.4em; } li { margin: 0.2em 0; }
code { font: 12px ui-monospace, Menlo, monospace; }
"""
(p / "Lumik.html").write_text('<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>Lumik release notes</title><style>' + style + '</style></head><body>' + notes + '</body></html>')
PY

# Pass the signing key over stdin; never put it in argv or in published artifacts.
printf '%s' "$SPARKLE_KEY" | "$SPARKLE_BIN/generate_appcast" "$WORK_DIR" \
  --ed-key-file - --maximum-deltas 0 \
  --link "https://github.com/rxtech-lab/lumik/releases/tag/$VERSION" \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  --release-notes-url-prefix "https://update.lumik.dev/"

python3 "$SCRIPT_DIR/validate-appcast.py" "$WORK_DIR/appcast.xml" "$ARCHIVE" \
  "$APP_PATH/Contents/Info.plist" "$DOWNLOAD_PREFIX"
cp "$WORK_DIR/appcast.xml" "$WORK_DIR/Lumik.html" "$PAGES_DIR/"
printf '%s\n' 'update.lumik.dev' > "$PAGES_DIR/CNAME"
touch "$PAGES_DIR/.nojekyll"

mkdir -p "$PAGES_DIR/$VERSION"
cp "$ARCHIVE" "$PAGES_DIR/$VERSION/Lumik.dmg"
