#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="0.1.0"
OUT="$ROOT/lms-freeradio-${VERSION}.zip"

cd "$ROOT"
rm -f "$OUT"
zip -rq "$OUT" install.xml Plugins README.md

echo "Created: $OUT"
