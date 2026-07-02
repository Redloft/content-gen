#!/usr/bin/env bash
# run-screencast.sh — оркестратор ветки /content-screencast (SCREENCAST-SPEC.md).
#
# MVP = Tier 2 (pan-screenshot): full-page скриншот → ffmpeg-панорама 60fps → рамка девайса.
# Механика детерминированная; суждения (тир/формат/палитра/gates) ведёт Claude по SKILL.md.
#
# КОНТРАКТЫ (plan-panel v3):
#   - state.json = source of truth; unit = (format/device); single writer = этот скрипт (§6.1).
#   - Exit-code 0 ≠ success: каждый stage завершается verify-подшагом (§6.2).
#   - continue-on-error по unit'ам; reason из enum (§6.3, §12).
#   - Никаких секретов: MVP полностью офлайн (capture/ffmpeg/PIL), op run не нужен.
#   - subprocess-гигиена: ffmpeg/node/python вызываются массивами аргументов, имена
#     файлов — от unit-slug (не от URL).
#
# Подкоманды:
#   validate --url U --formats F --tier T [--duration D] [--speed S] [--devices D]
#   capture  --out DIR --url U --formats F [--devices D]
#   polish   --out DIR [--duration D] [--speed S]
#   frame    --out DIR [--bg "c1,c2"]
#   deck     --out DIR
#   run      --out DIR --url U --formats F [--tier mid] [все флаги выше]  # все стадии
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/lib"
MATRIX="$LIB/screencast-matrix.json"
PY="python3"; NODE="node"

log(){ printf '  %s\n' "$*" >&2; }
step(){ printf '\n▸ %s\n' "$*" >&2; }
fail(){ printf '{"ok":false,"error":"%s"}\n' "$1"; exit 1; }
jset(){ # jset <state> <jq-args...> — атомарное обновление state.json (single writer)
  local f="$1"; shift; local tmp="$f.tmp"
  if [ -f "$f" ]; then jq "$@" "$f" > "$tmp"; else echo '{}' | jq "$@" > "$tmp"; fi
  mv "$tmp" "$f"
}
event(){ # event <state> <stage> <unit> <event> <reason-enum|null> [detail]
  # reason — строго enum §12: timeout|verify_failed|ssrf_blocked|capture_error|ffmpeg_error|upload_error|user_abort|unknown
  local st="$1" stage="$2" unit="$3" ev="$4" reason="${5:-}" detail="${6:-}"
  jset "$st" --arg s "$stage" --arg u "$unit" --arg e "$ev" --arg r "$reason" --arg d "$detail" \
    '.events += [{t: (now|todate), stage: $s, unit: $u, event: $e,
                  reason: (if $r=="" then null else $r end),
                  detail: (if $d=="" then null else $d end)}]'
}
# lock на run-папку (finalize critical #1): jset = read-modify-write, инвариант single
# writer гарантируем запретом конкурентных запусков на один --out
lock_out(){
  [ -n "$OUT" ] || return 0
  mkdir -p "$OUT"
  if ! mkdir "$OUT/.lock" 2>/dev/null; then
    fail "run-папка занята другим процессом (есть $OUT/.lock; если это остаток от crash — удали вручную)"
  fi
  trap 'rmdir "$OUT/.lock" 2>/dev/null' EXIT
}
unit_set(){ # unit_set <state> <unit> <stage> <jq-object-string>
  local st="$1" unit="$2" stage="$3" obj="$4"
  jset "$st" --arg u "$unit" --arg s "$stage" --argjson o "$obj" '.units[$u][$s] = $o'
}
slug(){ echo "$1" | tr '/' '_' ; }

# watchdog <timeout_s> <cmd...>: kill по таймауту (§8.4 — не зомби)
watchdog(){
  local t="$1"; shift
  "$@" & local pid=$!
  ( sleep "$t" && kill -9 "$pid" 2>/dev/null ) & local wd=$!
  wait "$pid" 2>/dev/null; local rc=$?
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  return $rc
}

# ── ffprobe verify (§6.2): video-stream, duration>0 и ±10%, resolution ─────────
verify_video(){ # verify_video <file> <expected_dur|-> <expected_w|-> <expected_h|->
  local f="$1" ed="$2" ew="$3" eh="$4"
  [ -s "$f" ] || { echo "verify_failed:empty"; return 1; }
  local probe; probe=$(ffprobe -v quiet -print_format json -show_streams -show_format "$f" 2>/dev/null) || { echo "verify_failed:ffprobe"; return 1; }
  local w h dur nbf
  w=$(echo "$probe" | jq -r '[.streams[]|select(.codec_type=="video")][0].width // 0')
  h=$(echo "$probe" | jq -r '[.streams[]|select(.codec_type=="video")][0].height // 0')
  dur=$(echo "$probe" | jq -r '.format.duration // 0')
  [ "$w" -gt 0 ] 2>/dev/null || { echo "verify_failed:no_video_stream"; return 1; }
  awk -v d="$dur" 'BEGIN{exit !(d>0)}' || { echo "verify_failed:zero_duration"; return 1; }
  if [ "$ed" != "-" ]; then
    # finalize warn #6: null/0 expected → отдельная причина, не тихий pass
    awk -v e="$ed" 'BEGIN{exit !(e>0)}' || { echo "verify_failed:missing_expected_duration"; return 1; }
    # tolerance = max(10%, 0.5s) — floor для коротких клипов (3s static-loop)
    awk -v d="$dur" -v e="$ed" 'BEGIN{t=e*0.1; if(t<0.5)t=0.5; exit !(d>=e-t && d<=e+t)}' || { echo "verify_failed:duration_off(got=${dur},want=${ed}±max(10%,0.5s))"; return 1; }
  fi
  if [ "$ew" != "-" ]; then
    [ "$w" = "$ew" ] && [ "$h" = "$eh" ] || { echo "verify_failed:resolution(got=${w}x${h},want=${ew}x${eh})"; return 1; }
  fi
  echo "ok:${w}x${h}@${dur}s"
}

png_dims(){ # png_dims <file> → "W H"
  "$PY" - "$1" <<'EOF'
import sys
from PIL import Image
im = Image.open(sys.argv[1]); print(im.size[0], im.size[1])
EOF
}

# ── arg parsing (общий) ─────────────────────────────────────────────────────────
CMD="${1:-}"; shift || true
URL="" OUT="" FORMATS="" TIER="mid" DURATION="" SPEED="" DEVICES="" BG="" PII_OK=0 WITH_UPLOAD=0 WITH_DERIVE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --url) URL="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --formats) FORMATS="$2"; shift 2;;
    --tier) TIER="$2"; shift 2;;
    --duration) DURATION="$2"; shift 2;;
    --speed) SPEED="$2"; shift 2;;
    --devices) DEVICES="$2"; shift 2;;
    --bg) BG="$2"; shift 2;;
    --pii-ok) PII_OK=1; shift;;
    --upload) WITH_UPLOAD=1; shift;;
    --derive|--loop) WITH_DERIVE=1; shift;;
    --scenario) SCENARIO="$2"; shift 2;;
    --unit) UNIT="$2"; shift 2;;
    --credits) CREDITS="$2"; shift 2;;
    --params-hash) PARAMS_HASH="$2"; shift 2;;
    --job-id) JOB_ID="$2"; shift 2;;
    --file) FILE="$2"; shift 2;;
    --confirm-total) CONFIRM_TOTAL="$2"; shift 2;;
    --refunded) REFUNDED=1; shift;;
    *) shift;;
  esac
