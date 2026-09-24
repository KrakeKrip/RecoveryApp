#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
real_untrunc="$project_dir/ThirdParty/untrunc/bin/arm64/untrunc"
test_dir="${VIDEO_CLI_TEST_DIR:-$project_dir/work/tests/video-cli-$RANDOM-$$}"
cache_dir="${BUILD_CACHE_DIR:-$project_dir/work/swift-video-cli}"

for command_name in ffmpeg ffprobe python3 clang pgrep diskutil hdiutil; do
    command -v "$command_name" >/dev/null || {
        echo "Для теста нужен $command_name" >&2
        exit 1
    }
done
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

# Синтетические носители (никаких пользовательских накопителей):
# 1) ASIF-образ на внутреннем диске — его том имеет ДРУГОЙ st_dev, но лежит
#    на том же ФИЗИЧЕСКОМ носителе, что и входные файлы, поэтому политика
#    должна отказывать (регрессия сравнения томов вместо дисков);
# 2) RAM-диск — действительно другой носитель (память), на нём проверяется
#    успешный путь. Образ живёт внутри test_dir.
image_file="$test_dir/volume.asif"
image_mount="$test_dir/image-mnt"
ram_sectors=98304   # 48 MiB
ram_device=""
ram_verified=no
ram_mount=""

create_image_volume() {
    if diskutil image create blank --format ASIF --fs APFS --size 32m \
        --volumeName VIDIMG "$image_file" >/dev/null 2>&1; then
        mkdir -p "$image_mount"
        diskutil image attach "$image_file" -mountPoint "$image_mount" \
            -mountOptions nobrowse >/dev/null
    else
        image_file="$test_dir/volume.dmg"
        hdiutil create -size 32m -fs 'FAT32' -volname VIDIMG \
            -o "$image_file" -ov -quiet
        mkdir -p "$image_mount"
        hdiutil attach "$image_file" -mountpoint "$image_mount" \
            -nobrowse -noautoopen -quiet
    fi
}

# RAM-диск: до форматирования доказывается, что устройство принадлежит
# ram://-образу с запрошенным размером и появилось только в этом запуске
# (снимок hdiutil info до/после подключения); точка монтирования берётся из
# diskutil по фактическому контейнеру, а не из предположения /Volumes/VIDCLI.
create_ram_volume() {
    local before_plist="$test_dir/ram-before.plist"
    local after_plist="$test_dir/ram-after.plist"
    hdiutil info -plist > "$before_plist" 2>/dev/null \
        || fail "не удалось прочитать hdiutil info до подключения RAM-диска"
    ram_device="$(hdiutil attach -nomount "ram://$ram_sectors" 2>/dev/null | awk 'NR==1{print $1}')"
    [[ "$ram_device" == /dev/disk* ]] \
        || fail "hdiutil attach не вернул устройство RAM-диска (получено: «$ram_device»)"
    hdiutil info -plist > "$after_plist" 2>/dev/null \
        || fail "не удалось прочитать hdiutil info после подключения RAM-диска"
    python3 - "$ram_device" "$ram_sectors" "$before_plist" "$after_plist" <<'PY' \
        || fail "не удалось доказать, что $ram_device — RAM-диск этого запуска (проверьте hdiutil info вручную)"
import plistlib
import sys

device, sectors, before_path, after_path = sys.argv[1:5]
expected = f"ram://{sectors}"

def image_devices(path):
    with open(path, "rb") as handle:
        plist = plistlib.load(handle)
    mapping = {}
    for image in plist.get("images", []):
        image_path = image.get("image-path", "")
        for entity in image.get("system-entities", []):
            entry = entity.get("dev-entry", "")
            if entry:
                mapping[entry] = image_path
    return mapping

before = image_devices(before_path)
after = image_devices(after_path)
assert device in after, f"{device} отсутствует в hdiutil info после подключения"
assert after[device] == expected, f"{device} принадлежит {after[device]!r}, ожидался {expected}"
assert device not in before, f"{device} существовал до подключения этого запуска"
print(f"RAM-диск проверен: {device} = {expected}")
PY
    ram_verified=yes
    diskutil eraseVolume APFS VIDCLI "$ram_device" >/dev/null \
        || fail "не удалось отформатировать проверенный RAM-диск $ram_device"

    # Фактический контейнер и точка монтирования: имя тома могло получить
    # суффикс, а контейнер — другой номер диска.
    local ram_container
    ram_container="$(diskutil info -plist "$ram_device" 2>/dev/null | python3 -c '
import plistlib, sys

plist = plistlib.loads(sys.stdin.buffer.read())
print(plist.get("APFSContainerReference") or "")
' 2>/dev/null || true)"
    [[ -n "$ram_container" ]] \
        || fail "RAM-носитель $ram_device не дал APFS-контейнера"
    ram_mount="$(diskutil list -plist "$ram_container" 2>/dev/null | python3 -c '
import plistlib, sys

plist = plistlib.loads(sys.stdin.buffer.read())
for disk in plist.get("AllDisksAndPartitions", []):
    for key in ("APFSVolumes", "Partitions"):
        for volume in disk.get(key) or []:
            mount = volume.get("MountPoint") or ""
            if mount:
                print(mount)
                sys.exit(0)
sys.exit(1)
')" || fail "не найдена фактическая точка монтирования RAM-тома $ram_container"
    [[ -n "$ram_mount" && -d "$ram_mount" ]] \
        || fail "точка монтирования RAM-тома не является каталогом: «$ram_mount»"
}

