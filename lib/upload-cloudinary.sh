#!/usr/bin/env bash
# Cloudinary signed upload — uses $CLOUDINARY_{CLOUD_NAME,API_KEY,API_SECRET} from environment
# Usage: upload-cloudinary.sh <file_path> [folder]
set -euo pipefail

FILE="$1"
FOLDER="${2:-content-gen/$(date +%Y-%m)}"

if [ ! -f "$FILE" ]; then
  echo "✗ file not found: $FILE"; exit 1
fi

# Если env vars не выставлены (вызов вне op run) — обернись сам в op run
if [ -z "${CLOUDINARY_API_SECRET:-}" ]; then
  LIBDIR="$(cd "$(dirname "$0")" && pwd)"
  exec op run --env-file="$LIBDIR/all-secrets.env" -- bash "$0" "$@"
fi

BASE=$(basename "$FILE")
RAW="${BASE%.*}"
SLUG=$(python3 -c "
import sys, re
T = {'а':'a','б':'b','в':'v','г':'g','д':'d','е':'e','ё':'yo','ж':'zh','з':'z','и':'i','й':'y','к':'k','л':'l','м':'m','н':'n','о':'o','п':'p','р':'r','с':'s','т':'t','у':'u','ф':'f','х':'kh','ц':'ts','ч':'ch','ш':'sh','щ':'sch','ъ':'','ы':'y','ь':'','э':'e','ю':'yu','я':'ya'}
s = sys.argv[1].lower()
s = ''.join(T.get(c, c) for c in s)
s = re.sub(r'[^a-z0-9]+', '-', s).strip('-')
print(s or 'image')
" "$RAW")
NAME="${SLUG}-$(date +%s)"
TS=$(date +%s)

# Build signature (alphabetical params + secret)
PARAMS_STR="folder=$FOLDER&public_id=$NAME&timestamp=$TS"
SIG=$(printf '%s' "${PARAMS_STR}${CLOUDINARY_API_SECRET}" | shasum -a 1 | awk '{print $1}')

RESP=$(curl --silent --max-time 60 -X POST \
  "https://api.cloudinary.com/v1_1/$CLOUDINARY_CLOUD_NAME/image/upload" \
  -F "file=@$FILE" \
  -F "api_key=$CLOUDINARY_API_KEY" \
  -F "timestamp=$TS" \
  -F "folder=$FOLDER" \
  -F "public_id=$NAME" \
  -F "signature=$SIG")

echo "$RESP" | jq -r 'if .secure_url then
  "✅ uploaded\n  url: \(.secure_url)\n  public_id: \(.public_id)\n  format: \(.format)  size: \(.bytes / 1024 | floor)KB  dims: \(.width)x\(.height)\n  webp:  \(.secure_url | sub("/upload/"; "/upload/f_webp,q_auto/"))\n  thumb: \(.secure_url | sub("/upload/"; "/upload/c_thumb,w_400,f_webp,q_auto/"))"
else
  "✗ " + (.error.message // tostring)
end'
