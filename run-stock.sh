#!/usr/bin/env bash
# Stock aggregator — single op run wraps all 3 stocks
# Usage: run-stock.sh <query> [--sources unsplash,pexels,pixabay] [--pixabay-type all|photo|illustration|vector]
set -euo pipefail

QUERY="${1:-}"
shift || true
SOURCES="unsplash,pexels,pixabay"
PIXABAY_TYPE="all"

while [ $# -gt 0 ]; do
  case "$1" in
    --sources) SOURCES="$2"; shift 2 ;;
    --pixabay-type) PIXABAY_TYPE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [ -z "$QUERY" ]; then
  echo "Usage: run-stock.sh <query> [--sources csv] [--pixabay-type all|photo|illustration|vector]"
  exit 1
fi

LIBDIR="$(cd "$(dirname "$0")/lib" && pwd)"
SLUG=$(echo "$QUERY" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' | cut -c1-40)
TS=$(date +%Y-%m-%d_%H-%M-%S)
OUTDIR="$HOME/Downloads/content-gen/${TS}_stock-${SLUG}"
mkdir -p "$OUTDIR"

echo "═══ content-stock ═══"
echo "  query:   $QUERY"
echo "  sources: $SOURCES"
echo "  output:  $OUTDIR"
echo

jq -n --arg q "$QUERY" --arg s "$SOURCES" --arg t "$(date -u +%FT%TZ)" \
  '{mode: "stock", query: $q, sources: $s, started_at: $t}' > "$OUTDIR/meta.json"

SECRETS_WRAP=(bash -c)
if [ -f "$LIBDIR/all-secrets.env" ] && command -v op >/dev/null 2>&1; then
  SECRETS_WRAP=(op run --env-file="$LIBDIR/all-secrets.env" -- bash -c)
fi
"${SECRETS_WRAP[@]}" "
  set -uo pipefail
  IFS=',' read -ra SRC_ARR <<< '$SOURCES'
  PIDS=()
  for src in \"\${SRC_ARR[@]}\"; do
    case \"\$src\" in
      unsplash) bash '$LIBDIR/stock-unsplash.sh' '$QUERY' '$OUTDIR' & ;;
      pexels)   bash '$LIBDIR/stock-pexels.sh'   '$QUERY' '$OUTDIR' & ;;
      pixabay)  bash '$LIBDIR/stock-pixabay.sh'  '$QUERY' '$OUTDIR' '$PIXABAY_TYPE' & ;;
      *) echo '✗ unknown source: '\$src ;;
    esac
    PIDS+=(\$!)
  done
  for pid in \"\${PIDS[@]}\"; do wait \"\$pid\" || true; done
"

echo
echo "═══ Rendering preview ═══"
python3 "$LIBDIR/render-grid.py" "$OUTDIR" "STOCK: $QUERY"

echo
echo "═══ Готово ═══"
echo "  Папка: $OUTDIR"
open "$OUTDIR/preview.html"
