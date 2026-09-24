#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
real_untrunc="$project_dir/ThirdParty/untrunc/bin/arm64/untrunc"
test_dir="${VIDEO_CLI_TEST_DIR:-$project_dir/work/tests/video-cli-$RANDOM-$$}"
cache_dir="${BUILD_CACHE_DIR:-$project_dir/work/swift-video-cli}"

for command_name in ffmpeg ffprobe python3 clang pgrep; do
    command -v "$command_name" >/dev/null || {
        echo "Для теста нужен $command_name" >&2
        exit 1
    }
done
if ! command -v diskutil >/dev/null || ! command -v hdiutil >/dev/null; then
    echo "Для теста нужны diskutil и hdiutil (синтетический том для политики носителей)" >&2
    exit 1
fi
test -x "$real_untrunc"

export SDKROOT="${RECOVERYAPP_SDKROOT:-$(xcrun --show-sdk-path)}"
mkdir -p "$cache_dir/module-cache"
export CLANG_MODULE_CACHE_PATH="$cache_dir/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$cache_dir/module-cache"
swift build --disable-sandbox --scratch-path "$cache_dir" -c debug --product recoveryapp-cli
cli="$(swift build --disable-sandbox --scratch-path "$cache_dir" -c debug --product recoveryapp-cli --show-bin-path)/recoveryapp-cli"

mkdir -p "$test_dir/tools"
clang -Wall -Wextra -Werror -Os "$project_dir/Packaging/tool-launcher.c" -o "$test_dir/tools/tool-launcher"

fail() {
    print -u2 "FAIL: $1"
    exit 1
}

# Синтетический том (никаких пользовательских накопителей): новый синтаксис
# diskutil image, на старых системах — hdiutil. Файл образа живёт внутри
# test_dir и удаляется вместе с ним.
volume_image="$test_dir/volume.asif"
volume_mount="$test_dir/volume-mnt"
create_synthetic_volume() {
    if diskutil image create blank --format ASIF --fs APFS --size 48m \
        --volumeName VIDCLI "$volume_image" >/dev/null 2>&1; then
        mkdir -p "$volume_mount"
        diskutil image attach "$volume_image" -mountPoint "$volume_mount" \
            -mountOptions nobrowse >/dev/null
    else
        volume_image="$test_dir/volume.dmg"
        hdiutil create -size 48m -fs 'FAT32' -volname VIDCLI \
            -o "$volume_image" -ov -quiet
        mkdir -p "$volume_mount"
        hdiutil attach "$volume_image" -mountpoint "$volume_mount" \
            -nobrowse -noautoopen -quiet
    fi
}
detach_synthetic_volume() {
    # Лучшее усилие с ретраями: том может «занять» пару секунд после
    # завершения процессов; при раннем отказе скрипта trap тоже вызывает
    # эту функцию, поэтому незакрытых томов не остаётся.
    for _ in {1..5}; do
        hdiutil detach "$volume_mount" -quiet >/dev/null 2>&1 \
            && return 0
        diskutil image detach "$volume_image" >/dev/null 2>&1 \
            && return 0
        sleep 1
    done
    hdiutil detach "$volume_mount" -force -quiet >/dev/null 2>&1 || true
}
trap detach_synthetic_volume EXIT

export RECOVERYAPP_TOOL_LAUNCHER_PATH="$test_dir/tools/tool-launcher"
export RECOVERYAPP_UNTRUNC_PATH="$real_untrunc"

# Запуск CLI из постороннего рабочего каталога: $1 scratch, $2 stdout,
# $3 stderr, остальные аргументы — CLI.
run_video() {
    local scratch="$1" stdout_file="$2" stderr_file="$3"
    shift 3
    (
        cd "$scratch" || exit 97
        exec "$cli" "$@" > "$stdout_file" 2> "$stderr_file"
    )
}

