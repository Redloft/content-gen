#!/usr/bin/env bash
# Cloudinary list resources — показывает что залито в folder/prefix
# Usage:
#   list-cloudinary.sh                       — последние 50 (видео+картинки)
#   list-cloudinary.sh content-gen/batch     — всё с этим префиксом
#   list-cloudinary.sh ... --type video      — только видео
#   list-cloudinary.sh ... --max 200         — больше результатов
#   list-cloudinary.sh ... --json            — raw JSON (для скриптов)
set -uo pipefail

PREFIX="${1:-}"
TYPE="all"   # image | video | all
MAX=50
JSON=false

# Skip the prefix arg, parse flags
shift_args=0
[ -n "$PREFIX" ] && case "$PREFIX" in
  --*) PREFIX=""; ;;
  *) shift_args=1 ;;
esac
[ $shift_args -eq 1 ] && shift

while [ $# -gt 0 ]; do
  case "$1" in
    --type) TYPE="$2"; shift 2 ;;
    --max)  MAX="$2"; shift 2 ;;
    --json) JSON=true; shift ;;
    *) echo "unknown flag: $1"; exit 1 ;;
  esac
done

# Self-wrap into op run
if [ -z "${CLOUDINARY_API_SECRET:-}" ]; then
  LIBDIR="$(cd "$(dirname "$0")" && pwd)"
  exec op run --env-file="$LIBDIR/all-secrets.env" -- bash "$0" "$@"
fi

fetch() {
  local rtype="$1"
  local url="https://api.cloudinary.com/v1_1/$CLOUDINARY_CLOUD_NAME/resources/$rtype"
  curl --silent --max-time 30 -u "$CLOUDINARY_API_KEY:$CLOUDINARY_API_SECRET" \
    --get \
    --data-urlencode "max_results=$MAX" \
    ${PREFIX:+--data-urlencode "prefix=$PREFIX"} \
    "$url"
}

RESULTS="[]"
if [ "$TYPE" = "all" ] || [ "$TYPE" = "image" ]; then
  IMG=$(fetch image)
  RESULTS=$(echo "$RESULTS" "$IMG" | jq -s '.[0] + (.[1].resources // [])')
fi
if [ "$TYPE" = "all" ] || [ "$TYPE" = "video" ]; then
  VID=$(fetch video)
  RESULTS=$(echo "$RESULTS" "$VID" | jq -s '.[0] + (.[1].resources // [])')
fi

if [ "$JSON" = true ]; then
  echo "$RESULTS"
  exit 0
fi

COUNT=$(echo "$RESULTS" | jq 'length')
if [ "$COUNT" = "0" ]; then
  echo "No resources found${PREFIX:+ matching prefix \"$PREFIX\"}"
  exit 0
fi

echo "═══════════════════════════════════════════════════════════════"
echo "Cloudinary resources${PREFIX:+ matching \"$PREFIX\"}"
echo "═══════════════════════════════════════════════════════════════"
echo

# Сортировка: по created_at desc
echo "$RESULTS" | jq -r 'sort_by(.created_at) | reverse | .[] |
  "\(.resource_type | .[0:1] | ascii_upcase) | \(.public_id) | \(.format) | \(.bytes / 1024 | floor)KB | \(.width // "")x\(.height // "") | \(.created_at[0:10])"
' | awk -F' \\| ' '
  BEGIN {
    printf "%-4s  %-60s  %-7s  %-9s  %-12s  %s\n", "T", "PUBLIC_ID", "FORMAT", "SIZE", "DIMS", "CREATED"
    printf "%s\n", "──────────────────────────────────────────────────────────────────────────────────────────────────────────"
  }
  { printf "%-4s  %-60s  %-7s  %-9s  %-12s  %s\n", $1, $2, $3, $4, $5, $6 }
'

# Totals
TOTAL_BYTES=$(echo "$RESULTS" | jq 'map(.bytes) | add')
TOTAL_MB=$(awk "BEGIN{printf \"%.2f\", $TOTAL_BYTES/1024/1024}")
IMG_CNT=$(echo "$RESULTS" | jq '[.[] | select(.resource_type=="image")] | length')
VID_CNT=$(echo "$RESULTS" | jq '[.[] | select(.resource_type=="video")] | length')

echo
echo "Total: $COUNT  ($IMG_CNT image / $VID_CNT video)  ·  $TOTAL_MB MB"
echo
echo "💡 Удалить: ~/.claude/skills/content-gen/lib/delete-cloudinary.sh <public_id-or-prefix>"
