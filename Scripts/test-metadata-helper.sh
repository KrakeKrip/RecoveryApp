#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
test_dir="${METADATA_HELPER_TEST_DIR:-$project_dir/work/tests/metadata-helper-$RANDOM-$$}"
tools_dir="$test_dir/tools"
helper="$tools_dir/recoveryapp-metadata-helper"
image="$test_dir/deleted.img"
original="$test_dir/RECOVERY_NOTE.TXT"
result="$test_dir/result"

for command_name in clang mformat mcopy mdel xz; do
    command -v "$command_name" >/dev/null || {
        echo "Для теста нужен $command_name" >&2
        exit 1
    }
done

mkdir -p "$tools_dir" "$result"
clang -Wall -Wextra -Werror -Os \
    "$project_dir/Packaging/recoveryapp-metadata-helper.c" -o "$helper"
cp "$project_dir/ThirdParty/sleuthkit/bin/arm64/fls" "$tools_dir/fls"
cp "$project_dir/ThirdParty/sleuthkit/bin/arm64/icat" "$tools_dir/icat"
cp "$project_dir/ThirdParty/sleuthkit/bin/arm64/mmls" "$tools_dir/mmls"

printf '%s\n' \
    'RECOVERYAPP-METADATA-HELPER-TEST' \
    'Полностью синтетические данные.' > "$original"
mformat -i "$image" -C -F -v METAHELPER -T 262144 ::
mcopy -i "$image" "$original" ::/RECOVERY.TXT
mdel -i "$image" ::/RECOVERY.TXT

expected_size="$(stat -f %z "$image")"
"$helper" fls "$image" "$expected_size" 0 fat32 > "$test_dir/fls.stdout"
inode="$(awk '/_ECOVERY.TXT/{gsub(":", "", $3); print $3}' "$test_dir/fls.stdout")"
test -n "$inode"
"$helper" icat "$image" "$expected_size" "$result" 0 "$inode" fat32 \
    > "$result/_ECOVERY.TXT"
cmp "$original" "$result/_ECOVERY.TXT"

exfat_before="$test_dir/exfat-before.dmg"
exfat_deleted="$test_dir/exfat-deleted.dmg"
xz -dc "$project_dir/Tests/Fixtures/exfat-before-files.dmg.xz" > "$exfat_before"
"$project_dir/Scripts/make-deleted-exfat-fixture.py" \
    "$exfat_before" "$exfat_deleted" --delete RECOVERY_NOTE.TXT \
    > "$test_dir/exfat-fixture.stdout"
exfat_size="$(stat -f %z "$exfat_deleted")"
"$helper" mmls "$exfat_deleted" "$exfat_size" > "$test_dir/mmls.stdout"
offset="$(awk '$1 == "004:" { print $3 }' "$test_dir/mmls.stdout" | sed 's/^0*//')"
test "$offset" = 2048

"$helper" fls "$exfat_deleted" "$exfat_size" "$offset" exfat \
    > "$test_dir/exfat-fls.stdout"
exfat_inode="$(awk '/RECOVERY_NOTE.TXT/{gsub(":", "", $3); print $3}' "$test_dir/exfat-fls.stdout")"
test -n "$exfat_inode"
"$helper" icat "$exfat_deleted" "$exfat_size" "$result" "$offset" \
    "$exfat_inode" exfat > "$result/RECOVERY_NOTE.TXT"
"$tools_dir/icat" -o "$offset" "$exfat_before" "$exfat_inode" \
    > "$test_dir/exfat-original.txt"
cmp "$test_dir/exfat-original.txt" "$result/RECOVERY_NOTE.TXT"

set +e
"$helper" fls "$image" 1 0 fat32 > "$test_dir/replaced.stdout" 2>&1
replaced_status=$?
set -e
test "$replaced_status" -eq 74
rg -q 'selected source device has changed' "$test_dir/replaced.stdout"

echo "PASS: metadata helper found and restored a deleted FAT32 file exactly"
echo "PASS: metadata helper found GPT/exFAT and restored a deleted file exactly"
echo "PASS: metadata helper rejects a source with an unexpected size"
echo "result=$test_dir"
