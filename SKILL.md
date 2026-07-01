---
name: content-gen
description: |
  Use when user wants to generate or find visual content (photos, illustrations, icons,
  graphics) for landing pages, posts, presentations, marketing. Generates IN PARALLEL
  across multiple AI providers (Recraft v3, Gemini Nano Banana, Imagen 4, OpenAI
  gpt-image-1, Replicate Flux) plus 3 stock photo APIs (Unsplash, Pexels, Pixabay),
  shows HTML preview grid in browser, optionally uploads to Cloudinary. Has 3-tier cost
  system and smart-brief mode when prompt is too short.
  
  TRIGGER on ALL these phrasings (русский + английский):
  • «сгенери картинку», «сделай фото / иллюстрацию», «нужна картинка / фотка для X»
  • «давай погенерим», «погенери», «сгенерируй», «генерим контент»
  • «контент для X», «визуал для X», «hero / иконка / лендинг картинка»
  • "generate an image", "make me a picture", "create visual", "I need a photo of"
  • Explicit: «/content-gen», «/content-stock», «/content-brief», «/content-upload», «/content-vectorize»

  VECTORIZE / COMPRESS (имеет смысл и без генерации — работа с готовым файлом):
  • «трассируй / векторизуй / переведи в SVG», «сделай вектор из этой картинки», «отрисуй логотип в svg»
  • «сожми картинку», «оптимизируй изображение», «переведи в webp / avif», «уменьши вес фото»
  • "trace to svg", "vectorize this", "convert to svg", "compress this image", "convert to webp/avif"

  MOCKUPS (ветка `/content-mockup` — красивые мокапы сайта/приложения из URL):
  • «сделай мокап(ы) сайта X», «покажи сайт X в рамке айфона / ноутбука / браузера»
  • «мокап для презентации / кейса», «оформи скриншоты сайта красиво», «телефон в руке с сайтом»
  • «сайт X в контексте (баня/spa/…)», «картинки под слоты страницы X», «device mockup»
  • "make mockups of site X", "put the site in an iphone/macbook frame", "device mockups from url"
  • Explicit: «/content-mockup»

  TIER hints из контекста пользователя:
  • «пристрелочный», «попробуй», «прикинь», «быстрый», "quick test", "let's see" → --tier explore
  • просто generate без указаний → --tier mid (default)
  • «финальный», «для production», «hero для лендинга», «нужно качество» → --tier premium
  
  SOURCES: использовать stocks (`/content-stock`) если фраза вида «найди фото X», «есть готовые
  фотки X?», «нужна реальная фотография реки», «фото / стоковое фото X». Иначе → AI generation.
allowed-tools:
  - Bash
  - Read
  - Edit
  - Write
  - AskUserQuestion
---

# content-gen — multi-source visual content generator

Параллельная генерация в нескольких AI + поиск по стокам + умный smart-brief режим + Cloudinary upload. **Один Touch ID на весь запуск** (батчинг secrets через `op run --env-file`).

## Tier-система (cost-first)

| Tier | Sources | Цена | Когда |
|---|---|---|---|
| `--tier explore` | Replicate Flux + Nano Banana | **~$0.04** | Пристрелочный — отрабатываем промпт, ловим направление |
| `--tier mid` (default) | + Recraft v3 | **~$0.06** | Промпт ясен, нужны 3 уникальных варианта |
| `--tier premium` | + OpenAI gpt-image-1 + Imagen 4 | **~$0.14** | Финальный отбор для production-используемой картинки |

**Workflow**: пользователь обычно начинает с `explore`, видит что получается, докручивает промпт → `mid` → если ещё не то → `premium`.

## Команды

### `/content-gen <prompt>` (auto)

- Если **prompt ≤ 5 значимых слов** → переходит в brief-режим (см. ниже)
- Если **prompt детальный** → запускает сразу. Tier по умолчанию `mid`.
- Флаги: `--tier explore|mid|premium`, `--sources csv`, `--style <recraft-style>`

### `/content-brief <идея>` (explicit)

**Smart-brief режим**: я задаю 3-5 вопросов, собираю enriched промпт, потом генерирую.

Шаги:
1. **Прочитай контекст**: (опционально) если ведёшь базу проектов — подтяни `brand_colors`, `style`, `domain_primary` из карточки проекта для консистентного визуала
2. **Прочитай** `lib/prompt-engineering.md` — справочник правил
3. **Спроси через AskUserQuestion** (выбирай 3-5 параметров наиболее релевантных, не больше):
   - Subject — что главное на картинке
   - Style — photo / illustration / 3D / vector / sketch
   - Mood — calm / energetic / cozy / luxurious / mystic / playful
   - Palette — brand colors / warm earth / pastel / mono / vivid
   - Composition — close-up / wide / aerial / top-down
   - Lighting — golden hour / studio / neon / dawn
   - Usage — hero banner / app icon / social post / pres slide
   - Aspect ratio — 1:1 / 16:9 / 9:16 / 4:5