done
SCENARIO="${SCENARIO:-}"; UNIT="${UNIT:-}"; CREDITS="${CREDITS:-}"; PARAMS_HASH="${PARAMS_HASH:-}"
JOB_ID="${JOB_ID:-}"; FILE="${FILE:-}"; CONFIRM_TOTAL="${CONFIRM_TOTAL:-}"; REFUNDED="${REFUNDED:-0}"

# ── VALIDATE (§7.1, fail-fast ДО capture) ───────────────────────────────────────
do_validate(){
  [ -f "$MATRIX" ] || fail "matrix not found: $MATRIX"
  command -v jq >/dev/null || fail "jq not installed"
  command -v ffmpeg >/dev/null || fail "ffmpeg not installed — brew install ffmpeg (сам не ставлю: §7.1)"
  command -v ffprobe >/dev/null || fail "ffprobe not installed — brew install ffmpeg"
  local ffv; ffv=$(ffmpeg -version 2>/dev/null | head -1 | grep -oE 'version [0-9]+' | grep -oE '[0-9]+')
  [ "${ffv:-0}" -ge 6 ] || fail "ffmpeg >=6.x required, got ${ffv:-unknown}"
  [ -n "$URL" ] || fail "--url required"
  case "$URL" in http://*|https://*) ;; *) fail "url must be http(s)";; esac
  [ -n "$FORMATS" ] || fail "--formats required"
  # tier известен?
  jq -e --arg t "$TIER" '.tiers[$t]' "$MATRIX" >/dev/null || fail "unknown tier: $TIER (allowed: $(jq -r '.tiers|keys|join(",")' "$MATRIX"))"
  jq -e --arg t "$TIER" '.tiers[$t].implemented' "$MATRIX" | grep -q true || fail "tier '$TIER' not implemented yet (MVP = mid)"
  # каждый формат: существует и совместим с tier
  local f
  for f in $(echo "$FORMATS" | tr ',' ' '); do
    jq -e --arg f "$f" '.formats[$f]' "$MATRIX" >/dev/null || fail "unknown format: $f (allowed: $(jq -r '.formats|keys|join(",")' "$MATRIX"))"
    jq -e --arg f "$f" --arg t "$TIER" '.formats[$f].tiers | index($t)' "$MATRIX" >/dev/null \
      || fail "format '$f' not supported on tier '$TIER' (supported: $(jq -r --arg f "$f" '.formats[$f].tiers|join(",")' "$MATRIX"))"
  done
  # devices известны?
  if [ -n "$DEVICES" ]; then
    local d
    for d in $(echo "$DEVICES" | tr ',' ' '); do
      jq -e --arg d "$d" '.devices[$d]' "$MATRIX" >/dev/null || fail "unknown device: $d (allowed: $(jq -r '.devices|keys|join(",")' "$MATRIX"))"
    done
  fi
  # диапазоны
  local dmin dmax smin smax
  dmin=$(jq -r '.limits.duration_min_s' "$MATRIX"); dmax=$(jq -r '.limits.duration_max_s' "$MATRIX")
  smin=$(jq -r '.limits.speed_min_px_s' "$MATRIX"); smax=$(jq -r '.limits.speed_max_px_s' "$MATRIX")
  if [ -n "$DURATION" ]; then
    awk -v v="$DURATION" -v a="$dmin" -v b="$dmax" 'BEGIN{exit !(v>=a && v<=b)}' || fail "--duration out of [$dmin,$dmax]"
  fi
  if [ -n "$SPEED" ]; then
    awk -v v="$SPEED" -v a="$smin" -v b="$smax" 'BEGIN{exit !(v>=a && v<=b)}' || fail "--speed out of [$smin,$smax]"
  fi
  # clicks требует сценарий (§5): fail-fast до capture
  if echo ",$FORMATS," | grep -q ",clicks,"; then
    [ -n "$SCENARIO" ] || fail "format 'clicks' requires --scenario <steps.json> (SPEC §5)"
    [ -f "$SCENARIO" ] || fail "scenario file not found: $SCENARIO"
    jq -e '.steps | length > 0' "$SCENARIO" >/dev/null 2>&1 || fail "scenario: .steps пуст или не JSON"
  fi
  echo '{"ok":true,"validated":true}'
}

# ── unit-план из formats×devices ────────────────────────────────────────────────
# echo строки "format device viewport" (device = явный или default формата)
plan_units(){
  local f dev vp
  for f in $(echo "$FORMATS" | tr ',' ' '); do
    if [ -n "$DEVICES" ]; then
      for dev in $(echo "$DEVICES" | tr ',' ' '); do
        vp=$(jq -r --arg d "$dev" '.devices[$d].viewport' "$MATRIX")
        echo "$f $dev $vp"
      done
    else
      dev=$(jq -r --arg f "$f" '.formats[$f].default_device' "$MATRIX")
      vp=$(jq -r --arg f "$f" '.formats[$f].viewport' "$MATRIX")
      echo "$f $dev $vp"
    fi
  done | sort -u
}

