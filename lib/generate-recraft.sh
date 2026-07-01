#!/usr/bin/env bash
# Recraft v3 — uses $RECRAFT_API_KEY from environment (no op run here)
# Usage: generate-recraft.sh <prompt> <output_dir> [style]
set -euo pipefail

PROMPT="$1"
OUTDIR="$2"
STYLE="${3:-digital_illustration}"

mkdir -p "$OUTDIR"

RESP=$(curl --silent --max-time 60 -X POST "https://external.api.recraft.ai/v1/images/generations" \
  -H "Authorization: Bearer $RECRAFT_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg p "$PROMPT" --arg s "$STYLE" '{prompt: $p, style: $s, size: "1024x1024", n: 1}')")
URL=$(echo "$RESP" | jq -r '.data[0].url // empty')

if [ -n "$URL" ]; then
  curl --silent --max-time 30 -o "$OUTDIR/recraft.png" "$URL"
  echo "✓ recraft.png"
else
  echo "$RESP" | head -c 300 > "$OUTDIR/recraft.error.txt"
  echo "✗ recraft"
fi
