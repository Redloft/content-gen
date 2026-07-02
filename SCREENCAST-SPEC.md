# content-screencast — спека ветки видео-мокапов сайта

> Ревизия: **v3 после plan-panel #2** (2026-07-02, NEEDS-WORK@0.85 = потолок панели, архитектура подтверждена).
> v2 закрыл 5 critical раунда 1; v3 закрывает 4 архитектурных остатка раунда 2:
> DM write-ahead intent (идемпотентность платного job), PII-gate на ЛЮБОЙ --upload,
> capability-matrix как явный подшаг §9, session cost-ceiling + разделение ssrf.mjs/ssrf-route.
> Остаток = implementation-DoD (→ /finalize) + 2 empirical-unknown (→ live-тесты §12).

> Статус: **SPEC / не реализовано.** Ветка `content-gen` для motion-мокапов: из URL сайта
> делает красивые видео-ролики (скролл / клики / loop) в рамке девайса — desktop и mobile —
> с автозаливкой в Cloudinary. Сиблинг `/content-mockup` (там статика, тут motion).
> Движок захвата и safety-слой переиспользуются целиком.

---

## 0. Зачем и главный инсайт

Задача: «видосики сайта на лету» для вставки на страницы/в соцсети/кейсы.

**Ключевой инсайт — захват и красота это два разных слоя.** Сырой скролл из браузера всегда
дёргается (variable framerate, реальный wheel-скролл прыгает). Поэтому:

- **Слой 1 — Захват** (что снять): Playwright.
- **Слой 2 — Полировка** (как сделать гладко+красиво): плавный скролл 60fps + рамка девайса +
  фон/переходы. Именно тут рождается «красиво», и главный трюк — **не записывать реальный
  скролл, а панорамировать по одному длинному скриншоту** (Tier 2).

---

## 1. Три тира (cost/качество), как везде в content-gen

| Tier | Движок | Как получается «красиво» | Скролл | Цена | Когда |
|---|---|---|---|---|---|
| `explore` (T1) | Playwright `recordVideo` | реальная запись + injected easing-скролл | ~смузи, но VFR-дрожь | **бесплатно** | пристрелка, «прикинь как выйдет» |
| `mid` (T2) ⭐ default | full-page screenshot → ffmpeg `zoompan` pan → рамка | **идеально гладкий 60fps** (скролл ненастоящий = анимация панорамы) | буттер | **бесплатно** (ffmpeg офлайн) | «видосик на сайт на лету» — sweet spot |
| `premium` (T3) | Remotion **или** Dynamic Mockups `create_video` | React-сцена: phone-mockup + Lottie-жесты + курсор-рука + фон-градиент + переходы | буттер + постановка | Remotion бесплатно (тяжёлый render); DM = кредиты | hero/промо для лендинга и кейсов |

**Cost-first:** перед T3 через Dynamic Mockups — оценить и подтвердить кредиты. Полный контракт — §10 (Cost governance): total-estimate за ВСЕ форматы×тиры разом, один explicit confirm, fail-closed, re-confirm в loop/batch.

**T3: критерий выбора Remotion vs Dynamic Mockups (фиксируем на этапе спеки, не в рантайме):**
- **Default = Dynamic Mockups** `create_video`: нет нового кода в репе, MCP уже подключён, единственный минус — кредиты.
- **Remotion — только при выполнении хотя бы одного:** (а) нужен формат `clicks` в premium-качестве (курсор-рука/жесты — DM этого не умеет); (б) нужен полный контроль постановки (свой фон/переходы/брендинг кадра); (в) объём роликов такой, что кредиты DM дороже разового setup.
- Remotion-ветка (`lib/remotion/`) реализуется **последней** (§9 п.4) и живёт как отдельный изолированный подпроект — не тянуть React-зависимости в корневой `package.json` content-gen.

---

## 2. Четыре формата (флаг `--format`, можно несколько)

1. **`mobile-scroll`** — сайт в рамке iPhone, вертикальный скролл сверху вниз. Классика для соцсетей/hero. Выход 9:16 и 1:1.
2. **`desktop-scroll`** — сайт в рамке браузера/MacBook, широкий формат 16:9.
3. **`clicks`** — скриптованный сценарий: переходы по разделам, hover, открытие меню/аккордеона. Требует **сценарий шагов** (см. §5). Только T1/T3 (T2 — панорама по статике, кликов не умеет).
4. **`loop` / `gif`** — короткий зацикленный ролик или GIF для превью-карточек. Деривативы из любого тира.

