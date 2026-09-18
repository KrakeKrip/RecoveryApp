#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
# Каталог инструментов переопределяется, чтобы тем же сценарием показать отказ
# на сборке без поддержки унаследованного FD.
tools_dir="${SLEUTHKIT_TOOLS_DIR:-$project_dir/ThirdParty/sleuthkit/bin/arm64}"
test_dir="${SLEUTHKIT_FD_TEST_DIR:-$project_dir/work/tests/sleuthkit-fd-$RANDOM-$$}"
fls="$tools_dir/fls"
icat="$tools_dir/icat"
mmls="$tools_dir/mmls"

for command_name in mformat mcopy mdel xz strings; do
    command -v "$command_name" >/dev/null || {
        echo "Для теста нужен $command_name" >&2
        exit 1
    }
done
test -x "$fls" && test -x "$icat" && test -x "$mmls"

mkdir -p "$test_dir"

# 1. Маркер патча: в чистом исходнике Sleuth Kit 4.15.0 строки "/dev/fd/" нет,
#    поэтому её наличие в бинарнике доказывает, что ветка dup() из
#    sleuthkit-preopened-fd.patch действительно собрана.
for tool_name in fls icat mmls; do
    # grep -c дочитывает весь вывод strings: с pipefail grep -q рвал бы
    # конвейер по SIGPIPE сразу после первого совпадения; || true сохраняет
    # счётчик 0, чтобы ниже напечатать внятный FAIL вместо тихого выхода.
    marker_count="$(strings -a "${tools_dir}/${tool_name}" | grep -cxF '/dev/fd/' || true)"
    [[ "$marker_count" -gt 0 ]] || {
        echo "FAIL: $tool_name собран без поддержки унаследованного FD" >&2
        exit 1
    }
done
echo "PASS: fls, icat и mmls содержат ветку /dev/fd/N из патча"

# 2. Синтетическая FAT32 с одним удалённым файлом.
original="$test_dir/RECOVERY_NOTE.TXT"
printf '%s\n' \
    'RECOVERYAPP-SLEUTHKIT-FD-TEST' \
    'Полностью синтетические данные без пользовательского содержимого.' \
    > "$original"
fat_image="$test_dir/fat32-deleted.img"
mformat -i "$fat_image" -C -F -v FDTEST -T 262144 ::
mcopy -i "$fat_image" "$original" ::/RECOVERY.TXT
mdel -i "$fat_image" ::/RECOVERY.TXT

# 3. Обычный путь к образу продолжает работать.
"$fls" -f fat32 -r -d -p "$fat_image" > "$test_dir/fat32-fls-plain.txt"
inode="$(awk '/_ECOVERY.TXT/{gsub(":", "", $3); print $3}' "$test_dir/fat32-fls-plain.txt")"
test -n "$inode"
"$icat" -r -f fat32 "$fat_image" "$inode" > "$test_dir/fat32-icat-plain.txt"
cmp "$original" "$test_dir/fat32-icat-plain.txt"
echo "PASS: обычный путь к образу по-прежнему работает"

# 4. Прямой унаследованный дескриптор: fd 9 открывает сам сценарий и
#    наследуется дочерним процессом. fls дочитывает образ до конца, поэтому
#    следующий icat с тем же fd 9 проходит только при явном lseek из патча
#    (seek_pos = -1 при общем смещении продублированного дескриптора).
exec 9<"$fat_image"
"$fls" -f fat32 -r -d -p /dev/fd/9 > "$test_dir/fat32-fls-fd9.txt"
cmp "$test_dir/fat32-fls-plain.txt" "$test_dir/fat32-fls-fd9.txt"
"$icat" -r -f fat32 /dev/fd/9 "$inode" > "$test_dir/fat32-icat-fd9.txt"
exec 9<&-
cmp "$original" "$test_dir/fat32-icat-fd9.txt"
echo "PASS: fls и icat читают FAT32 через заранее открытый /dev/fd/9"

# 5. Перенос образа на stdin — то же, что делает recoveryapp-metadata-helper
#    с авторизованным дескриптором перед запуском инструментов.
"$fls" -f fat32 -r -d -p /dev/fd/0 < "$fat_image" > "$test_dir/fat32-fls-fd0.txt"
cmp "$test_dir/fat32-fls-plain.txt" "$test_dir/fat32-fls-fd0.txt"
"$icat" -r -f fat32 /dev/fd/0 "$inode" < "$fat_image" > "$test_dir/fat32-icat-fd0.txt"
cmp "$original" "$test_dir/fat32-icat-fd0.txt"
echo "PASS: FAT32 читается через /dev/fd/0 после переноса дескриптора на stdin"

