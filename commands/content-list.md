Покажи что залито в Cloudinary: $ARGUMENTS

Используй skill `content-gen`. $ARGUMENTS — опциональный prefix (folder в Cloudinary).

```bash
~/.claude/skills/content-gen/lib/list-cloudinary.sh $ARGUMENTS
```

Примеры:
```bash
/content-list                              # последние 50 (image + video)
/content-list content-gen/                 # всё в content-gen folder
/content-list content-gen/videos --type video
/content-list "" --max 200                 # больше результатов
```

Вывод — таблица в терминале:
- `T` (image / video)
- `public_id`
- `format`, `size`, `dims`, `created_at`

Внизу — totals по числу и MB.

После — обычно делают:
- Хотят перезалить → `/content-upload` или `/content-upload-folder`
- Хотят удалить ненужное → `/content-delete <public_id-or-prefix>`
