Сделай красивые мокапы сайта/приложения из URL: $ARGUMENTS

Используй skill `content-gen`, секцию **/content-mockup**. Общайся по-русски.

## Что это
Из URL → пачка мокапов: рамки устройств (браузер/iPhone/iPad/MacBook) + устройство в тематическом контексте (ноут в бане, телефон в руке в spa). Скриншот вставляется детерминированно (green-composite) — экран пиксель-в-пиксель. desktop **и** mobile.

## Поток (веду я, механику делает `run-mockup.sh`)

Рабочая папка: `~/Downloads/content-mockup/<host>-<ts>/` (передавай как `--out`).

0. **Preflight:** если нет chromium — сказать пользователю `cd ~/.claude/skills/content-gen && npx playwright install chromium`.
   **PII-чек:** если URL выглядит приватным/staging — предупредить, что скриншот уйдёт в Recraft.

1. **Назначение (объём):**
   - есть `--for-page <repo|url>` → слоты из `capture` (репо: `slots-from-page.mjs`; url: `--measure-slots`).
   - слотов 0 / `fallback:true` ИЛИ нет `--for-page` → спросить через **AskUserQuestion**: презентация 16:9 / соцсети 4:5+9:16 / произвольно (N картинок) → пресет → `slots.json`.

2. **Capture:** `bash ~/.claude/skills/content-gen/run-mockup.sh capture --url "<url>" --out "<dir>" [--for-page …]`
   → скриншоты + бренд (имя/лого/палитра/вайб) в `state.json`.

3. **Контексты ветки C:** из вайба бренда придумай 4–8 сцен → `<dir>/contexts.json`:
   `[{context:"<англ. сцена>", device:"laptop|phone|tablet", label:"<рус>", size:"1365x1024"}]`.
   Креативь по нише (баня→парная с вениками; кофейня→чашка; фитнес→зал; SaaS→стол/рабочее место).

4. **Explore (тиндер):** оцени стоимость (кол-во сцен ×$0.04), **подтверди у пользователя** если >2–3 сцен.
   `run-mockup.sh explore --out "<dir>" --contexts "<dir>/contexts.json" --devices browser,iphone --tier mid`
   → открой деку: `open <deck.html>`. Пользователь листает 👍/👎/оценка/коммент.
   Дождись `round-1.answers.json` (feedback-server пишет его; можно опросить файл).
   `--skip-deck` — если направление уже ясно, тиндер пропустить.

5. **Синтез направления:** из ответов (что лайкнули) собери `<dir>/art.json`:
   `{mode:"frame|scene", device:"browser|iphone|…", bg:"#c1,#c2", context:"<если scene>", scene_device:"laptop"}`.

6. **Produce (объём):** `run-mockup.sh produce --out "<dir>" --art "<dir>/art.json" --slots "<dir>/slots.json"`
   → мокапы под каждый слот desktop+mobile → `final/preview.html` откроется.

7. **Финал:** покажи grid. Спроси: перегенерить в другом направлении? Залить в Cloudinary (`/content-upload`)?

## Тиры
`explore` — только рамки (офлайн, бесплатно) · `mid` (деф) — +Recraft-сцены (~$0.04/шт) · `premium` — крупнее/больше.
**Не жги Recraft без подтверждения стоимости.**

## Важно
- SSRF-guard и узкий `op run` (секрет только вокруг сцен) — не трогать.
- Ветка C: плоские экраны (ноут) чище скруглённых (телефон).
- Прерванный прогон → `state.json` хранит фазу, можно продолжить с нужного шага.
