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

# 1. Синтетический FAT32: два текстовых файла и пустой файл, все удалены.
printf '%s\n' \
    'RECOVERYAPP-QUICK-CLI-FAT32' \
    'Полностью синтетические данные. Контроль: quick-cli-482917.' \
    > "$test_dir/originals/RECOVERY.TXT"
printf '%s\n' \
    'RECOVERYAPP-QUICK-CLI-FAT32-REPORT' \
    'Вторая контрольная запись: quick-cli-report-913257.' \
    > "$test_dir/originals/REPORT.TXT"
: > "$test_dir/originals/EMPTY.TXT"
fat_image="$test_dir/fat32-deleted.img"
mformat -i "$fat_image" -C -F -v QUICKCLI -T 262144 ::
mmd -i "$fat_image" ::/DOCS
mcopy -i "$fat_image" "$test_dir/originals/RECOVERY.TXT" ::/RECOVERY.TXT
mcopy -i "$fat_image" "$test_dir/originals/REPORT.TXT" ::/DOCS/REPORT.TXT
mcopy -i "$fat_image" "$test_dir/originals/EMPTY.TXT" ::/EMPTY.TXT
mdel -i "$fat_image" ::/RECOVERY.TXT ::/DOCS/REPORT.TXT ::/EMPTY.TXT

# 2. quick scan --json: схема, абсолютный source, тип ФС и ожидаемые размеры.
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
assert len(candidates) == 3, candidates
paths = {candidate["path"] for candidate in candidates}
assert paths == {"_ECOVERY.TXT", "DOCS/_EPORT.TXT", "_MPTY.TXT"}, paths
for candidate in candidates:
    assert candidate["filesystemType"] == "fat32", candidate
    assert candidate["partitionOffset"] == 0, candidate
    assert candidate["inode"].isdigit(), candidate
    assert candidate["displayName"] == candidate["path"].split("/")[-1], candidate
    # Ноль в fls -l означает отсутствие метаданных размера: парсер отдаёт
    # null (ключ опускается) либо положительное число.
    expected = candidate.get("expectedSize")
    assert expected is None or (isinstance(expected, int) and expected > 0), candidate
print("PASS: quick scan --json FAT32 соответствует схеме с ожидаемыми размерами")
PY

# 3. Человекочитаемый scan на русском.
scan_text="$("$cli" quick scan --image "$fat_image")"
[[ "$scan_text" == *"Найдено удалённых файлов: 3"* ]] \
    || fail "scan: неожиданный вывод: $scan_text"
print "PASS: quick scan печатает русскую сводку"

# 4. quick recover --all --json: восстановление, точное содержимое и статусы.
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
assert report["recoveredCount"] == 3, report
assert len(report["files"]) == 3, report
for path in report["files"]:
    assert os.path.isabs(path), path
    assert os.path.isfile(path), path
items = report["items"]
assert len(items) == 3, report
def expected_status(expected, actual):
    if expected is None or actual is None:
        return "sizeUnknown"
    if expected == 0 and actual == 0:
        return "expectedEmpty"
    if actual == expected:
        return "sizeMatches"
    if actual < expected:
        return "incomplete"
    return "sizeMismatch"
by_name = {os.path.basename(item["path"]): item for item in items}
assert by_name["_MPTY.TXT"].get("expectedSize") is None, by_name
assert by_name["_MPTY.TXT"]["actualSize"] == 0, by_name
assert by_name["_MPTY.TXT"]["status"] == "sizeUnknown", by_name
for item in items:
    actual = os.path.getsize(item["path"])
    assert item["actualSize"] == actual, item
    assert item["status"] == expected_status(item.get("expectedSize"), actual), item
counts = report["statusCounts"]
assert counts["expectedEmpty"] == 0, counts
assert counts["sizeUnknown"] == 1, counts
assert sum(counts.values()) == report["recoveredCount"], report
print("PASS: quick recover --json FAT32 соответствует схеме со статусами")
PY
cmp "$test_dir/originals/RECOVERY.TXT" "$test_dir/result/_ECOVERY.TXT"
cmp "$test_dir/originals/REPORT.TXT" "$test_dir/result/_EPORT.TXT"
cmp "$test_dir/originals/EMPTY.TXT" "$test_dir/result/_MPTY.TXT"
print "PASS: FAT32 файлы совпадают побайтно с эталоном"

# 4b. Регрессия маленького образа: автоопределение TSK не работает для
#     части FAT32-образов (mformat 32 МиБ), тип ФС из скана передаётся
#     icat явно. Без исправления восстановление падает с ошибкой icat.
small_image="$test_dir/fat32-small.img"
mformat -i "$small_image" -C -F -v SMALLCLI -T 65536 ::
mcopy -i "$small_image" "$test_dir/originals/RECOVERY.TXT" ::/RECOVERY.TXT
mdel -i "$small_image" ::/RECOVERY.TXT
mkdir -p "$test_dir/result-small"
"$cli" quick recover --image "$small_image" --output "$test_dir/result-small" --all --json \
    > "$test_dir/small.json" 2> "$test_dir/small.err"
