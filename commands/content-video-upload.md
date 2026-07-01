Перезалей видео в Cloudinary (с auto-оптимизацией и derivatives): $ARGUMENTS

Используй skill `content-gen`. $ARGUMENTS — это:
- URL видео (`https://example.com/video.mp4`) — Cloudinary сам скачает (fetch upload)
- Или локальный путь к файлу

**Auto-detect**. Перед вызовом — посмотри на extension:
- `.jpg .jpeg .png .webp .heic .gif .svg .avif` → это картинка, делегируй на `/content-upload "$ARGUMENTS"`
- Иначе — продолжай:

```bash
~/.claude/skills/content-gen/lib/upload-cloudinary-video.sh "$ARGUMENTS"
```

Опционально вторым аргументом — folder:
```bash
~/.claude/skills/content-gen/lib/upload-cloudinary-video.sh "$ARGUMENTS" "samudro/banya/intro"
```

По умолчанию folder = `content-gen/videos/<YYYY-MM>`.

После загрузки покажи мне:
1. `secure_url` — оригинал
2. `auto` — `f_auto,q_auto` версия (формат и качество подбираются на лету по User-Agent)
3. `720p mp4` — H.264, до 1280×720 (универсал для всех плееров)
4. `webm` — лёгкий формат для современных браузеров
5. `poster jpg` — стоп-кадр на 1 секунде (для `<video poster="...">`)
6. `gif preview` — 3-секундная превьюха-лупа (для hover/preview)

Эти URL = всё что нужно. Cloudinary делает derivatives on-the-fly, оригинал — single source of truth.

## Зачем перезаливать видео в Cloudinary

- **Скорость**: Cloudinary CDN, multi-region
- **Адаптивность**: один URL → разные форматы/битрейты в зависимости от устройства
- **Превью**: автоматические poster + gif preview без отдельной возни с ffmpeg
- **Стабильность**: tildacdn / clients' websites могут менять URLs или удалять файлы — Cloudinary остаётся у нас

## Не делай

- Не качай файл локально если это URL — Cloudinary fetch сам справится
- Не делай больше одной перезаливки одного и того же URL без причины (Cloudinary считает usage)
