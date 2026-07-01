Делаем визуал с подробным брифом. Идея: $ARGUMENTS

Используй skill `content-gen`, режим smart-brief:

1. **Прочитай справочник** `~/.claude/skills/content-gen/lib/prompt-engineering.md` — узнаешь правила формирования промптов.

2. **Контекст проекта** (если есть):
   - (Опционально) если ведёшь базу проектов и $ARGUMENTS упоминает проект — прочитай его карточку
   - Достань оттуда: brand colors, style guidelines, domain_primary, audience tone
   - Используй эти данные как defaults в брифе (не спрашивай заново)

3. **Бриф через AskUserQuestion** (3-5 вопросов, не больше):

   Выбери самые релевантные параметры из списка (смотря что не очевидно из контекста):
   - **Subject** — что главное на картинке (если из идеи не ясно)
   - **Style** — photo / illustration / 3D / vector / sketch / mixed
   - **Mood** — calm / energetic / cozy / luxurious / mystic / playful
   - **Palette** — brand / warm earth / pastel / mono / vivid (если не из проекта)
   - **Composition** — close-up / wide / aerial / top-down / portrait
   - **Lighting** — golden hour / overcast / studio / neon / dawn
   - **Usage** — hero / icon / social / slide / blog header
   - **Aspect ratio** — 1:1 / 16:9 / 9:16 / 4:5 (если не очевидно из usage)

4. **Собери enriched prompt** на ENGLISH по структуре:
   ```
   [scene/background] → [subject] → [key details] → [style] → [composition] → [lighting] → [usage context]
   ```

5. **Покажи финальный prompt** пользователю + предложенный tier:
   - Для иконок / простых иллюстраций → `--tier explore`
   - Для лендингов / контента → `--tier mid` (default)
   - Для финальной production-картинки → `--tier premium`

   Спроси: «вот такой prompt, запускаем на tier X? или поправить?»

6. **После подтверждения** — запусти:
   ```bash
   ~/.claude/skills/content-gen/run.sh "<enriched prompt>" --tier <tier>
   ```

7. **После генерации** — открываются preview.html в браузере, дальше пользователь выбирает любимый, можно `/content-upload <path>` загрузить в Cloudinary.

## Если контекст слишком мало даже для брифа

Если $ARGUMENTS совсем пустой или 1-2 слова без направления — задай **сначала open-ended вопрос**: «расскажи в 1-2 предложениях для чего тебе картинка и какой настрой?» — потом уже структурный бриф.
