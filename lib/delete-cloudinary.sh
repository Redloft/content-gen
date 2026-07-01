#!/usr/bin/env bash
# Cloudinary delete — удаляет ресурс(ы) по public_id или prefix.
# Usage:
#   delete-cloudinary.sh <public_id>                     — один ресурс (image, авто)
#   delete-cloudinary.sh <public_id> --type video        — конкретный тип
#   delete-cloudinary.sh content-gen/batch/old/ --prefix — удалить всё с префиксом
#   delete-cloudinary.sh ... --yes                        — без подтверждения
#
# По умолчанию: ИНТЕРАКТИВНОЕ подтверждение перед удалением.
set -uo pipefail

TARGET="${1:?usage: delete-cloudinary.sh <public_id-or-prefix> [--type image|video] [--prefix] [--yes]}"
shift || true

TYPE=""       # image | video | "" (try both)
PREFIX=false
YES=false

while [ $# -gt 0 ]; do
  case "$1" in
    --type) TYPE="$2"; shift 2 ;;
    --prefix) PREFIX=true; shift ;;
    --yes|-y) YES=true; shift ;;
    *) echo "unknown: $1"; exit 1 ;;
  esac
done

if [ -z "${CLOUDINARY_API_SECRET:-}" ]; then
  LIBDIR="$(cd "$(dirname "$0")" && pwd)"
  exec op run --env-file="$LIBDIR/all-secrets.env" -- bash "$0" "$TARGET" "$@"
fi

# Backup log — на случай если удалил по ошибке (для re-upload reference)
TS=$(date +%s)
BACKUP_LOG="/tmp/cloudinary-deleted-${TS}.log"

# Если type не указан — попробуем оба ресурса
TYPES_TO_TRY=()
if [ -n "$TYPE" ]; then
  TYPES_TO_TRY=("$TYPE")
else
  TYPES_TO_TRY=("image" "video")
fi

# Dry-run: посмотрим что собираемся удалять
echo "🔍 Lookup before delete..."
TO_DELETE="[]"
for T in "${TYPES_TO_TRY[@]}"; do
  if [ "$PREFIX" = true ]; then
    LIST=$(curl --silent --max-time 30 -u "$CLOUDINARY_API_KEY:$CLOUDINARY_API_SECRET" \
      --get --data-urlencode "prefix=$TARGET" --data-urlencode "max_results=500" \
      "https://api.cloudinary.com/v1_1/$CLOUDINARY_CLOUD_NAME/resources/$T" \
      | jq -c '.resources // []')
  else
    LIST=$(curl --silent --max-time 30 -u "$CLOUDINARY_API_KEY:$CLOUDINARY_API_SECRET" \
      "https://api.cloudinary.com/v1_1/$CLOUDINARY_CLOUD_NAME/resources/$T/upload/$TARGET" \
      | jq -c 'if .error then [] else [.] end')
  fi
  TO_DELETE=$(echo "$TO_DELETE" "$LIST" | jq -s 'add')
done

COUNT=$(echo "$TO_DELETE" | jq 'length')
if [ "$COUNT" = "0" ]; then
  echo "✗ Nothing found matching: $TARGET"
  echo "  (попробуй --prefix если это folder)"
  exit 1
fi

# Show summary
echo "$TO_DELETE" | jq -r '.[] | "  \(.resource_type | .[0:1] | ascii_upcase)  \(.public_id)  \(.bytes / 1024 | floor)KB"'
TOTAL_MB=$(echo "$TO_DELETE" | jq 'map(.bytes) | add / 1024 / 1024' | awk '{printf "%.2f", $1}')
echo
echo "⚠️  Will delete $COUNT resources (~$TOTAL_MB MB)"
echo "    Backup metadata: $BACKUP_LOG"

# Confirmation
if [ "$YES" != true ]; then
  printf "\nProceed? Type 'yes' to confirm: "
  read -r REPLY
  if [ "$REPLY" != "yes" ]; then
    echo "Cancelled."
    exit 0
  fi
fi

# Save backup
echo "$TO_DELETE" | jq '.' > "$BACKUP_LOG"

# Group by resource_type
for T in image video; do
  IDS=$(echo "$TO_DELETE" | jq -r ".[] | select(.resource_type==\"$T\") | .public_id")
  [ -z "$IDS" ] && continue

  echo
  echo "→ Deleting $T resources..."
  # Cloudinary DELETE accepts public_ids as multiple form params
  ARGS=()
  while IFS= read -r ID; do
    [ -z "$ID" ] && continue
    ARGS+=(-d "public_ids[]=$ID")
  done <<< "$IDS"

  RESP=$(curl --silent --max-time 60 -X DELETE \
    -u "$CLOUDINARY_API_KEY:$CLOUDINARY_API_SECRET" \
    "${ARGS[@]}" \
    "https://api.cloudinary.com/v1_1/$CLOUDINARY_CLOUD_NAME/resources/$T/upload")

  echo "$RESP" | jq -r '
    if .deleted then
      .deleted | to_entries[] | "  \(if .value == "deleted" then "✅" else "✗" end) \(.key) (\(.value))"
    elif .error then
      "  ✗ ERROR: \(.error.message)"
    else
      "  ✗ unexpected response"
    end'
done

echo
echo "Backup log: $BACKUP_LOG"