# ── CAPTURE: full-page скриншоты по нужным viewport (переиспользуем capture.mjs) ─
do_capture(){
  [ -n "$OUT" ] && [ -n "$URL" ] && [ -n "$FORMATS" ] || fail "capture: --out --url --formats required"
  mkdir -p "$OUT"
  local st="$OUT/state.json" run_id="sc-$(head -c4 /dev/urandom | xxd -p)"
  # init state (§6.1) если нет
  if [ ! -f "$st" ]; then
    jq -n --arg rid "$run_id" --arg url "$URL" --arg tier "$TIER" \
       --arg fmts "$FORMATS" --arg devs "$DEVICES" \
       '{schema_version:1, run_id:$rid, url:$url, tier:$tier,
         formats: ($fmts|split(",")), devices: (if $devs=="" then [] else ($devs|split(",")) end),
         cost_confirmed:{credits:0,total_estimate:0,confirmed_at:null},
         pii_confirmed:{third_party:[],confirmed_at:null},
         units:{}, events:[]}' > "$st"
  else
    local sv; sv=$(jq -r '.schema_version // 0' "$st")
    [ "$sv" = "1" ] || fail "state schema_version=$sv incompatible (want 1) — запусти заново в новой папке"
  fi
  # per-viewport вызовы capture.mjs (finalize warn #3): сбой одного viewport НЕ топит
  # остальные — continue-on-error §6.3 работает уже на стадии capture
  local cap_h_cap gtmo; cap_h_cap=$(jq -r '.limits.fullpage_height_cap_px' "$MATRIX"); gtmo=$(jq -r '.limits.goto_timeout_ms' "$MATRIX")
  local vp capjson
  declare -A VPJSON
  for vp in $(plan_units | awk '{print $3}' | sort -u); do
    step "capture: full-page @ $vp"
    if capjson=$("$NODE" "$LIB/capture.mjs" --url "$URL" --out-dir "$OUT/shots" --viewports "$vp" --full-page --timeout "$gtmo") \
       && echo "$capjson" | jq -e '.ok' >/dev/null; then
      VPJSON[$vp]="$capjson"
    else
      local errdetail; errdetail=$(echo "${capjson:-}" | jq -r '.error // "capture.mjs died"' 2>/dev/null || echo "capture.mjs died")
      local reason=capture_error
      case "$errdetail" in *SSRF*|*ssrf*|*private*) reason=ssrf_blocked;; esac
      log "✗ viewport $vp: $errdetail"
      VPJSON[$vp]=""
      # unit'ы этого viewport'а пометим failed в цикле ниже
      event "$st" capture "vp:$vp" failed "$reason" "$errdetail"
    fi
  done
  # verify + запись unit'ов (§6.2 capture: bytes>10KB, imgH>=viewportH)
  local f dev
  while read -r f dev vp; do
    local unit="$f/$dev"
    capjson="${VPJSON[$vp]:-}"
    if [ -z "$capjson" ]; then
      unit_set "$st" "$unit" capture '{"status":"failed","verified":false}'
      event "$st" capture "$unit" failed capture_error; continue
    fi
    # контракт capture.mjs: .file = полный путь (path.join(outDir,…))
    local shot; shot=$(echo "$capjson" | jq -r --arg v "$vp" '[.shots[]|select(.viewport==$v)][0].file // empty')
    if [ -z "$shot" ] || [ ! -s "$shot" ]; then
      unit_set "$st" "$unit" capture '{"status":"failed","verified":false}'
      event "$st" capture "$unit" failed capture_error "no shot for $vp"; continue
    fi
    local bytes dims w h
    bytes=$(stat -f%z "$shot" 2>/dev/null || echo 0)
    dims=$(png_dims "$shot"); w=${dims% *}; h=${dims#* }
    case "$w$h" in *[!0-9]*|"") w=0; h=0;; esac
    if [ "$bytes" -lt 10240 ] || [ "$w" -le 0 ] || [ "$h" -le 0 ]; then
      unit_set "$st" "$unit" capture '{"status":"failed","verified":false}'
      event "$st" capture "$unit" failed verify_failed "bytes=$bytes dims=${w}x${h}"; continue
    fi
    if [ "$h" -gt "$cap_h_cap" ]; then
      log "⚠ $unit: page height ${h}px > cap ${cap_h_cap}px — панорама по первым ${cap_h_cap}px"
    fi
    unit_set "$st" "$unit" capture "$(jq -n --arg a "$shot" --argjson b "$bytes" --argjson w "$w" --argjson h "$h" --arg vp "$vp" \
      '{status:"done", artifact:$a, verified:true, bytes:$b, img_w:$w, img_h:$h, viewport:$vp}')"
    event "$st" capture "$unit" done
    log "✓ $unit: ${w}x${h} (${bytes}b)"
  done < <(plan_units)
  jq '{ok:true, stage:"capture", units:(.units|map_values(.capture.status // "pending"))}' "$st"
}

# ── RECORD (T1 explore): реальная запись через record.mjs → транскод в polish ───
# Заполняет units[].record (webm) и units[].polish (mp4) — дальше frame/deck общие.
do_record(){
  [ -n "$OUT" ] || fail "record: --out required"
  local st="$OUT/state.json"
  # state мог не создаться (T1 не ходит через do_capture) — init как в do_capture
  if [ ! -f "$st" ]; then
    [ -n "$URL" ] && [ -n "$FORMATS" ] || fail "record: --url --formats required (нет state.json)"
    mkdir -p "$OUT"
    local run_id="sc-$(head -c4 /dev/urandom | xxd -p)"
    jq -n --arg rid "$run_id" --arg url "$URL" --arg tier "$TIER" \
       --arg fmts "$FORMATS" --arg devs "$DEVICES" \
       '{schema_version:1, run_id:$rid, url:$url, tier:$tier,
         formats: ($fmts|split(",")), devices: (if $devs=="" then [] else ($devs|split(",")) end),
         cost_confirmed:{credits:0,total_estimate:0,confirmed_at:null},
         pii_confirmed:{third_party:[],confirmed_at:null},
         units:{}, events:[]}' > "$st"
  fi
  local url speed tmo; url=$(jq -r '.url' "$st")
  speed="${SPEED:-$(jq -r '.limits.speed_default_px_s' "$MATRIX")}"
  tmo=$(jq -r '.limits.ffmpeg_timeout_s' "$MATRIX")
  mkdir -p "$OUT/rec" "$OUT/pan"
  local f dev vp
  while read -r f dev vp; do
    local unit="$f/$dev" uslug; uslug=$(slug "$f/$dev")
    jq -e --arg u "$unit" '.units[$u].polish.status=="done" and .units[$u].polish.verified' "$st" >/dev/null 2>&1 && { log "= $unit (resume)"; continue; }
    local webm="$OUT/rec/$uslug.webm" args=()
    [ -n "$SCENARIO" ] && [ "$f" = "clicks" ] && args+=(--scenario "$SCENARIO")
    step "record $unit: $vp (T1 live)"
    # watchdog и на node (finalize critical #1): goto 15s + сценарий 45s + финализация
    # recordVideo ~40s = 100s; зависший chromium НЕ держит lock вечно
    local rjson rec_budget=100
    rjson=$(watchdog "$rec_budget" "$NODE" "$LIB/record.mjs" --url "$url" --out "$webm" --viewport "$vp" \
                   --speed "$speed" ${DURATION:+--max-duration "$DURATION"} \
                   --timeout "$(jq -r '.limits.goto_timeout_ms' "$MATRIX")" "${args[@]}")
    local rrc=$?
    if [ "$rrc" = 137 ]; then
      unit_set "$st" "$unit" record '{"status":"failed","verified":false}'
      unit_set "$st" "$unit" polish '{"status":"failed","verified":false}'
      event "$st" record "$unit" failed timeout "record.mjs killed after ${rec_budget}s"
      log "✗ $unit: record timeout (${rec_budget}s)"; continue
    fi
    if [ "$rrc" != 0 ] || ! echo "$rjson" | jq -e '.ok' >/dev/null 2>&1; then
      local err reason=capture_error
      err=$(echo "${rjson:-}" | jq -r '.error // "record.mjs died"' 2>/dev/null || echo "record.mjs died")
      case "$(echo "${rjson:-}" | jq -r '.reason // ""' 2>/dev/null)" in ssrf) reason=ssrf_blocked;; esac
      unit_set "$st" "$unit" record '{"status":"failed","verified":false}'
      unit_set "$st" "$unit" polish '{"status":"failed","verified":false}'
      event "$st" record "$unit" failed "$reason" "$err"; log "✗ $unit: $err"; continue
    fi
    local blocked; blocked=$(echo "$rjson" | jq -c '.blocked_hosts')
    [ "$blocked" != "[]" ] && log "  ⚠ SSRF route-guard blocked: $blocked"
    unit_set "$st" "$unit" record "$(jq -n --arg a "$webm" --argjson b "$(echo "$rjson" | jq '.bytes')" \
      '{status:"done", artifact:$a, verified:true, bytes:$b}')"
    event "$st" record "$unit" done
    # транскод WebM → mp4 (h264, yuv420p, even, faststart) → polish-слот
    local out_mp4="$OUT/pan/$uslug.mp4"
    watchdog "$tmo" ffmpeg -y -v error -i "$webm" \
      -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" \
      -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p -movflags +faststart -an "$out_mp4" 2>>"$OUT/pan/$uslug.err"
    local rc=$?
    if [ "$rc" = 0 ]; then
      # длительность T1 определяется сценарием — verify без expected (только >0/stream)
      local v; v=$(verify_video "$out_mp4" "-" "-" "-")
      if [ "${v%%:*}" = "ok" ]; then
        local adur; adur=$(ffprobe -v quiet -print_format json -show_format "$out_mp4" | jq -r '.format.duration')
        unit_set "$st" "$unit" polish "$(jq -n --arg a "$out_mp4" --arg d "$adur" '{status:"done", artifact:$a, verified:true, duration:($d|tonumber)}')"
        event "$st" polish "$unit" done; log "✓ $unit: $v"
        rm -f "$webm"   # §8.4 TTL: WebM сразу после транскода
        jset "$st" --arg u "$unit" '.units[$u].record.artifact = null'
      else
        unit_set "$st" "$unit" polish '{"status":"failed","verified":false}'
        event "$st" polish "$unit" failed verify_failed "$v"; log "✗ $unit: $v"
      fi
    else
      local reason=ffmpeg_error; [ "$rc" = 137 ] && reason=timeout
      unit_set "$st" "$unit" polish '{"status":"failed","verified":false}'
      event "$st" polish "$unit" failed "$reason" "rc=$rc"; log "✗ $unit: transcode $reason"
    fi
  done < <(plan_units)
  jq '{ok:true, stage:"record", units:(.units|map_values(.polish.status // "pending"))}' "$st"
}

