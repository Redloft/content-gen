#!/usr/bin/env bash
# OpenAI gpt-image-1 — uses $OPENAI_API_KEY from environment
# Usage: generate-openai.sh <prompt> <output_dir>
set -euo pipefail

PROMPT="$1"
OUTDIR="$2"
mkdir -p "$OUTDIR"

RESP=$(curl --silent --max-time 120 -X POST "https://api.openai.com/v1/images/generations" \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg p "$PROMPT" '{model: "gpt-image-1", prompt: $p, n: 1, size: "1024x1024", quality: "medium"}')")
B64=$(echo "$RESP" | jq -r '.data[0].b64_json // empty')

if [ -n "$B64" ] && [ "$B64" != "null" ]; then
  echo "$B64" | base64 -d > "$OUTDIR/openai.png"
  echo "✓ openai.png"
else
  echo "$RESP" | head -c 300 > "$OUTDIR/openai.error.txt"
  echo "✗ openai"
fi
