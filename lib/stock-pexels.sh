#!/usr/bin/env bash
# Pexels stock search — uses $PEXELS_API_KEY from environment
# Usage: stock-pexels.sh <query> <output_dir>
set -euo pipefail

QUERY="$1"
OUTDIR="$2"
mkdir -p "$OUTDIR"

ENCQ=$(printf '%s' "$QUERY" | jq -sRr @uri)
RESP=$(curl --silent --max-time 15 \
  "https://api.pexels.com/v1/search?query=$ENCQ&per_page=3&orientation=landscape" \
  -H "Authorization: $PEXELS_API_KEY")

COUNT=$(echo "$RESP" | jq '.photos | length // 0')
if [ "$COUNT" = '0' ]; then
  echo "$RESP" | head -c 300 > "$OUTDIR/pexels.error.txt"
  echo "✗ pexels: no results"
  exit 0
fi

i=1
echo "$RESP" | jq -r '.photos[] | "\(.src.large)\t\(.photographer)\t\(.url)"' | while IFS=$'\t' read -r url author link; do
  curl --silent --max-time 30 -o "$OUTDIR/pexels-$i.jpg" "$url"
  echo "$author | $link" > "$OUTDIR/pexels-$i.meta.txt"
  i=$((i+1))
done
echo "✓ pexels (3 photos)"
