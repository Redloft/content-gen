#!/usr/bin/env bash
# run-mockup.sh — оркестратор ветки /content-mockup.
#
# Механические шаги (детерминированные); суждения (бренд→контексты, вопросы назначения,
# синтез арт-дирекшна из тиндера) выполняет Claude по SKILL.md и передаёт сюда JSON-файлами.
#
# КОНТРАКТ БЕЗОПАСНОСТИ (plan-panel):
#   - state.json, скриншоты, рамки, композит — БЕЗ секретов, вне op run.
#   - ТОЛЬКО генерация Recraft-сцен обёрнута в ОДИН op run (короткое окно секрета).
#
# Подкоманды:
#   capture  --url U --out DIR [--for-page PATH] [--full-page]
#            → скриншоты + brand-probe + palette (+ slots если --for-page) → state.json
#   explore  --out DIR --contexts contexts.json [--devices a,b] [--tier T]
#            → колода A(рамки)+C(сцены) → cards.json + deck.html + feedback-server (порт/токен в stdout)
#   produce  --out DIR --art art.json [--slots slots.json] [--devices a,b] [--tier T]
#            → продовый объём под слоты (desktop+mobile) в выбранном направлении → grid
#   grid     --out DIR      → пересобрать preview.html
#
# Общее: state.json в <out>/ отражает фазу и пути (для --resume оркестрации Claude).
set -uo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
PY="python3"; NODE="node"

# Secrets: если есть lib/all-secrets.env + 1Password CLI (op) — генерация Recraft-сцен
# идёт под op run (секрет только в дочернем процессе). Иначе — RECRAFT_API_KEY берётся
# из окружения напрямую. Скриншоты/рамки/композит секретов не требуют (всегда вне op).
run_ai(){  # run_ai <cmd...>
  if [ -f "$LIB/all-secrets.env" ] && command -v op >/dev/null 2>&1; then
    op run --no-masking=false --env-file="$LIB/all-secrets.env" -- "$@"
  else
    "$@"
  fi
}

log(){ printf '  %s\n' "$*" >&2; }
step(){ printf '\n▸ %s\n' "$*" >&2; }
jset(){ # jset <file> <jq-filter> — атомарно обновить state.json
  local f="$1"; shift; local tmp="$f.tmp"
  if [ -f "$f" ]; then jq "$@" "$f" > "$tmp"; else echo '{}' | jq "$@" > "$tmp"; fi
  mv "$tmp" "$f"
}

# ── брэнд-производный фон (палитра) для рамок ветки A ──────────────────────────
bg_from_state(){ # echo "c1,c2" из палитры state.json (или дефолт)
  local st="$1"
  local c1 c2 dark
  c1=$(jq -r '.brand.palette.colors[0] // "#0f1420"' "$st" 2>/dev/null)
  c2=$(jq -r '.brand.palette.colors[1] // .brand.palette.colors[0] // "#1b2436"' "$st" 2>/dev/null)
  echo "$c1,$c2"
}

