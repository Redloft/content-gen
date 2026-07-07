#!/usr/bin/env bash
# scene-gemini.sh — атмосферная сцена с chroma-green экраном через Gemini image-модели
# (Nano Banana Pro = gemini-3-pro-image). Контракт идентичен scene-recraft.sh.
#
# Использует $GEMINI_API_KEY из ОКРУЖЕНИЯ (оркестратор оборачивает в один op run).
#
# Usage:
#   scene-gemini.sh --context "<сцена по-английски>" --device laptop|phone|tablet \
#       --out scene.png [--aspect 4:3|3:4|16:9|9:16|1:1] [--imgsize 1K|2K|4K] \
#       [--model gemini-3-pro-image] [--prompt "<raw prompt override>"]
# stdout: JSON {ok, out} | {ok:false, error}
set -euo pipefail

CONTEXT=""; DEVICE="laptop"; OUT=""; ASPECT="4:3"; IMGSIZE="2K"
MODEL="gemini-3-pro-image"; RAW_PROMPT=""
while [ $# -gt 0 ]; do case "$1" in
  --context) CONTEXT="$2"; shift 2;;
  --device)  DEVICE="$2";  shift 2;;
  --out)     OUT="$2";     shift 2;;
  --aspect)  ASPECT="$2";  shift 2;;
  --imgsize) IMGSIZE="$2"; shift 2;;
  --model)   MODEL="$2";   shift 2;;
  --prompt)  RAW_PROMPT="$2"; shift 2;;
  *) shift;;
esac; done

[ -n "$OUT" ] || { echo '{"ok":false,"error":"need --out"}'; exit 1; }
[ -n "${GEMINI_API_KEY:-}" ] || { echo '{"ok":false,"error":"GEMINI_API_KEY not in env (wrap in op run)"}'; exit 1; }

# Gemini гео-блокирует РФ (прямой → 400). Через openclaw FI (SOCKS, TLS e2e, ключ на сервере не
# виден, хелпер прогревает туннель). Fail-open: FI недоступен → PROXY пуст → прямой маршрут.
_GFI=~/.claude/skills/_shared/gemini-fi/fi-proxy.sh
[ -f "$_GFI" ] && source "$_GFI" && PROXY=$(gemini_fi_proxy) || PROXY=""

# Ключ — в заголовке через curl --config (600), НЕ инлайном -H (тот виден в `ps`/argv). ОДИН раз до retry-loop.
CFG=$(mktemp); chmod 600 "$CFG"; trap 'rm -f "$CFG"' EXIT
printf 'header = "x-goog-api-key: %s"\n' "$GEMINI_API_KEY" > "$CFG"

if [ -n "$RAW_PROMPT" ]; then
  PROMPT="$RAW_PROMPT"
else
  [ -n "$CONTEXT" ] || { echo '{"ok":false,"error":"need --context or --prompt"}'; exit 1; }
  case "$DEVICE" in
    laptop)  PLACEMENT="an open modern laptop";;
    phone)   PLACEMENT="a modern smartphone held in a hand";;
    tablet)  PLACEMENT="a modern tablet";;
    *)       PLACEMENT="an open modern laptop";;
  esac
  # Тот же screen-first промт, что в scene-recraft.sh (см. комментарий там).
  PROMPT="CRITICAL: tight close-up composition — the device screen is the hero and fills 75-90% of the frame: a large, perfectly flat SOLID BRIGHT CHROMA-GREEN rectangle (pure #00FF00) facing the camera almost straight-on with only a slight angle, all four corners visible inside the frame, sharp straight edges, no glare, no reflections, no icons, no content, the entire screen uniform green. The environment is visible only at the edges of the frame around the screen. ${PLACEMENT} in ${CONTEXT}. Photorealistic editorial photograph, cinematic atmospheric directional light, rich material textures, high detail."
fi

REQ=$(jq -n --arg p "$PROMPT" --arg ar "$ASPECT" --arg sz "$IMGSIZE" \
  '{contents:[{parts:[{text:$p}]}],
    generationConfig:{responseModalities:["IMAGE"], imageConfig:{aspectRatio:$ar, imageSize:$sz}}}')

# retry: до 3 попыток с backoff на 429/5xx/сетевые (panel warning: один сбой ≠ смерть батча)
ATTEMPT=0; B64=""
while [ $ATTEMPT -lt 3 ]; do
  ATTEMPT=$((ATTEMPT+1))
  RESP=$(curl --silent --max-time 240 ${PROXY:+--proxy "$PROXY"} --config "$CFG" -X POST \
    "https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent" \
    -H "Content-Type: application/json" \
    -d "$REQ" || echo '')
  B64=$(echo "$RESP" | jq -r '.candidates[0].content.parts[]? | select(.inlineData.data?) | .inlineData.data' 2>/dev/null | head -1)
  [ -n "$B64" ] && [ "$B64" != "null" ] && break
  CODE=$(echo "$RESP" | jq -r '.error.code // empty' 2>/dev/null)
  case "$CODE" in
    429|500|502|503|504|"") sleep $((ATTEMPT*5));;
    *) break;;   # постоянная ошибка (404/400/403) — ретраить бессмысленно
  esac
done

if [ -n "$B64" ] && [ "$B64" != "null" ]; then
  echo "$B64" | base64 -d > "$OUT"
  [ -s "$OUT" ] || { echo '{"ok":false,"error":"decoded image is empty"}'; exit 3; }
  echo "{\"ok\":true,\"out\":\"$OUT\"}"
else
  ERR=$(echo "$RESP" | jq -c '{code:(.error.code // null), message:((.error.message // "unknown")[:200])}' 2>/dev/null || echo '"unparseable response"')
  echo "{\"ok\":false,\"error\":$ERR}"
  exit 2
fi
