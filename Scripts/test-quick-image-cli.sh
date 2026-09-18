#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
tools_dir="$project_dir/ThirdParty/sleuthkit/bin/arm64"
test_dir="${QUICK_IMAGE_TEST_DIR:-$project_dir/work/tests/quick-image-cli-$RANDOM-$$}"
cache_dir="${BUILD_CACHE_DIR:-$project_dir/work/swift-quick-cli}"

for command_name in mformat mmd mcopy mdel xz python3; do
    command -v "$command_name" >/dev/null || {
        echo "Для теста нужен $command_name" >&2
        exit 1
    }
done
test -x "$tools_dir/mmls" && test -x "$tools_dir/fls" && test -x "$tools_dir/icat"

export SDKROOT="${RECOVERYAPP_SDKROOT:-$(xcrun --show-sdk-path)}"
mkdir -p "$cache_dir/module-cache"
export CLANG_MODULE_CACHE_PATH="$cache_dir/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$cache_dir/module-cache"
swift build --disable-sandbox --scratch-path "$cache_dir" -c debug --product recoveryapp-cli
cli="$(swift build --disable-sandbox --scratch-path "$cache_dir" -c debug --product recoveryapp-cli --show-bin-path)/recoveryapp-cli"

# Точные пути встроенных инструментов передаются только переменными окружения.
export RECOVERYAPP_MMLS_PATH="$tools_dir/mmls"
export RECOVERYAPP_FLS_PATH="$tools_dir/fls"
export RECOVERYAPP_ICAT_PATH="$tools_dir/icat"

mkdir -p "$test_dir/originals" "$test_dir/result"

fail() {
    print -u2 "FAIL: $1"
    exit 1
}

# 1. Синтетический FAT32 с двумя удалёнными файлами, один во вложенной папке.
printf '%s\n' \
    'RECOVERYAPP-QUICK-CLI-FAT32' \
    'Полностью синтетические данные. Контроль: quick-cli-482917.' \
    > "$test_dir/originals/RECOVERY.TXT"
printf '%s\n' \
    'RECOVERYAPP-QUICK-CLI-FAT32-REPORT' \
    'Вторая контрольная запись: quick-cli-report-913257.' \
    > "$test_dir/originals/REPORT.TXT"
fat_image="$test_dir/fat32-deleted.img"
mformat -i "$fat_image" -C -F -v QUICKCLI -T 262144 ::
mmd -i "$fat_image" ::/DOCS
mcopy -i "$fat_image" "$test_dir/originals/RECOVERY.TXT" ::/RECOVERY.TXT
mcopy -i "$fat_image" "$test_dir/originals/REPORT.TXT" ::/DOCS/REPORT.TXT
mdel -i "$fat_image" ::/RECOVERY.TXT ::/DOCS/REPORT.TXT

# 2. quick scan --json: схема, абсолютный source, тип ФС и смещение.
"$cli" quick scan --image "$fat_image" --json > "$test_dir/fat32-scan.json" \
    2> "$test_dir/fat32-scan.err"
[[ ! -s "$test_dir/fat32-scan.err" ]] || fail "scan --json: stderr должен быть пустым"
python3 - "$test_dir/fat32-scan.json" "$fat_image" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)
assert report["schemaVersion"] == 1, report
assert report["source"] == sys.argv[2], report
candidates = report["candidates"]
assert len(candidates) == 2, candidates
paths = {candidate["path"] for candidate in candidates}
assert paths == {"_ECOVERY.TXT", "DOCS/_EPORT.TXT"}, paths
for candidate in candidates:
    assert candidate["filesystemType"] == "fat32", candidate
    assert candidate["partitionOffset"] == 0, candidate
    assert candidate["inode"].isdigit(), candidate
    assert candidate["displayName"] == candidate["path"].split("/")[-1], candidate
print("PASS: quick scan --json FAT32 соответствует схеме")
PY

# 3. Человекочитаемый scan на русском.
scan_text="$("$cli" quick scan --image "$fat_image")"
[[ "$scan_text" == *"Найдено удалённых файлов: 2"* ]] \
    || fail "scan: неожиданный вывод: $scan_text"
print "PASS: quick scan печатает русскую сводку"

# 4. quick recover --all --json: восстановление и точное содержимое.
"$cli" quick recover --image "$fat_image" --output "$test_dir/result" --all --json \
    > "$test_dir/fat32-recover.json" 2> "$test_dir/fat32-recover.err"
[[ ! -s "$test_dir/fat32-recover.err" ]] || fail "recover --json: stderr должен быть пустым"
python3 - "$test_dir/fat32-recover.json" "$test_dir/result" <<'PY'
import json
import os
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)
assert report["schemaVersion"] == 1, report
assert report["outputDirectory"] == sys.argv[2], report
assert report["recoveredCount"] == 2, report
for path in report["files"]:
    assert os.path.isabs(path), path
    assert os.path.isfile(path), path
print("PASS: quick recover --json FAT32 соответствует схеме")
PY
cmp "$test_dir/originals/RECOVERY.TXT" "$test_dir/result/_ECOVERY.TXT"
cmp "$test_dir/originals/REPORT.TXT" "$test_dir/result/_EPORT.TXT"
print "PASS: FAT32 файлы совпадают побайтно с эталоном"