# ══════════════════════════════════════════════════════════════════════════════
cmd_capture(){
  local URL="" OUT="" FORPAGE="" FULL=""
  while [ $# -gt 0 ]; do case "$1" in
    --url) URL="$2"; shift 2;; --out) OUT="$2"; shift 2;;
    --for-page) FORPAGE="$2"; shift 2;; --full-page) FULL="--full-page"; shift;;
    *) shift;; esac; done
  [ -n "$URL" ] && [ -n "$OUT" ] || { echo '{"ok":false,"error":"capture: need --url --out"}'; return 1; }
  mkdir -p "$OUT/shots"
  local ST="$OUT/state.json"

  step "Скриншоты (Playwright, SSRF-guarded)"
  local CAP; CAP=$($NODE "$LIB/capture.mjs" --url "$URL" --out-dir "$OUT/shots" \
        --viewports desktop,mobile,tablet --measure-slots $FULL 2>>"$OUT/capture.err")
  if [ "$(echo "$CAP" | jq -r '.ok')" != "true" ]; then
    echo "$CAP"; log "capture.err:"; tail -3 "$OUT/capture.err" >&2; return 1
  fi
  echo "$CAP" | jq -r '.shots[] | "  ✓ \(.viewport): \(.file)"' >&2

  step "Бренд + палитра"
  local BR; BR=$($NODE "$LIB/brand-probe.mjs" --url "$URL" 2>/dev/null || echo '{"ok":false}')
  local DESKSHOT; DESKSHOT=$(echo "$CAP" | jq -r '.shots[]|select(.viewport=="desktop")|.file')
  local PAL='{"ok":false}'
  [ -f "$DESKSHOT" ] && PAL=$($PY "$LIB/palette.py" "$DESKSHOT" --n 5 2>/dev/null || echo '{"ok":false}')
  log "бренд: $(echo "$BR" | jq -r '.name // "?"') · вайб: $(echo "$BR" | jq -rc '.vibe // []')"
  log "палитра: $(echo "$PAL" | jq -rc '.colors // []')"

  # слоты: репо → slots-from-page; живой url → из capture.measure; иначе — later ask
  local SLOTS='null'
  if [ -n "$FORPAGE" ]; then
    if [ -e "$FORPAGE" ]; then
      SLOTS=$($NODE "$LIB/slots-from-page.mjs" --path "$FORPAGE" 2>/dev/null || echo 'null')
    else
      SLOTS=$(echo "$CAP" | jq '{ok:true,slots:(.slots // []|map({id:("live-"+(.w|tostring)+"x"+(.h|tostring)),purpose:.kind,desktop:{w:.w,h:.h},mobile:{w:(.w|if .>760 then 760 else . end),h:.h},format:"webp"})),fallback:((.slots|length)==0)}')
    fi
    local NS; NS=$(echo "$SLOTS" | jq -r '.slots|length' 2>/dev/null || echo 0)
    if [ "$(echo "$SLOTS" | jq -r '.fallback // false')" = "true" ] || [ "${NS:-0}" -eq 0 ]; then
      log "⚠ слоты не найдены → назначение уточнит Claude (AskUserQuestion-пресет)"
    else
      log "слотов найдено: $NS"
    fi
  fi

  echo '{}' > "$ST"
  jset "$ST" --arg url "$URL" --argjson cap "$CAP" --argjson br "$BR" --argjson pal "$PAL" --argjson slots "$SLOTS" \
    '.phase="captured" | .url=$url | .shots=$cap.shots | .brand={name:$br.name,logo:$br.logo,vibe:($br.vibe//[]),themeColor:$br.themeColor,palette:$pal} | .slots=$slots'
  echo "{\"ok\":true,\"phase\":\"captured\",\"state\":\"$ST\"}"
}

# ── сгенерировать один мокап: рамка(A) или сцена(C) + композит ─────────────────
# A: gen_frame <device> <shot> <out> <bg> ; C-сцены генерятся пачкой в op run (см. explore/produce)
gen_frame(){ # offline
  local device="$1" shot="$2" out="$3" bg="$4"
  [ -n "$shot" ] && [ -f "$shot" ] || { log "✗ нет скриншота: ${shot:-<пусто>}"; return 1; }
  local sw sh; read sw sh < <($PY - "$shot" <<'PY'
import sys
try:
    from PIL import Image
    w, h = Image.open(sys.argv[1]).size
    print(int(w), int(h))
except Exception:
    print("0 0")
PY
)
  { [ -n "$sw" ] && [ "$sw" -gt 0 ] 2>/dev/null && [ "$sh" -gt 0 ] 2>/dev/null; } \
    || { log "✗ не удалось получить размеры: $shot"; return 1; }
  local frame="${out%.png}.frame.png"
  $PY "$LIB/frames.py" --device "$device" --shot-w "$sw" --shot-h "$sh" --out "$frame" --bg "$bg" >/dev/null 2>&1 || return 1
  $PY "$LIB/frame-composite.py" --scene "$frame" --shot "$shot" --out "$out" --mode green --bleed 3 >/dev/null 2>&1 && rm -f "$frame"
}