# 1. Аргументы: неверные, дубли, чужие флаги — код 2, stdout пуст.
expect_usage_error() {
    set +e
    "$cli" "$@" > "$test_dir/usage.out" 2> "$test_dir/usage.err"
    local rc=$?
    set -e
    [[ "$rc" -eq 2 ]] || fail "ожидался код 2 для: $* (получен $rc)"
    [[ ! -s "$test_dir/usage.out" ]] || fail "ошибка аргументов должна печатать только в stderr: $*"
}
expect_usage_error video
expect_usage_error video show
expect_usage_error video repair
expect_usage_error video repair --reference
expect_usage_error video repair --reference a.mp4 --damaged b.mp4
expect_usage_error video repair --reference a.mp4 --damaged b.mp4 --output
expect_usage_error video repair --reference a.mp4 --reference c.mp4 --damaged b.mp4 --output d
expect_usage_error video repair --reference a.mp4 --damaged b.mp4 --output d --output e
expect_usage_error video repair --reference a.mp4 --damaged b.mp4 --output d --json
expect_usage_error video repair --reference a.mp4 --damaged b.mp4 --output d --image x
expect_usage_error video repair --reference a.mp4 --damaged b.mp4 --output d --drive disk4
expect_usage_error video repair --reference a.mp4 --damaged b.mp4 --output d --expected-size 5
expect_usage_error video repair --reference a.mp4 --damaged b.mp4 --output d --all
expect_usage_error video repair --reference a.mp4 --damaged b.mp4 --output d --yaml
"$cli" help | grep -q "video repair" || fail "справка не упоминает video repair"
print "PASS: парсер video repair отклоняет неверные аргументы кодом 2"

# 2. Preflight: входы, папка результата, том-политика — код 1 и событие error.
mkdir -p "$test_dir/in" "$test_dir/scratch-preflight"
printf 'synthetic reference\n' > "$test_dir/in/reference.mp4"
printf 'synthetic damaged\n' > "$test_dir/in/damaged.mp4"
ln -s "$test_dir/in/reference.mp4" "$test_dir/in/damaged-alias.mp4"

expect_preflight_error() {
    local expected_code="$1"
    shift
    set +e
    run_video "$test_dir/scratch-preflight" "$test_dir/preflight.out" "$test_dir/preflight.err" \
        video repair --jsonl "$@"
    local rc=$?
    set -e
    [[ "$rc" -eq 1 ]] || fail "ожидался код 1 для: $* (получен $rc)"
    python3 - "$test_dir/preflight.out" "$expected_code" <<'PY'
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
assert event["code"] == sys.argv[2], event
assert isinstance(event["message"], str) and event["message"], event
PY
}
expect_preflight_error inputMissing \
    --reference "$test_dir/in/absent.mp4" --damaged "$test_dir/in/damaged.mp4" --output "$test_dir/in"
expect_preflight_error inputMissing \
    --reference "$test_dir/in/reference.mp4" --damaged "$test_dir/in/absent.mp4" --output "$test_dir/in"
expect_preflight_error inputNotRegularFile \
    --reference "$test_dir/in/reference.mp4" --damaged "$test_dir/in" --output "$test_dir/in"
expect_preflight_error sameInputFiles \
    --reference "$test_dir/in/reference.mp4" --damaged "$test_dir/in/reference.mp4" --output "$test_dir/in"
expect_preflight_error sameInputFiles \
    --reference "$test_dir/in/reference.mp4" --damaged "$test_dir/in/damaged-alias.mp4" --output "$test_dir/in"
expect_preflight_error outputFolderMissing \
    --reference "$test_dir/in/reference.mp4" --damaged "$test_dir/in/damaged.mp4" --output "$test_dir/absent-dir"
printf 'plain file\n' > "$test_dir/not-a-dir"
expect_preflight_error outputFolderIsFile \
    --reference "$test_dir/in/reference.mp4" --damaged "$test_dir/in/damaged.mp4" --output "$test_dir/not-a-dir"