python3 - "$test_dir/small.json" <<'PY'
import json, sys

with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)
assert report["recoveredCount"] == 1, report
assert report["items"][0]["status"] == "sizeMatches", report
print("PASS: маленький FAT32-образ восстановлен с явным типом ФС")
PY
small_recovered="$(find "$test_dir/result-small" -type f -name '*.TXT' -print -quit)"
test -n "$small_recovered"
cmp "$test_dir/originals/RECOVERY.TXT" "$small_recovered"

# 5. Повторный запуск не перезаписывает: новые имена _2, прежние файлы целы.
"$cli" quick recover --image "$fat_image" --output "$test_dir/result" --all --json \
    > "$test_dir/fat32-recover-2.json"
python3 - "$test_dir/fat32-recover-2.json" "$test_dir/result" <<'PY'
import json
import os
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)
assert report["recoveredCount"] == 3, report
names = {os.path.basename(path) for path in report["files"]}
assert names == {"_ECOVERY_2.TXT", "_EPORT_2.TXT", "_MPTY_2.TXT"}, names
PY
cmp "$test_dir/originals/RECOVERY.TXT" "$test_dir/result/_ECOVERY.TXT"
cmp "$test_dir/originals/RECOVERY.TXT" "$test_dir/result/_ECOVERY_2.TXT"
cmp "$test_dir/originals/REPORT.TXT" "$test_dir/result/_EPORT_2.TXT"
cmp "$test_dir/originals/EMPTY.TXT" "$test_dir/result/_MPTY_2.TXT"
print "PASS: повторный запуск не перезаписывает и снова совпадает побайтно"

# 5b. Чистый образ без удалённых записей: код 0 и корректный пустой отчёт.
clean_image="$test_dir/clean.img"
mformat -i "$clean_image" -C -F -v CLEAN -T 262144 ::
mkdir -p "$test_dir/result-clean"
"$cli" quick scan --image "$clean_image" --json > "$test_dir/clean-scan.json" \
    2> "$test_dir/clean-scan.err"
[[ ! -s "$test_dir/clean-scan.err" ]] || fail "scan чистого образа: stderr должен быть пустым"
python3 - "$test_dir/clean-scan.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)
assert report["schemaVersion"] == 1, report
assert report["candidates"] == [], report
print("PASS: чистый образ даёт пустой список кандидатов")
PY
set +e
"$cli" quick recover --image "$clean_image" --output "$test_dir/result-clean" --all --json \
    > "$test_dir/clean-recover.json" 2> "$test_dir/clean-recover.err"
clean_rc=$?
set -e
[[ "$clean_rc" -eq 0 ]] \
    || fail "пустой recover должен завершаться кодом 0 (получен $clean_rc)"
python3 - "$test_dir/clean-recover.json" "$test_dir/result-clean" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)
assert report["schemaVersion"] == 1, report
assert report["outputDirectory"] == sys.argv[2], report
assert report["recoveredCount"] == 0, report
assert report["files"] == [] and report["items"] == [], report
assert report["statusCounts"] == {
    "expectedEmpty": 0, "sizeMatches": 0, "incomplete": 0,
    "sizeMismatch": 0, "sizeUnknown": 0
}, report
print("PASS: пустой JSON-отчёт корректен")
PY
clean_text="$("$cli" quick recover --image "$clean_image" --output "$test_dir/result-clean" --all 2>/dev/null)"
[[ "$clean_text" == *"Удалённые файлы не найдены — восстанавливать нечего."* ]] \
    || fail "текстовый режим пустого recover: $clean_text"
set +e
"$cli" quick recover --image "$clean_image" --output "$test_dir/absent-clean" --all >/dev/null 2>&1
absent_rc=$?
set -e
[[ "$absent_rc" -eq 1 ]] \
    || fail "пустой recover с несуществующей папкой должен давать код 1 (получен $absent_rc)"
print "PASS: пустой результат — код 0, валидация папки результата сохранена"

# 6. Синтетический GPT/exFAT из зафиксированной фикстуры: реальные размеры
#    в метаданных дают статус sizeMatches.
exfat_before="$test_dir/exfat-before.dmg"
exfat_deleted="$test_dir/exfat-deleted.dmg"
xz -dc "$project_dir/Tests/Fixtures/exfat-before-files.dmg.xz" > "$exfat_before"
"$project_dir/Scripts/make-deleted-exfat-fixture.py" \
    "$exfat_before" "$exfat_deleted" --delete RECOVERY_NOTE.TXT --delete TESTCARD.PNG \
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
by_path = {c["path"]: c for c in report["candidates"]}
assert by_path["RECOVERY_NOTE.TXT"]["expectedSize"] == 229, by_path
assert by_path["TESTCARD.PNG"]["expectedSize"] == 26672, by_path
for candidate in by_path.values():
    assert candidate["filesystemType"] == "exfat", candidate
    assert candidate["partitionOffset"] == 2048, candidate
print("PASS: quick scan --json GPT/exFAT содержит реальные ожидаемые размеры")
PY
"$cli" quick recover --image "$exfat_deleted" --output "$test_dir/result-exfat" --all --json \
    > "$test_dir/exfat-recover.json"
