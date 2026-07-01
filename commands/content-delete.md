Удали ресурс из Cloudinary: $ARGUMENTS

Используй skill `content-gen`. $ARGUMENTS — public_id или folder prefix.

⚠️ **ДЕСТРУКТИВНАЯ операция**. По умолчанию интерактивно спрашивает «Type 'yes' to confirm». Сохраняет backup metadata в `/tmp/cloudinary-deleted-<ts>.log`.

```bash
~/.claude/skills/content-gen/lib/delete-cloudinary.sh $ARGUMENTS
```

Примеры:
```bash
# Один ресурс по public_id (попробует и image, и video)
/content-delete content-gen/videos/2026-05/altay-vert-1779969058

# Конкретный тип (быстрее, не пробует обе категории)
/content-delete content-gen/.../foo --type video

# Удалить всё с префиксом (например очистить тестовый batch)
/content-delete content-gen/batch/test- --prefix

# Без подтверждения — только если уверен на 100%
/content-delete <id> --yes
```

## Перед запуском

1. **Сначала всегда `/content-list <prefix>`** — убедись что собираешься удалить именно что нужно
2. Скрипт **показывает список** что будет удалено и просит ввести `yes`
3. Backup в `/tmp/cloudinary-deleted-<ts>.log` сохраняется ВСЕГДА (на случай если удалил по ошибке — можешь восстановить из исходников зная public_ids)

## Не делай

- НЕ передавай слишком общий префикс типа `content-gen/` — удалит вообще всё
- НЕ используй `--yes` для prefix-delete если не делал dry-run через `/content-list` минуту назад