# 5. Повторный запуск не перезаписывает: новые имена _2, прежние файлы целы.
"$cli" quick recover --image "$fat_image" --output "$test_dir/result" --all --json \
    > "$test_dir/fat32-recover-2.json"
python3 - "$test_dir/fat32-recover-2.json" "$test_dir/result" <<'PY'
import json
import os
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)
assert report["recoveredCount"] == 2, report
names = {os.path.basename(path) for path in report["files"]}
assert names == {"_ECOVERY_2.TXT", "_EPORT_2.TXT"}, names
PY
cmp "$test_dir/originals/RECOVERY.TXT" "$test_dir/result/_ECOVERY.TXT"
cmp "$test_dir/originals/RECOVERY.TXT" "$test_dir/result/_ECOVERY_2.TXT"
cmp "$test_dir/originals/REPORT.TXT" "$test_dir/result/_EPORT.TXT"
cmp "$test_dir/originals/REPORT.TXT" "$test_dir/result/_EPORT_2.TXT"
print "PASS: повторный запуск не перезаписывает и снова совпадает побайтно"

# 6. Синтетический GPT/exFAT из зафиксированной фикстуры.
exfat_before="$test_dir/exfat-before.dmg"
exfat_deleted="$test_dir/exfat-deleted.dmg"
xz -dc "$project_dir/Tests/Fixtures/exfat-before-files.dmg.xz" > "$exfat_before"
"$project_dir/Scripts/make-deleted-exfat-fixture.py" \
    "$exfat_before" "$exfat_deleted" --delete RECOVERY_NOTE.TXT \
    > "$test_dir/exfat-fixture.stdout"
mkdir -p "$test_dir/result-exfat"
"$cli" quick scan --image "$exfat_deleted" --json > "$test_dir/exfat-scan.json"
python3 - "$test_dir/exfat-scan.json" "$exfat_deleted" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)
assert report["schemaVersion"] == 1, report
assert report["source"] == sys.argv[2], report
matches = [c for c in report["candidates"] if c["path"] == "RECOVERY_NOTE.TXT"]
assert len(matches) == 1, report
candidate = matches[0]
assert candidate["filesystemType"] == "exfat", candidate
assert candidate["partitionOffset"] == 2048, candidate
assert candidate["inode"].isdigit(), candidate
print(candidate["inode"])
PY
exfat_inode="$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print([c["inode"] for c in r["candidates"] if c["path"]=="RECOVERY_NOTE.TXT"][0])' "$test_dir/exfat-scan.json")"
"$cli" quick recover --image "$exfat_deleted" --output "$test_dir/result-exfat" --all --json \
    > "$test_dir/exfat-recover.json"
"$tools_dir/icat" -r -f exfat -o 2048 "$exfat_before" "$exfat_inode" \
    > "$test_dir/exfat-reference.txt"
test -s "$test_dir/exfat-reference.txt"
cmp "$test_dir/exfat-reference.txt" "$test_dir/result-exfat/RECOVERY_NOTE.TXT"
print "PASS: GPT/exFAT найден и восстановлен побайтно"

# 7. Ошибочные аргументы и окружение: код 2.
expect_usage_error() {
    set +e
    "$cli" "$@" > /dev/null 2> "$test_dir/usage.err"
    local rc=$?
    set -e
    [[ "$rc" -eq 2 ]] || fail "ожидался код 2 для: $* (получен $rc)"
}
expect_usage_error quick scan
expect_usage_error quick scan --image
expect_usage_error quick scan --image "$fat_image" --all
expect_usage_error quick scan --image "$fat_image" --output "$test_dir/result"
expect_usage_error quick recover --image "$fat_image" --output "$test_dir/result"
expect_usage_error quick recover --output "$test_dir/result" --all
expect_usage_error quick recover --image "$fat_image" --all
expect_usage_error quick scan --image "$fat_image" --yaml
expect_usage_error quick show --image "$fat_image"
expect_usage_error quick scan --image --json
expect_usage_error quick scan --image --all
expect_usage_error quick recover --image "$fat_image" --output --all
print "PASS: ошибочные и конфликтующие аргументы дают код 2"

# 8. Ошибки выполнения: код 1.
expect_runtime_error() {
    set +e
    "$cli" "$@" > /dev/null 2> "$test_dir/runtime.err"
    local rc=$?
    set -e
    [[ "$rc" -eq 1 ]] || fail "ожидался код 1 для: $* (получен $rc)"
}
expect_runtime_error quick scan --image "$test_dir/absent.img"
expect_runtime_error quick scan --image "$test_dir"
expect_runtime_error quick recover --image "$fat_image" --output "$test_dir/absent-dir" --all
expect_runtime_error quick recover --image "$fat_image" --output "$fat_image" --all
env -u RECOVERYAPP_FLS_PATH "$cli" quick scan --image "$fat_image" > /dev/null 2>&1 \
    && fail "без RECOVERYAPP_FLS_PATH ожидался код 1" \
    || true
print "PASS: ошибки выполнения дают код 1, включая отсутствие пути инструмента"

print "PASS: все проверки quick image CLI прошли"
echo "result=$test_dir"
