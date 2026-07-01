Загрузи выбранную картинку в Cloudinary с auto-оптимизацией: $ARGUMENTS

Используй skill `content-gen`. Путь к файлу — $ARGUMENTS (обычно копируется из preview.html по кнопке «copy path»).

**ВАЖНО: auto-detect**. Перед вызовом — посмотри на extension файла:
- `.mp4 .mov .webm .mkv .avi .m4v` → это видео, делегируй на `/content-video-upload "$ARGUMENTS"` (или напрямую `lib/upload-cloudinary-video.sh`)
- Иначе — это картинка, продолжаем:

```bash
~/.claude/skills/content-gen/lib/upload-cloudinary.sh "$ARGUMENTS"
```

Опционально вторым аргументом — folder (если хочешь сгруппировать под проект):
```bash
~/.claude/skills/content-gen/lib/upload-cloudinary.sh "$ARGUMENTS" "wellbookin/hero"
```

По умолчанию folder = `content-gen/<YYYY-MM>` (текущий месяц).

После загрузки покажи мне:
1. `secure_url` — основная HTTPS-ссылка
2. `webp` — авто-WebP версия (для современных браузеров)
3. `thumb` — 400px thumbnail (для preview/og:image)

Эти 3 URL — это всё что нужно вставить в проект. Cloudinary сам делает on-the-fly трансформации, original остаётся single source of truth.