# ══════════════════════════════════════════════════════════════════════════════
cmd_explore(){
  local OUT="" CONTEXTS="" DEVICES="browser,iphone" TIER="mid"
  while [ $# -gt 0 ]; do case "$1" in
    --out) OUT="$2"; shift 2;; --contexts) CONTEXTS="$2"; shift 2;;
    --devices) DEVICES="$2"; shift 2;; --tier) TIER="$2"; shift 2;; *) shift;; esac; done
  local ST="$OUT/state.json"
  [ -f "$ST" ] || { echo '{"ok":false,"error":"explore: state.json нет, сначала capture"}'; return 1; }
  mkdir -p "$OUT/deck/page"
  local BG; BG=$(bg_from_state "$ST")
  local DESKSHOT MOBSHOT
  DESKSHOT=$(jq -r '.shots[]|select(.viewport=="desktop")|.file' "$ST")
  MOBSHOT=$(jq -r '.shots[]|select(.viewport=="mobile")|.file' "$ST")

  local CARDS="[]"; local n=0
  step "Ветка A — рамки устройств (офлайн)"
  IFS=',' read -ra DEVS <<< "$DEVICES"
  for dev in "${DEVS[@]}"; do
    local shot="$DESKSHOT"; case "$dev" in iphone) shot="$MOBSHOT";; esac
    local out="$OUT/deck/cardA-$dev.png"
    if gen_frame "$dev" "$shot" "$out" "$BG"; then
      n=$((n+1)); log "✓ [$n] рамка $dev"
      CARDS=$(echo "$CARDS" | jq --arg id "A-$dev" --arg img "cardA-$dev.png" --arg l "Рамка · $dev" '. + [{card_id:$id,image:("../"+$img),label:$l,meta:"A"}]')
    else log "✗ рамка $dev (пропущено)"; fi
  done

  # Ветка C — сцены (Recraft, ОДИН op run на всю пачку)
  if [ "$TIER" != "explore" ] && [ -n "$CONTEXTS" ] && [ -f "$CONTEXTS" ] && jq -e '.[0]' "$CONTEXTS" >/dev/null 2>&1; then
    step "Ветка C — контекст-сцены (Recraft, один op run)"
    local NJOBS; NJOBS=$(jq 'length' "$CONTEXTS")
    log "сцен к генерации: $NJOBS  ·  оценка ~\$$(echo "$NJOBS*0.04" | bc -l | xargs printf '%.2f')"
    # пути передаём через ЭКСПОРТ env (op run пробрасывает окружение) — без хрупкого
    # string-embedding в bash -c; безопасно для путей с пробелами/кириллицей/спецсимволами
    export MK_LIB="$LIB" MK_OUT="$OUT" MK_CTX="$CONTEXTS"
    run_ai bash -c '
      jq -c ".[]" "$MK_CTX" | nl -w1 -s"|" | while IFS="|" read i row; do
        ctxstr=$(echo "$row" | jq -r ".context"); dev=$(echo "$row" | jq -r ".device // \"laptop\"")
        size=$(echo "$row" | jq -r ".size // \"1365x1024\"")
        bash "$MK_LIB/scene-recraft.sh" --context "$ctxstr" --device "$dev" --size "$size" \
          --out "$MK_OUT/deck/sceneC-$i.png" >>"$MK_OUT/deck/scenes.log" 2>&1 && echo "ok $i" || echo "fail $i"
      done' 2>>"$OUT/deck/scenes.err" | while read status i; do
        [ "$status" = "ok" ] && log "✓ сцена $i" || log "✗ сцена $i (пропущено)"
      done
    unset MK_LIB MK_OUT MK_CTX
    # композит скриншота в каждую удавшуюся сцену (офлайн)
    local ci=0
    while IFS= read -r row; do
      ci=$((ci+1))
      local scene="$OUT/deck/sceneC-$ci.png"; [ -f "$scene" ] || continue
      local dev; dev=$(echo "$row" | jq -r '.device // "laptop"')
      local shot="$DESKSHOT"; case "$dev" in phone) shot="$MOBSHOT";; esac
      local out="$OUT/deck/cardC-$ci.png"
      if $PY "$LIB/frame-composite.py" --scene "$scene" --shot "$shot" --out "$out" --mode green --bleed 3 --despill 1 >/dev/null 2>&1; then
        n=$((n+1)); log "✓ [$n] контекст-сцена $ci"
        local lbl; lbl=$(echo "$row" | jq -r '.label // "контекст"')
        CARDS=$(echo "$CARDS" | jq --arg id "C-$ci" --arg img "cardC-$ci.png" --arg l "$lbl" '. + [{card_id:$id,image:("../"+$img),label:$l,meta:"C"}]')
      else log "✗ композит сцены $ci (зелёный не найден, пропущено)"; fi
    done < <(jq -c '.[]' "$CONTEXTS")
  fi

  local NCARDS; NCARDS=$(echo "$CARDS" | jq 'length')
  if [ "$NCARDS" -lt 2 ]; then
    echo "{\"ok\":false,\"error\":\"собрано меньше 2 карточек ($NCARDS) — нечего показывать в деке\"}"; return 1
  fi
  echo "$CARDS" > "$OUT/deck/cards.json"

  step "Тиндер-дека + feedback-server"
  local NONCE; NONCE=$(uuidgen)
  $NODE "$LIB/feedback-server.js" --run-dir "$OUT/deck" --round 1 --nonce "$NONCE" > "$OUT/deck/srv.json" 2>"$OUT/deck/srv.err" &
  local SRVPID=$!
  # poll вместо жёсткого sleep (медленный FS / Node startup): ждём валидную первую строку {port}
  local tries=0 SRVLINE=""
  while [ $tries -lt 50 ]; do
    if [ -s "$OUT/deck/srv.json" ] && jq -e '.port' "$OUT/deck/srv.json" >/dev/null 2>&1; then
      SRVLINE=$(head -1 "$OUT/deck/srv.json"); break
    fi
    tries=$((tries+1)); sleep 0.1
  done
  if [ -z "$SRVLINE" ]; then
    kill "$SRVPID" 2>/dev/null   # не оставляем висящий процесс
    echo '{"ok":false,"error":"feedback-server не стартовал за ~5с"}'; cat "$OUT/deck/srv.err" >&2; return 1
  fi
  local PORT TOKEN
  PORT=$(echo "$SRVLINE" | jq -r '.port'); TOKEN=$(echo "$SRVLINE" | jq -r '.token')
  $NODE "$LIB/deck-page.js" --cards "$OUT/deck/cards.json" --out "$OUT/deck/page/deck.html" \
    --port "$PORT" --token "$TOKEN" --nonce "$NONCE" --round 1 --title "Мокапы — выбор направления" >/dev/null

  jset "$ST" --arg deck "$OUT/deck/page/deck.html" --arg ans "$OUT/deck/round-1.answers.json" \
    --argjson pid "$SRVPID" --argjson port "$PORT" \
    '.phase="explore" | .deck={html:$deck,answers:$ans,server_pid:$pid,port:$port}'
  echo "{\"ok\":true,\"phase\":\"explore\",\"cards\":$NCARDS,\"deck\":\"$OUT/deck/page/deck.html\",\"answers\":\"$OUT/deck/round-1.answers.json\",\"server_pid\":$SRVPID}"
}

