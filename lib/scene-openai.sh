#!/usr/bin/env bash
# scene-openai.sh — атмосферная сцена с chroma-green экраном через OpenAI gpt-image.
# Контракт идентичен scene-recraft.sh.
#
# Использует $OPENAI_API_KEY из ОКРУЖЕНИЯ (оркестратор оборачивает в один op run).
#
# Usage:
#   scene-openai.sh --context "<сцена по-английски>" --device laptop|phone|tablet \
#       --out scene.png [--size 1536x1024|1024x1536|1024x1024] [--quality low|medium|high] \
#       [--model gpt-image-1.5] [--prompt "<raw prompt override>"]
# stdout: JSON {ok, out} | {ok:false, error}
set -euo pipefail

CONTEXT=""; DEVICE="laptop"; OUT=""; SIZE="1536x1024"; QUALITY="high"
MODEL="gpt-image-1.5"; RAW_PROMPT=""
while [ $# -gt 0 ]; do case "$1" in
  --context) CONTEXT="$2"; shift 2;;
  --device)  DEVICE="$2";  shift 2;;
  --out)     OUT="$2";     shift 2;;
  --size)    SIZE="$2";    shift 2;;
  --quality) QUALITY="$2"; shift 2;;
  --model)   MODEL="$2";   shift 2;;
  --prompt)  RAW_PROMPT="$2"; shift 2;;
  *) shift;;
esac; done

[ -n "$OUT" ] || { echo '{"ok":false,"error":"need --out"}'; exit 1; }
[ -n "${OPENAI_API_KEY:-}" ] || { echo '{"ok":false,"error":"OPENAI_API_KEY not in env (wrap in op run)"}'; exit 1; }

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
  PROMPT="CRITICAL: tight close-up composition — the device screen is the hero and fills 75-90% of the frame: a large, perfectly flat SOLID BRIGHT CHROMA-GREEN rectangle (pure #00FF00) facing the camera almost straight-on with only a slight angle, all four corners visible inside the frame, sharp straight edges, no glare, no reflections, no icons, no content, the entire screen uniform green. The environment is visible only at the edges of the frame around the screen. ${PLACEMENT} in ${CONTEXT}. Photorealistic editorial photograph, cinematic atmospheric directional light, rich material textures, high detail."
fi

REQ=$(jq -n --arg p "$PROMPT" --arg m "$MODEL" --arg s "$SIZE" --arg q "$QUALITY" \
  '{model:$m, prompt:$p, n:1, size:$s, quality:$q}')

ATTEMPT=0; B64=""
while [ $ATTEMPT -lt 3 ]; do
  ATTEMPT=$((ATTEMPT+1))
  RESP=$(curl --silent --max-time 300 -X POST "https://api.openai.com/v1/images/generations" \
    -H "Authorization: Bearer $OPENAI_API_KEY" -H "Content-Type: application/json" \
    -d "$REQ" || echo '')
  B64=$(echo "$RESP" | jq -r '.data[0].b64_json // empty' 2>/dev/null)
  [ -n "$B64" ] && break
  TYPE=$(echo "$RESP" | jq -r '.error.type // empty' 2>/dev/null)
  case "$TYPE" in
    rate_limit_error|server_error|"") sleep $((ATTEMPT*5));;
    *) break;;
  esac
done

if [ -n "$B64" ]; then
  echo "$B64" | base64 -d > "$OUT"
  [ -s "$OUT" ] || { echo '{"ok":false,"error":"decoded image is empty"}'; exit 3; }
  echo "{\"ok\":true,\"out\":\"$OUT\"}"
else
  ERR=$(echo "$RESP" | jq -c '{type:(.error.type // null), message:((.error.message // "unknown")[:200])}' 2>/dev/null || echo '"unparseable response"')
  echo "{\"ok\":false,\"error\":$ERR}"
  exit 2
fi
