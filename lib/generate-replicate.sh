#!/usr/bin/env bash
# Replicate Flux schnell — uses $REPLICATE_API_TOKEN from environment
# Usage: generate-replicate.sh <prompt> <output_dir>
set -euo pipefail

PROMPT="$1"
OUTDIR="$2"
mkdir -p "$OUTDIR"

RESP=$(curl --silent --max-time 30 -X POST "https://api.replicate.com/v1/models/black-forest-labs/flux-schnell/predictions" \
  -H "Authorization: Token $REPLICATE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -H "Prefer: wait=60" \
  -d "$(jq -n --arg p "$PROMPT" '{input: {prompt: $p, num_outputs: 1, aspect_ratio: "1:1", output_format: "png"}}')")

URL=$(echo "$RESP" | jq -r '.output[0]? // empty')
STATUS=$(echo "$RESP" | jq -r '.status // empty')
GET_URL=$(echo "$RESP" | jq -r '.urls.get // empty')

# Poll if still processing
for i in 1 2 3 4 5 6 7 8 9 10; do
  [ -n "$URL" ] && [ "$URL" != 'null' ] && break
  [ "$STATUS" = 'failed' ] && break
  [ -z "$GET_URL" ] && break
  sleep 3
  POLL=$(curl --silent --max-time 10 -H "Authorization: Token $REPLICATE_API_TOKEN" "$GET_URL")
  URL=$(echo "$POLL" | jq -r '.output[0]? // empty')
  STATUS=$(echo "$POLL" | jq -r '.status // empty')
done

if [ -n "$URL" ] && [ "$URL" != 'null' ]; then
  curl --silent --max-time 30 -o "$OUTDIR/replicate-flux.png" "$URL"
  echo "✓ replicate-flux.png"
else
  { echo "status=$STATUS"; echo "$RESP" | head -c 300; } > "$OUTDIR/replicate-flux.error.txt"
  echo "✗ replicate-flux"
fi
