#!/usr/bin/env bash
# scene-recraft.sh — сгенерировать атмосферную сцену с устройством, экран = chroma-green.
# Ветка C мокапов: Recraft рисует контекст (баня, spa, стол…), потом
# frame-composite.py --mode green вставит реальный скриншот в зелёный экран.
#
# Использует $RECRAFT_API_KEY из ОКРУЖЕНИЯ (оркестратор оборачивает в один op run).
#
# NB: в отличие от sibling'ов scene-gemini.sh/scene-openai.sh (retry 3× с backoff на
# 429/5xx), здесь API-ретрая на генерацию НЕТ — только один ретрай на СКАЧИВАНИЕ по URL.
# Recraft — fallback-провайдер D2 (не дефолт), стабилен на практике; при переводе его в
# основной путь портировать retry-loop из scene-gemini.sh для консистентности.
#
# Usage:
#   scene-recraft.sh --context "<сцена по-английски>" --device laptop|phone|tablet \
#       --out scene.png [--size 1365x1024] [--style realistic_image] [--prompt "<raw>"]
# stdout: JSON {ok, out} | {ok:false, error}
set -euo pipefail

CONTEXT=""; DEVICE="laptop"; OUT=""; SIZE="1365x1024"; STYLE="realistic_image"; RAW_PROMPT=""
while [ $# -gt 0 ]; do case "$1" in
  --context) CONTEXT="$2"; shift 2;;
  --device)  DEVICE="$2";  shift 2;;
  --out)     OUT="$2";     shift 2;;
  --size)    SIZE="$2";    shift 2;;
  --style)   STYLE="$2";   shift 2;;
  --prompt)  RAW_PROMPT="$2"; shift 2;;   # raw override — для дуэлей провайдеров на идентичных промтах
  *) shift;;
esac; done

{ [ -n "$CONTEXT" ] || [ -n "$RAW_PROMPT" ]; } && [ -n "$OUT" ] || { echo '{"ok":false,"error":"need --context (or --prompt) and --out"}'; exit 1; }
[ -n "${RECRAFT_API_KEY:-}" ] || { echo '{"ok":false,"error":"RECRAFT_API_KEY not in env (wrap in op run)"}'; exit 1; }

case "$DEVICE" in
  laptop)  PLACEMENT="an open modern laptop";;
  phone)   PLACEMENT="a modern smartphone held in a hand";;
  tablet)  PLACEMENT="a modern tablet";;
  *)       PLACEMENT="an open modern laptop";;
esac

# Жёсткая инструкция на chroma-green экран — ПЕРВЫМ предложением (иначе богатая
# арт-дирекция сцены её перебивает и Recraft разворачивает девайс спиной/гасит экран).
# Проверено 2026-07-02 на ДНК-референсах: screen-first + «filling 50-70% of the frame»
# держит экран крупным и чистым даже в насыщенных editorial-сценах.
PROMPT="CRITICAL: tight close-up composition — the device screen is the hero and fills 75-90% of the frame: a large, perfectly flat SOLID BRIGHT CHROMA-GREEN rectangle (pure #00FF00) facing the camera almost straight-on with only a slight angle, all four corners visible inside the frame, sharp straight edges, no glare, no reflections, no icons, no content, the entire screen uniform green. The environment is visible only at the edges of the frame around the screen. ${PLACEMENT} in ${CONTEXT}. Photorealistic editorial photograph, cinematic atmospheric directional light, rich material textures, high detail."
[ -n "$RAW_PROMPT" ] && PROMPT="$RAW_PROMPT"

REQ=$(jq -n --arg p "$PROMPT" --arg s "$STYLE" --arg z "$SIZE" \
  '{prompt:$p, style:$s, size:$z, n:1}')
RESP=$(curl -s --max-time 90 -X POST "https://external.api.recraft.ai/v1/images/generations" \
  -H "Authorization: Bearer $RECRAFT_API_KEY" -H "Content-Type: application/json" -d "$REQ")
URL=$(echo "$RESP" | jq -r '.data[0].url // empty')

if [ -n "$URL" ]; then
  curl -s --max-time 40 -o "$OUT" "$URL"
  # временный URL Recraft мог истечь / сеть лагнуть → пустой файл; один ретрай
  if [ ! -s "$OUT" ]; then
    sleep 1; curl -s --max-time 40 -o "$OUT" "$URL"
  fi
  if [ ! -s "$OUT" ]; then
    echo '{"ok":false,"error":"downloaded scene is empty (url expired?)"}'; exit 3
  fi
  echo "{\"ok\":true,\"out\":\"$OUT\"}"
else
  ERR=$(echo "$RESP" | jq -c '{code,message:(.message // .error // "unknown")}' 2>/dev/null || echo "\"$(echo "$RESP" | head -c 160)\"")
  echo "{\"ok\":false,\"error\":$ERR}"
  exit 2
fi
