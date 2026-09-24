#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
real_photorec="$project_dir/ThirdParty/photorec/bin/arm64/photorec"
test_dir="${DEEP_PHOTOREC_TEST_DIR:-$project_dir/work/tests/deep-photorec-cli-$RANDOM-$$}"
cache_dir="${BUILD_CACHE_DIR:-$project_dir/work/swift-deep-cli}"

for command_name in mformat mcopy mdel ffmpeg clang python3 pgrep; do
    command -v "$command_name" >/dev/null || {
        echo "Для теста нужен $command_name" >&2
        exit 1
    }
done
test -x "$real_photorec"

export SDKROOT="${RECOVERYAPP_SDKROOT:-$(xcrun --show-sdk-path)}"
mkdir -p "$cache_dir/module-cache"
export CLANG_MODULE_CACHE_PATH="$cache_dir/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$cache_dir/module-cache"
swift build --disable-sandbox --scratch-path "$cache_dir" -c debug --product recoveryapp-cli
cli="$(swift build --disable-sandbox --scratch-path "$cache_dir" -c debug --product recoveryapp-cli --show-bin-path)/recoveryapp-cli"

mkdir -p "$test_dir"
tools_dir="$test_dir/tools"
mkdir -p "$tools_dir"
clang -Wall -Wextra -Werror -Os "$project_dir/Packaging/tool-launcher.c" -o "$tools_dir/tool-launcher"
cp "$real_photorec" "$tools_dir/photorec"

fail() {
    print -u2 "FAIL: $1"
    exit 1
}

# Детерминированный PhotoRec shim: известные находки с интервалом, режим
# DEEP_SHIM_SLOW=1 держит процесс живым для проверки отмены. photorec.ses
# пишется в текущий рабочий каталог: так проверяется, что CLI запускает
# процесс с рабочей папкой сессии.
cat > "$tools_dir/photorec-shim" <<'PY'
#!/usr/bin/env python3
import os, sys, time

start_delay = float(os.environ.get("DEEP_SHIM_START_DELAY", "0"))
if start_delay:
    time.sleep(start_delay)

args = sys.argv[1:]
log = base = image = None
i = 0
while i < len(args):
    a = args[i]
    if a == "/logname":
        i += 1; log = args[i]
    elif a == "/d":
        i += 1; base = args[i]
    elif a == "/cmd":
        i += 1; image = args[i]
    i += 1

with open(log, "w") as handle:
    handle.write("PhotoRec 7.2, Data Recovery Utility\n")
    handle.write(f"PhotoRec shim: {image}\n")
with open("photorec.ses", "w") as handle:
    handle.write("blocksize,512\n0-100\n")

directory = base + ".1"
os.makedirs(directory, exist_ok=True)
count = int(os.environ.get("DEEP_SHIM_FILES", "3"))
pause = float(os.environ.get("DEEP_SHIM_PAUSE", "2"))
for n in range(1, count + 1):
    with open(os.path.join(directory, f"f{n:06d}.jpg"), "wb") as handle:
        handle.write(f"RECOVERYAPP-DEEP-SHIM-{n}\n".encode())
    if os.environ.get("DEEP_SHIM_SLOW") == "1":
        time.sleep(600)
    else:
        time.sleep(pause)
with open(log, "a") as handle:
    handle.write("PhotoRec exited normally.\n")
PY
chmod +x "$tools_dir/photorec-shim"

export RECOVERYAPP_PHOTOREC_PATH="$tools_dir/photorec"
export RECOVERYAPP_TOOL_LAUNCHER_PATH="$tools_dir/tool-launcher"
unset DEEP_SHIM_SLOW DEEP_SHIM_FILES DEEP_SHIM_PAUSE
# Запуск CLI из постороннего рабочего каталога: $1 scratch, $2 stdout,
# $3 stderr, остальные аргументы — CLI.
run_deep() {
    local scratch="$1" stdout_file="$2" stderr_file="$3"
    shift 3
    (
        cd "$scratch" || exit 97
        exec "$cli" "$@" > "$stdout_file" 2> "$stderr_file"
    )
}

