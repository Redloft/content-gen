#!/usr/bin/env bash
# Unsplash stock search — uses $UNSPLASH_ACCESS_KEY from environment
# Usage: stock-unsplash.sh <query> <output_dir>
set -euo pipefail

QUERY="$1"
OUTDIR="$2"
mkdir -p "$OUTDIR"

ENCQ=$(printf '%s' "$QUERY" | jq -sRr @uri)
RESP=$(curl --silent --max-time 15 \
  "https://api.unsplash.com/search/photos?query=$ENCQ&per_page=3&orientation=landscape" \
  -H "Authorization: Client-ID $UNSPLASH_ACCESS_KEY")

COUNT=$(echo "$RESP" | jq '.results | length // 0')
if [ "$COUNT" = '0' ]; then
  echo "$RESP" | head -c 300 > "$OUTDIR/unsplash.error.txt"
  echo "✗ unsplash: no results"
  exit 0
fi

i=1
echo "$RESP" | jq -r '.results[] | "\(.urls.regular)\t\(.user.name)\t\(.links.html)"' | while IFS=$'\t' read -r url author link; do
  curl --silent --max-time 30 -o "$OUTDIR/unsplash-$i.jpg" "$url"
  echo "$author | $link" > "$OUTDIR/unsplash-$i.meta.txt"
  i=$((i+1))
done
echo "✓ unsplash (3 photos)"
