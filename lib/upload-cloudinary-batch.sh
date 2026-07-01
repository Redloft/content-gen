#!/usr/bin/env bash
# Batch upload папки в Cloudinary — авто-сортировка по типу (image vs video)
# Usage:
#   upload-cloudinary-batch.sh <folder> [target-folder] [--recursive]
#
# По умолчанию: top-level only, target-folder = content-gen/batch/<basename>-<date>
# С --recursive: обходит все подпапки (sub-folders передаются в Cloudinary как nested folders)
set -uo pipefail

SRC="${1:?usage: upload-cloudinary-batch.sh <folder> [target-folder] [--recursive]}"
TARGET="${2:-}"
RECURSIVE=false
for arg in "$@"; do
  [ "$arg" = "--recursive" ] && RECURSIVE=true
done

if [ ! -d "$SRC" ]; then
  echo "✗ not a directory: $SRC"; exit 1
fi

# Self-wrap into op run если env не выставлен (один Touch ID на весь batch)
if [ -z "${CLOUDINARY_API_SECRET:-}" ]; then
  LIBDIR="$(cd "$(dirname "$0")" && pwd)"
  exec op run --env-file="$LIBDIR/all-secrets.env" -- bash "$0" "$@"
fi

LIBDIR="$(cd "$(dirname "$0")" && pwd)"
SRC_ABS=$(cd "$SRC" && pwd)
BASE=$(basename "$SRC_ABS")
DATE=$(date +%Y-%m-%d)
[ -z "$TARGET" ] && TARGET="content-gen/batch/${BASE}-${DATE}"

# Расширения
IMG_EXTS='jpg|jpeg|png|webp|heic|gif|svg|avif|tiff|tif|bmp'
VID_EXTS='mp4|mov|webm|mkv|avi|m4v|m2v|m4p|mpg|mpeg'

# Find files
if [ "$RECURSIVE" = true ]; then
  FILES=$(find "$SRC_ABS" -type f -iregex ".*\.\($IMG_EXTS\|$VID_EXTS\)$" | sort)
else
  FILES=$(find "$SRC_ABS" -maxdepth 1 -type f -iregex ".*\.\($IMG_EXTS\|$VID_EXTS\)$" | sort)
fi

TOTAL_FILES=$(echo "$FILES" | grep -c . || true)
if [ "$TOTAL_FILES" = "0" ]; then
  echo "✗ no image/video files found in $SRC_ABS"; exit 1
fi

# Summary header
echo "═══════════════════════════════════════════════════════════════"
echo "Batch upload: $SRC_ABS"
echo "Target folder: $TARGET"
echo "Files found: $TOTAL_FILES  (recursive=$RECURSIVE)"
echo "═══════════════════════════════════════════════════════════════"
echo

# Results log (для HTML preview)
TS=$(date +%s)
LOG="/tmp/cloudinary-batch-${TS}.log"
HTML="/tmp/cloudinary-batch-${TS}.html"
: > "$LOG"

START=$(date +%s)
OK=0; FAIL=0; SKIP=0
IMG_OK=0; VID_OK=0

while IFS= read -r FILE; do
  [ -z "$FILE" ] && continue
  REL="${FILE#$SRC_ABS/}"
  EXT="${FILE##*.}"
  EXT_LC=$(echo "$EXT" | tr '[:upper:]' '[:lower:]')

  # Sub-folder из rel path (если recursive)
  SUB=$(dirname "$REL")
  if [ "$SUB" = "." ]; then
    FILE_TARGET="$TARGET"
  else
    FILE_TARGET="$TARGET/$SUB"
  fi

  # Detect type
  if echo "$EXT_LC" | grep -qE "^($IMG_EXTS)$"; then
    TYPE="image"
    SCRIPT="$LIBDIR/upload-cloudinary.sh"
  elif echo "$EXT_LC" | grep -qE "^($VID_EXTS)$"; then
    TYPE="video"
    SCRIPT="$LIBDIR/upload-cloudinary-video.sh"
  else
    echo "→ [skip] $REL (unsupported)"
    SKIP=$((SKIP + 1))
    continue
  fi

  SIZE=$(du -h "$FILE" 2>/dev/null | cut -f1)
  printf "→ [%s] %-50s %s  " "$TYPE" "$REL" "$SIZE"

  # Capture sub-script output
  OUT=$(bash "$SCRIPT" "$FILE" "$FILE_TARGET" 2>&1)
  URL=$(echo "$OUT" | awk '/url:/ {print $2; exit}')

  if [ -n "$URL" ]; then
    echo "✅"
    echo "$REL|$TYPE|$URL" >> "$LOG"
    OK=$((OK + 1))
    [ "$TYPE" = "image" ] && IMG_OK=$((IMG_OK + 1))
    [ "$TYPE" = "video" ] && VID_OK=$((VID_OK + 1))
  else
    echo "✗ FAILED"
    echo "  error: $(echo "$OUT" | tail -3 | head -1)"
    echo "$REL|$TYPE|FAILED" >> "$LOG"
    FAIL=$((FAIL + 1))
  fi