assert_clean_scratch() {
    local scratch="$1" label="$2"
    [[ -z "$(find "$scratch" -mindepth 1 -print -quit)" ]] \
        || fail "$label: в постороннем рабочем каталоге остались артефакты: $(ls -A "$scratch")"
}

# 1. Парсер: неверные, конфликтующие и отсутствующие аргументы — код 2,
#    stdout пуст, подсказка в stderr.
expect_usage_error() {
    set +e
    "$cli" "$@" > "$test_dir/usage.out" 2> "$test_dir/usage.err"
    local rc=$?
    set -e
    [[ "$rc" -eq 2 ]] || fail "ожидался код 2 для: $* (получен $rc)"
    [[ ! -s "$test_dir/usage.out" ]] || fail "ошибка аргументов должна печатать только в stderr: $*"
}
expect_usage_error deep
expect_usage_error deep scan --image a.img
expect_usage_error deep recover
expect_usage_error deep recover --image
expect_usage_error deep recover --image a.img
expect_usage_error deep recover --image a.img --output d --json
expect_usage_error deep recover --image a.img --output d --all
expect_usage_error deep recover --image a.img --output d --jsonl лишний
expect_usage_error deep recover --image a.img --drive disk4 --output d
expect_usage_error deep recover --image a.img --expected-name N --output d
expect_usage_error deep recover --drive /dev/rdisk4 --expected-name N --expected-size 5 --output d
expect_usage_error deep recover --drive disk4 --expected-size 5 --output d
expect_usage_error deep recover --drive disk4 --expected-name N --output d
expect_usage_error deep recover --drive disk4 --expected-name N --expected-size abc --output d
expect_usage_error deep recover --drive disk4 --expected-name N --expected-size 0 --output d
expect_usage_error quick scan --image a.img --jsonl
expect_usage_error version --jsonl
"$cli" help | grep -q "deep recover" || fail "справка не упоминает deep recover"
print "PASS: парсер deep recover отклоняет неверные аргументы кодом 2"

# 2. Ошибки выполнения — код 1 и событие error в JSONL.
printf 'RECOVERYAPP-DEEP-CLI-SOURCE\n' > "$test_dir/shim-source.img"
expect_runtime_error() {
    set +e
    "$cli" "$@" > "$test_dir/runtime.out" 2> "$test_dir/runtime.err"
    local rc=$?
    set -e
    [[ "$rc" -eq 1 ]] || fail "ожидался код 1 для: $* (получен $rc)"
}
expect_runtime_error deep recover --image "$test_dir/absent.img" --output "$test_dir/out"
expect_runtime_error deep recover --image "$test_dir" --output "$test_dir/out"
mkdir -p "$test_dir/out-absent-parent"
expect_runtime_error deep recover --image "$test_dir/shim-source.img" --output "$test_dir/absent-output"
env -u RECOVERYAPP_PHOTOREC_PATH "$cli" deep recover --image "$test_dir/shim-source.img" \
    --output "$test_dir/out-absent-parent" --jsonl > "$test_dir/no-photorec.out" 2> "$test_dir/no-photorec.err" \
    && fail "без RECOVERYAPP_PHOTOREC_PATH ожидался код 1" || true
grep -q '"event":"error"' "$test_dir/no-photorec.out" \
    || fail "без photorec ожидается событие error в stdout"
grep -q '"code":"toolMissing"' "$test_dir/no-photorec.out" \
    || fail "без photorec ожидается стабильный код toolMissing"
print "PASS: ошибки выполнения дают код 1 и событие error со стабильным кодом"

# 3. Физический источник: повторное обнаружение и сверка отвергают диск до
#    Authorization Services; в JSONL ровно одно событие error без started.
mkdir -p "$test_dir/out-drive" "$test_dir/scratch-drive"
set +e
run_deep "$test_dir/scratch-drive" "$test_dir/drive.out" "$test_dir/drive.err" \
    deep recover --drive disk99999 --expected-name RECOVERYAPP-DEEP-NOPE --expected-size 5 \
    --output "$test_dir/out-drive" --jsonl