python3 - "$test_dir/exfat-recover.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)
assert report["recoveredCount"] == 2, report
counts = report["statusCounts"]
assert counts["sizeMatches"] == 2, counts
assert counts["incomplete"] == 0 and counts["expectedEmpty"] == 0, counts
assert counts["sizeMismatch"] == 0 and counts["sizeUnknown"] == 0, counts
items = {item["path"].split("/")[-1]: item for item in report["items"]}
assert items["RECOVERY_NOTE.TXT"]["expectedSize"] == 229, items
assert items["RECOVERY_NOTE.TXT"]["actualSize"] == 229, items
assert items["TESTCARD.PNG"]["actualSize"] == 26672, items
print("PASS: quick recover --json GPT/exFAT даёт sizeMatches по всем файлам")
PY
for name in RECOVERY_NOTE.TXT TESTCARD.PNG; do
    inode="$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print([c["inode"] for c in r["candidates"] if c["path"]==sys.argv[2]][0])' "$test_dir/exfat-scan.json" "$name")"
    "$tools_dir/icat" -r -f exfat -o 2048 "$exfat_before" "$inode" > "$test_dir/ref-$name"
    cmp "$test_dir/ref-$name" "$test_dir/result-exfat/$name"
done
print "PASS: GPT/exFAT найден и восстановлен побайтно"

# 7. Усечение: shim icat отдаёт только первые 4096 байт при большем
#    ожидаемом размере. Короткий результат сохраняется и помечается incomplete.
mkdir -p "$test_dir/result-truncated" "$test_dir/shim"
cat > "$test_dir/shim/icat-truncate" <<SHIM
#!/bin/zsh
"$tools_dir/icat" "\$@" | head -c 4096
SHIM
chmod +x "$test_dir/shim/icat-truncate"
RECOVERYAPP_ICAT_PATH="$test_dir/shim/icat-truncate" \
    "$cli" quick recover --image "$exfat_deleted" --output "$test_dir/result-truncated" --all --json \
    > "$test_dir/truncated-recover.json"
python3 - "$test_dir/truncated-recover.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)
assert report["recoveredCount"] == 2, report
counts = report["statusCounts"]
assert counts["sizeMatches"] == 1, counts
assert counts["incomplete"] == 1, counts
items = {item["path"].split("/")[-1]: item for item in report["items"]}
assert items["RECOVERY_NOTE.TXT"]["status"] == "sizeMatches", items
assert items["TESTCARD.PNG"]["status"] == "incomplete", items
assert items["TESTCARD.PNG"]["expectedSize"] == 26672, items
assert items["TESTCARD.PNG"]["actualSize"] == 4096, items
print("PASS: усечённый icat помечен incomplete, короткий файл сохранён")
PY
test -s "$test_dir/result-truncated/TESTCARD.PNG"
[[ "$(stat -f %z "$test_dir/result-truncated/TESTCARD.PNG")" -eq 4096 ]] \
    || fail "усечённый файл должен быть ровно 4096 байт"
[[ -z "$(find "$test_dir/result-truncated" -name '*.partial' -print -quit)" ]] \
    || fail "после успешной публикации не должно быть .partial"
mkdir -p "$test_dir/result-human"
truncate_text="$(RECOVERYAPP_ICAT_PATH="$test_dir/shim/icat-truncate" \
    "$cli" quick recover --image "$exfat_deleted" --output "$test_dir/result-human" --all 2>/dev/null)"
[[ "$truncate_text" == *"извлечены не полностью"* ]] \
    || fail "текстовый режим должен предупреждать о неполных файлах"
[[ "$truncate_text" == *"Совпадение размеров не является проверкой целостности содержимого."* ]] \
    || fail "текстовый режим должен напоминать, что сверка размеров не проверка целостности"
print "PASS: усечённые результаты warned в текстовом режиме, .partial отсутствует"

# 8. Ошибка icat: код 1, .partial удаляется.
cat > "$test_dir/shim/icat-fail" <<SHIM
#!/bin/zsh
exit 1
SHIM
chmod +x "$test_dir/shim/icat-fail"
mkdir -p "$test_dir/result-failed"
set +e
RECOVERYAPP_ICAT_PATH="$test_dir/shim/icat-fail" \
    "$cli" quick recover --image "$exfat_deleted" --output "$test_dir/result-failed" --all --json \
    > "$test_dir/failed-recover.json" 2> "$test_dir/failed-recover.err"
error_status=$?
set -e
[[ "$error_status" -eq 1 ]] || fail "ожидался код 1 при отказе icat (получен $error_status)"
[[ -z "$(find "$test_dir/result-failed" -name '*.partial' -print -quit)" ]] \
    || fail "после ошибки не должно быть .partial"
print "PASS: ошибка icat даёт код 1 и удаляет .partial"

# 9. Ошибочные аргументы и окружение: код 2.
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
print "PASS: лишние аргументы отклоняются с кодом 2"

# 10. Ошибки выполнения: код 1.
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