# ══════════════════════════════════════════════════════════════════════════════
cmd_produce(){
  local OUT="" ART="" SLOTS="" DEVICES="browser,iphone" TIER="mid"
  while [ $# -gt 0 ]; do case "$1" in
    --out) OUT="$2"; shift 2;; --art) ART="$2"; shift 2;; --slots) SLOTS="$2"; shift 2;;
    --devices) DEVICES="$2"; shift 2;; --tier) TIER="$2"; shift 2;; *) shift;; esac; done
  local ST="$OUT/state.json"
  [ -f "$ST" ] && [ -n "$ART" ] && [ -f "$ART" ] || { echo '{"ok":false,"error":"produce: need state.json + --art"}'; return 1; }
  mkdir -p "$OUT/final"
  local BG; BG=$(jq -r '(.bg // "#0f1420,#1b2436")' "$ART")
  local MODE; MODE=$(jq -r '.mode // "frame"' "$ART")       # frame(A) | scene(C)
  local DEVICE; DEVICE=$(jq -r '.device // "browser"' "$ART")
  local DESKSHOT MOBSHOT
  DESKSHOT=$(jq -r '.shots[]|select(.viewport=="desktop")|.file' "$ST")
  MOBSHOT=$(jq -r '.shots[]|select(.viewport=="mobile")|.file' "$ST")

  # источник слотов: --slots | state.slots | дефолт (hero)
  local SLOTSRC="$SLOTS"
  [ -z "$SLOTSRC" ] && SLOTSRC="$OUT/.slots.json" && jq '.slots // {slots:[{id:"default-hero",purpose:"hero",desktop:{w:1600,h:900},mobile:{w:760,h:900},format:"webp"}]}' "$ST" > "$SLOTSRC"
  local SLOTLIST; SLOTLIST=$(jq -c '(.slots // .) | if type=="array" then . else .slots end' "$SLOTSRC" 2>/dev/null)
  if [ -z "$SLOTLIST" ] || [ "$SLOTLIST" = "null" ]; then
    SLOTLIST='[{"id":"default-hero","desktop":{"w":1600,"h":900},"mobile":{"w":760,"h":900}}]'
  fi

  step "Продовый объём: mode=$MODE, устройство=$DEVICE"
  local n=0 fails=0
  # для scene-mode заранее генерим ОДНУ сцену на устройство (в op run), переиспользуем для всех слотов
  local SCENE=""
  if [ "$MODE" = "scene" ]; then
    local CTX; CTX=$(jq -r '.context // "a clean neutral studio background"' "$ART")
    local sdev; sdev=$(jq -r '.scene_device // "laptop"' "$ART")
    step "Ветка C: генерирую опорную сцену (op run)"
    run_ai bash "$LIB/scene-recraft.sh" --context "$CTX" --device "$sdev" --out "$OUT/final/_scene.png" >/dev/null 2>>"$OUT/final/scene.err" \
      && SCENE="$OUT/final/_scene.png" || log "✗ сцена не сгенерилась → откат на рамку"
    [ -z "$SCENE" ] && MODE="frame"
  fi

  while IFS= read -r slot; do
    local sid; sid=$(echo "$slot" | jq -r '.id')
    for vp in desktop mobile; do
      local w h shot; w=$(echo "$slot" | jq -r ".$vp.w // 1200"); h=$(echo "$slot" | jq -r ".$vp.h // 800")
      shot="$DESKSHOT"; [ "$vp" = "mobile" ] && shot="$MOBSHOT"
      [ -f "$shot" ] || { fails=$((fails+1)); log "✗ $sid/$vp: нет скриншота"; continue; }
      local out="$OUT/final/${sid}-${vp}.png"
      local okgen=1
      if [ "$MODE" = "scene" ] && [ -n "$SCENE" ]; then
        $PY "$LIB/frame-composite.py" --scene "$SCENE" --shot "$shot" --out "$out" --mode green --bleed 3 --despill 1 >/dev/null 2>&1 || okgen=0
      else
        local dev="$DEVICE"; [ "$vp" = "mobile" ] && dev="iphone"
        gen_frame "$dev" "$shot" "$out" "$BG" || okgen=0
      fi
      if [ "$okgen" = 1 ]; then
        # привести к точным размерам слота (crop-to-fit)
        $PY - "$out" "$w" "$h" <<'PY' 2>/dev/null
