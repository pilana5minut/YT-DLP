#!/bin/bash

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

build_playlist_index() {
    local output_file="$1"
    local tmp_file="${output_file}.tmp"

    : > "$output_file"

    yt-dlp \
        --flat-playlist \
        --skip-download \
        --ignore-errors \
        --print '%(id)s\t%(title)s' \
        --cookies-from-browser "$BROWSER" \
        --js-runtimes node \
        --remote-components ejs:github \
        --socket-timeout 60 \
        "$PLAYLIST_URL" 2>/dev/null > "$output_file" || true

    if [ ! -s "$output_file" ]; then
        yt-dlp \
            --flat-playlist \
            --skip-download \
            --ignore-errors \
            --print '%(id)s\t%(title)s' \
            --js-runtimes node \
            --remote-components ejs:github \
            --socket-timeout 60 \
            "$PLAYLIST_URL" 2>/dev/null > "$output_file" || true
    fi

    awk -F'\t' 'NF >= 2 && !seen[$1]++ { print $1 "\t" $2 }' "$output_file" > "$tmp_file" 2>/dev/null || true
    if [ -s "$tmp_file" ]; then
        mv "$tmp_file" "$output_file"
    else
        rm -f "$tmp_file"
    fi
}

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
PLAYLIST_INDEX_FILE="$SERVICE_DIR/playlist_index.tsv"
BEFORE_ARCHIVE_FILE="$SERVICE_DIR/.archive_before_sync.tmp"

# Сохраняем индекс ID->название для красивых отчетов
build_playlist_index "$PLAYLIST_INDEX_FILE"

# Создаем файл архива внутри новой папки, если его нет
touch "$ARCHIVE_FILE"

# Фиксируем, сколько треков было скачано ДО этого сеанса
BEFORE_COUNT=$(wc -l < "$ARCHIVE_FILE")
cp -f "$ARCHIVE_FILE" "$BEFORE_ARCHIVE_FILE" 2>/dev/null || : > "$BEFORE_ARCHIVE_FILE"

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

    local clean_log_file=".intermediate_sync_log_clean.tmp"
    sed -E 's/\x1B\[[0-9;]*[[:alpha:]]//g' "$log_file" > "$clean_log_file"

    local stats
    stats=$(python3 - "$clean_log_file" "$real_new_count" <<'PY'
import re
import sys

log_path, real_new_count_str = sys.argv[1:3]
real_new_count = int(real_new_count_str)

restricted_re = re.compile(r'(not made this video available in your country|This video is not available in your country|blocked due to the claimed content|Private video|Sign in if you\'ve been granted access|This video is not available)')
deleted_re = re.compile(r'(Video unavailable|no longer available because|This video is no longer available)')

error_by_id = {}
hidden_unavailable = 0
skipped_archive = 0
total_items = 0

with open(log_path, 'r', encoding='utf-8', errors='replace') as f:
    for raw in f:
        line = raw.strip()
        m_total = re.search(r'Downloading\s+(\d+)\s+items', line)
        if m_total:
            total_items = int(m_total.group(1))

        m_hidden = re.search(r'INFO\s+-\s+(\d+)\s+unavailable videos are hidden', line)
        if m_hidden:
            hidden_unavailable += int(m_hidden.group(1))

        if 'has already been recorded in the archive' in line:
            skipped_archive += 1

        m_err = re.match(r'^ERROR: \[youtube\] ([^:]+):\s*(.*)$', line)
        if not m_err:
            continue

        vid = m_err.group(1)
        msg = m_err.group(2)
        if restricted_re.search(msg):
            category = 'restricted'
        elif deleted_re.search(msg):
            category = 'deleted'
        else:
            category = 'restricted'

        prev = error_by_id.get(vid)
        if prev is None or (prev == 'deleted' and category == 'restricted'):
            error_by_id[vid] = category

restricted_ids = sum(1 for c in error_by_id.values() if c == 'restricted')
deleted_ids = sum(1 for c in error_by_id.values() if c == 'deleted')
hidden_extra = max(hidden_unavailable - len(error_by_id), 0)
restricted_count = restricted_ids + hidden_extra
deleted_count = deleted_ids

skipped_count = skipped_archive

print(f'{skipped_count}|{deleted_count}|{restricted_count}')
PY
)

