#!/usr/bin/env bash
# Imagen 4 — uses $GEMINI_API_KEY from environment
# Usage: generate-imagen.sh <prompt> <output_dir>
set -euo pipefail

PROMPT="$1"
OUTDIR="$2"
mkdir -p "$OUTDIR"

RESP=$(curl --silent --max-time 90 -X POST \
  "https://generativelanguage.googleapis.com/v1beta/models/imagen-4.0-generate-001:predict?key=$GEMINI_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg p "$PROMPT" '{instances: [{prompt: $p}], parameters: {sampleCount: 1, aspectRatio: "1:1"}}')")
B64=$(echo "$RESP" | jq -r '.predictions[0].bytesBase64Encoded // empty')

if [ -n "$B64" ] && [ "$B64" != "null" ]; then
  echo "$B64" | base64 -d > "$OUTDIR/imagen.png"
  echo "✓ imagen.png"
else
  echo "$RESP" | head -c 300 > "$OUTDIR/imagen.error.txt"
  echo "✗ imagen"
fi
