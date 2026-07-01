Batch-загрузка целой папки картинок и видео в Cloudinary: $ARGUMENTS

Используй skill `content-gen`. $ARGUMENTS — путь к папке (можно с пробелами).

```bash
~/.claude/skills/content-gen/lib/upload-cloudinary-batch.sh "$ARGUMENTS"
```

Опции:
- **2-й аргумент** — folder в Cloudinary (по умолчанию `content-gen/batch/<basename>-<date>`):
  ```bash
  ~/.claude/skills/content-gen/lib/upload-cloudinary-batch.sh "$ARGUMENTS" "samudro/banya"
  ```
- **`--recursive`** — обходить подпапки (sub-folders передаются в Cloudinary как nested):
  ```bash
  ~/.claude/skills/content-gen/lib/upload-cloudinary-batch.sh "$ARGUMENTS" --recursive
  ```

## Что делает

1. Сканирует папку, фильтрует image/video extensions (jpg, png, webp, heic, gif, svg, avif, tiff, bmp, mp4, mov, webm, mkv, avi, m4v, mpg)
2. По типу — делегирует на `upload-cloudinary.sh` (image) или `upload-cloudinary-video.sh` (video)
3. Транслит кириллицы в public_id (`банно-1234.jpg` → `banno-<ts>.jpg`)
4. Один Touch ID на весь batch (op run обёрнут на уровне batch-скрипта)
5. Открывает HTML preview с превью каждого файла + кнопками на полные ссылки

## Анти-паттерны

- НЕ делать `--recursive` на корне `~/Downloads` или `~/Pictures` — там слишком много мусора, израсходуешь Cloudinary credits
- НЕ перезаливать одну и ту же папку дважды — Cloudinary считает usage; используй уже залитую папку через `/content-find` или 1Password item с base URL

## После загрузки

В терминале — компактная таблица «✅ name → URL». В браузере — HTML grid с превью каждого. Plain log в `/tmp/cloudinary-batch-<ts>.log` (формат `path|type|url` через `|`).
