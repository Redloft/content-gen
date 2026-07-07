#!/usr/bin/env bash
# Imagen 4 — uses $GEMINI_API_KEY from environment
# Usage: generate-imagen.sh <prompt> <output_dir>
set -euo pipefail

PROMPT="$1"
OUTDIR="$2"
mkdir -p "$OUTDIR"

# Gemini гео-блокирует РФ (прямой → 400). Гоним через openclaw FI (SOCKS, TLS e2e, ключ на
# сервере не виден). Fail-open: FI недоступен → PROXY пуст → прямой маршрут. Хелпер прогревает туннель.
_GFI=~/.claude/skills/_shared/gemini-fi/fi-proxy.sh
[ -f "$_GFI" ] && source "$_GFI" && PROXY=$(gemini_fi_proxy) || PROXY=""

# Ключ — в заголовке через curl --config (600), НЕ в URL ?key= (тот виден в `ps`/argv — см.
# secrets-протокол). x-goog-api-key работает и через FI, и напрямую на :predict.
CFG=$(mktemp); chmod 600 "$CFG"; trap 'rm -f "$CFG"' EXIT
printf 'header = "x-goog-api-key: %s"\n' "$GEMINI_API_KEY" > "$CFG"
RESP=$(curl --silent --max-time 90 ${PROXY:+--proxy "$PROXY"} --config "$CFG" -X POST \
  "https://generativelanguage.googleapis.com/v1beta/models/imagen-4.0-generate-001:predict" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg p "$PROMPT" '{instances: [{prompt: $p}], parameters: {sampleCount: 1, aspectRatio: "1:1"}}')")
B64=$(echo "$RESP" | jq -r '.predictions[0].bytesBase64Encoded // empty')

if [ -n "$B64" ] && [ "$B64" != "null" ]; then
  echo "$B64" | base64 -d > "$OUTDIR/imagen.png"
  echo "✓ imagen.png"
else
  echo "$RESP" | head -c 300 > "$OUTDIR/imagen.error.txt"
  echo "✗ imagen"
fi
