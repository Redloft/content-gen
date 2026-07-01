#!/usr/bin/env bash
# imgforge — raster → SVG tracing + raster compression/conversion combine.
# Engines: vtracer (color/bw tracing), potrace+mkbitmap (ultra-clean B&W),
#          svgo (SVG optimize), sharp (resize/convert), oxipng/pngquant (PNG), cwebp.
#
# Usage:
#   imgforge.sh <input> [mode] [options]
#
# Modes (pick one; default = compress):
#   --svg            trace to SVG, full color   (vtracer color preset)
#   --poster         trace to SVG, flat poster  (vtracer poster preset, fewer colors)
#   --photo          trace to SVG, photographic (vtracer photo preset, gradients)
#   --bw             trace to SVG, black & white (vtracer bw preset)
#   --potrace        trace to SVG, B&W ultra-clean curves (mkbitmap + potrace)
#   --compress       compress / convert raster (DEFAULT when no trace mode given)
#
# Compress options:
#   --to <fmt>       webp | avif | png | jpeg   (default: webp)
#   --max <px>       longest side, downscale only (e.g. 1600)
#   --q <1-100>      quality (default: 80; ignored for png)
#
# Common:
#   --out <path>     explicit output file path
#   --no-svgo        skip SVG optimization pass
#   --upload         upload result to Cloudinary (reuses upload-cloudinary.sh)
#
# Examples:
#   imgforge.sh logo.png --svg
#   imgforge.sh icon.png --potrace
#   imgforge.sh photo.jpg --to webp --max 1600 --q 82
#   imgforge.sh shot.png --to avif --max 2000 --upload
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"

LIBDIR="$(cd "$(dirname "$0")" && pwd)"

# ---- arg parse ----
IN=""; MODE="compress"; TO="webp"; MAX=""; Q="80"; OUT=""; SVGO=1; UPLOAD=0
while [ $# -gt 0 ]; do
  case "$1" in
    --svg)      MODE="svg" ;;
    --poster)   MODE="poster" ;;
    --photo)    MODE="photo" ;;
    --bw)       MODE="bw" ;;
    --potrace)  MODE="potrace" ;;
    --compress) MODE="compress" ;;
    --to)       TO="$2"; shift ;;
    --max)      MAX="$2"; shift ;;
    --q)        Q="$2"; shift ;;
    --out)      OUT="$2"; shift ;;
    --no-svgo)  SVGO=0 ;;
    --upload)   UPLOAD=1 ;;
    -*)         echo "✗ unknown option: $1"; exit 2 ;;
    *)          IN="$1" ;;
  esac
  shift
done

[ -z "$IN" ] && { echo "✗ no input file. Usage: imgforge.sh <input> [--svg|--bw|--potrace|--to webp ...]"; exit 2; }
[ -f "$IN" ] || { echo "✗ file not found: $IN"; exit 1; }

human() { # bytes -> human
  awk -v b="$1" 'BEGIN{ s="B K M G"; split(s,u," "); i=1; while(b>=1024 && i<4){b/=1024;i++} printf (i==1?"%d%s":"%.1f%s"), b, u[i] }'
}
fsize() { stat -f%z "$1" 2>/dev/null || echo 0; }

ABS_IN="$(cd "$(dirname "$IN")" && pwd)/$(basename "$IN")"
BASE="$(basename "$IN")"; STEM="${BASE%.*}"
IN_BYTES=$(fsize "$ABS_IN")
OUTDIR="${OUT:+$(dirname "$OUT")}"; OUTDIR="${OUTDIR:-$HOME/Downloads/imgforge}"
mkdir -p "$OUTDIR"

trace_report() {
  local out="$1"; local ob; ob=$(fsize "$out")
  local pct; pct=$(awk -v a="$IN_BYTES" -v b="$ob" 'BEGIN{ if(a>0) printf "%d", (1-b/a)*100; else print 0 }')
  echo "✅ $out"
  echo "   $(human "$IN_BYTES") → $(human "$ob")  (${pct}% smaller)"
}

