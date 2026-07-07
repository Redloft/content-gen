#!/usr/bin/env bash
# image-to-image: реальное фото на вход (inlineData) + промт -> Nano Banana Pro дорисовывает ноут с chroma-green
set -euo pipefail
PHOTO=""; PROMPT=""; OUT=""; MODEL="gemini-3-pro-image"; ASPECT=""
while [ $# -gt 0 ]; do case "$1" in
  --photo) PHOTO="$2"; shift 2;; --prompt) PROMPT="$2"; shift 2;;
  --out) OUT="$2"; shift 2;; --model) MODEL="$2"; shift 2;;
  --aspect) ASPECT="$2"; shift 2;; *) shift;;
esac; done
[ -n "$OUT" ] && [ -n "$PHOTO" ] && [ -n "$PROMPT" ] || { echo '{"ok":false,"error":"need --photo --prompt --out"}'; exit 1; }
[ -n "${GEMINI_API_KEY:-}" ] || { echo '{"ok":false,"error":"no GEMINI_API_KEY"}'; exit 1; }
# Gemini гео-блокирует РФ (прямой → 400). Через openclaw FI (SOCKS, TLS e2e, ключ на сервере не
# виден, хелпер прогревает туннель). Fail-open: FI недоступен → PROXY пуст → прямой маршрут.
_GFI=~/.claude/skills/_shared/gemini-fi/fi-proxy.sh
[ -f "$_GFI" ] && source "$_GFI" && PROXY=$(gemini_fi_proxy) || PROXY=""
# Ключ — в заголовке через curl --config (600), НЕ инлайном -H (тот виден в `ps`/argv). ОДИН раз до retry-loop.
CFG=$(mktemp); chmod 600 "$CFG"; trap 'rm -f "$CFG"' EXIT
printf 'header = "x-goog-api-key: %s"\n' "$GEMINI_API_KEY" > "$CFG"
B64IN=$(base64 -i "$PHOTO" | tr -d '\n')
if [ -n "$ASPECT" ]; then
  GEN=$(jq -n --arg ar "$ASPECT" '{responseModalities:["IMAGE"], imageConfig:{aspectRatio:$ar, imageSize:"2K"}}')
else
  GEN='{"responseModalities":["IMAGE"],"imageConfig":{"imageSize":"2K"}}'
fi
REQ=$(jq -n --arg p "$PROMPT" --arg img "$B64IN" --argjson gen "$GEN" \
  '{contents:[{parts:[{inlineData:{mimeType:"image/jpeg",data:$img}},{text:$p}]}], generationConfig:$gen}')
ATTEMPT=0; B64=""
while [ $ATTEMPT -lt 3 ]; do
  ATTEMPT=$((ATTEMPT+1))
  RESP=$(curl --silent --max-time 300 ${PROXY:+--proxy "$PROXY"} --config "$CFG" -X POST \
    "https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent" \
    -H "Content-Type: application/json" -d "$REQ" || echo '')
  B64=$(echo "$RESP" | jq -r '.candidates[0].content.parts[]? | select(.inlineData.data?) | .inlineData.data' 2>/dev/null | head -1)
  [ -n "$B64" ] && [ "$B64" != "null" ] && break
  CODE=$(echo "$RESP" | jq -r '.error.code // empty' 2>/dev/null)
  case "$CODE" in 429|500|502|503|504|"") sleep $((ATTEMPT*5));; *) break;; esac
done
if [ -n "$B64" ] && [ "$B64" != "null" ]; then
  echo "$B64" | base64 -d > "$OUT"; [ -s "$OUT" ] || { echo '{"ok":false,"error":"empty"}'; exit 3; }
  echo "{\"ok\":true,\"out\":\"$OUT\"}"
else
  echo "$RESP" | jq -c '{ok:false,error:{code:(.error.code//null),message:((.error.message//"unknown")[:200])}}' 2>/dev/null || echo '{"ok":false,"error":"unparseable"}'
  exit 2
fi