Матрица: T2 покрывает `mobile-scroll`+`desktop-scroll`+`loop/gif`; `clicks` → T1 (быстро) или T3 (красиво).

---

## 3. Что переиспользуем (уже есть в lib/)

- **`capture.mjs`** — Playwright-скриншоты + SSRF-защита (`ssrf.mjs`) + `VIEWPORTS` пресеты (desktop 1440×900, mobile 390×844, tablet). Full-page скриншот для T2 — уже умеет (`--full-page`).
- **`ssrf.mjs`** — блок приватных/loopback/metadata IP + file/data схем. **Не отключать** — тот же SSRF-контур для записи.
- **`frames.py` / `frame-composite.py`** — офлайн PIL-рамки девайсов (browser/iphone/ipad/macbook) + green-screen composite. Для T2 рамку кладём поверх видео (см. §4).
- **`upload-cloudinary-video.sh`** — signed video upload + деривативы. Хвост пайплайна закрыт.
- **Dynamic Mockups MCP** — `create_video` / `get_video_models` / `get_video_status` для T3 device-frame видео.
- **Playwright 1.60** в `package.json` (chromium ставится `npx playwright install chromium`).
- **`op run --env-file=all-secrets.env`** — один Touch ID на весь прогон.

**Новая зависимость:** `ffmpeg` (для T2 pan + деривативов + рамка-overlay). Проверка наличия при старте, понятная ошибка + `brew install ffmpeg` если нет.

---

## 4. Реализация по тирам

### T1 — Playwright recordVideo (explore)
- Новый `lib/record.mjs` (сиблинг `capture.mjs`, тот же SSRF-контур):
  - `browser.newContext({ recordVideo: { dir, size }, viewport, ...devices[preset] })`.
  - Инжектим **плавный easing-скролл** через `page.evaluate`: пошаговый `window.scrollTo` с cubic-easing и стабильным шагом по времени (не `behavior:'smooth'` браузера — он неровный), либо `page.screencast` API (v1.59+) для контроля fps.
  - `mobile` → `devices['iPhone 13']`; `desktop` → viewport 1440×900.
  - На выходе WebM → ffmpeg транскод в mp4 (h264, yuv420p, faststart).
- Рамку T1 накидываем опц. тем же ffmpeg-overlay, что и в T2.

### T2 — pan-screenshot (mid, ⭐ default)
Пайплайн полностью офлайн, детерминированный:
1. `capture.mjs --url … --full-page` → длинный PNG (desktop и/или mobile viewport).
2. **ffmpeg `zoompan`/`crop`-панорама** по картинке сверху вниз: длина ролика ∝ высоте страницы (напр. 800px/сек), easing на старте/финише, 60fps. Скролл идеально гладкий, т.к. это движение вьюпорта по статике.
   - Формула кадрирования: окно `WxH` viewport'а движется `y = ease(t)*(imgH - H)`.
3. **Рамка девайса**: `frames.py` даёт PNG-рамку с прозрачным «экраном» (alpha-окно) → ffmpeg `overlay` рамки поверх pan-видео, экран-видео в вырезе. Тени/скругления — из рамки.
4. Фон-градиент (палитра из `brand-probe`, как в мокапах) как подложка ffmpeg.
5. Деривативы: mp4 (h264), webm (vp9), gif (`loop`), + постер-кадр.

### T3 — Remotion / Dynamic Mockups (premium)
- **Ветка Remotion** (`lib/remotion/` — отдельный минимальный Node/React проект):
  - Phone/Browser Mockup компонент (scrollable content, sticky header, zoom-переход между экранами).
  - Lottie-жесты (scroll/swipe/drag) + physics курсор-рука для `clicks`.
  - Вход — либо full-page скриншот (панорама внутри рамки), либо серия скриншотов состояний (для `clicks`).
  - `npx remotion render` → mp4. Тяжёлый setup (headless chromium для рендера), поэтому за флагом.
- **Ветка Dynamic Mockups `create_video`** (проще, без React): скриншот/скролл → device-video через MCP, `get_video_status` поллинг → скачать. Кредиты — подтвердить cost-first.
- Claude выбирает под-ветку по запросу: нужен курсор/жесты/постановка → Remotion; нужна просто гладкая рамка-видео премиум-качества → Dynamic Mockups.

