#!/bin/bash

# ==============================================================================
# УНИВЕРСАЛЬНЫЙ СКРИПТ С АВТОМАТИЧЕСКИМ РАЗДЕЛЕНИЕМ ФАЙЛОВ ПО ДИРЕКТОРИЯМ
# Разработано для Linux Fedora 44 (GNOME). Ссылка передается аргументом.
# ==============================================================================

# 1. ПРОВЕРКА АРГУМЕНТОВ КОМАНДНОЙ СТРОКИ
PLAYLIST_URL="$1"

if [ -z "$PLAYLIST_URL" ]; then
    echo -e "\n================================================================================"
    echo -e " ОШИБКА: Не указана ссылка на плейлист YouTube!"
    echo -e "================================================================================"
    echo -e " Пожалуйста, передайте ссылку аргументом при запуске скрипта."
    echo -e "\n Пример правильного запуска:"
    echo -e "   bash YT-DLP.sh \"https://youtube.com\""
    echo -e "================================================================================\n"
    exit 1
fi

# 2. НАСТРОЙКА КАТАЛОГОВ (Автоматическое разделение)
BROWSER="chrome"

if [ -t 1 ]; then
    COLOR_RESET='\033[0m'
    COLOR_SKIP='\033[34m'      # Синий
    COLOR_DELETED='\033[31m'   # Красный
    COLOR_RESTRICTED='\033[33m' # Жёлтый
    COLOR_DOWNLOADED='\033[32m' # Зелёный
    COLOR_STATUS='\033[36m'    # Бирюзовый
else
    COLOR_RESET=''
    COLOR_SKIP=''
    COLOR_DELETED=''
    COLOR_RESTRICTED=''
    COLOR_DOWNLOADED=''
    COLOR_STATUS=''
fi

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

echo -e "\n================================================================================"
echo -e " Начинаем синхронизацию YouTube плейлиста"
echo -e " Рабочая директория: $PWD"
echo -e " Элементы плейлиста сохраняются в: $MUSIC_DIR"
echo -e " Логи и архив сохраняются в: $SERVICE_DIR"
echo -e "================================================================================\n"

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
echo -e "\n================================================================================"
echo -e " ФОРМИРОВАНИЕ ИТОГОВОГО ОТЧЕТА СЕАНСА"
echo -e "================================================================================"

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

# Подсчет проблемных видео по типам ошибок YouTube.
# Важно: итоговое количество элементов плейлиста должно сходиться ровно:
# TOTAL_ITEMS = DOWNLOADED + DELETED + RESTRICTED + SKIPPED
DELETED_COUNT=$(grep -E 'ERROR: \[youtube\].*(Video unavailable|not made this video available in your country|blocked due to the claimed content|no longer available because|This video is not available|This video is no longer available|This video is not available in your country)' "$LOG_FILE" 2>/dev/null | wc -l | tr -d ' ')
RESTRICTED_COUNT=$(grep -E "ERROR: \[youtube\].*(Private video|Sign in if you've been granted access)" "$LOG_FILE" 2>/dev/null | wc -l | tr -d ' ')

# Получаем общее количество видео в плейлисте
TOTAL_ITEMS=$(grep -oE "Downloading [0-9]+ items" "$LOG_FILE" | head -n 1 | awk '{print $2}')

if [ -z "$TOTAL_ITEMS" ]; then
    TOTAL_ITEMS=$((BEFORE_COUNT + REAL_NEW_COUNT + DELETED_COUNT + RESTRICTED_COUNT))
    SKIPPED_COUNT=$BEFORE_COUNT
else
    SKIPPED_COUNT=$((TOTAL_ITEMS - REAL_NEW_COUNT - DELETED_COUNT - RESTRICTED_COUNT))
    if [ "$SKIPPED_COUNT" -lt 0 ]; then SKIPPED_COUNT=0; fi
fi

