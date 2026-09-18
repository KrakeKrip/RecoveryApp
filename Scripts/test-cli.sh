#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
cache_dir="${BUILD_CACHE_DIR:-$project_dir/work/swift-cli-test}"
sdk_root="${RECOVERYAPP_SDKROOT:-$(xcrun --show-sdk-path)}"

cd "$project_dir"
mkdir -p "$cache_dir/module-cache"
export SDKROOT="$sdk_root"
export CLANG_MODULE_CACHE_PATH="$cache_dir/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$cache_dir/module-cache"

swift build --disable-sandbox --scratch-path "$cache_dir" -c debug --product recoveryapp-cli
cli_bin="$(swift build --disable-sandbox --scratch-path "$cache_dir" -c debug --product recoveryapp-cli --show-bin-path)/recoveryapp-cli"

fail() {
    print -u2 "FAIL: $1"
    exit 1
}

# 1. version — человекочитаемый вывод на русском.
version_text="$("$cli_bin" version)"
[[ "$version_text" == "RecoveryApp 0.8.1, сборка 13" ]] \
    || fail "version: неожиданный вывод: $version_text"
print "PASS: version печатает русскую версию"

# 2. version --json — точная машинночитаемая строка, stderr пустой.
version_json="$("$cli_bin" version --json 2>"$cache_dir/version-json.err")"
[[ "$version_json" == '{"appVersion":"0.8.1","build":"13","schemaVersion":1}' ]] \
    || fail "version --json: неожиданный вывод: $version_json"
[[ ! -s "$cache_dir/version-json.err" ]] \
    || fail "version --json: stderr должен быть пустым"
print "PASS: version --json соответствует схеме"

# 3. help — справка перечисляет все команды.
help_text="$("$cli_bin" help)"
[[ "$help_text" == *"version"* && "$help_text" == *"drives list"* ]] \
    || fail "help: нет перечня команд"
print "PASS: help перечисляет команды"

# 4. Запуск без аргументов ведёт себя как help.
[[ "$("$cli_bin")" == "$help_text" ]] \
    || fail "запуск без аргументов: ожидалась справка"
print "PASS: запуск без аргументов показывает справку"

# 5. Неизвестная команда — ненулевой код и подсказка в stderr.
set +e
"$cli_bin" заведомо-неизвестная-команда >"$cache_dir/unknown.out" 2>"$cache_dir/unknown.err"
unknown_status=$?
set -e
[[ "$unknown_status" -ne 0 ]] \
    || fail "неизвестная команда: ожидался ненулевой код выхода"
grep -q "Неизвестная команда" "$cache_dir/unknown.err" \
    || fail "неизвестная команда: нет подсказки в stderr"
print "PASS: неизвестная команда даёт код $unknown_status и подсказку в stderr"

# 6. Лишний аргумент для version — ненулевой код.
set +e
"$cli_bin" version лишний >/dev/null 2>&1
extra_status=$?
set -e
[[ "$extra_status" -ne 0 ]] \
    || fail "version лишний-аргумент: ожидался ненулевой код"
print "PASS: лишние аргументы отклоняются с кодом $extra_status"

# 7. drives list — код 0, флешка для проверки не требуется.
"$cli_bin" drives list >/dev/null \
    || fail "drives list: ненулевой код выхода"
print "PASS: drives list завершается без ошибок"

# 8. drives list --json — валидный JSON со schemaVersion 1 и массивом drives.
"$cli_bin" drives list --json >"$cache_dir/drives.json" \
    || fail "drives list --json: ненулевой код выхода"
python3 - "$cache_dir/drives.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
assert payload.get("schemaVersion") == 1, payload
drives = payload.get("drives")
assert isinstance(drives, list), payload
for drive in drives:
    for key in ("id", "name", "size", "rawDevicePath", "mountPoints"):
        assert key in drive, drive
print(f"PASS: drives list --json соответствует схеме, накопителей: {len(drives)}")
PY

print "PASS: все проверки CLI прошли"