# 6. Дискриминатор dup(): macOS открывает /dev/fd/N повторно с проверкой прав,
#    поэтому после chmod 000 обычный путь недоступен (как авторизованный
#    дескриптор на реальном носителе), а dup() заранее открытого дескриптора
#    продолжает читать образ.
locked_checks() {
    exec 9<"$fat_image"
    chmod 000 "$fat_image"
    set +e
    "$fls" -f fat32 -r -d -p "$fat_image" >"$test_dir/locked-plain.txt" 2>&1
    plain_status=$?
    set -e
    if [[ "$plain_status" -eq 0 ]]; then
        echo "FAIL: образ остался читаемым по обычному пути, контроль прав не сработал" >&2
        chmod 644 "$fat_image"
        exec 9<&-
        return 1
    fi
    "$fls" -f fat32 -r -d -p /dev/fd/9 > "$test_dir/fat32-fls-fd9-locked.txt"
    "$icat" -r -f fat32 /dev/fd/9 "$inode" > "$test_dir/fat32-icat-fd9-locked.txt"
    chmod 644 "$fat_image"
    exec 9<&-
}
locked_checks
cmp "$test_dir/fat32-fls-plain.txt" "$test_dir/fat32-fls-fd9-locked.txt"
cmp "$original" "$test_dir/fat32-icat-fd9-locked.txt"
grep -q "Permission denied" "$test_dir/locked-plain.txt" \
    || echo "Примечание: переоткрытие по пути вернуло другую ошибку доступа" >&2
echo "PASS: dup() читает образ, недоступный по пути; переоткрытие пути отвергнуто"

# 7. GPT/exFAT из зафиксированной фикстуры: mmls, fls и icat через тот же
#    унаследованный fd 9, включая повторное использование после mmls.
exfat_dmg="$test_dir/exfat-before.dmg"
xz -dc "$project_dir/Tests/Fixtures/exfat-before-files.dmg.xz" > "$exfat_dmg"

"$mmls" "$exfat_dmg" > "$test_dir/exfat-mmls-plain.txt"
exec 9<"$exfat_dmg"
"$mmls" /dev/fd/9 > "$test_dir/exfat-mmls-fd9.txt"
cmp "$test_dir/exfat-mmls-plain.txt" "$test_dir/exfat-mmls-fd9.txt"
offset="$(awk '$1 == "004:" { print $3 }' "$test_dir/exfat-mmls-fd9.txt" | sed 's/^0*//')"
test "$offset" = 2048
"$fls" -f exfat -r -o "$offset" /dev/fd/9 > "$test_dir/exfat-fls-fd9.txt"
"$fls" -f exfat -r -o "$offset" "$exfat_dmg" > "$test_dir/exfat-fls-plain.txt"
cmp "$test_dir/exfat-fls-plain.txt" "$test_dir/exfat-fls-fd9.txt"
# В живом листинге (без -d) номер инода находится во втором поле.
exfat_inode="$(awk '/RECOVERY_NOTE.TXT/{gsub(":", "", $2); print $2; exit}' "$test_dir/exfat-fls-fd9.txt")"
test -n "$exfat_inode"
"$icat" -r -f exfat -o "$offset" /dev/fd/9 "$exfat_inode" > "$test_dir/exfat-icat-fd9.txt"
exec 9<&-
"$icat" -r -f exfat -o "$offset" "$exfat_dmg" "$exfat_inode" > "$test_dir/exfat-icat-plain.txt"
cmp "$test_dir/exfat-icat-plain.txt" "$test_dir/exfat-icat-fd9.txt"
test -s "$test_dir/exfat-icat-fd9.txt"
echo "PASS: mmls, fls и icat читают GPT/exFAT через заранее открытый /dev/fd/9"

# 8. Недопустимый /dev/fd/N завершается ненулевым кодом без падения.
set +e
"$fls" -f fat32 -r -d -p /dev/fd/999 \
    >"$test_dir/invalid-fd999.stdout" 2>"$test_dir/invalid-fd999.stderr"
invalid_fd999=$?
"$fls" -f fat32 -r -d -p /dev/fd/notanumber \
    >"$test_dir/invalid-name.stdout" 2>"$test_dir/invalid-name.stderr"
invalid_name=$?
set -e
test "$invalid_fd999" -ne 0 && test "$invalid_fd999" -lt 128
test "$invalid_name" -ne 0 && test "$invalid_name" -lt 128
echo "PASS: недопустимый /dev/fd/N даёт коды $invalid_fd999 и $invalid_name без падения"

echo "PASS: все проверки унаследованного read-only FD прошли"
echo "result=$test_dir"