# Выводим обновленный отчет по вашим требованиям
echo -e "${COLOR_SKIP} Количество пропущенных элементов плейлиста: $SKIPPED_COUNT${COLOR_RESET}"
echo -e "--------------------------------------------------------------------------------"
echo -e "${COLOR_DELETED} Количество удаленных и скрытых элементов плейлиста: $DELETED_COUNT${COLOR_RESET}"
echo -e "--------------------------------------------------------------------------------"
echo -e "${COLOR_RESTRICTED} Количество элементов плейлиста с ограниченным доступом: $RESTRICTED_COUNT${COLOR_RESET}"
echo -e "--------------------------------------------------------------------------------"
echo -e "${COLOR_DOWNLOADED} Всего элементов плейлиста скачано за текущий сеанс: $REAL_NEW_COUNT${COLOR_RESET}"
echo -e "--------------------------------------------------------------------------------"

if [ "$REAL_NEW_COUNT" -gt 0 ] && [ -s .downloaded_names.tmp ]; then
    echo -e " Скачанные элементы плейлиста за текущий сеанс:"
    cat -n .downloaded_names.tmp
else
    if [ "$REAL_NEW_COUNT" -gt 0 ]; then
        echo -e "${COLOR_STATUS} [!] Успешно добавлено новых треков: $REAL_NEW_COUNT${COLOR_RESET}"
    else
        echo -e "${COLOR_STATUS} (Новых файлов добавлено не было, ваш плейлист полностью синхронизирован)${COLOR_RESET}"
    fi
fi

echo -e "--------------------------------------------------------------------------------"

# Добавляем список проблемных элементов с названием файла и ID
PROBLEMATIC_LIST_FILE=".problematic_entries.tmp"
: > "$PROBLEMATIC_LIST_FILE"

awk '
BEGIN { current_title = "" }
{
    if ($0 ~ />>> \[СКАЧИВАНИЕ\]/) {
        current_title = substr($0, index($0, ">>> [СКАЧИВАНИЕ] ") + length(">>> [СКАЧИВАНИЕ] "))
        next
    }

    if ($0 ~ /^ERROR: \[youtube\]/) {
        if (match($0, /^ERROR: \[youtube\] ([^:]+):/, m)) {
            id = m[1]
            if (current_title == "") {
                current_title = "Неизвестно"
            }
            print current_title "\t" id "\t" $0
            current_title = ""
        }
    }
}
' "$LOG_FILE" > "$PROBLEMATIC_LIST_FILE"

if [ -s "$PROBLEMATIC_LIST_FILE" ]; then
    echo -e " Проблемные элементы плейлиста:"

    DELETED_PROBLEMS=$(grep -vE "Private video|Sign in if you've been granted access" "$PROBLEMATIC_LIST_FILE" | sed '/^$/d' | wc -l | tr -d ' ')
    RESTRICTED_PROBLEMS=$(grep -E "Private video|Sign in if you've been granted access" "$PROBLEMATIC_LIST_FILE" | sed '/^$/d' | wc -l | tr -d ' ')

    if [ "$DELETED_PROBLEMS" -gt 0 ]; then
        echo -e " [Удаленные и скрытые]"
        grep -vE "Private video|Sign in if you've been granted access" "$PROBLEMATIC_LIST_FILE" | awk -F'\t' '{print "  " NR ". " $1 " | ID: " $2}'
    fi

    if [ "$RESTRICTED_PROBLEMS" -gt 0 ]; then
        echo -e " [С ограниченным доступом]"
        grep -E "Private video|Sign in if you've been granted access" "$PROBLEMATIC_LIST_FILE" | awk -F'\t' '{print "  " NR ". " $1 " | ID: " $2}'
    fi

    echo -e "--------------------------------------------------------------------------------"
fi

# Удаляем временный скрытый файл
rm -f .downloaded_names.tmp "$PROBLEMATIC_LIST_FILE"

echo -e "================================================================================"
echo -e " Синхронизация полностью завершена!"
echo -e "================================================================================\n"