# Тот же том: папка результата рядом с исходниками на внутреннем диске.
expect_preflight_error resultOnSourceVolume \
    --reference "$test_dir/in/reference.mp4" --damaged "$test_dir/in/damaged.mp4" --output "$test_dir/in"
print "PASS: preflight даёт код 1 и одиночное событие error со стабильным кодом"

# 3. Синтетический том: результат на другом носителе разрешён.
create_synthetic_volume
[[ -d "$volume_mount" ]] || fail "синтетический том не смонтировался"
volume_out="$volume_mount/out"
mkdir -p "$volume_out"

# Недоступный инструмент: отсутствие пути к untrunc (preflight на томе
# уже пройден, поэтому отказ даёт именно поиск инструмента).
mkdir -p "$volume_mount/notool"
set +e
env -u RECOVERYAPP_UNTRUNC_PATH "$cli" video repair \
    --reference "$test_dir/in/reference.mp4" --damaged "$test_dir/in/damaged.mp4" \
    --output "$volume_mount/notool" --jsonl > "$test_dir/no-tool.out" 2> "$test_dir/no-tool.err"
tool_rc=$?
set -e
[[ "$tool_rc" -eq 1 ]] || fail "ожидался код 1 при отсутствии untrunc (получен $tool_rc)"
grep -q '"code":"toolMissing"' "$test_dir/no-tool.out" \
    || fail "ожидается стабильный код toolMissing"
print "PASS: недоступный инструмент даёт код 1 и код ошибки toolMissing"

ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i testsrc2=size=320x240:rate=15 \
    -f lavfi -i sine=frequency=440:sample_rate=44100 \
    -t 2 -c:v libx264 -pix_fmt yuv420p -g 15 -c:a aac -b:a 96k \
    "$test_dir/in/reference.mp4"
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i testsrc2=size=320x240:rate=15 \
    -f lavfi -i sine=frequency=660:sample_rate=44100 \
    -t 2 -c:v libx264 -pix_fmt yuv420p -g 15 -c:a aac -b:a 96k \
    "$test_dir/in/original.mp4"
moov_offset="$(LC_ALL=C grep -abo moov "$test_dir/in/original.mp4" | tail -1 | cut -d: -f1)"
test -n "$moov_offset"
dd if="$test_dir/in/original.mp4" of="$test_dir/in/damaged.mp4" \
    bs=1 count="$((moov_offset - 4))" status=none
shasum -a 256 "$test_dir/in/reference.mp4" "$test_dir/in/damaged.mp4" > "$test_dir/before.sha256"

mkdir -p "$test_dir/scratch-e2e"
run_video "$test_dir/scratch-e2e" "$test_dir/e2e.out" "$test_dir/e2e.err" \
    video repair --reference "$test_dir/in/reference.mp4" \
    --damaged "$test_dir/in/damaged.mp4" --output "$volume_out" --jsonl
python3 - "$test_dir/e2e.out" "$test_dir/in/reference.mp4" "$test_dir/in/damaged.mp4" "$volume_out" <<'PY'
import json, os, sys

reference, damaged, out_dir = sys.argv[2:5]
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
started = events[0]
assert started["schemaVersion"] == 1, started
assert started["reference"] == os.path.realpath(reference), started
assert started["damaged"] == os.path.realpath(damaged), started
assert os.path.isabs(started["reference"]) and os.path.isabs(started["damaged"]), started
assert started["outputDirectory"] == os.path.realpath(out_dir), started
completed = events[-1]
result = completed["result"]
assert os.path.isabs(result), completed
assert os.path.basename(result).endswith("_recovered.mp4"), completed
print("PASS: JSONL схема видео: started/completed с абсолютными путями")
PY
grep -q "Info:" "$test_dir/e2e.out" \
    && fail "сырой вывод untrunc не должен попадать в stdout" || true