---

## 5. Сценарий для `clicks` (скриптованный флоу)

Для формата `clicks` нужен список шагов. Claude генерит `scenario.json` из вайба/структуры сайта
(или пользователь даёт явно):
```json
{ "steps": [
  { "action": "scroll", "to": "#features", "ease": "easeInOut", "dwell": 800 },
  { "action": "hover",  "selector": ".card:first-child" },
  { "action": "click",  "selector": "nav a[href='#pricing']" },
  { "action": "wait",   "ms": 1200 }
]}
```
`record.mjs` проигрывает шаги под запись (T1) или снимает скриншот-состояния для Remotion (T3).
Селекторы — только на публичной странице; тот же SSRF/PII-нотис, что в мокапах.

---

## 6. Оркестратор, state.json и verify-контракты

`lib/run-screencast.sh {validate|capture|record|polish|frame|upload}` — механика; **Claude ведёт
суждения** (выбор тира/формата/девайса/сценария, палитра фона, cost/PII-подтверждение).

### 6.1 state.json — схема (обязательная, panel critical #4)

Run-папка именуется по **run_id** (uuid-short), НЕ по URL (санитизация имён файлов, инъекции путей).

```json
{
  "schema_version": 1,
  "run_id": "sc-a1b2c3",
  "url": "https://…",
  "tier": "mid",
  "formats": ["mobile-scroll", "desktop-scroll"],
  "devices": ["iphone", "browser"],
  "cost_confirmed":  { "credits": 0, "total_estimate": 0, "confirmed_at": null },
  "pii_confirmed":   { "third_party": [], "confirmed_at": null },
  "units": {
    "mobile-scroll/iphone": {
      "capture":  { "status": "done|failed|pending", "artifact": "…png", "verified": true, "ms": 0, "bytes": 0 },
      "polish":   { "status": "…", "artifact": "…mp4", "verified": true },
      "frame":    { "status": "…", "artifact": "…mp4", "verified": true },
      "upload":   { "status": "…", "public_id": "…", "url": "…", "verified": true }
    }
  },
  "events": [ { "t": "…", "stage": "polish", "unit": "…", "event": "done|failed", "reason": null } ]
}
```

- **Resume-unit = `(format, device)`**: `--resume` доигрывает только незавершённые unit'ы, done+verified не трогает.
- **schema_version mismatch** при resume → refuse с сообщением «state несовместим, запусти заново» (или явная миграция). НЕ доигрывать молча.
- **Идемпотентный upload**: Cloudinary `public_id = sc/<hash(url+format+tier+run_id)>` + `overwrite: true` → resume после сбоя между HTTP-ответом и записью state не плодит дубли.
- **Write-ahead intent для платных внешних job'ов (panel-2 critical #1)**: ПЕРЕД вызовом DM `create_video` в state.json пишется `dm_job: {intent_at, params_hash, job_id: null}`; после ответа — `job_id`. При resume: intent есть, `job_id: null` → НЕ вызывать create_video вслепую (возможен двойной списанный кредит) — сначала `get_mockups`/статус на стороне DM или спросить пользователя. state.json = source of truth для платных вызовов, а не только для локальных артефактов.
- **Session-ledger для loop/batch (panel-2)**: cost-потолок сессии живёт НЕ в run-scoped state.json, а в `~/Library/Application Support/content-screencast/session-ledger.json` (`{session_id, confirmed_total, spent, runs[]}`). Каждый платный вызов инкрементит `spent`; `spent >= confirmed_total` → re-confirm gate (§10 п.5).

### 6.2 Verify-контракт каждого шага (panel critical #2)

**Exit-code 0 ≠ success.** Шаг помечается `done` в state.json ТОЛЬКО после verify-подшага:

| Шаг | Verify |
|---|---|
| capture | PNG существует, `bytes > 10KB`, размеры соответствуют viewport (full-page: `imgH >= viewportH`) |
| polish/frame | `ffprobe`: есть video-stream, `duration > 0` и в пределах ожидаемой ±10%, resolution == expected, не 0 кадров |
| upload | HTTP round-trip: `HEAD <secure_url>` → 200 + `Content-Type: video/*` + `Content-Length` ≈ локальному (±5%) |
| T3 DM render | скачанный файл проходит тот же ffprobe-verify |