done <<< "$FILES"

DUR=$(( $(date +%s) - START ))

echo
echo "═══════════════════════════════════════════════════════════════"
echo "Done in ${DUR}s:  ✅ $OK uploaded ($IMG_OK image / $VID_OK video)  ✗ $FAIL failed  → $SKIP skipped"
echo "═══════════════════════════════════════════════════════════════"

# Compact URL list для копирования в чат / IDE
echo
echo "── URLs ──"
while IFS='|' read -r REL TYPE URL; do
  [ "$URL" = "FAILED" ] && continue
  if [ "$TYPE" = "video" ]; then
    SILENT=$(echo "$URL" | sed 's|/upload/|/upload/ac_none,q_auto,f_auto/|')
    POSTER=$(echo "$URL" | sed 's|/upload/|/upload/w_1280,h_720,c_fit,so_1,q_auto/|' | sed 's|\.[^.]*$|.jpg|')
    printf "🎬 %s\n    src:    %s\n    silent: %s\n    poster: %s\n" "$REL" "$URL" "$SILENT" "$POSTER"
  else
    AUTO=$(echo "$URL" | sed 's|/upload/|/upload/q_auto,f_auto/|')
    printf "🖼  %s\n    src:  %s\n    auto: %s\n" "$REL" "$URL" "$AUTO"
  fi
done < "$LOG"

# Generate HTML preview
{
  echo '<!doctype html><html><head><meta charset="utf-8"><title>Cloudinary batch upload</title>'
  echo '<style>body{font-family:-apple-system,system-ui,sans-serif;margin:0;padding:24px;background:#0d0d0f;color:#e8e8ea}'
  echo 'h1{font-size:20px;margin:0 0 16px}.meta{color:#888;margin-bottom:24px;font-size:13px}'
  echo '.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:12px}'
  echo '.card{background:#18181b;padding:12px;border-radius:8px;border:1px solid #2a2a30}'
  echo '.card .type{font-size:11px;color:#888;text-transform:uppercase;letter-spacing:0.5px;margin-bottom:6px}'
  echo '.card .name{font-family:ui-monospace,monospace;font-size:13px;color:#e8e8ea;margin-bottom:8px;word-break:break-all}'
  echo '.card a{color:#93c5fd;text-decoration:none;font-size:12px;word-break:break-all}'
  echo '.card a:hover{color:#bfdbfe}.card.fail{opacity:0.5}'
  echo 'img,video{max-width:100%;border-radius:4px;background:#0d0d0f;margin:6px 0}'
  echo '</style></head><body>'
  echo "<h1>📦 Cloudinary batch — $BASE</h1>"
  echo "<div class=\"meta\">$SRC_ABS → $TARGET · ✅ $OK / ✗ $FAIL / → $SKIP · ${DUR}s</div>"
  echo '<div class="grid">'
  while IFS='|' read -r REL TYPE URL; do
    [ "$URL" = "FAILED" ] && cls="card fail" || cls="card"
    echo "<div class=\"$cls\">"
    echo "<div class=\"type\">$TYPE</div>"
    echo "<div class=\"name\">$REL</div>"
    if [ "$URL" != "FAILED" ]; then
      if [ "$TYPE" = "image" ]; then
        AUTO=$(echo "$URL" | sed 's|/upload/|/upload/q_auto,f_auto,w_640/|')
        echo "<img src=\"$AUTO\" loading=\"lazy\" />"
      else
        POSTER=$(echo "$URL" | sed 's|/upload/|/upload/w_640,c_fit,so_1,q_auto/|' | sed 's|\.[^.]*$|.jpg|')
        SILENT=$(echo "$URL" | sed 's|/upload/|/upload/w_640,c_fit,ac_none,q_auto,f_auto/|')
        # Видео с autoplay/muted/loop — без controls, для preview-feel
        echo "<video autoplay muted loop playsinline poster=\"$POSTER\" preload=\"metadata\"><source src=\"$SILENT\" type=\"video/mp4\"/></video>"
      fi
      echo "<a href=\"$URL\" target=\"_blank\">open original</a>"
    else
      echo "<div style=\"color:#fb7185\">❌ upload failed</div>"
    fi
    echo "</div>"
  done < "$LOG"
  echo '</div></body></html>'
} > "$HTML"

echo
echo "📄 Preview HTML: $HTML"
echo "📋 Plain log:    $LOG"

# Open preview
command -v open >/dev/null && open "$HTML" || true