# ── POLISH: ffmpeg-панорама по длинному скриншоту (§4 T2) ───────────────────────
do_polish(){
  [ -n "$OUT" ] || fail "polish: --out required"
  local st="$OUT/state.json"; [ -f "$st" ] || fail "no state.json — сначала capture"
  local speed="${SPEED:-$(jq -r '.limits.speed_default_px_s' "$MATRIX")}"
  local dmin dmax hcap tmo
  dmin=$(jq -r '.limits.duration_min_s' "$MATRIX"); dmax=$(jq -r '.limits.duration_max_s' "$MATRIX")
  hcap=$(jq -r '.limits.fullpage_height_cap_px' "$MATRIX"); tmo=$(jq -r '.limits.ffmpeg_timeout_s' "$MATRIX")
  mkdir -p "$OUT/pan"
  local unit
  for unit in $(jq -r '.units | keys[]' "$st"); do
    jq -e --arg u "$unit" '.units[$u].capture.status=="done" and .units[$u].capture.verified' "$st" >/dev/null || { log "− $unit: capture не done, skip"; continue; }
    jq -e --arg u "$unit" '.units[$u].polish.status=="done" and .units[$u].polish.verified' "$st" >/dev/null 2>&1 && { log "= $unit: polish уже done (resume)"; continue; }
    local shot imgw imgh vp
    shot=$(jq -r --arg u "$unit" '.units[$u].capture.artifact' "$st")
    imgw=$(jq -r --arg u "$unit" '.units[$u].capture.img_w' "$st")
    imgh=$(jq -r --arg u "$unit" '.units[$u].capture.img_h' "$st")
    vp=$(jq -r --arg u "$unit" '.units[$u].capture.viewport' "$st")
    # guards на чтениях state (finalize warn #6): null → failed, не тихий мусор в арифметике
    case "$imgw$imgh" in *[!0-9]*|"")
      unit_set "$st" "$unit" polish '{"status":"failed","verified":false}'
      event "$st" polish "$unit" failed verify_failed "bad img dims in state: ${imgw}x${imgh}"; log "✗ $unit: bad dims"; continue;;
    esac
    # viewport-высота: единый источник = matrix.viewports (синк с capture.mjs VIEWPORTS)
    local vh dsf
    vh=$(jq -r --arg v "$vp" '.viewports[$v].h // 900' "$MATRIX")
    dsf=$(jq -r --arg v "$vp" '.viewports[$v].dsf // 2' "$MATRIX")
    local vhs=$((vh * dsf))                 # окно панорамы в source px
    local imgh_eff="$imgh"
    [ "$imgh_eff" -gt "$hcap" ] && imgh_eff="$hcap"
    # duration = clamp((imgH−viewH)/speed_src, dmin, dmax)  (§12; speed в CSS px/сек → ×dsf)
    local speed_src=$((speed * dsf))
    local dur static=0
    if [ "$imgh_eff" -le "$vhs" ]; then
      dur=3; static=1                       # §8.4: панорамировать нечего → статичный short-loop
      vhs="$imgh_eff"
      log "⚠ $unit: imgH<=viewportH → статичный 3s loop"
    else
      dur=$(awk -v ih="$imgh_eff" -v vh="$vhs" -v s="$speed_src" -v a="$dmin" -v b="$dmax" \
        'BEGIN{d=(ih-vh)/s; if(d<a)d=a; if(d>b)d=b; printf "%.2f", d}')
    fi
    [ -n "$DURATION" ] && dur="$DURATION"
    local uslug; uslug=$(slug "$unit")
    local out_mp4="$OUT/pan/$uslug.mp4"
    step "polish $unit: pan ${imgw}x${imgh_eff} window=${vhs}px dur=${dur}s (~$((${dur%.*}+2))s render)"
    # smoothstep easing по y; even-размеры для yuv420p
    local vf
    if [ "$static" = "1" ]; then
      vf="crop=w=trunc(iw/2)*2:h=trunc(${vhs}/2)*2:x=0:y=0"
    else
      vf="crop=w=iw:h=${imgh_eff}:x=0:y=0,crop=w=trunc(iw/2)*2:h=trunc(${vhs}/2)*2:x=0:y='(ih-oh)*(3*pow(min(t/${dur}\,1)\,2)-2*pow(min(t/${dur}\,1)\,3))'"
    fi
    watchdog "$tmo" ffmpeg -y -v error -loop 1 -framerate 60 -i "$shot" -t "$dur" \
         -vf "$vf" -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p -movflags +faststart "$out_mp4" 2>>"$OUT/pan/$uslug.err"
    local rc=$?
    if [ "$rc" = 0 ]; then
      local v; v=$(verify_video "$out_mp4" "$dur" "-" "-")
      if [ "${v%%:*}" = "ok" ]; then
        unit_set "$st" "$unit" polish "$(jq -n --arg a "$out_mp4" --arg d "$dur" '{status:"done", artifact:$a, verified:true, duration:($d|tonumber)}')"
        event "$st" polish "$unit" done; log "✓ $unit: $v"
      else
        unit_set "$st" "$unit" polish '{"status":"failed","verified":false}'
        event "$st" polish "$unit" failed verify_failed "$v"; log "✗ $unit: $v"
      fi
    else
      # enum §12: 137 = SIGKILL от watchdog → timeout, иначе ffmpeg_error
      local reason=ffmpeg_error; [ "$rc" = 137 ] && reason=timeout
      unit_set "$st" "$unit" polish '{"status":"failed","verified":false}'
      event "$st" polish "$unit" failed "$reason" "rc=$rc limit=${tmo}s"; log "✗ $unit: $reason (rc=$rc)"
    fi
  done
  jq '{ok:true, stage:"polish", units:(.units|map_values(.polish.status // "pending"))}' "$st"
}

