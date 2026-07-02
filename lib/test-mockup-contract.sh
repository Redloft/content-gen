#!/usr/bin/env bash
# test-mockup-contract.sh — контракт-тест: /content-screencast НЕ регрессирует /content-mockup (§11).
# Проверяет что общие файлы (capture.mjs, ssrf.mjs, frames.py) сохраняют интерфейсы сиблинга.
# Usage: test-mockup-contract.sh [--url https://example.com]  (default example.com — стабильный)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
URL="https://example.com"
[ "${1:-}" = "--url" ] && URL="$2"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
t(){ if eval "$2"; then PASS=$((PASS+1)); echo "  ✓ $1"; else FAIL=$((FAIL+1)); echo "  ✗ $1"; fi }

echo "▸ contract: capture.mjs (сиблинг-интерфейс /content-mockup)"
CAP=$(node "$HERE/capture.mjs" --url "$URL" --out-dir "$TMP/shots" --viewports desktop,mobile 2>/dev/null)
t "capture.mjs exit + ok:true"        '[ -n "$CAP" ] && echo "$CAP" | jq -e ".ok" >/dev/null'
t "JSON-shape: shots[].viewport"      'echo "$CAP" | jq -e ".shots[0].viewport" >/dev/null'
t "JSON-shape: shots[].{w,h,file}"    'echo "$CAP" | jq -e ".shots[0].w and .shots[0].h and .shots[0].file" >/dev/null'
t "оба viewport'а вернулись"          '[ "$(echo "$CAP" | jq ".shots|length")" -ge 2 ]'
t "файлы ненулевые"                   'for f in $(echo "$CAP" | jq -r ".shots[].file"); do [ -s "$f" ] || exit 1; done'

echo "▸ contract: ssrf.mjs (блокирует приватные)"
SSRF=$(node "$HERE/capture.mjs" --url "http://127.0.0.1:9/x" --out-dir "$TMP/ssrf" 2>/dev/null || true)
t "loopback отклонён"                 '! echo "$SSRF" | jq -e ".ok==true" >/dev/null 2>&1'

echo "▸ contract: frames.py (рамка с green-экраном тех же размеров)"
python3 "$HERE/frames.py" --device browser --shot-w 1440 --shot-h 900 --out "$TMP/fr.png" >/dev/null 2>&1
t "frames.py рендерит"                '[ -s "$TMP/fr.png" ]'
GEO=$(python3 "$HERE/screencast-frame-alpha.py" --frame "$TMP/fr.png" --out "$TMP/fr-a.png" 2>/dev/null)
t "green-экран детектится"            'echo "$GEO" | jq -e ".ok" >/dev/null'
t "экран == shot-размерам (±2px)"     'w=$(echo "$GEO"|jq -r .screen.w); h=$(echo "$GEO"|jq -r .screen.h); [ $((w>1437&&w<1443)) = 1 ] && [ $((h>897&&h<903)) = 1 ]'

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
