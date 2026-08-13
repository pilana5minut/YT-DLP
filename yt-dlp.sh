#!/bin/bash

# ==============================================================================
# УНИВЕРСАЛЬНЫЙ СКРИПТ С АВТОМАТИЧЕСКИМ РАЗДЕЛЕНИЕМ ФАЙЛОВ ПО ДИРЕКТОРИЯМ
# Разработано для Linux Fedora 44 (GNOME). Ссылка передается аргументом.
# ==============================================================================

set -o pipefail

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

get_playlist_name() {
    local playlist_name

    playlist_name=$(yt-dlp \
        --flat-playlist \
        --playlist-items 1 \
        --print '%(playlist_title)s' \
        --skip-download \
        --cookies-from-browser "$BROWSER" \
        --js-runtimes node \
        --remote-components ejs:github \
        --socket-timeout 60 \
        "$PLAYLIST_URL" 2>/dev/null | sed -n '1p')

    if [ -z "$playlist_name" ]; then
        playlist_name=$(yt-dlp \
            --flat-playlist \
            --playlist-items 1 \
            --print '%(playlist_title)s' \
            --skip-download \
            --js-runtimes node \
            --remote-components ejs:github \
            --socket-timeout 60 \
            "$PLAYLIST_URL" 2>/dev/null | sed -n '1p')
    fi

    printf '%s\n' "$playlist_name"
}

PLAYLIST_NAME=$(get_playlist_name)
PLAYLIST_NAME=${PLAYLIST_NAME:-Название плейлиста не определено}

if [ -t 1 ]; then
    COLOR_RESET='\033[0m'
    COLOR_SKIP='\033[34m'      # Синий
    COLOR_DELETED='\033[31m'   # Красный
    COLOR_RESTRICTED='\033[33m' # Жёлтый
    COLOR_DOWNLOADED='\033[32m' # Зелёный
    COLOR_STATUS='\033[36m'    # Бирюзовый
    COLOR_REPORT_INTERMEDIATE='\033[38;2;37;230;230m' # #25e6e6
    COLOR_REPORT_FINAL='\033[38;2;196;59;196m'       # #c43bc4
else
    COLOR_RESET=''
    COLOR_SKIP=''
    COLOR_DELETED=''
    COLOR_RESTRICTED=''
    COLOR_DOWNLOADED=''
    COLOR_STATUS=''
    COLOR_REPORT_INTERMEDIATE=''
    COLOR_REPORT_FINAL=''
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
echo -e "${COLOR_SKIP} Начало синхронизации плейлиста: $PLAYLIST_NAME${COLOR_RESET}"
echo -e " Рабочая директория: $PWD"
echo -e " Элементы плейлиста сохраняются в: $MUSIC_DIR"
echo -e " Логи и архив сохраняются в: $SERVICE_DIR"
echo -e "================================================================================\n"

print_intermediate_report() {
    local log_file="$1"
    local archive_file="$2"
    local before_count="$3"
    local report_name="${4:-ПРОМЕЖУТОЧНЫЙ ОТЧЕТ СИНХРОНИЗАЦИИ ПЛЕЙЛИСТА: $PLAYLIST_NAME}"
    local progress_tmp=".progress_summary.tmp"

    grep ">>> \[ГОТОВО\]" "$log_file" 2>/dev/null | sed "s/.*>>> \[ГОТОВО\] //" | sed -e 's/[[:space:]]*$//' > "$progress_tmp"

    local downloaded_count=$(wc -l < "$progress_tmp" | tr -d ' ')
    local after_count=$(wc -l < "$archive_file" 2>/dev/null | tr -d ' ')
    local new_archive_count=$((after_count - before_count))
    if [ "$new_archive_count" -gt "$downloaded_count" ]; then
        local real_new_count=$new_archive_count
    else
        local real_new_count=$downloaded_count
    fi

    local deleted_count=$(grep -E 'ERROR: \[youtube\].*(Video unavailable|not made this video available in your country|blocked due to the claimed content|no longer available because|This video is not available|This video is no longer available|This video is not available in your country)' "$log_file" 2>/dev/null | wc -l | tr -d ' ')
    local restricted_count=$(grep -E "ERROR: \[youtube\].*(Private video|Sign in if you've been granted access)" "$log_file" 2>/dev/null | wc -l | tr -d ' ')
    local total_items=$(grep -oE "Downloading [0-9]+ items" "$log_file" | tail -n 1 | awk '{print $2}')

    local skipped_count=0
    if [ -z "$total_items" ]; then
        total_items=$((before_count + real_new_count + deleted_count + restricted_count))
        skipped_count=$before_count
    else
        skipped_count=$((total_items - real_new_count - deleted_count - restricted_count))
        if [ "$skipped_count" -lt 0 ]; then skipped_count=0; fi
    fi

    echo -e "\n================================================================================"
    echo -e "${COLOR_REPORT_INTERMEDIATE} $report_name${COLOR_RESET}"
    echo -e "================================================================================"
    echo -e "${COLOR_SKIP} Количество пропущенных элементов плейлиста: $skipped_count${COLOR_RESET}"
    echo -e "--------------------------------------------------------------------------------"
    echo -e "${COLOR_DELETED} Количество удаленных и скрытых элементов плейлиста: $deleted_count${COLOR_RESET}"
    echo -e "--------------------------------------------------------------------------------"
    echo -e "${COLOR_RESTRICTED} Количество элементов плейлиста с ограниченным доступом: $restricted_count${COLOR_RESET}"
    echo -e "--------------------------------------------------------------------------------"
    echo -e "${COLOR_DOWNLOADED} Всего элементов плейлиста скачано за текущий сеанс: $real_new_count${COLOR_RESET}"
    echo -e "--------------------------------------------------------------------------------"

    rm -f "$progress_tmp"
}

