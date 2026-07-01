Найди готовые stock-фото по запросу: $ARGUMENTS

Используй skill `content-gen`. Запускает параллельно Unsplash + Pexels + Pixabay (3 фото из каждого = 9 в grid).

```bash
~/.claude/skills/content-gen/run-stock.sh "$ARGUMENTS"
```

Опционально:
- `--pixabay-type illustration` — если нужны иллюстрации/вектора (Pixabay умеет, Unsplash/Pexels — фотки)
- `--sources pexels,pixabay` — конкретный набор

После prevenu.html в браузере — я выбираю любимый, ты возьмёшь путь и можешь `/content-upload <path>` для загрузки в Cloudinary с оптимизацией.

Если результаты слабые / не подходят — предложи `/content-gen "<тот же или переформулированный prompt>"` для AI-генерации, она даст уникальные варианты которых нет на стоках.