# ── FRAME: рамка девайса поверх pan-видео (§4 T2 шаг 3-4) ───────────────────────
do_frame(){
  [ -n "$OUT" ] || fail "frame: --out required"
  local st="$OUT/state.json"; [ -f "$st" ] || fail "no state.json"
  local bg="${BG:-#0f1420,#1b2436}" tmo
  tmo=$(jq -r '.limits.ffmpeg_timeout_s' "$MATRIX")
  mkdir -p "$OUT/framed"
  local unit
  for unit in $(jq -r '.units | keys[]' "$st"); do
    jq -e --arg u "$unit" '.units[$u].polish.status=="done"' "$st" >/dev/null || { log "− $unit: polish не done, skip"; continue; }
    jq -e --arg u "$unit" '.units[$u].frame.status=="done" and .units[$u].frame.verified' "$st" >/dev/null 2>&1 && { log "= $unit (resume)"; continue; }
    local dev="${unit#*/}" pan uslug
    pan=$(jq -r --arg u "$unit" '.units[$u].polish.artifact' "$st")
    uslug=$(slug "$unit")
    # размеры pan-видео → shot-w/h для рамки (масштаб 0.5: рамка в CSS-подобных px)
    local pw ph
    pw=$(ffprobe -v quiet -print_format json -show_streams "$pan" | jq -r '[.streams[]|select(.codec_type=="video")][0].width // 0')
    ph=$(ffprobe -v quiet -print_format json -show_streams "$pan" | jq -r '[.streams[]|select(.codec_type=="video")][0].height // 0')
    if [ "$pw" -le 0 ] 2>/dev/null || [ "$ph" -le 0 ] 2>/dev/null; then
      unit_set "$st" "$unit" frame '{"status":"failed","verified":false}'
      event "$st" frame "$unit" failed verify_failed "pan video unreadable: ${pw}x${ph}"; log "✗ $unit: pan unreadable"; continue
    fi
    local fdev; fdev=$(jq -r --arg d "$dev" '.devices[$d].frame_device // "browser"' "$MATRIX")
    step "frame $unit: $fdev поверх ${pw}x${ph}"
    local framepng="$OUT/framed/$uslug-frame.png" rgba="$OUT/framed/$uslug-frame-rgba.png"
    "$PY" "$LIB/frames.py" --device "$fdev" --shot-w "$pw" --shot-h "$ph" --bg "$bg" --out "$framepng" >/dev/null \
      || { unit_set "$st" "$unit" frame '{"status":"failed","verified":false}'; event "$st" frame "$unit" failed ffmpeg_error; log "✗ $unit: frames.py failed"; continue; }
    local geo; geo=$("$PY" "$LIB/screencast-frame-alpha.py" --frame "$framepng" --out "$rgba") \
      || { unit_set "$st" "$unit" frame '{"status":"failed","verified":false}'; event "$st" frame "$unit" failed verify_failed; log "✗ $unit: frame-alpha failed"; continue; }
    local sx sy sw sh cw ch
    sx=$(echo "$geo" | jq -r '.screen.x'); sy=$(echo "$geo" | jq -r '.screen.y')
    sw=$(echo "$geo" | jq -r '.screen.w'); sh=$(echo "$geo" | jq -r '.screen.h')
    cw=$(echo "$geo" | jq -r '.canvas.w'); ch=$(echo "$geo" | jq -r '.canvas.h')
    cw=$((cw / 2 * 2)); ch=$((ch / 2 * 2))
    local out_mp4="$OUT/framed/$uslug.mp4"
    # видео → в окно рамки (cover), рамка-RGBA поверх
    watchdog "$tmo" ffmpeg -y -v error -i "$pan" -i "$rgba" -filter_complex \
       "[0:v]scale=${sw}:${sh}:force_original_aspect_ratio=increase,crop=${sw}:${sh}[vid];color=c=black:s=${cw}x${ch}:r=60[cv];[cv][vid]overlay=${sx}:${sy}:shortest=1[base];[base][1:v]overlay=0:0,format=yuv420p" \
       -c:v libx264 -preset medium -crf 18 -movflags +faststart "$out_mp4" 2>>"$OUT/framed/$uslug.err"
    local rc=$?
    if [ "$rc" = 0 ]; then
      # '// 0' + verify_video сам фейлит missing_expected_duration при 0/null (finalize warn #6)
      local exp_dur; exp_dur=$(jq -r --arg u "$unit" '.units[$u].polish.duration // 0' "$st")
      local v; v=$(verify_video "$out_mp4" "$exp_dur" "$cw" "$ch")
      if [ "${v%%:*}" = "ok" ]; then
        unit_set "$st" "$unit" frame "$(jq -n --arg a "$out_mp4" '{status:"done", artifact:$a, verified:true}')"
        event "$st" frame "$unit" done; log "✓ $unit: $v"
      else
        unit_set "$st" "$unit" frame '{"status":"failed","verified":false}'
        event "$st" frame "$unit" failed verify_failed "$v"; log "✗ $unit: $v"
      fi
    else
      local reason=ffmpeg_error; [ "$rc" = 137 ] && reason=timeout
      unit_set "$st" "$unit" frame '{"status":"failed","verified":false}'
      event "$st" frame "$unit" failed "$reason" "rc=$rc limit=${tmo}s"; log "✗ $unit: $reason (rc=$rc)"
    fi
  done
  jq '{ok:true, stage:"frame", units:(.units|map_values(.frame.status // "pending"))}' "$st"
}

# ── DERIVE: gif/loop + постер из framed mp4 (§4 T2 п.5, §9 шаг 2) ───────────────
do_derive(){
  [ -n "$OUT" ] || fail "derive: --out required"
  local st="$OUT/state.json"; [ -f "$st" ] || fail "no state.json"
  local tmo; tmo=$(jq -r '.limits.ffmpeg_timeout_s' "$MATRIX")
  mkdir -p "$OUT/derived"
  local unit
  for unit in $(jq -r '.units | keys[]' "$st"); do
    jq -e --arg u "$unit" '.units[$u].frame.status=="done" and .units[$u].frame.verified' "$st" >/dev/null || { log "− $unit: frame не done, skip"; continue; }
    jq -e --arg u "$unit" '.units[$u].derive.status=="done" and .units[$u].derive.verified' "$st" >/dev/null 2>&1 && { log "= $unit (resume)"; continue; }
    local src uslug; src=$(jq -r --arg u "$unit" '.units[$u].frame.artifact' "$st"); uslug=$(slug "$unit")
    local gif="$OUT/derived/$uslug.gif" poster="$OUT/derived/$uslug-poster.png"
    step "derive $unit: gif + poster"
    # gif: 15fps, ширина 480, palettegen/paletteuse (качество), бесконечный loop
    watchdog "$tmo" ffmpeg -y -v error -i "$src" -vf \
      "fps=15,scale=480:-2:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=128[p];[s1][p]paletteuse=dither=bayer" \
      -loop 0 "$gif" 2>>"$OUT/derived/$uslug.err"
    local rc=$?
    # poster: кадр из середины
    ffmpeg -y -v error -sseof -3 -i "$src" -frames:v 1 "$poster" 2>>"$OUT/derived/$uslug.err" || true
    # verify (§6.2): gif существует, непустой, <10MB (DoD шага 2), постер непустой
    local gbytes; gbytes=$(stat -f%z "$gif" 2>/dev/null || echo 0)
    if [ "$rc" = 0 ] && [ "$gbytes" -gt 1024 ] && [ "$gbytes" -lt 10485760 ] && [ -s "$poster" ]; then
      unit_set "$st" "$unit" derive "$(jq -n --arg g "$gif" --arg p "$poster" --argjson b "$gbytes" '{status:"done", gif:$g, poster:$p, gif_bytes:$b, verified:true}')"
      event "$st" derive "$unit" done; log "✓ $unit: gif $((gbytes/1024))KB + poster"
    else
      # enum §12 (finalize warn #5): rc!=0 → ffmpeg_error/timeout; rc=0 но брак → verify_failed
      local reason
      if [ "$rc" = 137 ]; then reason=timeout
      elif [ "$rc" != 0 ]; then reason=ffmpeg_error
      else reason=verify_failed; fi
      unit_set "$st" "$unit" derive '{"status":"failed","verified":false}'
      event "$st" derive "$unit" failed "$reason" "rc=$rc gif_bytes=$gbytes"; log "✗ $unit: $reason (gif=$((gbytes/1024))KB)"
    fi
  done
  jq '{ok:true, stage:"derive", units:(.units|map_values(.derive.status // "pending"))}' "$st"
}