monitor_download_progress() {
    local last_reported=0

    while kill -0 "$YT_PID" 2>/dev/null; do
        local current_downloaded
        current_downloaded=$(grep -c ">>> \[ГОТОВО\]" "$LOG_FILE" 2>/dev/null || true)
        current_downloaded=${current_downloaded//[[:space:]]/}
        current_downloaded=${current_downloaded:-0}

        if [ "$current_downloaded" -ge $((last_reported + 10)) ]; then
            last_reported=$((current_downloaded / 10 * 10))
            print_intermediate_report "$LOG_FILE" "$ARCHIVE_FILE" "$BEFORE_COUNT" "ПРОМЕЖУТОЧНЫЙ ОТЧЕТ СИНХРОНИЗАЦИИ ПЛЕЙЛИСТА: $PLAYLIST_NAME"
        fi

        sleep 2
    done

    local final_downloaded
    final_downloaded=$(grep -c ">>> \[ГОТОВО\]" "$LOG_FILE" 2>/dev/null || true)
    final_downloaded=${final_downloaded//[[:space:]]/}
    final_downloaded=${final_downloaded:-0}

    if [ "$final_downloaded" -gt "$last_reported" ] && [ $((final_downloaded % 10)) -ne 0 ]; then
        print_intermediate_report "$LOG_FILE" "$ARCHIVE_FILE" "$BEFORE_COUNT" "ПРОМЕЖУТОЧНЫЙ ОТЧЕТ СИНХРОНИЗАЦИИ ПЛЕЙЛИСТА: $PLAYLIST_NAME"
    fi
}

cleanup_and_exit() {
    local signal_name="${1:-INT}"

    echo -e "\n================================================================================"
    echo -e "${COLOR_DELETED} Прерывание работы по Ctrl+C. Синхронизация плейлиста: $PLAYLIST_NAME была остановлена.${COLOR_RESET}"
    echo -e "================================================================================\n"

    if [ -n "${YT_PID:-}" ] && kill -0 "$YT_PID" 2>/dev/null; then
        kill -INT "$YT_PID" 2>/dev/null || kill -TERM "$YT_PID" 2>/dev/null || true
    fi

    if [ -n "${TAIL_PID:-}" ] && kill -0 "$TAIL_PID" 2>/dev/null; then
        kill "$TAIL_PID" 2>/dev/null || true
    fi

    if [ -n "${MONITOR_PID:-}" ] && kill -0 "$MONITOR_PID" 2>/dev/null; then
        kill "$MONITOR_PID" 2>/dev/null || true
    fi

    exit 130
}

trap 'cleanup_and_exit INT' INT
trap 'cleanup_and_exit TERM' TERM

# 3. ЗАПУСК YT-DLP
# Надёжный вариант: обёртка на Python, которая показывает live-вывод,
# считает готовые треки, печатает промежуточный отчёт каждые 10 и
# корректно обрабатывает Ctrl+C без докачивания полного плейлиста.

python3 - "$PLAYLIST_URL" "$LOG_FILE" "$ARCHIVE_FILE" "$BEFORE_COUNT" "$MUSIC_DIR" "$BROWSER" "$PLAYLIST_NAME" <<'PY'
import os, sys, subprocess, signal, re

playlist_url, log_file, archive_file, before_count_str, music_dir, browser, playlist_name = sys.argv[1:8]
before_count = int(before_count_str)


def report_stats(log_path, archive_path, before_total):
    names = []
    if os.path.exists(log_path):
        with open(log_path, 'r', encoding='utf-8', errors='replace') as f:
            for line in f:
                if '>>> [ГОТОВО]' in line:
                    names.append(line.split('>>> [ГОТОВО] ', 1)[1].strip())

    downloaded_count = len(names)
    if os.path.exists(archive_path):
        with open(archive_path, 'r', encoding='utf-8', errors='replace') as f:
            after_count = sum(1 for line in f if line.strip())
    else:
        after_count = 0

    real_new_count = max(after_count - before_total, downloaded_count)

    deleted_count = 0
    restricted_count = 0
    if os.path.exists(log_path):
        with open(log_path, 'r', encoding='utf-8', errors='replace') as f:
            for line in f:
                if 'ERROR: [youtube]' in line:
                    if re.search(r'(Video unavailable|not made this video available in your country|blocked due to the claimed content|no longer available because|This video is not available|This video is no longer available|This video is not available in your country)', line):
                        deleted_count += 1
                    if re.search(r'(Private video|Sign in if you\'ve been granted access)', line):
                        restricted_count += 1

    total_items = 0
    if os.path.exists(log_path):
        with open(log_path, 'r', encoding='utf-8', errors='replace') as f:
            for line in f:
                m = re.search(r'Downloading\s+(\d+)\s+items', line)
                if m:
                    total_items = int(m.group(1))

    if total_items:
        skipped_count = max(total_items - real_new_count - deleted_count - restricted_count, 0)
    else:
        skipped_count = before_total

    print('\n' + '=' * 80)
    report_color = '\033[38;2;37;230;230m' if sys.stdout.isatty() else ''
    reset_color = '\033[0m' if sys.stdout.isatty() else ''
    print(f'{report_color} ПРОМЕЖУТОЧНЫЙ ОТЧЕТ СИНХРОНИЗАЦИИ ПЛЕЙЛИСТА: {playlist_name}{reset_color}')
    print('=' * 80)
    print(f' Количество пропущенных элементов плейлиста: {skipped_count}')
    print('-' * 80)
    print(f' Количество удаленных и скрытых элементов плейлиста: {deleted_count}')
    print('-' * 80)
    print(f' Количество элементов плейлиста с ограниченным доступом: {restricted_count}')
    print('-' * 80)
    print(f' Всего элементов плейлиста скачано за текущий сеанс: {real_new_count}')
    print('-' * 80)
    print('')


cmd = [
    'yt-dlp',
    '--extract-audio',
    '--audio-format', 'mp3',
    '--audio-quality', '0',
    '--yes-playlist',
    '--download-archive', archive_file,
    '--cookies-from-browser', browser,
    '--restrict-filenames',
    '--js-runtimes', 'node',
    '--remote-components', 'ejs:github',
    '--socket-timeout', '60',
    '--retries', '10',
    '--file-access-retries', '5',
    '--fragment-retries', '10',
    '--extractor-args', 'youtubetab:skip=authcheck',
    '--http-chunk-size', '10M',
    '--paths', music_dir,
    '--output', '%(title)s [%(id)s].%(ext)s',
    '--ignore-errors',
    '--console-title',
    '--progress',
    '--print', 'before_dl:>>> [СКАЧИВАНИЕ] %(title)s',
    '--print', 'after_move:>>> [ГОТОВО] %(title)s',
    playlist_url,
]

log_handle = open(log_file, 'wb', buffering=0)
proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=1)

last_reported = 0
finished_count = 0


def stop_child(signum, frame):
    try:
        proc.send_signal(signal.SIGINT)
    except ProcessLookupError:
        pass
    raise SystemExit(130)


signal.signal(signal.SIGINT, stop_child)
signal.signal(signal.SIGTERM, stop_child)

try:
    while True:
        chunk = proc.stdout.readline()
        if not chunk:
            break
        text = chunk.decode('utf-8', errors='replace')
        sys.stdout.write(text)
        sys.stdout.flush()
        log_handle.write(chunk)
        log_handle.flush()

        if '>>> [ГОТОВО]' in text:
            finished_count += 1
            if finished_count >= last_reported + 10:
                last_reported = (finished_count // 10) * 10
                report_stats(log_file, archive_file, before_count)

    rc = proc.wait()
    if rc != 0 and rc != 130:
        raise SystemExit(rc)
    if rc == 130:
        raise SystemExit(130)
except SystemExit:
    raise
except KeyboardInterrupt:
    stop_child(signal.SIGINT, None)
finally:
    try:
        log_handle.close()
    except Exception:
        pass

PY
YT_EXIT=$?

if [ "$YT_EXIT" -eq 130 ]; then
    echo -e "\n================================================================================"
    echo -e "${COLOR_DELETED} Прерывание работы по Ctrl+C. Синхронизация плейлиста: $PLAYLIST_NAME была остановлена.${COLOR_RESET}"
    echo -e "================================================================================\n"
    exit 130
fi

# 4. АНАЛИЗ И МАТЕМАТИЧЕСКИЙ РАСЧЕТ ОТЧЕТА
echo -e "\n================================================================================"
echo -e "${COLOR_REPORT_FINAL} ИТОГОВЫЙ ОТЧЕТ СИНХРОНИЗАЦИИ ПЛЕЙЛИСТА: $PLAYLIST_NAME${COLOR_RESET}"
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
echo -e "${COLOR_DOWNLOADED} Синхронизация плейлиста: $PLAYLIST_NAME полностью завершена.${COLOR_RESET}"
echo -e "================================================================================\n"