Провал verify → `status: failed` + `reason` в events, артефакт НЕ считается готовым.

### 6.3 Partial-success и прогресс-UX (panel warning)

- **continue-on-error по unit'ам**: упал один `(format,device)` — остальные доводятся до конца.
- `deck.html` показывает упавший unit **карточкой с причиной ошибки** (не тихий пропуск); grid responsive под смешанные aspect (9:16 + 16:9 + 1:1).
- Каждый шаг оркестратора печатает статус в чат с оценкой времени по тиру (T2 ~10-30с/unit, T3 DM — минуты) — пользователь отличает работу от зависания.
- Итоговый summary: сколько unit'ов готово / упало / почему.

### 6.4 Поток

0. **Validate** — валидатор флагов, capability-matrix, ffmpeg-check (§7.1). Fail-fast ДО captura.
1. **Назначение** — куда видео (страница/соцсети/кейс) → пресет размеров и форматов. `--for-page` → `capture.mjs --measure-slots`.
2. **Gates** — cost-gate (если T3/DM, §10) и PII-gate (если 3rd-party, §8) — оба фиксируются в state.json.
3. **Захват** — `capture`/`record` по тиру (+verify).
4. **Полировка** — `polish` (+ffprobe verify).
5. **Рамка+фон** — `frame` (+ffprobe verify).
6. **Превью** — `deck.html` с `<video>`, `open`.
7. **Upload** — опц. (+HTTP round-trip verify).

---

## 7. Флаги

```
/content-screencast <url>
  --format mobile-scroll,desktop-scroll,clicks,loop   (можно несколько)
  --tier explore|mid|premium                            (default mid)
  --devices iphone,browser,macbook,ipad
  --duration <sec>            (или auto ∝ высоте страницы)
  --speed <px/sec>            (скорость скролла, default ~800)
  --scenario <path>           (для clicks)
  --for-page <path|url>       (мерить video-слоты)
  --loop                      (зациклить + gif-дериватив)
  --upload                    (Cloudinary)
  --resume                    (продолжить из state.json)
```

### 7.1 Валидатор флагов — ПЕРВЫЙ шаг, до capture (panel warning → fail-fast)

- Диапазоны: `0 < duration <= 60`; `speed ∈ [100, 3000]` px/sec (`--speed 0` → деление на ноль → тихий чёрный кадр — reject).
- **Capability-matrix** `format × tier` — данные, не if-else (JSON в lib/): `clicks` требует T1|T3; T2+clicks → explicit reject с объяснением. Невалидные device/format-имена → reject со списком допустимых.
- **Subprocess-гигиена (security)**: ffmpeg и все внешние процессы — через `execFile(bin, args[])`, НИКОГДА shell-string с интерполяцией URL/путей (command injection через hostname). Имена файлов — от run_id/hash, не от URL.
- **ffmpeg startup-check**: `which ffmpeg` + `ffmpeg -version` (минимум 6.x). Нет — понятная ошибка с подсказкой `brew install ffmpeg`. **НЕ запускать brew автоматически** (в неинтерактиве/cron зависнет на prompt).

---

## 8. Безопасность и ресурсы

### 8.1 SSRF route-level для record.mjs (panel critical #5; panel-2 — явное разделение модулей)

**Разделение (не менять сиблинга):** `ssrf.mjs` (`hostIsPublic`) остаётся как есть — его использует живой `capture.mjs`. Route-level enforcement для записи — **новый** `lib/ssrf-route.mjs` (экспорт `installRouteGuard(page)`), который внутри вызывает `hostIsPublic` из `ssrf.mjs`. Аддитивность §11 соблюдена: сиблинг не трогаем, record.mjs подключает оба.

`record.mjs` — **route-level enforcement**:
- `page.route('**/*')`: **каждый** подзапрос страницы (не только entry URL) — DNS-resolve hostname → проверка IP ПЕРЕД запросом.
- Блок: private (10/8, 172.16/12, 192.168/16), loopback (127/8), link-local (169.254/16), metadata (169.254.169.254) + **IPv6**: `::1`, `fd00::/8`, `fe80::/10`, IPv4-mapped (`::ffff:…`).
- Схемы `file:` / `data:` / `javascript:` → reject. **Redirect-chain**: проверка на каждом хопе (redirect на приватный IP = abort), лимит редиректов как в capture.mjs.
- То же для длинных T1-записей: SSRF-проверка живёт всю сессию записи, не только на goto.

