#!/usr/bin/env bash
# screencast-upload.sh — идемпотентный Cloudinary video upload для /content-screencast.
# Форк upload-cloudinary-video.sh (§11: сиблинга не меняем): детерминированный public_id
# + overwrite=true (resume не плодит дубли, SCREENCAST-SPEC §6.1) + JSON stdout.
#
# Usage: screencast-upload.sh <file.mp4|.gif|.png> <public_id> [folder] [url-out-file]
# stdout: {ok, public_id, bytes, format}  |  {ok:false, error}
# secure_url пишется в url-out-file (НЕ в stdout): op run маскирует значения секретов
# в stdout/stderr (live-факт 2026-07-02: CLOUDINARY_CLOUD_NAME входит в secure_url →
# '<concealed>'), а файлы маскирование не трогает. Так маскирование остаётся ВКЛЮЧЕННЫМ
# для всех секретов env-файла (finalize critical #2: --no-masking снимал бы его со всех).
set -euo pipefail

INPUT="$1"; PUBLIC_ID="$2"; FOLDER="${3:-content-gen/screencast}"; URL_OUT="${4:-}"

# Self-wrap в op run (секрет только в env дочернего процесса, маскирование активно)
if [ -z "${CLOUDINARY_API_SECRET:-}" ]; then
  LIBDIR="$(cd "$(dirname "$0")" && pwd)"
  exec op run --env-file="$LIBDIR/all-secrets.env" -- bash "$0" "$@"
fi

[ -f "$INPUT" ] || { echo '{"ok":false,"error":"file not found"}'; exit 1; }

# ресурс-тип: video для mp4/gif (Cloudinary гонит gif как video), image для png
RTYPE=video
case "$INPUT" in *.png|*.jpg|*.webp) RTYPE=image;; esac

TS=$(date +%s)
PARAMS_STR="folder=$FOLDER&overwrite=true&public_id=$PUBLIC_ID&timestamp=$TS"
SIG=$(printf '%s' "${PARAMS_STR}${CLOUDINARY_API_SECRET}" | shasum -a 1 | awk '{print $1}')

RESP=$(curl --silent --max-time 600 -X POST \
  "https://api.cloudinary.com/v1_1/$CLOUDINARY_CLOUD_NAME/$RTYPE/upload" \
  -F "file=@$INPUT" \
  -F "api_key=$CLOUDINARY_API_KEY" \
  -F "timestamp=$TS" \
  -F "folder=$FOLDER" \
  -F "public_id=$PUBLIC_ID" \
  -F "overwrite=true" \
  -F "signature=$SIG")

# secure_url → в файл (мимо op-маскирования stdout); JSON-выход без URL.
# error body обрезаем до сообщения (не светить сырые ответы — SPEC §8.2)
if [ -n "$URL_OUT" ]; then
  echo "$RESP" | jq -r '.secure_url // empty' > "$URL_OUT"
fi
echo "$RESP" | jq -c 'if .secure_url
  then {ok:true, public_id, bytes, format}
  else {ok:false, error:(.error.message // "upload failed" | .[0:200])} end'
