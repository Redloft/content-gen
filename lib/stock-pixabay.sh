#!/usr/bin/env bash
# Pixabay stock search — uses $PIXABAY_API_KEY from environment
# Usage: stock-pixabay.sh <query> <output_dir> [image_type]
set -euo pipefail

QUERY="$1"
OUTDIR="$2"
TYPE="${3:-all}"
mkdir -p "$OUTDIR"

ENCQ=$(printf '%s' "$QUERY" | jq -sRr @uri)
RESP=$(curl --silent --max-time 15 \
  "https://pixabay.com/api/?key=$PIXABAY_API_KEY&q=$ENCQ&per_page=3&orientation=horizontal&image_type=$TYPE&safesearch=true")

COUNT=$(echo "$RESP" | jq '.hits | length // 0')
if [ "$COUNT" = '0' ]; then
  echo "$RESP" | head -c 300 > "$OUTDIR/pixabay.error.txt"
  echo "✗ pixabay: no results"
  exit 0
fi

i=1
echo "$RESP" | jq -r '.hits[] | "\(.webformatURL)\t\(.user)\t\(.pageURL)"' | while IFS=$'\t' read -r url author link; do
  curl --silent --max-time 30 -o "$OUTDIR/pixabay-$i.jpg" "$url"
  echo "$author | $link" > "$OUTDIR/pixabay-$i.meta.txt"
  i=$((i+1))
done
echo "✓ pixabay (3 results, type=$TYPE)"