import sys; from PIL import Image, ImageOps
p=sys.argv[1]; w=int(sys.argv[2]); h=int(sys.argv[3])
im=Image.open(p).convert("RGB"); ImageOps.fit(im,(w,h),Image.LANCZOS).save(p)
PY
        n=$((n+1)); log "✓ [$n] $sid/$vp → ${w}×${h}"
      else fails=$((fails+1)); log "✗ $sid/$vp (пропущено)"; fi
    done
  done < <(echo "$SLOTLIST" | jq -c '.[]')

  cmd_grid --out "$OUT" --dir final >/dev/null 2>>"$OUT/grid.err" || log "⚠ grid не собрался (preview.html пропущен), см. grid.err"
  jset "$ST" --argjson made "$n" --argjson f "$fails" '.phase="produced" | .produced={made:$made,failed:$f}'
  echo "{\"ok\":true,\"phase\":\"produced\",\"made\":$n,\"failed\":$fails,\"grid\":\"$OUT/final/preview.html\"}"
}

cmd_grid(){
  local OUT="" DIR="final"
  while [ $# -gt 0 ]; do case "$1" in --out) OUT="$2"; shift 2;; --dir) DIR="$2"; shift 2;; *) shift;; esac; done
  $PY "$LIB/render-grid.py" "$OUT/$DIR" "content-mockup" >/dev/null 2>&1 \
    && echo "{\"ok\":true,\"grid\":\"$OUT/$DIR/preview.html\"}" || echo '{"ok":false,"error":"grid failed"}'
}

# ── dispatch ──────────────────────────────────────────────────────────────────
SUB="${1:-}"; shift || true
case "$SUB" in
  capture) cmd_capture "$@";;
  explore) cmd_explore "$@";;
  produce) cmd_produce "$@";;
  grid)    cmd_grid "$@";;
  *) echo '{"ok":false,"error":"usage: run-mockup.sh {capture|explore|produce|grid} ..."}'; exit 64;;
esac