# ---------------- TRACE MODES ----------------
if [ "$MODE" != "compress" ]; then
  command -v vtracer >/dev/null || { echo "✗ vtracer not installed"; exit 1; }
  DEST="${OUT:-$OUTDIR/${STEM}.svg}"
  TMP_RASTER=""

  if [ "$MODE" = "potrace" ]; then
    command -v mkbitmap >/dev/null && command -v potrace >/dev/null || { echo "✗ potrace/mkbitmap missing"; exit 1; }
    # potrace needs a bitmap; sharp can't emit PNM, so go via BMP (potrace reads BMP).
    TMP_BMP="$(mktemp).bmp"; TMP_PBM="$(mktemp).pbm"
    sharp -i "$ABS_IN" -f png -o "$(dirname "$TMP_BMP")" >/dev/null 2>&1 || true
    # mkbitmap reads PNM/BMP. Convert PNG→BMP via sharp first.
    SHARP_BMP_DIR="$(mktemp -d)"
    sharp -i "$ABS_IN" greyscale -f png -o "$SHARP_BMP_DIR" >/dev/null
    GREY_PNG="$SHARP_BMP_DIR/$(basename "${ABS_IN%.*}").png"
    # mkbitmap accepts PNM/BMP only → use potrace's own bmp path: feed via `magick`? not present.
    # Fallback: mkbitmap can read PNM; produce PNM with a tiny python (Pillow if present), else vtracer bw.
    if python3 -c "import PIL" 2>/dev/null; then
      TMP_PNM="$(mktemp).pnm"
      python3 -c "from PIL import Image; Image.open('$GREY_PNG').convert('L').save('$TMP_PNM')"
      mkbitmap -f 2 -s 2 -t 0.48 "$TMP_PNM" -o "$TMP_PBM" >/dev/null 2>&1
      potrace "$TMP_PBM" -s --flat -o "$DEST"
      rm -f "$TMP_PNM" "$TMP_PBM"
    else
      echo "ℹ️  Pillow not found — potrace path needs PNM. Falling back to vtracer --preset bw."
      vtracer -i "$ABS_IN" -o "$DEST" --preset bw
    fi
    rm -rf "$SHARP_BMP_DIR"
  else
    case "$MODE" in
      svg)    vtracer -i "$ABS_IN" -o "$DEST" ;;                       # default = full color
      poster) vtracer -i "$ABS_IN" -o "$DEST" --preset poster ;;
      photo)  vtracer -i "$ABS_IN" -o "$DEST" --preset photo ;;
      bw)     vtracer -i "$ABS_IN" -o "$DEST" --preset bw ;;
    esac
  fi

  # SVG optimize
  if [ "$SVGO" = "1" ] && command -v svgo >/dev/null; then
    PRE=$(fsize "$DEST")
    svgo --quiet --multipass "$DEST" -o "$DEST" >/dev/null 2>&1 || true
    POST=$(fsize "$DEST")
    echo "   svgo: $(human "$PRE") → $(human "$POST")"
  fi
  trace_report "$DEST"
  [ "$UPLOAD" = "1" ] && { echo "→ uploading…"; bash "$LIBDIR/upload-cloudinary.sh" "$DEST"; }
  exit 0
fi

# ---------------- COMPRESS / CONVERT ----------------
command -v sharp >/dev/null || { echo "✗ sharp-cli not installed"; exit 1; }
case "$TO" in webp|avif|png|jpeg|jpg) ;; *) echo "✗ --to must be webp|avif|png|jpeg"; exit 2 ;; esac
[ "$TO" = "jpg" ] && TO="jpeg"
EXT="$TO"; [ "$TO" = "jpeg" ] && EXT="jpg"
DEST="${OUT:-$OUTDIR/${STEM}.${EXT}}"
WORK="$(mktemp -d)"

ARGS=(-i "$ABS_IN" -o "$WORK" -f "$TO")
[ "$TO" != "png" ] && ARGS+=(-q "$Q")
[ -n "$MAX" ] && RESIZE=(resize "$MAX" "$MAX" --fit inside --withoutEnlargement) || RESIZE=()

sharp "${ARGS[@]}" "${RESIZE[@]}" >/dev/null
# sharp writes <stem>.<ext> into WORK
SHARP_OUT="$WORK/${STEM}.${EXT}"
[ -f "$SHARP_OUT" ] || SHARP_OUT="$(ls "$WORK"/*."$EXT" 2>/dev/null | head -1)"
mv "$SHARP_OUT" "$DEST"
rm -rf "$WORK"

# Extra lossless pass for PNG
if [ "$TO" = "png" ]; then
  if command -v pngquant >/dev/null; then
    pngquant --force --skip-if-larger --quality=65-90 --output "$DEST" "$DEST" 2>/dev/null || true
  fi
  command -v oxipng >/dev/null && oxipng -o 4 --strip safe "$DEST" >/dev/null 2>&1 || true
fi

trace_report "$DEST"
[ "$UPLOAD" = "1" ] && { echo "→ uploading…"; bash "$LIBDIR/upload-cloudinary.sh" "$DEST"; }
exit 0
