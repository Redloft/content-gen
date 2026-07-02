#!/usr/bin/env bash
# content-gen orchestrator — single op run wraps ALL parallel generators (one Touch ID for all)
# Usage: run.sh <prompt> [--tier explore|mid|premium] [--sources csv] [--style <recraft-style>]
set -euo pipefail

PROMPT="${1:-}"
shift || true
TIER="mid"
SOURCES=""
RECRAFT_STYLE="digital_illustration"

while [ $# -gt 0 ]; do
  case "$1" in
    --tier) TIER="$2"; shift 2 ;;
    --sources) SOURCES="$2"; shift 2 ;;
    --style) RECRAFT_STYLE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [ -z "$PROMPT" ] || [ "$PROMPT" = "--help" ] || [ "$PROMPT" = "-h" ] || [ "$PROMPT" = "help" ]; then
  cat <<'USAGE'
╔══════════════════════════════════════════════════════════════════════════════╗
║                  CONTENT-GEN — copy-paste cheatsheet                         ║
╚══════════════════════════════════════════════════════════════════════════════╝

📸 AI generation (5 моделей, parallel, single Touch ID)
──────────────────────────────────────────────────────────────────────────────
  /content-gen "<prompt>"                          # auto — mid tier (3 src, ~$0.06)
  /content-gen "<prompt>" --tier explore           # ~$0.04, 2 src: Flux + Nano Banana
  /content-gen "<prompt>" --tier mid               # ~$0.06, +Recraft (default)
  /content-gen "<prompt>" --tier premium           # ~$0.14, все 5 — финал

  /content-gen "<prompt>" --sources recraft,openai # явный список
  /content-gen "<prompt>" --style realistic_image  # Recraft style (digital_illustration|realistic_image|vector_illustration|icon)

🖼  Stock photos (3 источника, 9 фото)
──────────────────────────────────────────────────────────────────────────────
  /content-stock "<query>"                         # Unsplash + Pexels + Pixabay
  /content-stock "<query>" --pixabay-type vector   # vector / illustration / photo

🧠 Smart brief (если идея размытая)
──────────────────────────────────────────────────────────────────────────────
  /content-brief "<идея>"                          # 3-5 вопросов → enriched prompt → generate
  /content-gen "икона тренинга"                    # auto-brief, ≤5 слов = вопросы

☁️  Cloudinary upload
──────────────────────────────────────────────────────────────────────────────
  /content-upload <path>                           # default folder: content-gen/<YYYY-MM>
  /content-upload <path> wellbookin/hero           # custom folder для проекта

💰 Цены (на 1 запуск)
──────────────────────────────────────────────────────────────────────────────
  explore    ~$0.04   (Flux $0.003 + Nano Banana $0.039)
  mid        ~$0.06   (+ Recraft $0.02)
  premium    ~$0.14   (+ OpenAI $0.04 + Imagen $0.04)
  stocks     FREE
  cloudinary FREE до 25GB/мес

📁 Results: ~/Downloads/content-gen/<timestamp>_<tier>_<slug>/preview.html

USAGE
  exit 0
fi

# Resolve tier → sources (если --sources не задан явно)
if [ -z "$SOURCES" ]; then
  case "$TIER" in
    explore) SOURCES="replicate,gemini" ;;
    mid)     SOURCES="recraft,gemini,replicate" ;;
    premium) SOURCES="recraft,gemini,imagen,openai,replicate" ;;
    *) echo "Unknown tier: $TIER"; exit 1 ;;
  esac
fi

LIBDIR="$(cd "$(dirname "$0")/lib" && pwd)"
SLUG=$(echo "$PROMPT" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' | cut -c1-40)
TS=$(date +%Y-%m-%d_%H-%M-%S)
OUTDIR="$HOME/Downloads/content-gen/${TS}_${TIER}_${SLUG}"
mkdir -p "$OUTDIR"

echo "═══ content-gen ═══"
echo "  prompt:  $PROMPT"
echo "  tier:    $TIER"
echo "  sources: $SOURCES"
echo "  output:  $OUTDIR"
echo

jq -n --arg p "$PROMPT" --arg t "$TIER" --arg s "$SOURCES" --arg ts "$(date -u +%FT%TZ)" --arg style "$RECRAFT_STYLE" \
  '{prompt: $p, tier: $t, sources: $s, started_at: $ts, recraft_style: $style}' > "$OUTDIR/meta.json"

# КЛЮЧЕВОЕ: ОДИН op run на всё параллельное → ОДНА авторизация
op run --env-file="$LIBDIR/all-secrets.env" -- bash -c "
  set -uo pipefail
  IFS=',' read -ra SRC_ARR <<< '$SOURCES'
  PIDS=()
  for src in \"\${SRC_ARR[@]}\"; do
    case \"\$src\" in
      recraft)   bash '$LIBDIR/generate-recraft.sh'   '$PROMPT' '$OUTDIR' '$RECRAFT_STYLE' & ;;
      gemini)    bash '$LIBDIR/generate-gemini.sh'    '$PROMPT' '$OUTDIR' & ;;
      imagen)    bash '$LIBDIR/generate-imagen.sh'    '$PROMPT' '$OUTDIR' & ;;
      openai)    bash '$LIBDIR/generate-openai.sh'    '$PROMPT' '$OUTDIR' & ;;
      replicate) bash '$LIBDIR/generate-replicate.sh' '$PROMPT' '$OUTDIR' & ;;
      *) echo '✗ unknown source: '\$src ;;
    esac
    PIDS+=(\$!)
  done
  for pid in \"\${PIDS[@]}\"; do wait \"\$pid\" || true; done
"

echo
echo "═══ Rendering preview ═══"
python3 "$LIBDIR/render-grid.py" "$OUTDIR" "$PROMPT"

echo
echo "═══ Готово ═══"
echo "  Папка:  $OUTDIR"
open "$OUTDIR/preview.html"