# ── UPLOAD: Cloudinary с PII-gate, идемпотентным public_id и round-trip verify ──
# (§6.1 идемпотентность, §6.2 verify, §8.2 PII-gate, §12 empirical: retry на async)
do_upload(){
  [ -n "$OUT" ] || fail "upload: --out required"
  local st="$OUT/state.json"; [ -f "$st" ] || fail "no state.json"
  # PII-gate (§8.2): Cloudinary = 3rd-party для ЛЮБОГО тира; fail-closed без подтверждения
  if ! jq -e '.pii_confirmed.confirmed_at != null' "$st" >/dev/null; then
    if [ "$PII_OK" = "1" ]; then
      jset "$st" '.pii_confirmed = {third_party:["cloudinary"], confirmed_at:(now|todate)}'
    else
      fail "PII-gate: upload в Cloudinary (3rd-party) не подтверждён — перезапусти с --pii-ok после явного согласия пользователя (SPEC §8.2)"
    fi
  fi
  local url tier run_id; url=$(jq -r '.url' "$st"); tier=$(jq -r '.tier' "$st"); run_id=$(jq -r '.run_id' "$st")
  # folder фиксируется в state при ПЕРВОМ upload (finalize warn #3): resume через
  # границу месяца иначе пересчитал бы $(date +%Y-%m) и создал дубль-ассет
  local folder; folder=$(jq -r '.upload_folder // empty' "$st")
  if [ -z "$folder" ]; then
    folder="content-gen/screencast/$(date +%Y-%m)"
    jset "$st" --arg f "$folder" '.upload_folder = $f'
  fi
  local unit
  for unit in $(jq -r '.units | keys[]' "$st"); do
    jq -e --arg u "$unit" '.units[$u].frame.status=="done" and .units[$u].frame.verified' "$st" >/dev/null || { log "− $unit: frame не done, skip"; continue; }
    jq -e --arg u "$unit" '.units[$u].upload.status=="done" and .units[$u].upload.verified' "$st" >/dev/null 2>&1 && { log "= $unit (resume)"; continue; }
    local src; src=$(jq -r --arg u "$unit" '.units[$u].frame.artifact' "$st")
    # идемпотентный public_id (§6.1): hash(url+format+tier+run_id) → resume = overwrite, не дубль
    local pid; pid="sc-$(printf '%s' "${url}|${unit}|${tier}|${run_id}" | shasum -a 1 | cut -c1-16)"
    step "upload $unit → $folder/$pid"
    # secure_url приходит через файл (мимо op-маскирования stdout, см. screencast-upload.sh)
    local urlf="$OUT/.upload-url.$$"
    local resp; resp=$(bash "$LIB/screencast-upload.sh" "$src" "$pid" "$folder" "$urlf")
    if ! echo "$resp" | jq -e '.ok' >/dev/null 2>&1; then
      rm -f "$urlf"
      unit_set "$st" "$unit" upload '{"status":"failed","verified":false}'
      event "$st" upload "$unit" failed upload_error "$(echo "$resp" | jq -r '.error // "unknown"' 2>/dev/null | head -c200)"
      log "✗ $unit: upload failed"; continue
    fi
    local surl bytes; surl=$(cat "$urlf" 2>/dev/null); rm -f "$urlf"
    bytes=$(echo "$resp" | jq -r '.bytes // 0')
    if [ -z "$surl" ]; then
      unit_set "$st" "$unit" upload '{"status":"failed","verified":false}'
      event "$st" upload "$unit" failed upload_error "no secure_url returned"; log "✗ $unit: no url"; continue
    fi
    # round-trip verify (§6.2 + §12 empirical, live-проверено 2026-07-02):
    # Cloudinary на HEAD НЕ отдаёт Content-Length (HTTP/2) → range-GET 0-0 и total
    # из Content-Range; заголовки с \r → tr -d. Retry 3×5s на async post-processing.
    local lbytes vok=0 attempt
    lbytes=$(stat -f%z "$src" 2>/dev/null || echo 0)
    if [ "$lbytes" -le 0 ]; then
      unit_set "$st" "$unit" upload '{"status":"failed","verified":false}'
      event "$st" upload "$unit" failed verify_failed "local file empty"; log "✗ $unit: local empty"; continue
    fi
    for attempt in 1 2 3; do
      local hdr code ctype total
      hdr=$(curl -s --max-time 30 -r 0-0 -D - -o /dev/null "$surl" 2>/dev/null | tr -d '\r')
      code=$(echo "$hdr" | head -1 | awk '{print $2}')
      ctype=$(echo "$hdr" | grep -i '^content-type:' | awk '{print $2}')
      total=$(echo "$hdr" | grep -i '^content-range:' | sed 's|.*/||')
      if { [ "$code" = "206" ] || [ "$code" = "200" ]; } \
         && case "$ctype" in video/*|image/*) true;; *) false;; esac \
         && [ -n "$total" ] && awk -v a="$total" -v b="$lbytes" 'BEGIN{d=a>b?a-b:b-a; exit !(d<=b*0.05)}'; then
        vok=1; break
      fi
      log "  … range-GET attempt $attempt: code=${code:-?} type=${ctype:-?} total=${total:-?} local=$lbytes (retry 5s)"
      sleep 5
    done
    if [ "$vok" = 1 ]; then
      unit_set "$st" "$unit" upload "$(jq -n --arg p "$folder/$pid" --arg u "$surl" '{status:"done", public_id:$p, url:$u, verified:true}')"
      event "$st" upload "$unit" done; log "✓ $unit: $surl"
    else
      unit_set "$st" "$unit" upload "$(jq -n --arg p "$folder/$pid" '{status:"failed", public_id:$p, verified:false}')"
      event "$st" upload "$unit" failed verify_failed "HEAD round-trip failed after 3 attempts"
      log "✗ $unit: залит, но round-trip не подтверждён"
    fi
  done
  jq '{ok:true, stage:"upload", units:(.units|map_values(.upload.status // "pending"))}' "$st"
}

# ── DM (T3 premium): bookkeeping для платного Dynamic Mockups create_video ──────
# MCP-вызовы делает Claude (SKILL.md); скрипт хранит state-инварианты §6.1/§10:
# write-ahead intent, session-ledger, verify скачанного рендера. Single writer = мы.
SESSION_LEDGER="$HOME/Library/Application Support/content-screencast/session-ledger.json"

# глобальный lock на ledger (finalize-3 warn #3): файл общий для ВСЕХ ранов, per-OUT
# lock_out его не покрывает — RMW под собственным mkdir-lock с ожиданием ≤5s
ledger_lock(){
  local d="$SESSION_LEDGER.lock" i=0
  while ! mkdir "$d" 2>/dev/null; do
    i=$((i+1)); [ "$i" -ge 50 ] && fail "session-ledger занят другим процессом (>5s): $d"
    sleep 0.1
  done
}
ledger_unlock(){ rmdir "$SESSION_LEDGER.lock" 2>/dev/null || true; }

# инициализация + TTL-reset (finalize-3 critical #2): «сессия» = 24ч, иначе cap
# деградирует в lifetime-бюджет и недоспенд прошлых дней раздувает headroom
ledger_init(){
  mkdir -p "$(dirname "$SESSION_LEDGER")"
  [ -f "$SESSION_LEDGER" ] || echo '{"confirmed_total":0,"spent":0,"runs":[],"updated_at":0}' > "$SESSION_LEDGER"
  local now upd; now=$(date +%s); upd=$(jq -r '.updated_at // 0' "$SESSION_LEDGER")
  if [ $((now - upd)) -gt 86400 ]; then
    echo "{\"confirmed_total\":0,\"spent\":0,\"runs\":[],\"updated_at\":$now}" > "$SESSION_LEDGER"
  fi
}
# ledger_rmw '<jq-выражение>' — атомарный read-modify-write под lock'ом
ledger_rmw(){
  ledger_lock
  jq --argjson now "$(date +%s)" "$1 | .updated_at = \$now" "$SESSION_LEDGER" > "$SESSION_LEDGER.tmp" \
    && mv "$SESSION_LEDGER.tmp" "$SESSION_LEDGER"
  local rc=$?
  ledger_unlock
  return $rc
}
num_guard(){ # num_guard <value> <flag-name>: fail-closed на не-число/ноль/отрицательное
  case "$1" in *[!0-9]*|"") fail "$2 must be a positive integer (fail-closed §10 п.3)";; esac
  [ "$1" -gt 0 ] || fail "$2 must be > 0"
}

# dm-confirm --out DIR --confirm-total N  (после ЯВНОГО y/n пользователя в чате —
#   фиксация суммы в state §10 п.4 + потолок session-ledger §10 п.5)
do_dm_confirm(){
  local st="$OUT/state.json"; [ -f "$st" ] || fail "no state.json"
  [ -n "$CONFIRM_TOTAL" ] || fail "dm-confirm: --confirm-total <credits> required"
  num_guard "$CONFIRM_TOTAL" "--confirm-total"
  jset "$st" --argjson t "$CONFIRM_TOTAL" \
    '.cost_confirmed = {credits:0, total_estimate:$t, confirmed_at:(now|todate)}'
  ledger_init
  local rid; rid=$(jq -r '.run_id' "$st")
  ledger_rmw ".confirmed_total += $CONFIRM_TOTAL | .runs += [\"$rid\"]" || fail "ledger write failed"
  event "$st" dm all cost_confirmed "" "total=$CONFIRM_TOTAL"
  echo "{\"ok\":true,\"confirmed_total\":$CONFIRM_TOTAL}"
}

# dm-intent --out DIR --unit U --credits N [--params-hash H]
#   Write-ahead ДО create_video. Если intent уже есть с job_id=null → ОТКАЗ (возможен
#   двойной платный job — сначала проверить на стороне DM). Инкремент session-ledger;
#   spent >= confirmed_total → отказ (re-confirm gate §10 п.5).
do_dm_intent(){
  local st="$OUT/state.json"; [ -f "$st" ] || fail "no state.json"
  [ -n "$UNIT" ] || fail "dm-intent: --unit required"
  num_guard "$CREDITS" "--credits"   # finalize-3 critical #1: до арифметики; отрицательное/мусор → reject
  jq -e '.cost_confirmed.confirmed_at != null' "$st" >/dev/null || fail "cost-gate: cost_confirmed отсутствует в state — сначала явное подтверждение суммы (SPEC §10)"
  if jq -e --arg u "$UNIT" '.units[$u].dm_job.intent_at != null and .units[$u].dm_job.job_id == null' "$st" >/dev/null 2>&1; then
    fail "write-ahead intent уже висит без job_id (unit=$UNIT) — возможен созданный job на стороне DM; проверь get_video_status/дашборд, потом dm-clear или dm-job"
  fi
  # ДВА потолка (finalize-3 critical #2): per-run (state.total_estimate — то, что пользователь
  # подтвердил ЭТОМУ рану) И session-ledger (24h-сессия, все раны)
  local run_est run_spent
  run_est=$(jq -r '.cost_confirmed.total_estimate // 0' "$st")
  run_spent=$(jq -r '[.units[].dm_job.credits // 0] | add // 0' "$st")
  if [ "$((run_spent + CREDITS))" -gt "$run_est" ]; then
    fail "per-run потолок: spent($run_spent)+$CREDITS > total_estimate($run_est) этого рана — re-confirm (SPEC §10 п.5)"
  fi
  ledger_init
  # атомарный check-and-increment под lock'ом (TOCTOU): jq фейлит error(...) если превышение
  if ! ledger_rmw "if (.spent + $CREDITS) > .confirmed_total then error(\"ceiling\") else .spent += $CREDITS end" 2>/dev/null; then
    fail "session-ledger: spent+$CREDITS > confirmed_total($(jq -r '.confirmed_total' "$SESSION_LEDGER")) — нужен re-confirm у пользователя (SPEC §10 п.5)"
  fi
  jset "$st" --arg u "$UNIT" --argjson c "$CREDITS" --arg h "${PARAMS_HASH:-}" \
    '.units[$u].dm_job = {intent_at:(now|todate), credits:$c, params_hash:$h, job_id:null}'
  event "$st" dm "$UNIT" intent "" "credits=$CREDITS"
  echo "{\"ok\":true,\"intent\":\"$UNIT\",\"credits\":$CREDITS}"
}

# dm-job --out DIR --unit U --job-id ID   (после ответа create_video)
do_dm_job(){
  local st="$OUT/state.json"; [ -f "$st" ] || fail "no state.json"
  [ -n "$UNIT" ] && [ -n "$JOB_ID" ] || fail "dm-job: --unit --job-id required"
  # lifecycle (finalize-3 warn #4): job_id регистрируется только поверх живого intent'а
  jq -e --arg u "$UNIT" '.units[$u].dm_job.intent_at != null' "$st" >/dev/null 2>&1 \
    || fail "dm-job: нет write-ahead intent для unit=$UNIT — сначала dm-intent (SPEC §6.1)"
  jq -e --arg u "$UNIT" '.units[$u].dm_job.job_id == null' "$st" >/dev/null 2>&1 \
    || fail "dm-job: job_id уже зарегистрирован для unit=$UNIT"
  jset "$st" --arg u "$UNIT" --arg j "$JOB_ID" '.units[$u].dm_job.job_id = $j'
  event "$st" dm "$UNIT" job_registered "" "$JOB_ID"
  echo '{"ok":true}'
}

# dm-done --out DIR --unit U --file downloaded.mp4  (после COMPLETED+скачивания)
#   ffprobe verify → polish-слот (дальше frame/derive/upload общие или как есть)
do_dm_done(){
  local st="$OUT/state.json"; [ -f "$st" ] || fail "no state.json"
  [ -n "$UNIT" ] && [ -n "$FILE" ] || fail "dm-done: --unit --file required"
  # lifecycle (finalize-3 warn #4): done только для job'а с зарегистрированным job_id
  jq -e --arg u "$UNIT" '.units[$u].dm_job.job_id != null' "$st" >/dev/null 2>&1 \
    || fail "dm-done: нет job_id для unit=$UNIT — сначала dm-job"
  local v; v=$(verify_video "$FILE" "-" "-" "-")
  if [ "${v%%:*}" = "ok" ]; then
    local adur; adur=$(ffprobe -v quiet -print_format json -show_format "$FILE" | jq -r '.format.duration')
    unit_set "$st" "$UNIT" polish "$(jq -n --arg a "$FILE" --arg d "$adur" '{status:"done", artifact:$a, verified:true, duration:($d|tonumber), engine:"dm"}')"
    event "$st" dm "$UNIT" done; echo "{\"ok\":true,\"verify\":\"$v\"}"
  else
    unit_set "$st" "$UNIT" polish '{"status":"failed","verified":false}'
    event "$st" dm "$UNIT" failed verify_failed "$v"; echo "{\"ok\":false,\"verify\":\"$v\"}"; exit 1
  fi
}

# dm-clear --out DIR --unit U [--refunded]  (откат intent + ledger)
#   Без job_id: снять intent после подтверждения, что job НЕ создан на стороне DM.
#   С job_id: ТОЛЬКО с --refunded (finalize-3 warn #4/#5) — после подтверждения в
#   дашборде DM, что job упал и кредиты РЕАЛЬНО рефандились; иначе refuse.
do_dm_clear(){
  local st="$OUT/state.json"; [ -f "$st" ] || fail "no state.json"
  [ -n "$UNIT" ] || fail "dm-clear: --unit required"
  jq -e --arg u "$UNIT" '.units[$u].dm_job != null' "$st" >/dev/null 2>&1 || fail "dm-clear: нет dm_job для unit=$UNIT"
  if jq -e --arg u "$UNIT" '.units[$u].dm_job.job_id != null' "$st" >/dev/null 2>&1 && [ "$REFUNDED" != "1" ]; then
    fail "dm-clear: у unit=$UNIT есть job_id — job мог реально отработать/списаться. Проверь get_video_status/дашборд DM; если кредиты рефандились — повтори с --refunded"
  fi
  local c; c=$(jq -r --arg u "$UNIT" '.units[$u].dm_job.credits // 0' "$st")
  jset "$st" --arg u "$UNIT" '.units[$u].dm_job = null'
  if [ -f "$SESSION_LEDGER" ] && [ "$c" -gt 0 ] 2>/dev/null; then
    ledger_rmw ".spent = ([.spent - $c, 0] | max)" || true
  fi
  event "$st" dm "$UNIT" intent_cleared "" "refund=$c refunded_flag=$REFUNDED"
  echo '{"ok":true}'
}

# ── DECK: превью-страница (§6.3: упавшие unit'ы — карточкой с причиной) ─────────
do_deck(){
  [ -n "$OUT" ] || fail "deck: --out required"
  local st="$OUT/state.json"; [ -f "$st" ] || fail "no state.json"
  local deck="$OUT/deck.html"
  "$PY" - "$st" "$deck" <<'EOF'
import json, sys, html, os
st = json.load(open(sys.argv[1]))
cards = []
for unit, stages in st.get("units", {}).items():
    fr = stages.get("frame", {})
    if fr.get("status") == "done" and fr.get("verified"):
        rel = os.path.relpath(fr["artifact"], os.path.dirname(sys.argv[2]))
        cards.append(f'<div class="card ok"><video src="{html.escape(rel)}" autoplay muted loop playsinline></video><p>{html.escape(unit)}</p></div>')
    else:
        reasons = [e.get("reason") for e in st.get("events", []) if e.get("unit") == unit and e.get("event") == "failed" and e.get("reason")]
        reason = html.escape(reasons[-1] if reasons else "не дошёл до frame")
        cards.append(f'<div class="card fail"><div class="x">✗</div><p>{html.escape(unit)}</p><p class="r">{reason}</p></div>')
body = "".join(cards) if cards else '<p class="empty">Все unit\'ы упали или не запускались — смотри state.json → events.</p>'
open(sys.argv[2], "w").write(f"""<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>screencast deck — {html.escape(st.get('url',''))}</title>
<style>body{{background:#0d1117;color:#e6edf3;font:14px -apple-system,sans-serif;margin:24px}}
.grid{{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:20px}}
.card{{background:#161b22;border-radius:12px;padding:12px;text-align:center}}
.card video{{max-width:100%;border-radius:8px}}
.card.fail{{border:1px solid #f8514966}} .x{{font-size:40px;color:#f85149}} .r{{color:#8b949e;font-size:12px}}
.empty{{color:#8b949e}}</style>
<h2>🎬 {html.escape(st.get('url',''))} — tier {html.escape(st.get('tier',''))}</h2>
<div class="grid">{body}</div>""")
print(json.dumps({"ok": True, "deck": sys.argv[2], "cards": len(cards)}))
EOF
}

# ── RUN: все стадии continue-on-error + summary ─────────────────────────────────
do_run(){
  do_validate >/dev/null || exit 1
  # маршрут по engine тира (matrix): record (T1) vs pan (T2)
  local engine; engine=$(jq -r --arg t "$TIER" '.tiers[$t].engine' "$MATRIX")
  if [ "$engine" = "record" ]; then
    do_record || true
  else
    do_capture  || true
    do_polish   || true
  fi
  do_frame    || true
  [ "$WITH_DERIVE" = 1 ] && { do_derive || true; }
  [ "$WITH_UPLOAD" = 1 ] && { do_upload || true; }
  do_deck     || true
  local st="$OUT/state.json"
  step "summary"
  jq '{ok:true, url, tier,
       done:   [.units|to_entries[]|select(.value.frame.status=="done")|.key],
       failed: [.units|to_entries[]|select(.value.frame.status!="done")|.key],
       deck:   "'"$OUT"'/deck.html"}' "$st"
}

case "$CMD" in
  validate) do_validate;;
  capture)  lock_out; do_capture;;
  record)   lock_out; do_record;;
  polish)   lock_out; do_polish;;
  frame)    lock_out; do_frame;;
  derive)   lock_out; do_derive;;
  upload)   lock_out; do_upload;;
  dm-confirm) lock_out; do_dm_confirm;;
  dm-intent)  lock_out; do_dm_intent;;
  dm-job)     lock_out; do_dm_job;;
  dm-done)    lock_out; do_dm_done;;
  dm-clear)   lock_out; do_dm_clear;;
  deck)     lock_out; do_deck;;
  run)      lock_out; do_run;;
  *) fail "usage: run-screencast.sh {validate|capture|polish|frame|derive|upload|deck|run} --url U --out DIR --formats F [--tier mid] [--devices D] [--duration D] [--speed S] [--bg c1,c2] [--derive|--loop] [--upload --pii-ok]";;
esac