[[ -s "$test_dir/e2e.err" ]] || fail "stderr должен содержать вывод untrunc"
result_file="$volume_out/damaged_recovered.mp4"
test -f "$result_file"
stream_count="$(ffprobe -v error -show_entries stream=index -of csv=p=0 "$result_file" | wc -l | tr -d ' ')"
duration="$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$result_file")"
[[ "$stream_count" == "2" ]] || fail "ожидалось два потока (видео и аудио), получено $stream_count"
python3 - "$duration" <<'PY'
import sys

duration = float(sys.argv[1])
assert 1.5 <= duration <= 3.0, duration
print("PASS: ffprobe видит два потока и длительность ~2 c")
PY
shasum -a 256 "$test_dir/in/reference.mp4" "$test_dir/in/damaged.mp4" > "$test_dir/after.sha256"
cmp "$test_dir/before.sha256" "$test_dir/after.sha256" \
    || fail "входные файлы изменились после восстановления"
assert_no_artifacts() {
    local scratch="$1" label="$2"
    [[ -z "$(find "$scratch" -mindepth 1 -print -quit)" ]] \
        || fail "$label: в постороннем рабочем каталоге остались артефакты"
}
assert_no_artifacts "$test_dir/scratch-e2e" "end-to-end"
print "PASS: настоящий untrunc восстановил видео на другом томе, входы неизменны"

# 4. Повторный запуск: новое имя без перезаписи, прежний результат цел.
run_video "$test_dir/scratch-e2e" "$test_dir/e2e-2.out" "$test_dir/e2e-2.err" \
    video repair --reference "$test_dir/in/reference.mp4" \
    --damaged "$test_dir/in/damaged.mp4" --output "$volume_out" --jsonl
python3 - "$test_dir/e2e-2.out" "$volume_out" <<'PY'
import json, os, sys

events = []
with open(sys.argv[1], encoding="utf-8") as handle:
    for line in handle:
        line = line.strip()
        if line:
            events.append(json.loads(line))
kinds = [event["event"] for event in events]
assert kinds[-1] == "completed", kinds
result = events[-1]["result"]
assert os.path.basename(result).endswith("_recovered_2.mp4"), result
assert os.path.isfile(result), result
assert os.path.isfile(result.replace("_recovered_2", "_recovered")), "прежний результат пропал"
print("PASS: повторный запуск выбрал _recovered_2 без перезаписи")
PY
print "PASS: повторный запуск не перезаписывает существующий результат"

# 5. Отказ инструмента: код 1, error вместо completed, результат не
#    публикуется, недописанный файл текущей операции убирается.
shim_fail="$test_dir/tools/untrunc-fail"
cat > "$shim_fail" <<'SHIM'
#!/usr/bin/env python3
import sys

sys.stderr.write("Info: shim start\n")
sys.stderr.write("Error: broken input data\n")
sys.exit(7)
SHIM
chmod +x "$shim_fail"
mkdir -p "$test_dir/scratch-fail" "$volume_out/fail"
set +e
RECOVERYAPP_UNTRUNC_PATH="$shim_fail" \
    run_video "$test_dir/scratch-fail" "$test_dir/fail.out" "$test_dir/fail.err" \
    video repair --reference "$test_dir/in/reference.mp4" \
    --damaged "$test_dir/in/damaged.mp4" --output "$volume_out/fail" --jsonl
fail_rc=$?
set -e
[[ "$fail_rc" -eq 1 ]] || fail "ожидался код 1 при отказе инструмента (получен $fail_rc)"
python3 - "$test_dir/fail.out" "$volume_out/fail" <<'PY'
import json, os, sys

events = []
with open(sys.argv[1], encoding="utf-8") as handle:
    for line in handle:
        line = line.strip()
        if line:
            events.append(json.loads(line))