local skipped_count deleted_count restricted_count
IFS='|' read -r skipped_count deleted_count restricted_count <<< "$stats"

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

    rm -f "$progress_tmp" "$clean_log_file"
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

cleanup_incomplete_webm() {
    local file_name video_id removed_count=0

    if [ ! -d "$MUSIC_DIR" ]; then
        return
    fi

    while IFS= read -r -d '' file_name; do
        video_id=$(basename "$file_name" | grep -oE '\[[A-Za-z0-9_-]{11}\]' | tail -n 1 | tr -d '[]')

        # Файлы без распознаваемого ID в имени не трогаем — не относятся к загрузкам плейлиста
        if [ -z "$video_id" ]; then
            continue
        fi

        # ID есть в архиве только если загрузка и конвертация завершились успешно
        if ! grep -qF " $video_id" "$ARCHIVE_FILE" 2>/dev/null; then
            rm -f "$file_name"
            removed_count=$((removed_count + 1))
        fi
    done < <(find "$MUSIC_DIR" -maxdepth 1 -type f -print0 2>/dev/null)

    if [ "$removed_count" -gt 0 ]; then
        echo -e "${COLOR_DELETED} Удалено файлов от незавершенных/повреждённых загрузок: $removed_count${COLOR_RESET}"
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

    cleanup_incomplete_webm

    exit 130
}

trap 'cleanup_and_exit INT' INT
trap 'cleanup_and_exit TERM' TERM

DOWNLOAD_START_TIME=$(date +%s)

# 3. ЗАПУСК YT-DLP
# Надёжный вариант: обёртка на Python, которая показывает live-вывод,
# считает готовые треки, печатает промежуточный отчёт каждые 10 и
# корректно обрабатывает Ctrl+C без докачивания полного плейлиста.

python3 - "$PLAYLIST_URL" "$LOG_FILE" "$ARCHIVE_FILE" "$BEFORE_COUNT" "$MUSIC_DIR" "$BROWSER" "$PLAYLIST_NAME" "$DOWNLOAD_START_TIME" <<'PY'
import os, sys, subprocess, signal, re, time
from yt_dlp import YoutubeDL, parse_options

playlist_url, log_file, archive_file, before_count_str, music_dir, browser, playlist_name, start_time_str = sys.argv[1:9]
before_count = int(before_count_str)
start_time = int(start_time_str)
ansi_re = re.compile(r'\x1b\[[0-9;]*[A-Za-z]')


def format_duration(total_seconds):
    hours, remainder = divmod(int(total_seconds), 3600)
    minutes, seconds = divmod(remainder, 60)
    return f'{hours:02d}:{minutes:02d}:{seconds:02d}'


def report_stats(log_path, archive_path, before_total, sync_start_time, forced_new_count=None):
    names = []
    if os.path.exists(log_path):
        with open(log_path, 'r', encoding='utf-8', errors='replace') as f:
            for line in f:
                clean_line = ansi_re.sub('', line)
                if '>>> [ГОТОВО]' in clean_line:
                    names.append(clean_line.split('>>> [ГОТОВО] ', 1)[1].strip())

    downloaded_count = len(names)
    if os.path.exists(archive_path):
        with open(archive_path, 'r', encoding='utf-8', errors='replace') as f:
            after_count = sum(1 for line in f if line.strip())
    else:
        after_count = 0

    real_new_count = max(after_count - before_total, downloaded_count)
    if forced_new_count is not None and forced_new_count > real_new_count:
        real_new_count = forced_new_count

    deleted_count = 0
    restricted_count = 0
    hidden_unavailable_count = 0
    if os.path.exists(log_path):
        with open(log_path, 'r', encoding='utf-8', errors='replace') as f:
            for line in f:
                clean_line = ansi_re.sub('', line)
                if 'ERROR: [youtube]' in clean_line:
                    if re.search(r'(Video unavailable|no longer available because|This video is no longer available)', clean_line):
                        deleted_count += 1
                    if re.search(r'(not made this video available in your country|This video is not available in your country|blocked due to the claimed content|Private video|Sign in if you\'ve been granted access|This video is not available)', clean_line):
                        restricted_count += 1
                m_hidden = re.search(r'INFO\s+-\s+(\d+)\s+unavailable videos are hidden', clean_line)
                if m_hidden:
                    hidden_unavailable_count += int(m_hidden.group(1))

    restricted_count += hidden_unavailable_count

    total_items = 0
    if os.path.exists(log_path):
        with open(log_path, 'r', encoding='utf-8', errors='replace') as f:
            for line in f:
                clean_line = ansi_re.sub('', line)
                m = re.search(r'Downloading\s+(\d+)\s+items', clean_line)
                if m:
                    total_items = int(m.group(1))

    skipped_count = 0
    if os.path.exists(log_path):
        with open(log_path, 'r', encoding='utf-8', errors='replace') as f:
            for line in f:
                clean_line = ansi_re.sub('', line)
                if 'has already been recorded in the archive' in clean_line:
                    skipped_count += 1

    report_color = '\033[38;2;37;230;230m' if sys.stdout.isatty() else ''
    reset_color = '\033[0m' if sys.stdout.isatty() else ''
    print('\n' + f'{report_color}{"=" * 80}{reset_color}')
    print(f'{report_color} ПРОМЕЖУТОЧНЫЙ ОТЧЕТ СИНХРОНИЗАЦИИ ПЛЕЙЛИСТА: {playlist_name}{reset_color}')
    print(f'{report_color}{"=" * 80}{reset_color}')
    print(f' Количество пропущенных элементов плейлиста: {skipped_count}')
    print(f' Количество удаленных и скрытых элементов плейлиста: {deleted_count}')
    print(f' Количество элементов плейлиста с ограниченным доступом: {restricted_count}')
    print(f' Всего элементов плейлиста скачано на текущий момент: {real_new_count}')
    print('-' * 80)
    print(f' Времени затрачено: {format_duration(time.time() - sync_start_time)}')
    print(f'{report_color}{"=" * 80}{reset_color}')
    print('')


