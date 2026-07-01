Трассируй растр в SVG и/или сожми/конвертируй: $ARGUMENTS

Используй skill `content-gen`, движок — `lib/imgforge.sh`. Входной путь и флаги — в $ARGUMENTS.

**Авто-выбор режима** по тому, что просит пользователь:
- «в SVG», «векторизуй», «трассируй», «отрисуй вектор», логотип/иконка → режим трассировки
- «сожми», «оптимизируй», «в webp/avif», «уменьши вес» → режим компрессии

## Трассировка → SVG

```bash
~/.claude/skills/content-gen/lib/imgforge.sh "<input>" --svg       # полный цвет (vtracer)
~/.claude/skills/content-gen/lib/imgforge.sh "<input>" --poster    # плоский постер, мало цветов
~/.claude/skills/content-gen/lib/imgforge.sh "<input>" --photo     # фотографичный, градиенты
~/.claude/skills/content-gen/lib/imgforge.sh "<input>" --bw        # ч/б (vtracer preset bw)
~/.claude/skills/content-gen/lib/imgforge.sh "<input>" --potrace   # ч/б ultra-clean кривые (mkbitmap+potrace)
```

Выбор движка по картинке:
- **Логотип / иконка / line-art / силуэт** → `--potrace` (самые гладкие кривые) или `--bw`
- **Цветной логотип / плоская иллюстрация** → `--svg` или `--poster`
- **Фото / сложные градиенты** → `--photo` (но честно предупреди: SVG из фото бывает тяжёлым; часто лучше `--to webp`)

Все SVG прогоняются через `svgo --multipass` автоматически (отключить — `--no-svgo`).

## Компрессия / конвертация растра

```bash
~/.claude/skills/content-gen/lib/imgforge.sh "<input>" --to webp --max 1600 --q 82
~/.claude/skills/content-gen/lib/imgforge.sh "<input>" --to avif --max 2000
~/.claude/skills/content-gen/lib/imgforge.sh "<input>" --to png  --max 1200   # +pngquant +oxipng
~/.claude/skills/content-gen/lib/imgforge.sh "<input>" --to jpeg --q 80
```

- `--to` — webp (default) | avif | png | jpeg
- `--max <px>` — длинная сторона, только уменьшение (не апскейлит)
- `--q <1-100>` — качество (по умолчанию 80; для png игнорится — там lossless pngquant+oxipng)

## Общие флаги
- `--out <path>` — явный путь результата (иначе `~/Downloads/imgforge/<stem>.<ext>`)
- `--upload` — сразу залить результат в Cloudinary (через `upload-cloudinary.sh`)

После запуска покажи пользователю путь к результату и экономию веса (скрипт печатает `было → стало`). Если делал SVG из фото и он вышел тяжелее оригинала — предложи компрессию вместо трассировки.