4. **Собери enriched prompt** по структуре `[scene] → [subject] → [details] → [style] → [composition] → [lighting] → [usage]`
5. **Покажи финальный промпт** пользователю на подтверждение перед запуском
6. **Запускай** `/content-gen` (default mid tier, если не указано иначе)

### `/content-stock <query>`

Параллельный поиск по Unsplash + Pexels + Pixabay (3 фото из каждого = 9 в grid).

### `/content-upload <path>` 

Подписанный upload **картинки** в Cloudinary, возвращает URL + WebP вариант + thumbnail.

### `/content-video-upload <path-or-url>`

Подписанный upload **видео** в Cloudinary. Принимает либо локальный файл, либо URL (Cloudinary сам fetch'нет — не нужно качать). Возвращает: оригинал + 5 derivatives on-the-fly (auto `f_auto,q_auto`, 720p H.264, WebM, poster JPG, GIF preview 3 сек).

### `/content-vectorize <input> [флаги]` — трассировка в SVG + компрессия/конвертация

Комбайн на готовом файле (не генерация). Движок — `lib/imgforge.sh`. Два режима:

**Трассировка → SVG** (vtracer + potrace, авто-svgo):
| Флаг | Когда | Движок |
|---|---|---|
| `--svg` | цветной логотип / плоская иллюстрация | vtracer color |
| `--poster` | постер, ограниченная палитра | vtracer poster |
| `--photo` | фото с градиентами (осторожно — тяжёлый SVG) | vtracer photo |
| `--bw` | ч/б быстро | vtracer bw |
| `--potrace` | ч/б line-art / иконка, самые гладкие кривые | mkbitmap + potrace |

**Компрессия / конвертация** (sharp + pngquant/oxipng/cwebp):
- `--to webp\|avif\|png\|jpeg` (default webp) · `--max <px>` (downscale only) · `--q <1-100>`
- PNG дополнительно прогоняется через pngquant + oxipng (lossless).

Общие: `--out <path>`, `--no-svgo`, `--upload` (→ Cloudinary). Результат по умолчанию в `~/Downloads/imgforge/`. Скрипт печатает экономию веса `было → стало`.

Правило выбора: фото просят «в SVG» → честно предупреди, что вектор из фото бывает тяжелее оригинала, и предложи `--to webp/avif` как альтернативу. Логотип/иконку «сжать» → лучше `--potrace` (вектор масштабируется без потерь), а не растровая компрессия.

### `/content-mockup <url>` — красивые мокапы сайта/приложения

Из URL делает пачку мокапов: **ветка A** (скриншот в рамке браузера/iPhone/iPad/MacBook) и **ветка C** (устройство в тематическом контексте — ноут в бане, телефон в руке в spa). Скриншот вставляется **детерминированно** (green-screen composite), поэтому экран всегда пиксель-в-пиксель, без генеративных искажений. desktop **и** mobile — обязательно.

**Движок один на обе ветки**: сгенерить/нарисовать поверхность с chroma-green экраном → `frame-composite.py --mode green` вставляет реальный скриншот. Ветка A — `frames.py` (PIL-устройство, офлайн). Ветка C — `scene-recraft.sh` (Recraft-сцена, в `op run`).

**Оркестратор** `run-mockup.sh {capture|explore|produce|grid}` делает механику; **Claude ведёт суждения** (ниже). state.json в run-папке отражает фазу — можно продолжить прерванное.

#### Поток (две фазы)

**Фаза 0 — НАЗНАЧЕНИЕ (объём «куда и сколько»).** Определить, подо что картинки:
- `--for-page <repo-path>` → `run-mockup.sh capture` внутри дёрнет `slots-from-page.mjs` (next/image, `<img>`, background, компоненты Hero/Feature/Gallery) → slot-манифест.
- `--for-page <url>` → слоты меряет `capture.mjs --measure-slots` (реальные rendered-размеры на desktop+mobile).
- **Fallback (critical):** если слотов 0 / `fallback:true` — НЕ генерить молча. Спросить назначение через **AskUserQuestion** (презентация 16:9 / соцсети 4:5+9:16 / произвольно N) → пресет объёма.
- Нет `--for-page` вовсе → сразу спросить назначение пресетом.

**Фаза 1 — РАЗВЕДКА направления (тиндер).**
1. `run-mockup.sh capture` → скриншоты + `brand-probe` (имя/лого/палитра/вайб).
2. **Claude из вайба бренда придумывает 4–8 контекстов** для ветки C и кладёт в `contexts.json`:
   `[{context:"<сцена по-английски>", device:"laptop|phone|tablet", label:"<рус. подпись>", size:"1365x1024"}]`.
   Пример: вайб `spa-sauna` → «open laptop on a wooden bench in a steamy banya among birch brooms», «phone held in hand by a spa pool». Креативь по нише (баня→парная с вениками; кофейня→чашка рядом; фитнес→зал).
3. `run-mockup.sh explore --contexts contexts.json --devices … --tier …` → колода A+C, `deck.html`, feedback-server (порт/токен в stdout).
4. Открыть деку: `open <deck.html>` (или дать URL если headless). Пользователь лайкает/оценивает/комментит → ответы в `round-1.answers.json`.
5. **Claude синтезирует АРТ-ДИРЕКШН** из ответов (что лайкнули: устройство, контекст, палитра, настроение) → `art.json`:
   `{mode:"frame|scene", device:"browser|iphone|…", bg:"#c1,#c2", context:"<для scene>", scene_device:"laptop"}`.
   `--skip-deck` — если направление уже очевидно (пропустить тиндер, собрать `art.json` сразу).

**Фаза 2 — ОБЪЁМ.** `run-mockup.sh produce --art art.json --slots slots.json` → под каждый слот desktop+mobile в выбранном направлении, привод к точным WxH → `grid`. Опц. `--upload` (Cloudinary, как в базовом content-gen).

#### Тиры и стоимость
- `explore` — только рамки (офлайн, **бесплатно**). `mid` (деф.) — рамки + Recraft-сцены (~$0.04/сцена). `premium` — крупнее размеры/больше сцен.
- **Cost-first (critical):** перед фазой с Recraft **оценить и подтвердить** стоимость (кол-во сцен × $0.04). Как в базовом content-gen — не жечь premium без согласия.

#### Безопасность
- **SSRF (реализовано в `lib/ssrf.mjs`):** capture/brand-probe блокируют приватные/loopback/metadata IP + схемы file/data. Не отключать.
- **op run узко:** секрет Recraft живёт только внутри `op run` вокруг генерации сцен; state/скриншоты/композит — вне. Один Touch ID.
- **PII-нотис:** `/content-mockup` — для **публичных** страниц. Скриншот уходит в 3rd-party AI (Recraft). НЕ гнать на внутренние/staging-дашборды с реальными данными клиентов — предупредить пользователя, если URL выглядит приватным.

#### Флаги
`--for-page <путь|url>` · `--devices browser,iphone,ipad,macbook` · `--tier explore|mid|premium` · `--skip-deck` · `--full-page` · `--upload`

#### Первый запуск
Нужен Playwright chromium (~110MB): ставится один раз `cd ~/.claude/skills/content-gen && npx playwright install chromium`. `run-mockup.sh capture` понятно ругнётся, если браузера нет.

#### Известные ограничения v1
- Ветка A (чистый green) — идеальный композит. Ветка C — редкий тонкий зелёный кант на **скруглённых/наклонных** экранах (despill глушит основное); для чистоты предпочитать плоские экраны (ноут) наклонным телефонам.
- Ветка B (лого на носителях: билборды/мерч) — **не в v1** (бэклог).
- A и C — **независимые серии** картинок (рамка ИЛИ контекст), не комбинируются на одном изображении.

## Архитектура (что под капотом)

```
~/.claude/skills/content-gen/
├── SKILL.md
├── run.sh                          ← оркестратор AI gen (1 op run на всё)
├── run-stock.sh                    ← оркестратор stocks (1 op run на всё)
└── lib/
    ├── all-secrets.env             ← все op:// references в одном файле
    ├── prompt-engineering.md       ← справочник лучших практик
    ├── generate-recraft.sh         ← curl + jq, использует $RECRAFT_API_KEY из env
    ├── generate-gemini.sh
    ├── generate-imagen.sh
    ├── generate-openai.sh
    ├── generate-replicate.sh
    ├── stock-unsplash.sh
    ├── stock-pexels.sh
    ├── stock-pixabay.sh
    ├── upload-cloudinary.sh
    ├── imgforge.sh                 ← трассировка в SVG + компрессия/конвертация (vtracer/potrace/svgo/sharp)
    ├── render-grid.py              ← HTML preview generator
    │   — ↓ ветка /content-mockup ↓
    ├── capture.mjs                 ← Playwright: скриншоты desktop/mobile/tablet + замер слотов (SSRF-guard)
    ├── ssrf.mjs                    ← egress-guard (приватные IP/metadata/file) — общий для capture+brand-probe
    ├── brand-probe.mjs             ← бренд из URL: имя/лого/палитра-hook/вайб
    ├── palette.py                  ← доминирующие цвета скриншота (PIL quantize)
    ├── slots-from-page.mjs         ← slot-манифест из репо-шаблона (+fallback при 0 слотах)
    ├── frames.py                   ← PIL-устройства с green-экраном (ветка A): browser/iphone/ipad/macbook
    ├── frame-composite.py          ← green-детект (largest connected comp) + perspective-вставка + despill
    ├── scene-recraft.sh            ← Recraft-сцена с green-экраном (ветка C), $RECRAFT_API_KEY из env
    ├── feedback-server.js          ← эфемерный localhost-приёмник ответов тиндера (вендор из redreference)
    └── deck-page.js                ← HTML-тиндер колоды мокапов (👍/👎/оценка/коммент → POST серверу)
```
(+ `run-mockup.sh` в корне скилла, `package.json` с pinned playwright)

**Ключевой паттерн**: `run.sh` и `run-stock.sh` оборачивают весь параллельный запуск **в один `op run --env-file=all-secrets.env`**. Sub-скрипты используют env vars напрямую без своих `op` вызовов. Это → **один Touch ID на запуск** (или ноль если 1Password в режиме «authorize while unlocked»).

**Движки imgforge** (offline, без секретов; ставятся один раз): `vtracer` (~/.local/bin, prebuilt-бинарь с GitHub) · `potrace`+`mkbitmap`+`pngquant`+`oxipng` (brew) · `svgo`+`sharp-cli` (npm -g) · `cwebp` (brew) · Pillow (pip, нужен только для `--potrace`-пути PNG→PNM). Скрипт сам добавляет `~/.local/bin` в PATH. Cloudinary-аплоад (`--upload`) — единственное место, где нужен `op` (переиспользует `upload-cloudinary.sh`).

## Russian → English

Если промпт на русском — **сам перевожу на английский** перед вызовом скрипта. Все 5 AI работают значительно лучше с английским. Сохраняю оригинал в `meta.json` как `prompt_original`.

## Меня (Claude) задействуй проактивно когда

- Пользователь упоминает проект из `projects/` и нужна визуалка — auto-brief с context из его frontmatter
- На checkpoint 3 в `page-design-pipeline` — для hero/feature visuals
- После design-brief'а от `emil-design-eng` — для конкретики

## Acceptance-контракты /content-mockup («Done when», critical #5 панели)

| Компонент | Done when |
|---|---|
| `capture.mjs` | `{ok:true}` + PNG на каждый запрошенный viewport; приватный/опасный URL → `{ok:false,error:"SSRF…"}` (exit≠0), не скриншот. |
| `frame-composite.py` | `{ok:true, screen_px:[w,h]}`; скриншот занимает экран без видимого зелёного канта (bleed+despill); нет зелёного → `{ok:false}` code=3, не кривой результат. |
| `frames.py` | 4 устройства рисуются, green-экран = осевой прямоугольник (детект даёт точные углы). |
| `slots-from-page.mjs` | список слотов с desktop+mobile WxH; **0 слотов → `{fallback:true,reason}`**, не пустой тихий манифест. |
| `scene-recraft.sh` | `{ok:true,out}` с сохранённой сценой; ошибка API → `{ok:false,error}` exit=2 (не пустой файл). |
| тиндер (`feedback-server`+`deck-page`) | сервер стартует (bind 127.0.0.1, bearer-token), POST раунда → `round-N.answers.json`; неверный токен → 401. |
| `run-mockup.sh produce` | N мокапов **ровно под размеры слотов** (desktop+mobile); частичный сбой слота → `failed++`, не падение всего прогона. |
| Фича в целом | `/content-mockup <public-url>` проходит capture→explore→produce без ручного вмешательства кроме тиндер-выбора; partial-fail помечается, не блокирует. |

## Anti-patterns

- Не запускай `premium` без согласия пользователя — дорого
- Не оставляй results-папки месяцами — `~/Downloads/content-gen/` чистка вручную
- Не загружай в Cloudinary без явного выбора пользователя
- Не предлагай негативные промпты — модели не очень умеют (см. prompt-engineering.md)
- **/content-mockup:** не гони на приватные/staging URL с PII (скриншот уходит в Recraft); не отключай SSRF-guard; ветку C на скруглённых экранах — предпочитай ноут телефону (чище композит).

## См. также

- [`lib/prompt-engineering.md`](lib/prompt-engineering.md) — глубокий справочник
- [`commands/content-gen.md`](../../commands/content-gen.md), `content-brief.md`, `content-stock.md`, `content-upload.md`
