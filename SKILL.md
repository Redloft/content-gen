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

  SCREENCAST (ветка `/content-screencast` — ВИДЕО-мокапы сайта из URL, гладкий скролл 60fps):
  • «сделай видео сайта», «видосик как сайт скроллится», «скринкаст сайта», «видео-мокап»
  • «покажи сайт в движении», «ролик с сайтом в айфоне», «scroll-видео для соцсетей/hero»
  • "screencast of the site", "scrolling video of site X", "video mockup", "site scroll video"
  • Explicit: «/content-screencast»

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

> **fal.ai — доп. провайдер (⚠️ DORMANT, не подключён к tier'ам).** Ключ `FAL_KEY` заведён в 1Password (`AI-Tokens/FAL_KEY`, scope-global), даёт 100+ моделей (Flux целиком, Seedream, Qwen, видео Kling/Sora) через `POST https://fal.run/<model>`, auth `Authorization: Key $FAL_KEY`. **Не использовать: баланс аккаунта = 0** (fal → 403 "Exhausted balance"). Включать в tier-систему только после пополнения баланса (fal.ai/dashboard/billing). Вызов — через `op run --env-file=<(echo 'FAL_KEY=op://AI-Tokens/FAL_KEY/credential') -- ...`.

## Команды

### `/content-gen <prompt>` (auto)

- Если **prompt ≤ 5 значимых слов** → переходит в brief-режим (см. ниже)
- Если **prompt детальный** → запускает сразу. Tier по умолчанию `mid`.
- Флаги: `--tier explore|mid|premium`, `--sources csv`, `--style <recraft-style>`

### `/content-brief <идея>` (explicit)

**Smart-brief режим**: я задаю 3-5 вопросов, собираю enriched промпт, потом генерирую.

Шаги:
1. **Прочитай контекст**: если в чате упоминается проект из `$CLAUDECORE_PATH/projects/` — подтяни `brand_colors`, `style`, `domain_primary` из его frontmatter
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

Из URL делает пачку мокапов: **ветка A** (скриншот в рамке браузера/iPhone/iPad/MacBook), **ветка C** (устройство в тематическом контексте — ноут в бане, телефон в руке в spa) и **ветка D** (профессиональные PSD-сцены через Dynamic Mockups API — премиум editorial-качество, см. ниже). Скриншот вставляется **детерминированно** (green-screen composite в A/C; smart-object warp в D), поэтому экран всегда пиксель-в-пиксель, без генеративных искажений. desktop **и** mobile — обязательно.

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

#### Ветка D — PSD-мокапы (чужие профессиональные PSD со smart object)

Потолок качества веток A/C — плоская вклейка. Ветка D рендерит скриншот в **профессиональный PSD со smart object** (перспектива, блики, свет сцены). **Два движка, оба рабочие:**

- **D-local (Photopea, ДЕФОЛТ, 2026-07-03):** бесплатно, без watermark, без кредитов, полностью локально. Обкатан на GraphicBurger MacBook + Armchair (mockups-design). — см. ниже «Ветка D-local».
- **D-DM (Dynamic Mockups API):** облачный, free tier = watermark + 50 кредитов, Pro $19/мес. Держим как fallback для PSD, где нужен родной DM-варп/фичи (nested SO мы локально не рендерим). Доступ: MCP `dynamic-mockups` / REST; ключ в 1Password `AI-Tokens/Dynamic Mockups API`.

##### D-local — рендер чужих PSD через Photopea (бесплатно, дефолт)

Photopea обрабатывает PSD **client-side** (файл наружу НЕ уходит — локальные байты подсовываются через `context.route` перехват `https://local.mock/*`; в сеть идёт только статика самого photopea.com). Всё в `lib/`:

- **`psd-so-swap.mjs dims <psd> --so "<layer>"`** → `{w,h,doc_w,doc_h,transform}`. `transform` = **`nonAffineTransform`** placed-слоя (настоящий перспективный квад; обычный `transform` — лишь bbox, для наклонных PSD врёт).
- **`quad-warp.py <shot> <doc_w> <doc_h> '<quad8>' <out>`** — перспективный варп скриншота в квад на прозрачной канве (тот же PIL PERSPECTIVE + 4× AA-маска, что в D2).
- **`photopea-run.mjs overlay <psd> --overlay <warped.png> --above "<screen-layer>" --quad '<quad8>' [--rm "<placeholder substr>"] --out <png>`** — удаляет слои-заглушки → вставляет варп-растр ПРЯМО НАД слоем экрана (под Highlights, чтобы блики PSD легли сверху) → экспорт PNG.
  - Ещё режимы: `dump` (дерево слоёв), `export` (чистый рендер PSD как есть).

**Пайплайн D-local (desktop-пример):**
```bash
DIMS=$(node lib/psd-so-swap.mjs dims theirs.psd --so "Screen")
W=$(jq -r .w <<<"$DIMS"); H=$(jq -r .h <<<"$DIMS")
DW=$(jq -r .doc_w <<<"$DIMS"); DH=$(jq -r .doc_h <<<"$DIMS"); QUAD=$(jq -c .transform <<<"$DIMS")
# скриншот ровно под размер содержимого SO (cover-кроп в левый-верх, как в D2)
python3 -c '...resize shot to WxH...'  shot.png -> so-shot.png
python3 lib/quad-warp.py so-shot.png "$DW" "$DH" "$QUAD" warped.png
node lib/photopea-run.mjs overlay theirs.psd --overlay warped.png --above "Screen" --rm "delete this layer" --quad "$QUAD" --out render.png
```

**Грабли D-local (проверено 2026-07-03):**
- **Photopea в headless НЕ коммитит smart object** обратно в родителя (`placedLayerEditContents`+`save()` виснет на «loading…», [photopea#5921](https://github.com/photopea/photopea/issues/5921)). Поэтому НЕ редактируем SO — варпим сами и кладём **растровым слоем поверх** слоя экрана. Отсюда `overlay`-режим.
- **ag-psd roundtrip ломает сложные PSD** (78MB Armchair после ре-энкода Photopea не грузит/OOM). Вывод: **оригинал PSD не переписывать**, добавлять слой уже в Photopea (`overlay`), а не через `swap`+раст в linked file. `swap`-режим оставлен, но годится только для простых PSD (GraphicBurger 47MB грузился).
- **copy/paste в Photopea headless РАБОТАЕТ** (внутренний буфер, не OS clipboard); `duplicate(doc)` между документами — виснет, не использовать. Paste центрует **непрозрачный** bbox по центру дока → репозиционировать в `min(quad)` (флаг `--quad`).
- **ag-psd в node требует canvas-шим**: `initializeCanvas(()=>{throw}, (w,h)=>({width,height,data:new Uint8ClampedArray(w*h*4)}))` — 2 аргумента, второй = createImageData; хватает для imageData-путей.
- Большие PSD: `chromium.launch(args:["--js-flags=--max-old-space-size=8192"])` + загрузку ждать по пробе `app.documents.length>=1` (сигнал `done` приходит и от готовности приложения, и от файла — на него полагаться нельзя). Photopea иногда флейково не грузится с первой попытки → при `timeout waiting done after: photopea app ready` просто повторить.
- Слои-заглушки: `--rm "delete this layer"` (mockups-design). У GraphicBurger/Unblast заглушек нет.

##### D-DM — Dynamic Mockups API (fallback)

**Протокол:**
1. Скриншот → публичный URL (Cloudinary через `lib/upload-cloudinary.sh`, или litterbox 24h для разовых тестов).
2. Свой PSD: распаковать из zip → залить PSD на публичный URL → `upload_psd` (нужен **прямой** URL на `.psd`, не превью-страница) с `mockup_template.create_after_upload: true`. Шаблон возвращает `smart_objects[].uuid`.
3. `create_render` (mockup_uuid + smart object uuid + `asset.url`, `fit: "cover"` для экранов) → `export_path` (S3, живёт 24ч) → скачать локально сразу.
4. Много картинок за раз — `create_batch_render` (те же кредиты, один вызов).

**Библиотека PSD:** рефы стиля — `$CLAUDECORE_PATH/mockup/`; выбранные PSD хранить в `$CLAUDECORE_PATH/mockup/psd/` (источники и лицензии — в `SOURCES.md` рядом). Загруженный в Dynamic Mockups шаблон постоянный — повторный рендер любого сайта = 1 кредит, без ре-аплоада.

**Грабли (проверено 2026-07-02):**
- **MockAnything (AI-ветка API) НЕ детектит экраны устройств** — его детектор print-area заточен под POD (футболки/кружки). И prompt-, и image_url-flow возвращают пустой `smart_objects` для ноутбуков. Для сайтов — только classic PSD upload.
- **PSD от mockups-design.com содержат слой-заглушку «DELETE THIS LAYER»** поверх сцены — рендер даёт заглушку вместо мокапа. Чистить в Photoshop перед загрузкой. У GraphicBurger/Unblast заглушек нет — рендер сразу чистый.
- **Free tier: 50 кредитов, рендеры с водяным знаком** «Dynamic Mockups». Pro ($19/мес) снимает watermark и нужен для прода; для оценки качества free хватает.
- `upload_psd` через MCP на больших PSD (>70MB) иногда отдаёт timeout — **сначала `get_mockups`** (загрузка могла пройти на сервере), только потом ретрай, иначе дубликат шаблона.
- Скачивание free-PSD с download-monitor-сайтов (mockups-design и пр.): страница отдаёт meta-refresh с nonce — `lib/dlm-download.sh <download_url> <referer> <out>` (двухшаговый curl с cookie-jar) решает.

**Когда какая ветка:** D — готовые чужие PSD из библиотеки (**D-local через Photopea = дефолт, бесплатно**; D-DM только если нужен родной DM-движок). **D2 (основной путь для своих сцен, см. ниже)** — полностью локально. C (хромакей, legacy) — движок сцен для D2. A — быстрые чистые рамки.

#### Ветка D2 — self-made сцены с PSD-качеством (основной путь, полностью локально)

Дуэль 2026-07-02 (одна сцена, один скриншот): локальный композит **лучше** Dynamic Mockups на своих сценах — перспектива та же (гомография), а перенос света у DM отсутствует (glare-слои PSD он сам не придумывает). Бесплатно, без watermark. DM нужен только для чужих готовых PSD.

**Матрица генераторов сцены D2 (дуэль 2026-07-02, termoport, идентичные промты, все edge_fit):**

| Генератор | Скрипт | Роль | Цена/сцена | Факты дуэли |
|---|---|---|---|---|
| **NB Pro `gemini-3-pro-image`** | `lib/scene-gemini.sh` | **ДЕФОЛТ** | ~$0.13 (2K) | Единственный слушается «screen 70–90%» и даёт бесчёлочный iPhone; **точный текст бейджей** (TERMOPORT посимвольно — снимает боль clean-scene.py); богатая полоса света; editorial-реализм уровня рефов |
| Recraft v3 | `lib/scene-recraft.sh` | fallback, массовые дешёвые | ~$0.04 | Экран мельче запрошенного (50–60%), мусор-точки на зелёном, врёт текст, чёлочный iPhone |
| gpt-image-1.5 | `lib/scene-openai.sh` | fallback #2 | ~$0.07–0.25 | Чистый осевой квад, но композиция плоская/фронтальная; на телефоне рисует punch-hole НА зелёном → окклюзия-артефакт на вклейке (добавлять «no camera hole on the screen») |

Fallback-порядок: NB Pro → Recraft → gpt-image-1.5. Все три скрипта принимают `--prompt` (raw override) для дуэлей/кастома; контракт `{ok,out}` одинаковый; retry/backoff встроен в новые.

**1b «сцена вокруг якоря» (image-edit по green-якорю) — ОТКЛОНЁН (2026-07-02):** гипотеза «квад точный by construction» опровергнута — обе модели пересобирают холст (NB Pro сдвинул/наклонил якорь, gpt-image-1.5 уменьшил), преимущества перед обычной генерацией нет. Если когда-то возвращаться к image-edit путям: **PII pre-flight assert обязателен** — якорь только синтетика с green-квадом (≥8% чистого зелёного, 0% контента внутри bbox), НИКОГДА не запечённый скриншот (уйдёт в 3rd-party).

**Протокол D2** (все скрипты в `lib/`, python = `~/.claude/parsing-venv` с numpy+Pillow):
1. **Сцена**: дефолт — `scene-gemini.sh` (NB Pro, матрица выше); промт как в ветке C, но (а) «screen fills 85-90% of the frame», (б) **разрешить** «a soft diagonal band of window light falls across the green screen as a subtle reflection» — генератор запекает блики В зелёный, перенос света их заберёт; (в) лимит промта 1000 символов; (г) точный бренд-текст в сцене МОЖНО просить у NB Pro (посимвольный спеллинг в промте + визуальная сверка), для Recraft — по-прежнему только пост-композит.

**СПЕЦ ТЕЛЕФОНА (обязательно, жёстко — Игорь 2026-07-02):** для телефонных сцен —
   - **Дисплей крупный — 60–70% кадра**, это ключевое. Промт: «screen is HUGE, fills 70-80% of the whole frame, almost straight-on». Плюс `--crop-screen=0.68` в composite добивает точный процент авто-кропом (по построению, не на удачу генератора). ✅ работает.
   - **«Последний iPhone» — НЕ дорисовывать Dynamic Island** (флаг `--di` есть, но НЕ использовать): Recraft упорно даёт чёлочный корпус, дорисованный островок ложится ПОВЕРХ остатка чёлки — два элемента, выглядит плохо (проверено, Игорь забраковал). Если нужен честный современный iPhone — брать готовый бесчёлочный **PSD ветки D** (Dynamic Mockups), а не выбивать из Recraft.
   - Вызов: `selfmade-composite.py <scene> <shot> <out> <junk-mask> --crop-screen=0.68` (без `--di`).
   - **Брендинг — НЕ тату** (выглядит чужеродно, забраковано): `brand-corner.py <img> <wordmark.svg> <out> br 0.20 0.55` ставит деликатный знак РЕДЛОФТ/RedLoft в угол (замена watermark, как «mockupbureau.com» в рефах). `tattoo.py` оставлен в lib на случай уместной сцены, но по умолчанию не применять.
2. **Чистка** `clean-scene.py <scene> <clean> <junk-mask>`: мусор-иконки на зелёном → junk-маска (НЕ инпейнт сцены — их накроет вставка, важна только карта света); кривой текст бейджа (Recraft врёт в точных надписях!) → штрихи стираются median-inpaint вдоль наклонного нижнего ребра, поверх рисуется точный «RedLoft» (Helvetica, угол ребра). Брендинг = всегда пост-композит, не промт.
3. **Аспект-скриншот** `shot-aspect.mjs <url> <aspect> <out>`: аспект квада (`quad_true_size`) → Playwright-скриншот ровно под него → сайт влезает целиком by construction, никаких кропов.
4. **Композит** `selfmade-composite.py <clean-scene> <shot> <out> [junk-mask]`: гистерезисная детекция квада (строгий seed → реконструкция в мягкую маску g>r+18 — затенённые части экрана не теряются) → 4× суперсэмпл маска (AA-кромка) → despill в зоне ~±28px (глобальный ЖРЁТ легитимную зелёную ткань) → перспектива → **перенос света** (luma/blurred-ref: multiply тени + screen блики + specular вуаль) → ring-kill остаточного хрома у кромок.

Грабли D2: Recraft путает точный текст даже с посимвольным спеллингом («Real LoFs», «Reiloft») — не бороться промтом; junk-иконки на экране — почти в каждой генерации; экраны Recraft слегка выпуклые (bleed 4 + ring-kill обязательны); чёрная точка экрана поднята через `BLACK_FLOOR=14` в composite (живой дисплей ≠ RGB0; тюнить там же). Детекция квада печатает `quad_fit_quality` (edge_fit|extreme_point_fallback|strict_fallback) + stderr-флаг `degraded:true` при деградации — батч-оркестратор ловит подозрительные кадры.

**Безопасность ассетов:** `svg_p` в `tattoo.py`/`brand-corner.py` (и логотип в composite-брендинге) — ВСЕГДА доверенный локальный ассет (`$CLAUDECORE_PATH/.../logo/*.svg`). НЕ подавать сюда user-supplied SVG без санитайза: cairosvg рендерит внешние `<image href>`/`url()` → потенциальный SSRF/file-read.

**Регресс-фикстура (единственная страховка без гейтов):** держать 1 эталон (сцена + ожидаемые 4 угла ±5px) — при бампе Pillow/numpy знак SVD / поведение MaxFilter могут молча сдвинуть quad-fit. TODO: закрепить ref51 как фикстуру.

**Сборка своего PSD** (если нужен файл для DM/клиента): `build-psd.js <scene> <shot> <out.psd> <quad8>` (ag-psd; id placedLayer = GUID обязателен; pngjs требует чистые PNG — sips-овские прогонять через PIL; transform+nonAffineTransform = квад). DM принимает и рендерит такой PSD (проверено).

#### Ветка F — Figma MCP (on-demand, НЕ дефолт; проверено 2026-07-03)

Figma-коннектор (официальный MCP) авторизован под «Redloft team» (7 команд, Wellbokin = pro). **Round-trip доказан end-to-end**: `create_new_file` → `use_figma` строит рамку (browser-chrome/девайс с тенью и плейсхолдер-прямоугольником) → `upload_assets --nodeId <rect> --scaleMode FILL` заливает скриншот пиксель-в-пиксель → `get_screenshot` экспортирует PNG (2x). Детерминированно, без генеративных искажений — инвариант соблюдён.

**НО для ПЛОСКОЙ рамки Figma строго ХУЖЕ ветки A** (PIL-рамки): облачная зависимость + авторизация + 3-4 MCP-вызова ради того же результата, что A даёт локально/бесплатно/мгновенно/офлайн. Поэтому Figma — **не новая дефолт-ветка**, а on-demand для двух случаев, где она уникальна:
1. **Дизайн живёт в Figma** (проект ещё не сверстан): источник = не live-URL, а `get_screenshot` фрейма напрямую (`get_metadata` → nodeId → `get_screenshot`). Скриншотить макет вместо сайта.
2. **У клиента есть брендированные device-mockup компоненты / дизайн-система в Figma** (у Игоря 7 команд): залить скриншот в их фирменную рамку и экспортнуть.

Генерация UI-экранов из дизайн-системы (`generate_figma_design`/`use_figma` + `search_design_system`) — это ДРУГОЙ дедиверабл (дизайн-в-код), место которому в `page-design-pipeline`/`redloft`, не в мокапах. Обязательный префлайт: скилл `figma-use` ПЕРЕД любым `use_figma` (иначе трудноуловимые падения). Тестовый файл-проба: `figma.com/design/op45mKpBmMNBzif92dwdMz` (Redloft drafts — можно удалить).

#### Известные ограничения v1
- Ветка A (чистый green) — идеальный композит. Ветка C — редкий тонкий зелёный кант на **скруглённых/наклонных** экранах (despill глушит основное); для чистоты предпочитать плоские экраны (ноут) наклонным телефонам.
- Ветка B (лого на носителях: билборды/мерч) — **не в v1** (бэклог).
- A и C — **независимые серии** картинок (рамка ИЛИ контекст), не комбинируются на одном изображении.
- Ветка D: free tier = watermark; свои PSD должны иметь smart object (`MISSING_SMART_OBJECTS` иначе); библиотека PSD пока в стадии отбора.

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
    ├── scene-recraft.sh            ← Recraft-сцена с green-экраном (ветка C/D2), $RECRAFT_API_KEY из env
    ├── scene-gemini.sh             ← NB Pro-сцена (gemini-3-pro-image) — ДЕФОЛТ сцен D2, $GEMINI_API_KEY
    ├── scene-openai.sh             ← gpt-image-1.5-сцена — fallback D2, $OPENAI_API_KEY
    ├── photopea-run.mjs            ← headless-рендер чужих PSD (ветка D-local): dump|export|overlay|swap, client-side
    ├── psd-so-swap.mjs             ← читает nonAffineTransform-квад placed-слоя из PSD (ag-psd) + raster-swap
    ├── quad-warp.py                ← перспективный варп скриншота в квад на прозрачной канве (для D-local)
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

### `/content-screencast <url>` — видео-мокапы сайта (motion-сиблинг /content-mockup)

Из URL делает **видео-ролики** сайта в рамке девайса: гладкий скролл 60fps, desktop+mobile.
Полная спека и контракты — [`SCREENCAST-SPEC.md`](SCREENCAST-SPEC.md) (v3, прошла 2 раунда plan-panel).

**Главный трюк (Tier 2 = default):** НЕ записывать реальный скролл (он дёргается), а взять
один full-page скриншот и панорамировать по нему ffmpeg'ом со smoothstep-easing — скролл
получается идеально гладким, пайплайн офлайн и бесплатный.

**Запуск:**
```bash
./run-screencast.sh run --url <url> --out <dir> --formats mobile-scroll,desktop-scroll --tier mid
# стадии по отдельности: validate | capture | polish | frame | deck (+resume из state.json)
```

- Тиры: `mid` (T2 pan, default) и `explore` (T1 recordVideo — реальная запись + `clicks`-сценарии) — **реализованы**; `premium` (T3) — обвязка готова, рендер не обкатан (см. ниже).
- **T3-DM (premium)**: Dynamic Mockups `create_video` = **генеративное Kling image-to-video** (АI-«оживление» мокапа: камера/свет; UI не пиксель-в-пиксель → для атмосферных промо, не для читаемых скринкастов). ПЛАТНО (v2.6 5s = 40 кредитов). Протокол строго по SPEC §12: `dm-confirm` (после явного y/n с суммой!) → `dm-intent` → MCP `create_video` → `dm-job` → поллинг → `dm-done`. Обрыв: intent без job_id блокирует повтор — проверить DM, потом `dm-clear`/`dm-job`. Session-ledger в `~/Library/Application Support/content-screencast/`.
- Форматы: `mobile-scroll` (iPhone 9:16), `desktop-scroll` (browser 16:9), `clicks` (T1: `--scenario steps.json` — scroll/hover/click/wait, см. SPEC §5), `loop/gif`.
- T1: `lib/record.mjs` (easing-скролл через rAF+smoothstep, SSRF route-guard `lib/ssrf-route.mjs` на всю сессию, watchdog 45s, WebM cap 200MB → транскод в mp4, WebM чистится).
- **Exit-code 0 ≠ success**: каждый шаг верифицируется (ffprobe duration/resolution/stream; capture bytes+размеры). Упавший unit → карточка с причиной в deck.html, остальные доводятся (continue-on-error).
- state.json (schema v1) в run-папке: resume по unit'ам `(format/device)`, write-ahead intent для платных вызовов.
- Guards: goto 15s, ffmpeg 120s watchdog, height cap 20000px, `imgH<=viewportH` → статичный 3s loop.
- Требует **ffmpeg** (`brew install ffmpeg`, сам не ставит). SSRF/PII — как у мокапов.
- Регрессия сиблинга: `lib/test-mockup-contract.sh` (гонять после правок общих lib-файлов).
- **Деривативы** (`--derive`/`--loop` или стадия `derive`): gif <10MB (palette, зациклен) + poster png.
- **Заливка** (`--upload` или стадия `upload`, обкатано live): идемпотентный `public_id=sc-<hash>` + overwrite (resume без дублей), round-trip verify **range-GET** (Cloudinary на HEAD не отдаёт Content-Length!), retry 3×5s. **PII-gate fail-closed**: без `--pii-ok` откажет — сначала спросить пользователя (Cloudinary = 3rd-party). `lib/screencast-upload.sh` — самообёртка `op run --no-masking` (op маскирует cloud_name в secure_url — не убирать флаг).

## Anti-patterns

- Не запускай `premium` без согласия пользователя — дорого
- Не оставляй results-папки месяцами — `~/Downloads/content-gen/` чистка вручную
- Не загружай в Cloudinary без явного выбора пользователя
- Не предлагай негативные промпты — модели не очень умеют (см. prompt-engineering.md)
- **/content-mockup:** не гони на приватные/staging URL с PII (скриншот уходит в Recraft); не отключай SSRF-guard; ветку C на скруглённых экранах — предпочитай ноут телефону (чище композит).

## См. также

- [`lib/prompt-engineering.md`](lib/prompt-engineering.md) — глубокий справочник
- [`commands/content-gen.md`](../../commands/content-gen.md), `content-brief.md`, `content-stock.md`, `content-upload.md`