### 8.2 PII-gate (симметрично cost-gate; panel-2 critical #2 — scope расширен)

- Только **публичные** страницы. PII-gate срабатывает на **ЛЮБУЮ отправку в 3rd-party, не только T3-DM**: `--upload` в Cloudinary — тоже 3rd-party для любого тира. Explicit confirm перед первой отправкой, фиксация `pii_confirmed{third_party:["cloudinary"|"dynamic-mockups"], confirmed_at}` в state.json.
- Эвристика приватности URL (localhost/IP/staging-/admin-/dashboard-паттерны) → предупредить до захвата.
- **Incident-response postfactum**: если после заливки выяснилось, что в кадр попали приватные данные — протокол удаления: Cloudinary `destroy` по `public_id` (есть в `delete-cloudinary.sh`), DM-рендер — удалить asset. `public_id` всех заливок в state.json → удаление одной командой, orphaned-ассетов не остаётся.
- Маскирование секретов в выводе: signed Cloudinary URL содержит `signature`/`api_key` в query — в events/логи/чат писать URL **без query-string**; raw error body от DM/Cloudinary — обрезать до кода+сообщения.

### 8.3 Секреты

- **op run узко** — секреты (Cloudinary/DM) только внутри `op run` вокруг upload/render; захват/ffmpeg/composite вне. Один Touch ID.
- Signed-upload креды/подписи **не персистить** в state.json/deck.html — только `public_id` и итоговый URL.

### 8.4 Таблица resource-guard'ов (panel critical #3 — числа, не намерения)

| Guard | Лимит | При превышении |
|---|---|---|
| goto timeout | 15s | unit → failed |
| scroll-script watchdog (T1) | 45s (`Promise.race`) | запись останавливается, unit → failed |
| full-page height cap | 20 000 px | warning + cap (панорама по первым 20k; infinite-scroll не раскручивать бесконечно) |
| `imgH <= viewportH` (T2) | — | панорамировать нечего → fallback: статичный short-loop 3s + warning |
| ffmpeg / remotion render timeout | 120s / unit | kill процесса, unit → failed (не зомби) |
| WebM size cap (T1) | 200 MB | abort записи, unit → failed |
| длина видео | ≤ 60s | reject на валидаторе |
| DM polling (T3) | max 10 min, backoff 5s→30s cap | timeout → failed; статусы по **allow-list**, unknown status → explicit failed (не default-continue); failed render → сообщить БЕЗ auto-retry (кредиты уже потрачены) |

Все таймауты переводят unit в `failed` (+reason в events) — никаких бесконечных зависаний.
`page.close()`/`context.close()`/`browser.close()` в `finally`. **TTL-очистка**: временные WebM — сразу после транскода; run-папки старше 14 дней — при следующем запуске (спросить/лог).

---

## 9. Порядок реализации (MVP → полный) + DoD на каждый шаг