kinds = [event["event"] for event in events]
assert kinds[-1] == "error", kinds
assert "completed" not in kinds and "cancelled" not in kinds, kinds
assert kinds[0] == "started", kinds
assert events[-1]["code"] == "toolFailed", events[-1]
out_dir = sys.argv[2]
published = [name for name in os.listdir(out_dir) if "_recovered" in name]
assert published == [], published
print("PASS: отказ инструмента не публикует результат и убирает свой недописанный файл")
PY
[[ -z "$(find "$volume_out/fail" -name '*_recovered*' -print -quit)" ]] \
    || fail "после отказа инструмента не должно быть файла результата"
assert_no_artifacts "$test_dir/scratch-fail" "отказ инструмента"
print "PASS: отказ инструмента даёт код 1 без опубликованного результата"

# 6. Имитация нехватки места: текст ошибки распознаётся как ENOSPC.
shim_nospace="$test_dir/tools/untrunc-nospace"
cat > "$shim_nospace" <<'SHIM'
#!/usr/bin/env python3
import sys

sys.stderr.write("Error writing file: No space left on device\n")
sys.exit(1)
SHIM
chmod +x "$shim_nospace"
mkdir -p "$test_dir/scratch-space" "$volume_out/space"
set +e
RECOVERYAPP_UNTRUNC_PATH="$shim_nospace" \
    run_video "$test_dir/scratch-space" "$test_dir/space.out" "$test_dir/space.err" \
    video repair --reference "$test_dir/in/reference.mp4" \
    --damaged "$test_dir/in/damaged.mp4" --output "$volume_out/space" --jsonl
space_rc=$?
set -e
[[ "$space_rc" -eq 1 ]] || fail "ожидался код 1 при нехватке места (получен $space_rc)"
grep -q '"code":"outputSpaceExhausted"' "$test_dir/space.out" \
    || fail "ожидается стабильный код outputSpaceExhausted"
print "PASS: имитация нехватки места распознаётся как outputSpaceExhausted"

# 7. Потоковый started: событие появляется в stdout до завершения процесса.
shim_slow="$test_dir/tools/untrunc-slow"
cat > "$shim_slow" <<'SHIM'
#!/usr/bin/env python3
import os, shutil, sys, time

args = sys.argv[1:]
dst = None
for index, token in enumerate(args):
    if token == "-dst":
        dst = args[index + 1]
time.sleep(3)
shutil.copyfile(args[-2], dst)
sys.exit(0)
SHIM
chmod +x "$shim_slow"
mkdir -p "$test_dir/scratch-stream" "$volume_out/stream"
# Прямая подоболочка с exec: $! — pid CLI, как в реальном терминале.
(
    cd "$test_dir/scratch-stream" || exit 97
    exec env RECOVERYAPP_UNTRUNC_PATH="$shim_slow" "$cli" video repair \
        --reference "$test_dir/in/reference.mp4" \
        --damaged "$test_dir/in/damaged.mp4" \
        --output "$volume_out/stream" --jsonl \
        > "$test_dir/stream.out" 2> "$test_dir/stream.err"
) &
video_pid=$!
started_seen=no
for _ in {1..150}; do
    if grep -q '"event":"started"' "$test_dir/stream.out" 2>/dev/null; then
        started_seen=yes
        break
    fi
    if ! kill -0 "$video_pid" 2>/dev/null; then
        break
    fi
    sleep 0.1
done
[[ "$started_seen" == yes ]] || fail "started не появился в stdout до завершения процесса"
kill -0 "$video_pid" 2>/dev/null || fail "процесс завершился до появления started — событие не потоковое"
set +e
wait "$video_pid"
stream_rc=$?
set -e
[[ "$stream_rc" -eq 0 ]] || fail "медленный успешный запуск должен дать код 0 (получен $stream_rc)"
grep -q '"event":"completed"' "$test_dir/stream.out" || fail "нет completed после успешного запуска"
print "PASS: событие started поступает потоком до завершения операции"

