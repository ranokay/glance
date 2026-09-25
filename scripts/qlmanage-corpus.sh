#!/bin/sh
# Scripted Quick Look corpus: real extension path over the fixture corpus.
# Fuzzy gate — fails on missing output or crashes, never on pixel drift.
# Registers the BUILT appex (no install, no system-app removal) and unregisters on exit.
# Each file gets a bounded watchdog; hangs count as failures.
# Usage: sh scripts/qlmanage-corpus.sh [appex-path] [fixtures-dir] [size] [per-file-seconds]
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APPEX=${1:-"$ROOT/build/Build/Products/Release/Glance.app/Contents/PlugIns/QLPlugin.appex"}
FIXTURES=${2:-"$ROOT/GlanceTests/TestFiles"}
SIZE=${3:-512}
BUDGET=${4:-60}
if [ ! -d "$APPEX" ]; then
	echo "FAIL: appex not found at $APPEX (build first)" >&2
	exit 1
fi
OUT=$(mktemp -d)
trap 'pluginkit -r "$APPEX" >/dev/null 2>&1 || true; rm -rf "$OUT"' EXIT
pluginkit -a "$APPEX" >/dev/null 2>&1 || true
pass=0
fail=0
failed_files=""
total=0
for f in $(find "$FIXTURES" -type f ! -name ".DS_Store" ! -name "*.b64" | sort); do
	total=$((total + 1))
	name=$(basename "$f")
	rm -f "$OUT/$name.png"
	qlmanage -t -s "$SIZE" -o "$OUT" "$f" >/dev/null 2>&1 & qp=$!
	(sleep "$BUDGET" && kill -9 $qp 2>/dev/null) & wk=$!
	wait $qp 2>/dev/null || true
	kill $wk 2>/dev/null || true
	wait 2>/dev/null || true
	png="$OUT/$name.png"
	if [ -s "$png" ] && sips -g pixelWidth "$png" >/dev/null 2>&1; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		failed_files="$failed_files $f"
	fi
done
echo "corpus: $pass passed, $fail failed over $total fixtures"
if [ "$fail" -ne 0 ]; then
	echo "FAIL: missing, crashing, or hanging thumbnails for:$failed_files" >&2
	exit 1
fi
