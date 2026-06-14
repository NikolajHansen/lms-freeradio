#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="0.1.0"
OUT="$ROOT/lms-freeradio-${VERSION}.zip"

cd "$ROOT"
rm -f "$OUT"

# Copy install.xml into Plugins/FreeRadio/ for correct ZIP structure
cp install.xml Plugins/FreeRadio/install.xml

# Create ZIP with Plugins at root (LMS will extract to InstalledPlugins/Plugins/)
zip -rq "$OUT" Plugins/FreeRadio README.md

# Clean up
rm Plugins/FreeRadio/install.xml

echo "Created: $OUT"
