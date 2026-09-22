#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
tools_dir="$project_dir/ThirdParty/sleuthkit/bin/arm64"
test_dir="${PHYSICAL_CONTRACT_TEST_DIR:-$project_dir/work/tests/physical-contract-$RANDOM-$$}"
cache_dir="${BUILD_CACHE_DIR:-$project_dir/work/swift-physical-contract}"

for command_name in mformat mmd mcopy mdel xz python3 clang; do
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

export RECOVERYAPP_MMLS_PATH="$tools_dir/mmls"
export RECOVERYAPP_FLS_PATH="$tools_dir/fls"
export RECOVERYAPP_ICAT_PATH="$tools_dir/icat"

mkdir -p "$test_dir"

fail() {
    print -u2 "FAIL: $1"
    exit 1
}

# 1. Контракт разбора аргументов: неверные, конфликтующие и отсутствующие
#    параметры завершаются кодом 2 до всякого обращения к дискам.
expect_usage_error() {
    set +e
    "$cli" "$@" > /dev/null 2> "$test_dir/usage.err"
    local rc=$?
    set -e
    [[ "$rc" -eq 2 ]] || fail "ожидался код 2 для: $* (получен $rc)"
}
expect_usage_error quick scan --drive disk4
expect_usage_error quick scan --drive disk4 --expected-name N
expect_usage_error quick scan --drive /dev/rdisk4 --expected-name N --expected-size 5
expect_usage_error quick scan --drive disk4 --expected-name N --expected-size abc
expect_usage_error quick scan --drive disk4 --expected-name N --expected-size 0
expect_usage_error quick scan --drive disk4 --expected-name N --expected-size -5
expect_usage_error quick scan --image a.img --drive disk4 --expected-name N --expected-size 5
expect_usage_error quick scan --image a.img --expected-name N --expected-size 5
expect_usage_error quick recover --drive disk4 --expected-name N --expected-size 5 --output d
expect_usage_error quick scan --drive
expect_usage_error quick scan --drive disk4 --expected-name
expect_usage_error quick scan --drive disk4 --expected-name N --expected-size 5 --output d
print "PASS: физический контракт аргументов даёт код 2"

# 2. Корректные --drive аргументы принимаются парсером; затем выполняется
#    повторное обнаружение, и сверка ожиданий отвергает источник до
#    Authorization Services (код 1, stdout пуст, системного запроса нет).
set +e
"$cli" quick scan --drive disk4 --expected-name RECOVERYAPP-CONTRACT-NOPE --expected-size 5 \
    > "$test_dir/drive-scan.stdout" 2> "$test_dir/drive-scan.stderr"
match_status=$?
set -e
[[ "$match_status" -eq 1 ]] \
    || fail "ожидался код 1 при отвержении диска (получен $match_status)"
[[ ! -s "$test_dir/drive-scan.stdout" ]] \
    || fail "сверка должна отвергать источник до какого-либо вывода результата"
print "PASS: повторное обнаружение и сверка отвергают источник с кодом 1 до авторизации"

# 3. Доменные проверки Core: synthetic matcher диска, JSON-кодирование моделей,
#    нормализация опасных имён и разбор quick-команд.
"$project_dir/Scripts/test.sh" | tail -1
print "PASS: доменные проверки Core (matcher, JSON-модели, опасные имена) прошли"

# 4. Существующий helper на обычных образах: regular-файл открывается без
#    authopen, fls находит удалённую запись, icat извлекает побайтно.
helper_dir="$test_dir/tools"
mkdir -p "$helper_dir" "$test_dir/result"
clang -Wall -Wextra -Werror -Os \
    "$project_dir/Packaging/recoveryapp-metadata-helper.c" -o "$helper_dir/recoveryapp-metadata-helper"
cp "$tools_dir/fls" "$helper_dir/fls"
cp "$tools_dir/icat" "$helper_dir/icat"
cp "$tools_dir/mmls" "$helper_dir/mmls"

printf '%s\n' \
    'RECOVERYAPP-PHYSICAL-CONTRACT-HELPER' \
    'Полностью синтетические данные. Контроль: physical-365951.' \
    > "$test_dir/original.txt"
image="$test_dir/fat32-deleted.img"
mformat -i "$image" -C -F -v CONTRACT -T 262144 ::
mcopy -i "$image" "$test_dir/original.txt" ::/RECOVERY.TXT
mdel -i "$image" ::/RECOVERY.TXT

expected_size="$(stat -f %z "$image")"
"$helper_dir/recoveryapp-metadata-helper" fls "$image" "$expected_size" 0 fat32 \
    > "$test_dir/helper-fls.stdout"
inode="$(awk '/_ECOVERY.TXT/{gsub(":", "", $3); print $3}' "$test_dir/helper-fls.stdout")"
test -n "$inode"
# Helper добавляет -l: колонка ожидаемого размера должна присутствовать.
helper_size="$(awk '/_ECOVERY.TXT/{print $(NF-2)}' "$test_dir/helper-fls.stdout")"
[[ "$helper_size" -gt 0 ]] \
    || fail "helper fls -l должен показывать ожидаемый размер записи"
"$helper_dir/recoveryapp-metadata-helper" icat "$image" "$expected_size" "$test_dir/result" 0 "$inode" fat32 \
    > "$test_dir/result/_ECOVERY.TXT"
cmp "$test_dir/original.txt" "$test_dir/result/_ECOVERY.TXT"
[[ "$(stat -f %z "$test_dir/result/_ECOVERY.TXT")" -eq "$helper_size" ]] \
    || fail "фактический размер результата должен совпадать с размером из fls -l"
print "PASS: metadata helper на обычном образе находит и восстанавливает побайтно"

# 5. Helper продолжает отклонять подмену размера источника.
set +e
"$helper_dir/recoveryapp-metadata-helper" fls "$image" 1 0 fat32 \
    > "$test_dir/helper-replaced.stdout" 2>&1
replaced_status=$?
set -e
[[ "$replaced_status" -eq 74 ]] \
    || fail "ожидался код 74 при подмене размера (получен $replaced_status)"
grep -q "selected source device has changed" "$test_dir/helper-replaced.stdout" \
    || fail "нет сообщения о несовпадении размера"
print "PASS: helper отклоняет изменённый источник кодом 74"

print "PASS: все проверки контракта физического quick CLI прошли"
echo "result=$test_dir"