| # | Шаг | Done when (наблюдаемый исход) |
|---|---|---|
| 0 | **capability-matrix.json + validate** (panel-2 critical #3 — явный подшаг, фундамент MVP): `lib/screencast-matrix.json` (format×tier×device допустимость) + валидатор в run-screencast.sh | матрица существует как файл-данные; валидатор reject'ит clicks+T2, --speed 0, duration>60, невалидные имена — с внятным сообщением; ffmpeg-check работает |
| 1 | **T2 mobile+desktop scroll (MVP)**: validate → capture --full-page → polish ffmpeg pan → frame → deck.html | `--tier mid --format mobile-scroll,desktop-scroll <реальный URL>` даёт mp4 > 0 байт на оба unit'а; `ffprobe`: duration в пределах авторасчёта ±10%, 60fps, resolution == expected; deck.html проигрывает оба видео без ошибок консоли; state.json: оба unit'а done+verified; **smoke `/content-mockup` не регрессирует** (§11) |
| 2 | `--upload` + gif/loop деривативы | upload проходит HTTP round-trip verify; gif < 10MB, зациклен; повторный `--resume` после искусственного обрыва НЕ создаёт дублей в Cloudinary (тот же public_id) |
| 3 | **T1** recordVideo + easing-скролл + `clicks` по scenario.json | запись реального скролла+кликов → mp4 c ffprobe-verify; SSRF route-level срабатывает на тестовом приватном URL (unit → failed, не запрос) |
| 4 | **T3**: DM `create_video` → потом Remotion | cost-gate показывает total-estimate и блокирует без confirm; DM-render скачан и прошёл ffprobe; polling укладывается в policy §8.4 |
| 5 | SKILL.md — секция `/content-screencast` + триггеры (RU/EN: «сделай видео сайта», «скринкаст», «видео-мокап», «покажи сайт в движении», "screencast", "scrolling video of site") | триггеры в frontmatter description; секция в теле SKILL.md ссылается на эту спеку |

## 10. Cost governance (panel critical #1 — единый контракт, gap loop/batch)

Платный только T3-DM (кредиты Dynamic Mockups). Контракт:

1. **Оценка ДО**: `get_video_models` → цена за рендер → **total estimate за ВСЕ запрошенные форматы×девайсы разом** (не по одному).
2. **Один explicit confirm** с суммой: «N рендеров × M кредитов = K. Погнали? y/n». Без confirm — hard stop.
3. **Fail-closed**: cost-поле из API не распарсилось как число → НЕ считать «наверное дёшево», СТОП + показать сырой ответ.
4. Confirm фиксируется в `state.json.cost_confirmed {credits, total_estimate, confirmed_at}`.
5. **Loop/batch-режим** (redwork, /loop, cron): подтверждённый total — ЖЁСТКИЙ потолок сессии. Следующий вызов сверх потолка → **re-confirm у пользователя**, не silent-repeat первого «да». В полностью автономном контексте без канала подтверждения → T3-DM запрещён, деградация в T2.
6. Failed render у DM = кредиты потрачены → сообщить, **не** auto-retry.

## 11. Регрессия против /content-mockup (panel gap)

Ветка делит с живым статик-сиблингом `capture.mjs`, `ssrf.mjs`, `frames.py`, `upload-cloudinary*.sh`. Правила:

- Любое изменение общих файлов — **аддитивное** (новые флаги/функции), не менять поведение существующих кодпутей.
- **Контракт-тест** (`lib/test-mockup-contract.sh`, запуск в DoD шага 1 и в /finalize): `capture.mjs --url <стаб/реальный> --viewports desktop,mobile` возвращает тот же JSON-shape (`ok, shots[].{viewport,w,h,file}`), файлы ненулевые; `frames.py` рендерит рамку с alpha-окном тех же размеров, что до изменений.
- Если общий файл требует несовместимой правки → форкнуть в `record.mjs`/`frames-video.py`, не трогая сиблинга.

## 12. Implementation-DoD и empirical-unknown (panel-2 — для /finalize и live-тестов)

**Implementation-DoD (закрывается кодом + /finalize по diff, НЕ новым кругом панели):**
- T2 duration-формула фиксирована: `duration = clamp((imgH − viewportH) / speed, 3, 60)` сек; ffprobe-verify сверяет ±10% от ЭТОГО значения.
- Stage-контракт run-screencast.sh (**как реализовано**, finalize warn #4): каждый stage принимает `--out <run-dir>` и обрабатывает ВСЕ unit'ы батчем (внутри — continue-on-error per unit, done+verified скипаются = resume); печатает JSON `{ok, stage, units:{<unit>:status}}` в stdout. events/units в state.json пишет ТОЛЬКО этот скрипт; инвариант single writer обеспечен lock'ом `$OUT/.lock` (mkdir-атомарно, concurrent-запуск на тот же --out → отказ).
- `reason` — enum: `timeout|verify_failed|ssrf_blocked|capture_error|ffmpeg_error|upload_error|user_abort|unknown`; диагностика — в отдельном поле `detail` события. timeout отличается от ffmpeg_error по rc=137 (SIGKILL watchdog'а).
- deck.html: пустое состояние (все unit'ы упали), autoplay muted playsinline, mobile-ширина.
- Crash не-timeout природы (OOM, kill) → при resume незавершённый stage со статусом `pending`+intent трактуется как failed, не как «доиграть молча».

**Статус T3-DM (2026-07-02, шаг 4):** обвязка РЕАЛИЗОВАНА и протестирована fail-closed юнитами (6/6), live-рендер ОТЛОЖЕН решением Игоря (жалко 40 кредитов ≈ весь free tier на тест).
- **Live-разведка API**: `create_video` = **MotionMockups AI (Kling v2.6/v3 Pro) — генеративное image-to-video** из публичного URL картинки, НЕ детерминированная рамка. Цены: v2.6 5s=40/10s=80 кредитов; v3 Pro 3-15s=78-390 (+audio ×1.5-2). Кредиты резервируются на submit, **рефандятся при fail** (умягчает «failed = потрачены»; auto-retry всё равно запрещён). Rate limit 10 req/min. Поллинг: статусы IN_QUEUE|PROCESSING|COMPLETED|FAILED|CANCELLED|ERROR (allow-list §8.4), рендер 2-15 мин.
- **Позиционирование**: экран при движении генерится AI → «пиксель-в-пиксель» UI НЕ гарантирован. T3-DM = атмосферные промо-hero (экран мелкий/частичный в кадре), НЕ читаемые скринкасты (для них T1/T2).
- **Протокол (Claude-driven, MCP + bookkeeping-subcommands single-writer'а):**
  1. `get_video_models` → total estimate за все юниты → **явный y/n пользователя** →
  2. `run-screencast.sh dm-confirm --out DIR --confirm-total N` (state.cost_confirmed + session-ledger §10 п.5)
  3. постер юнита → публичный URL (upload) →
  4. `dm-intent --unit U --credits C` (write-ahead §6.1; отказ при висящем intent без job_id / превышении потолка) →
  5. MCP `create_video {start_image_url, model, duration, prompt}` → `dm-job --unit U --job-id ID` →
  6. поллинг `get_video_status` по policy §8.4 → COMPLETED → скачать →
  7. `dm-done --unit U --file f.mp4` (ffprobe verify → polish-слот, engine:"dm").
  Обрыв между 4 и 5: intent висит без job_id → повторный dm-intent ОТКАЗЫВАЕТ → проверить сторону DM → `dm-clear` (откат ledger) или `dm-job`.
- matrix `premium.implemented=false` осознанно: validate отсекает `--tier premium` в автопрогоне, пока рендер не обкатан live; ручной Claude-flow выше доступен.
- **Чеклист для `premium.implemented=true`** (finalize-3, обязателен ДО переключения флага):
  1. live happy-path: dm-confirm → dm-intent → реальный `create_video` → dm-job → поллинг до COMPLETED → скачивание → dm-done; read-back state: dm_job полный, polish verified.
  2. один преднамеренный fail-путь: убедиться что DM реально рефандит кредиты (баланс в дашборде до/после) → `dm-clear --refunded`.
  3. session-ledger «сессия» = 24h TTL (auto-reset), потолка ДВА: per-run (state.total_estimate) и session (ledger) — оба протестированы локально 19/19 + конкурентный тест (потолок не превышается при параллельных intent).

**Empirical-unknown (проверяется ТОЛЬКО live-тестом на реальном стыке):**
1. **DM create_video идемпотентность** — интеграционный тест: искусственный обрыв после отправки, до job_id → resume → assert НЕ создался второй платный job. *(открыт до первого платного рендера; обвязка готова, fail-closed путь оттестирован локально)*
2. ~~Cloudinary async post-processing~~ — **✅ ЗАКРЫТ live-тестом 2026-07-02.** Реальные находки оказались другими (панель была права, что стык непредсказуем из текста):
   - **Cloudinary на HEAD не отдаёт Content-Length** (HTTP/2) → verify через **range-GET 0-0** + total из `Content-Range`; заголовки с `\r` → `tr -d '\r'`.
   - **`op run` маскирует значения секретов в stdout** — `CLOUDINARY_CLOUD_NAME` входит в `secure_url` → URL приходил с `<concealed>`. Фикс: `--no-masking` в self-wrap `screencast-upload.sh` (безопасно: stdout жёстко фильтруется jq, ключи не попадают).
   - Идемпотентность подтверждена: re-upload после обрыва → тот же public_id/версия, Admin API показывает ровно N ассетов = N unit'ов.

---

## Источники ресерча
- Playwright Screencast API (v1.59+) — https://playwright.dev/docs/api/class-screencast · https://playwright.dev/docs/videos
- pagecast (Playwright+ffmpeg MCP) — https://github.com/mcpware/pagecast
- ScreenshotOne scrolling video API — https://screenshotone.com/scrolling-screenshots/
- Urlbox (video/GIF capture) — https://urlbox.com/
- Remotion (программное видео на React, phone-mockup + Lottie) — https://www.remotion.dev/ · https://github.com/remotion-dev/remotion
