#!/bin/bash
# One accuracy number for Freshflo, tracked across releases.
#   ./scripts/accuracy.sh            runs every suite on the installed app (about 15 minutes)
# Suites: everyday dictation, grammar, Hindi/Hinglish → English, 25 other languages ↔ English (text, after speech recognition),
# and spoken clips in 18 languages (speech recognition + clean-up, with word error rate).
# Writes Benchmarks/SCORECARD.md and adds a row to Benchmarks/history.csv.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=/Applications/Freshflo.app/Contents/MacOS/Freshflo
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
for suite in everyday grammar translate multilang; do
  echo "→ $suite…"
  "$APP" --grammar-eval "Benchmarks/$suite.json" --pace 2000 --verbose > "$OUT/$suite.txt" 2>&1 || true
  grep -E "^GRAMMAR|^engines" "$OUT/$suite.txt" || echo "  (no result)"
done
echo "→ audio…"
"$APP" --benchmark Benchmarks > "$OUT/audio.txt" 2>&1 || true
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" /Applications/Freshflo.app/Contents/Info.plist)
python3 -I scripts/scorecard.py "$OUT" "$VERSION"
