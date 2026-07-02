#!/usr/bin/env bash
# Download a file from a Download-Monitor (DLM) protected link.
# Usage: dlm-download.sh <download_url> <referer> <out_file>
set -euo pipefail
export LC_ALL=C
URL="$1"; REF="$2"; OUT="$3"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
JAR="$(mktemp)"
STEP1="$(curl -sL -A "$UA" -e "$REF" -b "$JAR" -c "$JAR" "$URL?tmstv=$(date +%s)")"
NEXT="$(printf '%s' "$STEP1" | grep -aoE 'url=https://[^"]+' | head -1 | sed 's/^url=//; s/&amp;/\&/g')"
if [ -z "$NEXT" ]; then echo "no meta-refresh found; page saved to $OUT.html"; printf '%s' "$STEP1" > "$OUT.html"; exit 1; fi
echo "following: $NEXT"
sleep 5
curl -sL -D "$OUT.headers" --max-time 300 -A "$UA" -e "$URL" -b "$JAR" -c "$JAR" -o "$OUT" "$NEXT"
file "$OUT"; ls -la "$OUT"