cmd = [
    'yt-dlp',
    '--no-colors',
    '--extract-audio',
    '--audio-format', 'mp3',
    '--audio-quality', '0',
    '--embed-thumbnail',
    '--convert-thumbnails', 'jpg',
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

_, ydl_options, urls, ydl_params = parse_options(cmd[1:])
state = {'finished_count': 0, 'last_reported': 0}


def progress_hook(status):
    if status.get('status') != 'finished':
        return

    state['finished_count'] += 1
    if state['finished_count'] >= state['last_reported'] + 10:
        state['last_reported'] = (state['finished_count'] // 10) * 10
        log_handle.flush()
        report_stats(
            log_file,
            archive_file,
            before_count,
            start_time,
            forced_new_count=state['finished_count'],
        )


ydl_params['progress_hooks'] = [progress_hook]
ydl_params['quiet'] = False
ydl_params['no_warnings'] = False

log_handle = open(log_file, 'w', encoding='utf-8', buffering=1)


class OutputLogger:
    terminal_patterns = (
        re.compile(r'^\[download\] Downloading item '),
        re.compile(r'^>>> \[(СКАЧИВАНИЕ|ГОТОВО)\]'),
        re.compile(r'^\[ExtractAudio\] Destination:'),
    )

    def _write(self, message):
        text = str(message)
        clean_text = ansi_re.sub('', text)
        log_handle.write(text + '\n')
        log_handle.flush()

        if any(pattern.search(text) for pattern in self.terminal_patterns):
            sys.stdout.write(text + '\n')
            sys.stdout.flush()

    debug = _write
    info = _write
    warning = _write
    error = _write


ydl_params['logger'] = OutputLogger()
ydl = YoutubeDL(ydl_params)

def stop_child(signum, frame):
    try:
        ydl._exit_status = 130
    except ProcessLookupError:
        pass
    raise SystemExit(130)


signal.signal(signal.SIGINT, stop_child)
signal.signal(signal.SIGTERM, stop_child)

try:
    exit_code = ydl.download(urls)
    if exit_code not in (None, 0):
        raise SystemExit(exit_code)
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
    cleanup_incomplete_webm
    exit 130
fi

# 4. АНАЛИЗ И МАТЕМАТИЧЕСКИЙ РАСЧЕТ ОТЧЕТА
CLEAN_LOG_FILE=".sync_log_clean.tmp"
ANALYSIS_FILE=".analysis_vars.tmp"
DOWNLOADED_NAMES_FILE=".downloaded_names.tmp"
NOT_DOWNLOADED_FILE=".not_downloaded_items.tmp"

sed -E 's/\x1B\[[0-9;]*[[:alpha:]]//g' "$LOG_FILE" > "$CLEAN_LOG_FILE"

python3 - "$CLEAN_LOG_FILE" "$ARCHIVE_FILE" "$BEFORE_COUNT" "$PLAYLIST_INDEX_FILE" "$ANALYSIS_FILE" "$DOWNLOADED_NAMES_FILE" "$NOT_DOWNLOADED_FILE" "$BEFORE_ARCHIVE_FILE" <<'PY'
import re
import sys
from pathlib import Path

clean_log_file, archive_file, before_count_str, playlist_index_file, analysis_file, downloaded_file, not_downloaded_file, before_archive_file = sys.argv[1:9]
before_count = int(before_count_str)

restricted_re = re.compile(r'(not made this video available in your country|This video is not available in your country|blocked due to the claimed content|Private video|Sign in if you\'ve been granted access|This video is not available)')
deleted_re = re.compile(r'(Video unavailable|no longer available because|This video is no longer available)')

playlist_title_by_id = {}
index_path = Path(playlist_index_file)
if index_path.exists():
    for raw in index_path.read_text(encoding='utf-8', errors='replace').splitlines():
        if '\t' not in raw:
            continue
        vid, title = raw.split('\t', 1)
        vid = vid.strip()
        title = title.strip()
        if vid and title and vid not in playlist_title_by_id:
            playlist_title_by_id[vid] = title

downloaded_title_by_id = {}
error_by_id = {}
hidden_unavailable = 0
total_items = 0
skipped_archive = 0

for raw in Path(clean_log_file).read_text(encoding='utf-8', errors='replace').splitlines():
    line = raw.strip()

    m_total = re.search(r'Downloading\s+(\d+)\s+items', line)
    if m_total:
        total_items = int(m_total.group(1))

    m_hidden = re.search(r'INFO\s+-\s+(\d+)\s+unavailable videos are hidden', line)
    if m_hidden:
        hidden_unavailable += int(m_hidden.group(1))

    if 'has already been recorded in the archive' in line:
        skipped_archive += 1

    m_dest = re.match(r'^\[ExtractAudio\] Destination:\s+.+/(.+?) \[([A-Za-z0-9_-]{11})\]\.mp3$', line)
    if m_dest:
        downloaded_title_by_id[m_dest.group(2)] = m_dest.group(1)

    m_err = re.match(r'^ERROR: \[youtube\] ([^:]+):\s*(.*)$', line)
    if not m_err:
        continue

    vid = m_err.group(1).strip()
    msg = m_err.group(2).strip()

    if restricted_re.search(msg):
        category = 'restricted'
    elif deleted_re.search(msg):
        category = 'deleted'
    else:
        category = 'restricted'

    prev = error_by_id.get(vid)
    if prev is None:
        error_by_id[vid] = (category, msg)
    elif prev[0] == 'deleted' and category == 'restricted':
        error_by_id[vid] = (category, msg)

after_count = 0
archive_path = Path(archive_file)
if archive_path.exists():
    after_count = sum(1 for line in archive_path.read_text(encoding='utf-8', errors='replace').splitlines() if line.strip())

def extract_ids(path):
    ids = []
    if not path.exists():
        return ids
    for row in path.read_text(encoding='utf-8', errors='replace').splitlines():
        row = row.strip()
        if not row:
            continue
        m = re.search(r'([A-Za-z0-9_-]{11})\s*$', row)
        if m:
            ids.append(m.group(1))
    return ids

before_ids = set(extract_ids(Path(before_archive_file)))
after_ids_ordered = extract_ids(Path(archive_file))
new_ids = [vid for vid in after_ids_ordered if vid not in before_ids]

downloaded_names = [playlist_title_by_id.get(vid, f'Видео с ID {vid}') for vid in new_ids]
downloaded_names = [f'{vid}\t{downloaded_title_by_id.get(vid, playlist_title_by_id.get(vid, f"Видео с ID {vid}"))}' for vid in new_ids]
real_new_count = len(new_ids)

restricted_ids = [vid for vid, (category, _) in error_by_id.items() if category == 'restricted']
deleted_ids = [vid for vid, (category, _) in error_by_id.items() if category == 'deleted']

hidden_extra = max(hidden_unavailable - len(error_by_id), 0)
restricted_count = len(restricted_ids) + hidden_extra
deleted_count = len(deleted_ids)

if total_items > 0:
    residual_skipped = max(total_items - real_new_count - deleted_count - restricted_count, 0)
else:
    residual_skipped = 0
skipped_count = max(skipped_archive, residual_skipped)

Path(downloaded_file).write_text('\n'.join(downloaded_names) + ('\n' if downloaded_names else ''), encoding='utf-8')

lines = []
for vid, (category, reason) in sorted(error_by_id.items(), key=lambda x: x[0]):
    lines.append(f'{vid}\t{reason}')

for idx in range(hidden_extra):
    lines.append(f'-\tYouTube: unavailable videos are hidden (скрытый недоступный элемент #{idx + 1})')

Path(not_downloaded_file).write_text('\n'.join(lines) + ('\n' if lines else ''), encoding='utf-8')

Path(analysis_file).write_text(
    f'REAL_NEW_COUNT={real_new_count}\n'
    f'DELETED_COUNT={deleted_count}\n'
    f'RESTRICTED_COUNT={restricted_count}\n'
    f'SKIPPED_COUNT={skipped_count}\n',
    encoding='utf-8'
)
PY

source "$ANALYSIS_FILE"

cleanup_incomplete_webm

DOWNLOAD_END_TIME=$(date +%s)
ELAPSED_DOWNLOAD_TIME=$((DOWNLOAD_END_TIME - DOWNLOAD_START_TIME))
ELAPSED_HOURS=$((ELAPSED_DOWNLOAD_TIME / 3600))
ELAPSED_MINUTES=$(((ELAPSED_DOWNLOAD_TIME % 3600) / 60))
ELAPSED_SECONDS=$((ELAPSED_DOWNLOAD_TIME % 60))
printf -v FORMATTED_DOWNLOAD_TIME '%02d:%02d:%02d' \
    "$ELAPSED_HOURS" "$ELAPSED_MINUTES" "$ELAPSED_SECONDS"

echo -e "\n${COLOR_REPORT_FINAL}================================================================================${COLOR_RESET}"
echo -e "${COLOR_REPORT_FINAL}ИТОГОВЫЙ ОТЧЕТ СИНХРОНИЗАЦИИ ПЛЕЙЛИСТА: $PLAYLIST_NAME${COLOR_RESET}"
echo -e "${COLOR_REPORT_FINAL}================================================================================${COLOR_RESET}"
echo -e "${COLOR_SKIP}Количество пропущенных элементов плейлиста: $SKIPPED_COUNT${COLOR_RESET}"
echo -e "Количество удаленных и скрытых элементов плейлиста: $DELETED_COUNT"
echo -e "Количество элементов плейлиста с ограниченным доступом: $RESTRICTED_COUNT"
echo -e "${COLOR_DOWNLOADED}Всего элементов плейлиста скачано за весь сеанс: $REAL_NEW_COUNT${COLOR_RESET}"
echo -e "--------------------------------------------------------------------------------"
echo -e "Времени затрачено: $FORMATTED_DOWNLOAD_TIME"
echo -e "--------------------------------------------------------------------------------"

if [ "$REAL_NEW_COUNT" -gt 0 ] && [ -s "$DOWNLOADED_NAMES_FILE" ]; then
    echo -e "Список скачанных элементов:"
    echo -e ""
    awk -F'\t' '{print NR " ID: " $1 " | " $2}' "$DOWNLOADED_NAMES_FILE"
    echo -e ""
else
    if [ "$REAL_NEW_COUNT" -eq 0 ]; then
        echo -e "${COLOR_STATUS} (Новых файлов добавлено не было, ваш плейлист полностью синхронизирован)${COLOR_RESET}"
    fi
fi

if [ -s "$NOT_DOWNLOADED_FILE" ]; then
    echo -e "--------------------------------------------------------------------------------"
    echo -e "Список элементов которые не были скачаны:"
    echo -e ""
    awk -F'\t' '{print NR " ID: " $1 " | Причина: " $2}' "$NOT_DOWNLOADED_FILE"
fi

rm -f "$ANALYSIS_FILE" "$DOWNLOADED_NAMES_FILE" "$NOT_DOWNLOADED_FILE" "$CLEAN_LOG_FILE" "$BEFORE_ARCHIVE_FILE"

echo -e "${COLOR_REPORT_FINAL}================================================================================${COLOR_RESET}"
