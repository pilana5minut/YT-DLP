#!/bin/bash

# ==============================================================================
# УНИВЕРСАЛЬНЫЙ СКРИПТ С АВТОМАТИЧЕСКИМ РАЗДЕЛЕНИЕМ ФАЙЛОВ ПО ДИРЕКТОРИЯМ
# Разработано для Linux Fedora 44 (GNOME). Ссылка передается аргументом.
# ==============================================================================

# 1. ПРОВЕРКА АРГУМЕНТОВ КОМАНДНОЙ СТРОКИ
PLAYLIST_URL="$1"

if [ -z "$PLAYLIST_URL" ]; then
    echo -e "\n========================================================"
    echo -e " ОШИБКА: Не указана ссылка на плейлист YouTube!"
    echo -e "========================================================"
    echo -e " Пожалуйста, передайте ссылку аргументом при запуске скрипта."
    echo -e "\n Пример правильного запуска:"
    echo -e "   bash YT-DLP.sh \"https://youtube.com\""
    echo -e "========================================================\n"
    exit 1
fi

# 2. НАСТРОЙКА КАТАЛОГОВ (Автоматическое разделение)
BROWSER="chrome"

# Имена новых целевых директорий
MUSIC_DIR="$PWD/Music_Files"
SERVICE_DIR="$PWD/Service_Files"

# Создаем их, если они еще не существуют
mkdir -p "$MUSIC_DIR"
mkdir -p "$SERVICE_DIR"

# Переносим пути служебных файлов в отдельную папку
LOG_FILE="$SERVICE_DIR/sync_log.txt"
ARCHIVE_FILE="$SERVICE_DIR/downloaded_songs.txt"

# Создаем файл архива внутри новой папки, если его нет
touch "$ARCHIVE_FILE"

# Фиксируем, сколько треков было скачано ДО этого сеанса
BEFORE_COUNT=$(wc -l < "$ARCHIVE_FILE")

# Очищаем технический лог перед началом работы
> "$LOG_FILE"

echo -e "\n========================================================"
echo -e " Начинаем синхронизацию YouTube плейлиста"
echo -e " Рабочая директория: $PWD"
echo -e " Элементы плейлиста сохраняются в: $MUSIC_DIR"
echo -e " Логи и архив сохраняются в: $SERVICE_DIR"
echo -e "========================================================\n"

# 3. ЗАПУСК YT-DLP
yt-dlp \
  --extract-audio \
  --audio-format mp3 \
  --audio-quality 0 \
  --yes-playlist \
  --download-archive "$ARCHIVE_FILE" \
  --cookies-from-browser "$BROWSER" \
  --restrict-filenames \
  --js-runtimes node \
  --remote-components ejs:github \
  --socket-timeout 60 \
  --retries 10 \
  --file-access-retries 5 \
  --fragment-retries 10 \
  --extractor-args "youtubetab:skip=authcheck" \
  --http-chunk-size 10M \
  --paths "$MUSIC_DIR" \
  --output "%(title)s [%(id)s].%(ext)s" \
  --ignore-errors \
  --console-title \
  --progress \
  --print "before_dl:>>> [СКАЧИВАНИЕ] %(title)s" \
  --print "after_move:>>> [ГОТОВО] %(title)s" \
  "$PLAYLIST_URL" 2>&1 | tee "$LOG_FILE"

# 4. АНАЛИЗ И МАТЕМАТИЧЕСКИЙ РАСЧЕТ ОТЧЕТА
echo -e "\n========================================================"
echo -e " ФОРМИРОВАНИЕ ИТОГОВОГО ОТЧЕТА СЕАНСА"
echo -e "========================================================"

# Извлекаем чистые названия скачанных треков из лога
grep ">>> \[ГОТОВО\]" "$LOG_FILE" | sed "s/.*>>> \[ГОТОВО\] //" | sed -e 's/[[:space:]]*$//' > .downloaded_names.tmp

DOWNLOADED_COUNT=$(wc -l < .downloaded_names.tmp)

# Сверяемся по изменению физического файла архива
AFTER_COUNT=$(wc -l < "$ARCHIVE_FILE")
NEW_ARCHIVE_COUNT=$((AFTER_COUNT - BEFORE_COUNT))

if [ "$NEW_ARCHIVE_COUNT" -gt "$DOWNLOADED_COUNT" ]; then
    REAL_NEW_COUNT=$NEW_ARCHIVE_COUNT
else
    REAL_NEW_COUNT=$DOWNLOADED_COUNT
fi

# Получаем общее количество видео в плейлисте
TOTAL_ITEMS=$(grep -oE "Downloading [0-9]+ items" "$LOG_FILE" | head -n 1 | awk '{print $2}')

if [ -z "$TOTAL_ITEMS" ]; then
    SKIPPED_COUNT=$BEFORE_COUNT
else
    SKIPPED_COUNT=$((TOTAL_ITEMS - REAL_NEW_COUNT))
    if [ "$SKIPPED_COUNT" -lt 0 ]; then SKIPPED_COUNT=0; fi
fi

# Выводим обновленный отчет по вашим требованиям
echo -e " Количество пропущенных элементов плейлиста: $SKIPPED_COUNT"
echo -e "--------------------------------------------------------"
echo -e " Скачанные элементы плейлиста за текущий сеанс: $REAL_NEW_COUNT"
echo -e "--------------------------------------------------------"

if [ "$REAL_NEW_COUNT" -gt 0 ] && [ -s .downloaded_names.tmp ]; then
    cat -n .downloaded_names.tmp
else
    if [ "$REAL_NEW_COUNT" -gt 0 ]; then
        echo " [!] Успешно добавлено новых треков: $REAL_NEW_COUNT"
    else
        echo " (Новых файлов добавлено не было, ваш плейлист полностью синхронизирован)"
    fi
fi

# Удаляем временный скрытый файл
rm -f .downloaded_names.tmp

echo -e "========================================================"
echo -e " Синхронизация полностью завершена!"
echo -e "========================================================\n"

