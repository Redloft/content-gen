#!/usr/bin/env bash
# Cloudinary signed VIDEO upload — uses $CLOUDINARY_{CLOUD_NAME,API_KEY,API_SECRET}
# Usage:
#   upload-cloudinary-video.sh <local-file-or-url> [folder]
#
# Поддерживает:
#   - локальный путь: /path/to/video.mp4
#   - URL: https://example.com/video.mp4 (Cloudinary сам скачает — fetch upload)
set -euo pipefail

INPUT="$1"
FOLDER="${2:-content-gen/videos/$(date +%Y-%m)}"

# Self-wrap into op run если env не выставлен
if [ -z "${CLOUDINARY_API_SECRET:-}" ]; then
  LIBDIR="$(cd "$(dirname "$0")" && pwd)"
  exec op run --env-file="$LIBDIR/all-secrets.env" -- bash "$0" "$@"
fi

# Определи URL vs file
IS_URL=false
case "$INPUT" in
  http://*|https://*) IS_URL=true ;;
esac

if [ "$IS_URL" = false ] && [ ! -f "$INPUT" ]; then
  echo "✗ file not found: $INPUT"; exit 1
fi

# Public ID — basename без extension, транслит кириллицы, плюс timestamp
if [ "$IS_URL" = true ]; then
  BASE=$(basename "${INPUT%%\?*}")
else
  BASE=$(basename "$INPUT")
fi
RAW="${BASE%.*}"
# Transliterate Cyrillic → latin, lowercase, replace non-alnum with `-`
SLUG=$(python3 -c "
import sys, re
T = {'а':'a','б':'b','в':'v','г':'g','д':'d','е':'e','ё':'yo','ж':'zh','з':'z','и':'i','й':'y','к':'k','л':'l','м':'m','н':'n','о':'o','п':'p','р':'r','с':'s','т':'t','у':'u','ф':'f','х':'kh','ц':'ts','ч':'ch','ш':'sh','щ':'sch','ъ':'','ы':'y','ь':'','э':'e','ю':'yu','я':'ya'}
s = sys.argv[1].lower()
s = ''.join(T.get(c, c) for c in s)
s = re.sub(r'[^a-z0-9]+', '-', s).strip('-')
print(s or 'video')
" "$RAW")
NAME="${SLUG}-$(date +%s)"
TS=$(date +%s)

# Подпись: алфавитно отсортированные params + secret (SHA1)
PARAMS_STR="folder=$FOLDER&public_id=$NAME&timestamp=$TS"
SIG=$(printf '%s' "${PARAMS_STR}${CLOUDINARY_API_SECRET}" | shasum -a 1 | awk '{print $1}')

echo "→ uploading to Cloudinary (folder: $FOLDER, public_id: $NAME)..."
if [ "$IS_URL" = true ]; then
  # Remote fetch — Cloudinary сам скачает по URL
  RESP=$(curl --silent --max-time 300 -X POST \
    "https://api.cloudinary.com/v1_1/$CLOUDINARY_CLOUD_NAME/video/upload" \
    -F "file=$INPUT" \
    -F "api_key=$CLOUDINARY_API_KEY" \
    -F "timestamp=$TS" \
    -F "folder=$FOLDER" \
    -F "public_id=$NAME" \
    -F "signature=$SIG")
else
  # Local file upload (multipart)
  RESP=$(curl --silent --max-time 600 -X POST \
    "https://api.cloudinary.com/v1_1/$CLOUDINARY_CLOUD_NAME/video/upload" \
    -F "file=@$INPUT" \
    -F "api_key=$CLOUDINARY_API_KEY" \
    -F "timestamp=$TS" \
    -F "folder=$FOLDER" \
    -F "public_id=$NAME" \
    -F "signature=$SIG")
fi

echo "$RESP" | jq -r '
if .secure_url then
  . as $r |
  ($r.format) as $ext |
  ($r.secure_url) as $u |
  ($u | sub("/upload/"; "/upload/ac_none,q_auto,f_auto/")) as $silent |
  ($u | sub("/upload/"; "/upload/w_1280,h_720,c_fit,so_1,q_auto/") | sub("\\."+$ext+"$"; ".jpg")) as $poster |
  "✅ uploaded\n"
  + "  url:         \($u)\n"
  + "  public_id:   \($r.public_id)\n"
  + "  format:      \($ext)\n"
  + "  size:        \($r.bytes / 1024 / 1024 * 100 | floor / 100) MB\n"
  + "  dims:        \($r.width)x\($r.height)\n"
  + (if $r.duration then "  duration:    \($r.duration | tostring) s\n" else "" end)
  + "\n— Derivatives (on-the-fly) —\n"
  + "  auto (full):    \($u | sub("/upload/"; "/upload/q_auto,f_auto/"))\n"
  + "  🔇 silent+auto:  \($silent)\n"
  + "  720p H.264:     \($u | sub("/upload/"; "/upload/w_1280,h_720,c_limit,q_auto,vc_h264/"))\n"
  + "  webm:           \($u | sub("/upload/"; "/upload/q_auto,f_webm/"))\n"
  + "  poster JPG:     \($poster)\n"
  + "  GIF preview:    \($u | sub("/upload/"; "/upload/w_480,c_fit,so_0,du_3,fl_animated,e_loop/") | sub("\\."+$ext+"$"; ".gif"))\n"
  + "\n— Landing-ready HTML (autoplay + muted + loop, без controls) —\n"
  + "  <video autoplay muted loop playsinline poster=\"\($poster)\">\n"
  + "    <source src=\"\($silent)\" type=\"video/mp4\" />\n"
  + "  </video>"
else
  "✗ upload failed:\n"
  + (.error.message // tostring)
end'