drive_rc=$?
set -e
[[ "$drive_rc" -eq 1 ]] || fail "ожидался код 1 при отвержении накопителя (получен $drive_rc)"
python3 - "$test_dir/drive.out" <<'PY' || fail "событие ошибки drive-режима некорректно"
import json, sys

events = []
with open(sys.argv[1], encoding="utf-8") as handle:
    for line in handle:
        line = line.strip()
        if line:
            events.append(json.loads(line))
assert len(events) == 1, events
event = events[0]
assert event["event"] == "error", event
assert event["schemaVersion"] == 1, event
assert event["code"] in ("sourceUnavailable", "sourceChanged"), event
assert isinstance(event["message"], str) and event["message"], event
print("PASS: отвержение накопителя до авторизации даёт одиночное событие error")
PY
assert_clean_scratch "$test_dir/scratch-drive" "drive-режим"

# 4. JSONL: построчный разбор каждой строки, схема событий, живой прогресс,
#    чистый рабочий каталог и photorec.ses только в папке сессии.
export RECOVERYAPP_PHOTOREC_PATH="$tools_dir/photorec-shim"
shim_image="$test_dir/shim-source.img"
mkdir -p "$test_dir/scratch-shim" "$test_dir/out-shim"
run_deep "$test_dir/scratch-shim" "$test_dir/shim.out" "$test_dir/shim.err" \
    deep recover --image "$shim_image" --output "$test_dir/out-shim" --jsonl
python3 - "$test_dir/shim.out" "$shim_image" "$test_dir/out-shim" <<'PY'
import json, os, sys

stdout_file, image_path, out_dir = sys.argv[1:4]
allowed = {"started", "progress", "completed", "cancelled", "error"}
events = []
with open(stdout_file, encoding="utf-8") as handle:
    for line_number, line in enumerate(handle, 1):
        if not line.endswith("\n"):
            raise AssertionError(f"строка {line_number} не завершена переводом строки")
        event = json.loads(line)  # каждая строка обязана быть валидным JSON
        assert isinstance(event, dict), event
        assert event.get("schemaVersion") == 1, event
        assert event.get("event") in allowed, event
        events.append(event)

kinds = [event["event"] for event in events]
assert kinds[0] == "started", kinds
assert kinds[-1] == "completed", kinds
assert "progress" in kinds, kinds
# Терминальное событие ровно одно и всегда последнее.
terminal = {"completed", "cancelled", "error"}
assert not (set(kinds[:-1]) & terminal), kinds

started = events[0]
assert started["source"]["type"] == "image", started
assert started["source"]["path"] == image_path, started
session = started["sessionDirectory"]
assert os.path.isabs(session) and session.startswith(out_dir), started
assert os.path.isdir(session), started

progress_events = [event for event in events if event["event"] == "progress"]
counts = [event["foundFiles"] for event in progress_events]
assert counts == sorted(counts), counts
assert counts[-1] == 3, counts
for event in progress_events:
    assert isinstance(event["elapsedSeconds"], (int, float)), event
    assert event["resultBytes"] >= 0, event
    # Значения, которые нельзя достоверно определить, должны опускаться,
    # а не подменяться нулём: если processedBytes есть, то и total есть.
    if "processedBytes" in event:
        assert "totalBytes" in event, event

completed = events[-1]
assert completed["recoveredCount"] == 3, completed
assert len(completed["files"]) == 3, completed
for name in ("f000001.jpg", "f000002.jpg", "f000003.jpg"):
    assert any(path.endswith("/" + name) for path in completed["files"]), completed
    assert os.path.isfile(os.path.join(session, "Recovered.1", name)), completed
for event in events:
    assert not any(key.lower().startswith("eta") for key in event), event