# 8. Ctrl-C: код 130, cancelled, живых PID нет, недописанный файл убран.
shim_hang="$test_dir/tools/untrunc-hang"
cat > "$shim_hang" <<'SHIM'
#!/usr/bin/env python3
import os, sys, time

pid_file = os.environ["VIDEO_CLI_PIDFILE"]
with open(pid_file, "w") as handle:
    handle.write(str(os.getpid()))
time.sleep(60)
SHIM
chmod +x "$shim_hang"
mkdir -p "$test_dir/scratch-cancel" "$volume_out/cancel"
export VIDEO_CLI_PIDFILE="$test_dir/shim.pid"
# Прямая подоболочка с exec: $! становится pid самого CLI.
(
    cd "$test_dir/scratch-cancel" || exit 97
    exec env RECOVERYAPP_UNTRUNC_PATH="$shim_hang" "$cli" video repair \
        --reference "$test_dir/in/reference.mp4" \
        --damaged "$test_dir/in/damaged.mp4" \
        --output "$volume_out/cancel" --jsonl \
        > "$test_dir/cancel.out" 2> "$test_dir/cancel.err"
) &
video_pid=$!
for _ in {1..100}; do
    [[ -s "$VIDEO_CLI_PIDFILE" ]] && break
    sleep 0.1
done
[[ -s "$VIDEO_CLI_PIDFILE" ]] || fail "shim не сообщил свой PID"
shim_pid="$(cat "$VIDEO_CLI_PIDFILE")"
grep -q '"event":"started"' "$test_dir/cancel.out" || fail "нет started до отмены"
sleep 0.3
kill -INT "$video_pid" || fail "не удалось отправить SIGINT процессу CLI"
set +e
wait "$video_pid"
cancel_rc=$?
set -e
unset VIDEO_CLI_PIDFILE
[[ "$cancel_rc" -eq 130 ]] || fail "ожидался код 130 после Ctrl-C (получен $cancel_rc)"
shim_gone=no
for _ in {1..50}; do
    if ! kill -0 "$shim_pid" 2>/dev/null; then
        shim_gone=yes
        break
    fi
    sleep 0.1
done
[[ "$shim_gone" == yes ]] || fail "после Ctrl-C остался живой дочерний процесс untrunc"
if pgrep -f "$shim_hang" >/dev/null 2>&1; then
    fail "pgrep находит живой shim после Ctrl-C"
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
cancelled = events[-1]
assert cancelled["schemaVersion"] == 1, cancelled
assert "result" not in cancelled, cancelled
print("PASS: итоговое событие cancelled без недописанного результата")
PY
[[ -z "$(find "$volume_out/cancel" -name '*_recovered*' -print -quit)" ]] \
    || fail "недописанный файл текущей операции должен быть убран"
assert_no_artifacts "$test_dir/scratch-cancel" "отмена"
print "PASS: Ctrl-C даёт код 130, не оставляет процессов и недописанных файлов"

# 9. Текстовый режим: краткий русский вывод с путём результата.
mkdir -p "$test_dir/scratch-text"
run_video "$test_dir/scratch-text" "$test_dir/text.out" "$test_dir/text.err" \
    video repair --reference "$test_dir/in/reference.mp4" \
    --damaged "$test_dir/in/damaged.mp4" --output "$volume_out"
grep -q "Видео восстановлено" "$test_dir/text.out" \
    || fail "текстовый режим: нет сообщения об успехе"
grep -q "_recovered_3.mp4" "$test_dir/text.out" \
    || fail "текстовый режим: путь результата должен указывать на _recovered_3.mp4"
assert_no_artifacts "$test_dir/scratch-text" "текстовый режим"
print "PASS: текстовый режим печатает русский итог с путём результата"

detach_synthetic_volume
print "PASS: все проверки video repair CLI прошли"
echo "result=$test_dir"
