#!/usr/bin/env bash
# Gemini Nano Banana — uses $GEMINI_API_KEY from environment
# Usage: generate-gemini.sh <prompt> <output_dir>
set -euo pipefail

PROMPT="$1"
OUTDIR="$2"
mkdir -p "$OUTDIR"

# Gemini гео-блокирует РФ (прямой маршрут → 400). Гоним через openclaw FI (SOCKS, TLS e2e,
# ключ на сервере не виден). Fail-open: FI недоступен → PROXY пуст → прямой маршрут как раньше.
_GFI=~/.claude/skills/_shared/gemini-fi/fi-proxy.sh
[ -f "$_GFI" ] && source "$_GFI" && PROXY=$(gemini_fi_proxy) || PROXY=""

# Ключ — в заголовке через curl --config (600), НЕ в URL ?key= (тот виден в `ps`/argv — secrets-протокол).
CFG=$(mktemp); chmod 600 "$CFG"; trap 'rm -f "$CFG"' EXIT
printf 'header = "x-goog-api-key: %s"\n' "$GEMINI_API_KEY" > "$CFG"
RESP=$(curl --silent --max-time 60 ${PROXY:+--proxy "$PROXY"} --config "$CFG" -X POST \
  "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-image:generateContent" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg p "$PROMPT" '{contents: [{parts: [{text: $p}]}]}')")
B64=$(echo "$RESP" | jq -r '.candidates[0].content.parts[]? | select(.inlineData.data?) | .inlineData.data' | head -1)

if [ -n "$B64" ] && [ "$B64" != "null" ]; then
  echo "$B64" | base64 -d > "$OUTDIR/gemini-nano-banana.png"
  echo "✓ gemini-nano-banana.png"
else
  echo "$RESP" | head -c 300 > "$OUTDIR/gemini-nano-banana.error.txt"
  echo "✗ gemini-nano-banana"
fi