print("PASS: JSONL схема, построчный разбор и живой прогресс корректны")
PY
[[ -s "$test_dir/shim.err" ]] || fail "stderr должен содержать диагностику запуска"
session_shim="$(find "$test_dir/out-shim" -mindepth 1 -maxdepth 1 -type d -print -quit)"
test -n "$session_shim"
test -f "$session_shim/photorec.ses" || fail "photorec.ses должен быть в папке сессии"
test -f "$session_shim/photorec.log" || fail "журнал PhotoRec должен быть в папке сессии"
[[ "$(find "$test_dir/out-shim" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -eq 1 ]] \
    || fail "внутри --output должна быть только папка сессии"
assert_clean_scratch "$test_dir/scratch-shim" "shim-режим"
print "PASS: photorec.ses и журнал только в папке сессии, cwd не засорён"

# 5. Текстовый режим: русский текст, прогресс на stderr, итог на stdout.
mkdir -p "$test_dir/scratch-text" "$test_dir/out-text"
run_deep "$test_dir/scratch-text" "$test_dir/text.out" "$test_dir/text.err" \
    deep recover --image "$shim_image" --output "$test_dir/out-text"
grep -q "Глубокий поиск завершён. PhotoRec создал файлов: 3." "$test_dir/text.out" \
    || fail "текстовый режим: нет итога о найденных файлах"
grep -q "Папка сессии: " "$test_dir/text.out" || fail "текстовый режим: нет папки сессии"
grep -q "найдено файлов: 3" "$test_dir/text.err" \
    || fail "текстовый режим: нет живого прогресса на stderr"
grep -q "Прошло " "$test_dir/text.err" || fail "текстовый режим: нет прошедшего времени"
grep -q "ETA" "$test_dir/text.err" && fail "текстовый режим не должен обещать ETA" || true
assert_clean_scratch "$test_dir/scratch-text" "текстовый режим"
print "PASS: текстовый режим сообщает запуск, прогресс и папку сессии без ETA"

# 6. Ctrl-C: код 130, событие cancelled, файлы сохранены, процессов нет.
mkdir -p "$test_dir/scratch-cancel" "$test_dir/out-cancel"
export DEEP_SHIM_SLOW=1
# Подоболочка с exec: $! становится pid самого CLI, как в реальном терминале.
(
    cd "$test_dir/scratch-cancel" || exit 97
    exec "$cli" deep recover --image "$shim_image" --output "$test_dir/out-cancel" --jsonl \
        > "$test_dir/cancel.out" 2> "$test_dir/cancel.err"
) &
cli_pid=$!
first_file=""
for _ in {1..150}; do
    first_file="$(find "$test_dir/out-cancel" -name 'f000001.jpg' -print -quit 2>/dev/null)"
    [[ -n "$first_file" ]] && break
    sleep 0.2
done
[[ -n "$first_file" ]] || fail "shim не создал первую находку для проверки отмены"
sleep 0.5
kill -INT "$cli_pid" || fail "не удалось отправить SIGINT процессу CLI"
set +e
wait "$cli_pid"
cancel_rc=$?
set -e
unset DEEP_SHIM_SLOW
[[ "$cancel_rc" -eq 130 ]] || fail "ожидался код 130 после Ctrl-C (получен $cancel_rc)"
sleep 1.5
if pgrep -f "$tools_dir/photorec-shim" >/dev/null 2>&1; then
    fail "после Ctrl-C остался живой дочерний процесс PhotoRec"
fi
python3 - "$test_dir/cancel.out" <<'PY'
import json, sys

events = []
with open(sys.argv[1], encoding="utf-8") as handle:
    for line in handle:
        line = line.strip()
        if line:
            events.append(json.loads(line))
kinds = [event["event"] for event in events]
assert kinds[0] == "started", kinds
assert kinds[-1] == "cancelled", kinds
assert "completed" not in kinds and "error" not in kinds, kinds
terminal = {"completed", "cancelled", "error"}
assert not (set(kinds[:-1]) & terminal), kinds
cancelled = events[-1]
assert cancelled["schemaVersion"] == 1, cancelled
assert cancelled["sessionDirectory"], cancelled
assert cancelled["foundFiles"] >= 1, cancelled
assert any(path.endswith("/f000001.jpg") for path in cancelled["files"]), cancelled
print("PASS: итоговое событие cancelled содержит папку сессии и найденные файлы")
PY
test -f "$first_file" || fail "найденные до отмены файлы должны сохраниться"
test -f "$session_shim" 2>/dev/null || true
cancel_session="$(find "$test_dir/out-cancel" -mindepth 1 -maxdepth 1 -type d -print -quit)"
test -n "$cancel_session"
test -f "$cancel_session/photorec.ses" || fail "папка сессии должна сохраниться с её файлами"
assert_clean_scratch "$test_dir/scratch-cancel" "отмена"
print "PASS: Ctrl-C даёт код 130, сохраняет находки и не оставляет процессов"

# 6b. Ранний Ctrl-C: сигнал приходит после создания папки сессии, но до
#     запуска PhotoRec (shim ещё спит). Запрос отмены не должен потеряться.
mkdir -p "$test_dir/scratch-early" "$test_dir/out-early"
export DEEP_SHIM_START_DELAY=3
(
    cd "$test_dir/scratch-early" || exit 97
    exec "$cli" deep recover --image "$shim_image" --output "$test_dir/out-early" --jsonl \
        > "$test_dir/early.out" 2> "$test_dir/early.err"
) &
early_pid=$!
early_session=""
for _ in {1..300}; do
    early_session="$(find "$test_dir/out-early" -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null)"
    [[ -n "$early_session" ]] && break
    sleep 0.05
done
[[ -n "$early_session" ]] || fail "сессия для раннего Ctrl-C не создалась"
kill -INT "$early_pid" || fail "не удалось отправить ранний SIGINT"
set +e
wait "$early_pid"
early_rc=$?
set -e
unset DEEP_SHIM_START_DELAY
[[ "$early_rc" -eq 130 ]] || fail "ожидался код 130 при раннем Ctrl-C (получен $early_rc)"
sleep 2
if pgrep -f "$tools_dir/photorec-shim" >/dev/null 2>&1; then
    fail "после раннего Ctrl-C остался живой дочерний процесс PhotoRec"
fi
[[ -z "$(find "$test_dir/out-early" -name '*.jpg' -print -quit 2>/dev/null)" ]] \
    || fail "при раннем Ctrl-C PhotoRec не должен успеть найти файлы"
python3 - "$test_dir/early.out" <<'PY'
import json, sys

events = []
with open(sys.argv[1], encoding="utf-8") as handle:
    for line in handle:
        line = line.strip()
        if line:
            events.append(json.loads(line))
kinds = [event["event"] for event in events]
assert kinds, "ожидается хотя бы одно событие"
assert kinds[-1] == "cancelled", kinds
assert "completed" not in kinds and "error" not in kinds, kinds
if "started" in kinds:
    assert kinds[0] == "started", kinds
print("PASS: ранний Ctrl-C даёт терминальное событие cancelled последним")
PY
assert_clean_scratch "$test_dir/scratch-early" "ранний Ctrl-C"
print "PASS: ранний Ctrl-C не теряется, PhotoRec не находит файлы, процессов нет"

# 7. End-to-end со встроенным PhotoRec на синтетическом FAT32-образе:
#    удалённые PNG и MP4 восстанавливаются побайтно.
export RECOVERYAPP_PHOTOREC_PATH="$tools_dir/photorec"
mkdir -p "$test_dir/originals"
ffmpeg -hide_banner -loglevel error -f lavfi \
    -i 'testsrc2=size=640x360:rate=1:duration=1' -frames:v 1 -y \
    "$test_dir/originals/TESTCARD.PNG"
ffmpeg -hide_banner -loglevel error \
    -f lavfi -i 'testsrc2=size=640x360:rate=25:duration=2' \
    -f lavfi -i 'sine=frequency=440:duration=2' \
    -c:v libx264 -pix_fmt yuv420p -c:a aac -movflags +faststart -y \
    "$test_dir/originals/CLIP.MP4"
fat_image="$test_dir/fat32-deleted.img"
mformat -i "$fat_image" -C -F -v DEEPCLI -T 262144 ::
mcopy -i "$fat_image" "$test_dir/originals/TESTCARD.PNG" ::/TESTCARD.PNG
mcopy -i "$fat_image" "$test_dir/originals/CLIP.MP4" ::/CLIP.MP4
mdel -i "$fat_image" ::/TESTCARD.PNG ::/CLIP.MP4

mkdir -p "$test_dir/scratch-e2e" "$test_dir/out-e2e"
RECOVERYAPP_PHOTOREC_PATH="$tools_dir/photorec" \
    run_deep "$test_dir/scratch-e2e" "$test_dir/e2e.out" "$test_dir/e2e.err" \
    deep recover --image "$fat_image" --output "$test_dir/out-e2e" --jsonl
python3 - "$test_dir/e2e.out" "$fat_image" <<'PY'
import json, sys

events = []
with open(sys.argv[1], encoding="utf-8") as handle:
    for line in handle:
        line = line.strip()
        if line:
            events.append(json.loads(line))
kinds = [event["event"] for event in events]
assert kinds[0] == "started" and kinds[-1] == "completed", kinds
assert "error" not in kinds and "cancelled" not in kinds, kinds
terminal = {"completed", "cancelled", "error"}
assert not (set(kinds[:-1]) & terminal), kinds
completed = events[-1]
assert completed["recoveredCount"] == 2, completed
kinds_lower = [path.lower() for path in completed["files"]]
assert any(path.endswith(".png") for path in kinds_lower), completed
assert any(path.endswith(".mp4") for path in kinds_lower), completed
print("PASS: встроенный PhotoRec нашёл оба удалённых файла, события согласованы")
PY
png_result="$(find "$test_dir/out-e2e" -type f -name '*.png' -print -quit)"
mp4_result="$(find "$test_dir/out-e2e" -type f -name '*.mp4' -print -quit)"
test -n "$png_result" && test -n "$mp4_result"
cmp "$test_dir/originals/TESTCARD.PNG" "$png_result"
cmp "$test_dir/originals/CLIP.MP4" "$mp4_result"
assert_clean_scratch "$test_dir/scratch-e2e" "end-to-end"
print "PASS: встроенный PhotoRec восстановил PNG и MP4 побайтно"

# 8. Чистый образ без сигнатур — пустой результат: код 0 и completed с нулём.
clean_image="$test_dir/clean.img"
mformat -i "$clean_image" -C -F -v CLEAN -T 262144 ::
mkdir -p "$test_dir/scratch-clean" "$test_dir/out-clean"
RECOVERYAPP_PHOTOREC_PATH="$tools_dir/photorec" \
    run_deep "$test_dir/scratch-clean" "$test_dir/clean.out" "$test_dir/clean.err" \
    deep recover --image "$clean_image" --output "$test_dir/out-clean" --jsonl
python3 - "$test_dir/clean.out" <<'PY'
import json, sys

events = []
with open(sys.argv[1], encoding="utf-8") as handle:
    for line in handle:
        line = line.strip()
        if line:
            events.append(json.loads(line))
kinds = [event["event"] for event in events]
assert kinds[0] == "started" and kinds[-1] == "completed", kinds
terminal = {"completed", "cancelled", "error"}
assert not (set(kinds[:-1]) & terminal), kinds
completed = events[-1]
assert completed["recoveredCount"] == 0, completed
assert completed["files"] == [], completed
print("PASS: пустой результат — код 0 и completed с нулём файлов")
PY
assert_clean_scratch "$test_dir/scratch-clean" "чистый образ"
print "PASS: пустой результат завершается кодом 0 без подмен"

print "PASS: все проверки deep photorec CLI прошли"
echo "result=$test_dir"
