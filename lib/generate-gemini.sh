#!/usr/bin/env bash
# Gemini Nano Banana — uses $GEMINI_API_KEY from environment
# Usage: generate-gemini.sh <prompt> <output_dir>
set -euo pipefail

PROMPT="$1"
OUTDIR="$2"
mkdir -p "$OUTDIR"

RESP=$(curl --silent --max-time 60 -X POST \
  "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-image:generateContent?key=$GEMINI_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg p "$PROMPT" '{contents: [{parts: [{text: $p}]}]}')")
B64=$(echo "$RESP" | jq -r '.candidates[0].content.parts[]? | select(.inlineData.data?) | .inlineData.data' | head -1)

if [ -n "$B64" ] && [ "$B64" != "null" ]; then
  echo "$B64" | base64 -d > "$OUTDIR/gemini-nano-banana.png"
  echo "✓ gemini-nano-banana.png"
else
  echo "$RESP" | head -c 300 > "$OUTDIR/gemini-nano-banana.error.txt"
  echo "✗ gemini-nano-banana"
fi