detach_all_volumes() {
    # Образ: отсоединяется по своей точке монтирования и файлу образа,
    # которые живут внутри test_dir и создаются только этим запуском.
    if [[ -d "$image_mount" ]]; then
        for _ in {1..5}; do
            hdiutil detach "$image_mount" -quiet >/dev/null 2>&1 && break
            diskutil image detach "$image_file" >/dev/null 2>&1 && break
            sleep 1
        done
    fi
    # RAM-диск: отсоединяется ТОЛЬКО устройство, принадлежность которого
    # доказана этим запуском (ram_verified=yes). При ранней ошибке до
    # завершения проверки ничего не отсоединяется: оставить собственный
    # носитель безопаснее, чем отсоединить чужой диск по непроверенному пути.
    if [[ "$ram_verified" == yes && -n "$ram_device" ]]; then
        for _ in {1..5}; do
            hdiutil detach "$ram_device" -quiet >/dev/null 2>&1 && return 0
            diskutil eject "$ram_device" >/dev/null 2>&1 && return 0
            sleep 1
        done
        hdiutil detach "$ram_device" -force -quiet >/dev/null 2>&1 || true
    fi
}
trap detach_all_volumes EXIT

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

assert_no_artifacts() {
    local scratch="$1" label="$2"
    [[ -z "$(find "$scratch" -mindepth 1 -print -quit)" ]] \
        || fail "$label: в постороннем рабочем каталоге остались артефакты"
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

# 2. Preflight: входы и папка результата — код 1 и событие error.
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

# 3. Физический носитель: том образа на внутреннем диске имеет ДРУГОЙ st_dev,
#    но тот же физический носитель, поэтому политика должна отказывать
#    (регрессия сравнения томов вместо дисков).
create_image_volume
image_out="$image_mount/out"
mkdir -p "$image_out"
inputs_volume="$(df -k "$test_dir/in" | awk 'NR==2{print $1}')"
image_volume="$(df -k "$image_out" | awk 'NR==2{print $1}')"
[[ "$inputs_volume" != "$image_volume" ]] \
    || fail "тестовая конфигурация: образ и входы оказались на одном томе"
set +e
run_video "$test_dir/scratch-preflight" "$test_dir/image.out" "$test_dir/image.err" \
    video repair --reference "$test_dir/in/reference.mp4" \
    --damaged "$test_dir/in/damaged.mp4" --output "$image_out" --jsonl
image_rc=$?
set -e
[[ "$image_rc" -eq 1 ]] || fail "ожидался код 1 для образа на том же диске (получен $image_rc)"
grep -q '"code":"resultOnSourceVolume"' "$test_dir/image.out" \
    || fail "образ на том же физическом диске должен отклоняться как resultOnSourceVolume"
print "PASS: другой том (образ) на том же физическом диске отклоняется"

# 4. RAM-диск — действительно другой носитель: успешный путь с настоящим
#    untrunc, ffprobe и неизменными входами.
create_ram_volume
ram_volume_device="$(df -k "$ram_mount" | awk 'NR==2{print $1}')"
[[ -n "$ram_volume_device" && "$ram_volume_device" != "$inputs_volume" ]] \
    || fail "тестовая конфигурация: RAM-том на устройстве входов ($ram_volume_device)"
volume_out="$ram_mount/out"
mkdir -p "$volume_out"

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
assert_no_artifacts "$test_dir/scratch-e2e" "end-to-end"
print "PASS: настоящий untrunc восстановил видео на другом носителе, входы неизменны"

# 5. Повторный запуск: новое имя без перезаписи, прежний результат цел.
run_video "$test_dir/scratch-e2e" "$test_dir/e2e-2.out" "$test_dir/e2e-2.err" \
    video repair --reference "$test_dir/in/reference.mp4" \
    --damaged "$test_dir/in/damaged.mp4" --output "$volume_out" --jsonl
python3 - "$test_dir/e2e-2.out" <<'PY'
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

# 6. Недоступный инструмент: отсутствие пути к untrunc (preflight на RAM-томе
#    уже пройден, поэтому отказ даёт именно поиск инструмента).
mkdir -p "$ram_mount/notool"
set +e
env -u RECOVERYAPP_UNTRUNC_PATH "$cli" video repair \
    --reference "$test_dir/in/reference.mp4" --damaged "$test_dir/in/damaged.mp4" \
    --output "$ram_mount/notool" --jsonl > "$test_dir/no-tool.out" 2> "$test_dir/no-tool.err"
tool_rc=$?
set -e
[[ "$tool_rc" -eq 1 ]] || fail "ожидался код 1 при отсутствии untrunc (получен $tool_rc)"
grep -q '"code":"toolMissing"' "$test_dir/no-tool.out" \
    || fail "ожидается стабильный код toolMissing"
print "PASS: недоступный инструмент даёт код 1 и код ошибки toolMissing"

# 7. Отказ инструмента: код 1, error вместо completed, результат не
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

# 8. «Молчаливый успех»: untrunc вернул 0, ничего не записав — плейсхолдер
#    пуст, результат не публикуется (регрессия пустого файла результата).
shim_silent="$test_dir/tools/untrunc-silent"
cat > "$shim_silent" <<'SHIM'
#!/usr/bin/env python3
import sys

sys.stderr.write("Info: shim exited without writing\n")
sys.exit(0)
SHIM
chmod +x "$shim_silent"
mkdir -p "$test_dir/scratch-silent" "$volume_out/silent"
set +e
RECOVERYAPP_UNTRUNC_PATH="$shim_silent" \
    run_video "$test_dir/scratch-silent" "$test_dir/silent.out" "$test_dir/silent.err" \
    video repair --reference "$test_dir/in/reference.mp4" \
    --damaged "$test_dir/in/damaged.mp4" --output "$volume_out/silent" --jsonl
silent_rc=$?
set -e
[[ "$silent_rc" -eq 1 ]] || fail "ожидался код 1 при пустом результате (получен $silent_rc)"
python3 - "$test_dir/silent.out" "$volume_out/silent" <<'PY'
import json, os, sys

events = []
with open(sys.argv[1], encoding="utf-8") as handle:
    for line in handle:
        line = line.strip()
        if line:
            events.append(json.loads(line))
kinds = [event["event"] for event in events]
assert kinds[0] == "started", kinds
assert kinds[-1] == "error", kinds
assert events[-1]["code"] == "resultMissing", events[-1]
assert "completed" not in kinds and "cancelled" not in kinds, kinds
out_dir = sys.argv[2]
published = [name for name in os.listdir(out_dir) if "_recovered" in name]
assert published == [], published
print("PASS: пустой файл после кода 0 не публикуется как результат")
PY
[[ -z "$(find "$volume_out/silent" -name '*_recovered*' -print -quit)" ]] \
    || fail "пустой плейсхолдер должен быть убран"
assert_no_artifacts "$test_dir/scratch-silent" "молчаливый успех"
print "PASS: код 0 без данных даёт resultMissing без публикации"

# 9. Имитация нехватки места: текст ошибки распознаётся как ENOSPC.
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

# 10. Потоковый started: событие появляется в stdout до завершения процесса.
shim_slow="$test_dir/tools/untrunc-slow"
cat > "$shim_slow" <<'SHIM'
#!/usr/bin/env python3
import shutil, sys, time

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

# 11. Ctrl-C с дочерним процессом: группа tool-launcher/untrunc/shim-ребёнок
#     останавливается целиком, код 130, недописанный файл убран.
shim_hang="$test_dir/tools/untrunc-hang"
cat > "$shim_hang" <<'SHIM'
#!/usr/bin/env python3
import os, subprocess, time

pid_file = os.environ["VIDEO_CLI_PIDFILE"]
child = subprocess.Popen(["sleep", "60"])
with open(pid_file, "w") as handle:
    handle.write(f"{os.getpid()} {child.pid}\n")
time.sleep(60)
SHIM
chmod +x "$shim_hang"
mkdir -p "$test_dir/scratch-cancel" "$volume_out/cancel"
export VIDEO_CLI_PIDFILE="$test_dir/shim.pid"
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
if ! read -r shim_pid child_pid < "$VIDEO_CLI_PIDFILE"; then
    fail "не удалось прочитать PID shim и ребёнка"
fi
test -n "$shim_pid" && test -n "$child_pid" || fail "PID shim и ребёнка не получены"
grep -q '"event":"started"' "$test_dir/cancel.out" || fail "нет started до отмены"
sleep 0.3
kill -INT "$video_pid" || fail "не удалось отправить SIGINT процессу CLI"
set +e
wait "$video_pid"
cancel_rc=$?
set -e
unset VIDEO_CLI_PIDFILE
[[ "$cancel_rc" -eq 130 ]] || fail "ожидался код 130 после Ctrl-C (получен $cancel_rc)"
all_gone=no
for _ in {1..50}; do
    if ! kill -0 "$shim_pid" 2>/dev/null && ! kill -0 "$child_pid" 2>/dev/null; then
        all_gone=yes
        break
    fi
    sleep 0.1
done
[[ "$all_gone" == yes ]] || fail "после Ctrl-C остался живой shim или его дочерний процесс"
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
print "PASS: Ctrl-C даёт код 130 и останавливает shim вместе с дочерним процессом"

# 12. Текстовый режим: краткий русский вывод с путём результата.
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

detach_all_volumes
print "PASS: все проверки video repair CLI прошли"
echo "result=$test_dir"
