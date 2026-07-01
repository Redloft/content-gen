# Prompt Engineering для content-gen

Compact справочник для Claude. Используй когда формируешь enriched prompt для каждого источника.

## Универсальная структура (works на всех моделях)

```
[scene/background] → [subject] → [key details] → [style/mood] → [composition] → [lighting] → [constraints]
```

Пример:
> _"Outdoor wellness retreat at dawn, a single ceramic cup of tea on a teakwood tray, soft steam rising, minimalist Japanese aesthetic, top-down composition, golden-hour backlighting filtering through bamboo, photorealistic"_

**Always include intended use** в финальной строке («for hero banner», «for app icon», «for social-media post 1:1») — это якорит модель в правильный визуальный язык.

---

## Per-source quirks

### Recraft v3 (`digital_illustration` / `realistic_image` / `vector_illustration` / `icon`)

- **Style через API parameter, не в промпте** — мы передаём `style` отдельным параметром в запросе. Поэтому в промпт **не пиши** «vector illustration of...» — только сам предмет и контекст.
- ✅ `"A cozy coffee shop interior with hanging plants and warm amber lighting"` + style=`realistic_image`
- ❌ `"vector illustration of cozy coffee shop, flat design"` — двойной стиль конфликтует
- Хорошо понимает **brand colors** через RGB hex в промпте: `"...palette: #1a3a5c, #d4a574, #f5e6d3"`
- Слабее в фотореализме, чем Imagen / OpenAI — играем на стиле.

### Gemini Nano Banana (gemini-2.5-flash-image)

- Любит **минимализм + iconic** запросы: «one object, clean background»
- Хорош в **iconography, app icons, simple illustrations**
- Лучше **короткие** промпты (30-80 слов), длинные размазывают
- Photorealistic не его конёк — для этого Imagen
- ✅ `"Minimalist line-art icon of a lotus flower, single color, transparent background, app icon style, 1024x1024"`

### Imagen 4

- **Лучший photorealism** в нашем стеке
- Любит **camera/lens specs**: `"shot on Hasselblad H6D, 85mm lens, f/1.4, shallow depth of field"`
- Лучше **детальные** промпты (100-250 слов)
- Не поддерживает **negative prompt** — что не хочешь, не упоминай (вместо `"no people"` пиши `"empty scene"`)
- ✅ `"Aerial photograph of pine forest at sunrise, low-hanging mist between trees, warm golden light filtering through, shot on medium-format Hasselblad, photorealistic, high dynamic range"`

### OpenAI gpt-image-1

- **Сильный в text-in-image** — если нужны слова на картинке, единственная модель которая стабильно делает читаемо
- Структура важнее длины: «фон → объект → детали → ограничения»
- Inclusion of `quality: "medium"` (наш default) vs `"high"` (×2.5 дороже) — для medium хватает обычного промпта
- ✅ `"Modern web hero illustration: a smartphone screen showing a wellness booking app with the text 'Book Your Calm' in clean sans-serif. Surrounding the phone: floating UI cards (calendar, masseuse avatar, 5-star review). Background: soft pastel gradient (#f5e6d3 to #d4a574). Style: flat 3D, Apple Vision Pro aesthetic."`

### Replicate Flux schnell

- **Быстрый, дешёвый** ($0.003), но 4-step модель — меньше деталей чем Flux dev
- Любит **длинные visual descriptions** с mood-словами
- Слабее в hands/text — избегай этого в промпте
- ✅ `"A serene Japanese tea ceremony space at golden hour, soft amber light through paper screens, low wooden table with single ceramic teapot, atmospheric haze, painterly aesthetic"`

---

## Promo для каждого tier

Когда формирую enriched prompt — могу слегка адаптировать одну базу под разные модели, или дать **одинаковый** промпт всем (так делает default content-gen).

### Когда давать одинаковый промпт

- В режиме explore — чтобы сравнить как разные модели интерпретируют одну формулировку
- Когда нужно собрать идеи / direction

### Когда адаптировать per-source

- В режиме premium — финальная генерация, выжимаем максимум из каждой модели
- Структура: один **базовый промпт** + 2-3 строки специфики per provider

---

## Brief — какие данные собирать

Если пользователь даёт короткий промпт (<5 значимых слов) — собираю дополнительный контекст через эти параметры:

| Параметр | Примеры значений |
|---|---|
| **Subject** | предмет / сцена / абстракция |
| **Style** | photo / illustration / 3D / vector / sketch / mixed |
| **Mood** | calm / energetic / cozy / luxurious / mystic / playful |
| **Palette** | brand colors (hex) / warm earth tones / pastel / mono / vivid |
| **Composition** | close-up / wide / aerial / top-down / portrait / landscape |
| **Lighting** | golden hour / overcast / studio / neon / dawn / candlelight |
| **Usage context** | hero banner / app icon / social post / pres slide / blog header |
| **Aspect ratio** | 1:1 / 16:9 / 9:16 / 4:5 |

**5-7 ответов хватает**. Не задавай больше — устаёт.

---

## Anti-patterns

| ✗ Не делать | Почему |
|---|---|
| Negative промпт «no clutter, no people, no text» | Imagen игнорирует, OpenAI частично интерпретирует — лучше явно описать что хочешь |
| 3-абзацный prompt со всем подряд | Все модели начинают «терять» детали к концу, лучше 1-3 чётких предложения |
| Mix style words: `"flat 3D photorealistic minimalist"` | Модель размазывается. Выбери один dominantный стиль |
| Указывать camera + 3D рендер одновременно | `"shot on Sony A7 with 3D Blender render"` — взаимоисключающее |
| Просить text-in-image у Flux/Recraft/Imagen | Только OpenAI и Nano Banana делают это надёжно |
| Слишком абстрактные эпитеты | `"beautiful amazing stunning"` — пустой шум. Лучше конкретика |

---

## Russian → English

Все наши модели **значительно лучше работают на английском**. Если пользователь дал промпт на русском:
1. Перевожу сам (хорошо знаю как термины звучат у нативных)
2. Сохраняю русский в `meta.json` как `prompt_original`
3. Использую английский в API-вызовах как `prompt_translated`
4. В preview.html показываю **оба** для контекста

DeepL/Google Translate использовать **не нужно** — я перевожу лучше чем сервисы (понимаю design-context).

---

## Sources

- OpenAI Cookbook: <https://developers.openai.com/cookbook/examples/multimodal/image-gen-models-prompting-guide>
- Runway Gen-4: <https://help.runwayml.com/hc/en-us/articles/35694045317139-Gen-4-Image-Prompting-Guide>
- Recraft styles: <https://www.recraft.ai/docs>
- Imagen prompt guide: <https://ai.google.dev/gemini-api/docs/imagen>
- Flux prompting: <https://blackforestlabs.ai/announcing-flux-1-tools/>
