#!/bin/zsh
set -euo pipefail
unsetopt BG_NICE

project_dir="${0:A:h:h}"
test_dir="${DELETED_FIXTURE_DIR:-$project_dir/work/tests/deleted-recovery-$RANDOM-$$}"
photorec="$project_dir/ThirdParty/photorec/bin/arm64/photorec"
fls="$project_dir/ThirdParty/sleuthkit/bin/arm64/fls"
icat="$project_dir/ThirdParty/sleuthkit/bin/arm64/icat"
launcher="$test_dir/tool-launcher"

for command_name in ffmpeg mformat mcopy mdel xz; do
    command -v "$command_name" >/dev/null || {
        echo "Для теста нужен $command_name" >&2
        exit 1
    }
done
test -x "$photorec"
test -x "$fls"
test -x "$icat"

mkdir -p "$test_dir/originals" "$test_dir/logs" "$test_dir/results"
printf '%s\n' \
    'RECOVERYAPP-SYNTHETIC-FAT32-2026-09-12' \
    'Это полностью синтетический тестовый файл без пользовательских данных.' \
    'Контрольная строка: murad-amina-482917.' \
    > "$test_dir/originals/RECOVERY_NOTE.TXT"
ffmpeg -hide_banner -loglevel error -f lavfi \
    -i 'testsrc2=size=640x360:rate=1:duration=1' -frames:v 1 -y \
    "$test_dir/originals/TESTCARD.PNG"
ffmpeg -hide_banner -loglevel error \
    -f lavfi -i 'testsrc2=size=640x360:rate=25:duration=4' \
    -f lavfi -i 'sine=frequency=880:duration=4' \
    -c:v libx264 -pix_fmt yuv420p -c:a aac -movflags +faststart -y \
    "$test_dir/originals/CLIP.MP4"

fat_image="$test_dir/fat32-deleted.img"
mformat -i "$fat_image" -C -F -v RECOVERY_FAT32 -T 262144 ::
mmd -i "$fat_image" ::/DOCS ::/MEDIA
mcopy -i "$fat_image" "$test_dir/originals/RECOVERY_NOTE.TXT" ::/DOCS/RECOVERY.TXT
mcopy -i "$fat_image" "$test_dir/originals/TESTCARD.PNG" ::/MEDIA/TESTCARD.PNG
mcopy -i "$fat_image" "$test_dir/originals/CLIP.MP4" ::/MEDIA/CLIP.MP4
mdel -i "$fat_image" ::/DOCS/RECOVERY.TXT ::/MEDIA/TESTCARD.PNG ::/MEDIA/CLIP.MP4

"$fls" -f fat32 -r -d -p "$fat_image" > "$test_dir/logs/fat32-fls.txt"
text_inode="$(awk '/_ECOVERY.TXT/{gsub(":", "", $3); print $3}' "$test_dir/logs/fat32-fls.txt")"
png_inode="$(awk '/_ESTCARD.PNG/{gsub(":", "", $3); print $3}' "$test_dir/logs/fat32-fls.txt")"
mp4_inode="$(awk '/_LIP.MP4/{gsub(":", "", $3); print $3}' "$test_dir/logs/fat32-fls.txt")"
mkdir -p "$test_dir/results/fat32-metadata"
"$icat" -r -f fat32 "$fat_image" "$text_inode" > "$test_dir/results/fat32-metadata/_ECOVERY.TXT"
"$icat" -r -f fat32 "$fat_image" "$png_inode" > "$test_dir/results/fat32-metadata/_ESTCARD.PNG"
"$icat" -r -f fat32 "$fat_image" "$mp4_inode" > "$test_dir/results/fat32-metadata/_LIP.MP4"
cmp "$test_dir/originals/RECOVERY_NOTE.TXT" "$test_dir/results/fat32-metadata/_ECOVERY.TXT"
cmp "$test_dir/originals/TESTCARD.PNG" "$test_dir/results/fat32-metadata/_ESTCARD.PNG"
cmp "$test_dir/originals/CLIP.MP4" "$test_dir/results/fat32-metadata/_LIP.MP4"

"$photorec" /log /logname "$test_dir/logs/fat32-photorec.log" \
    /d "$test_dir/results/fat32-photorec" /cmd "$fat_image" \
    partition_none,fileopt,everything,disable,txt,enable,png,enable,mov,enable,search \
    > "$test_dir/logs/fat32-photorec.stdout" 2>&1
fat_png="$(find "$test_dir/results/fat32-photorec.1" -type f -name '*.png' -print -quit)"
fat_mp4="$(find "$test_dir/results/fat32-photorec.1" -type f -name '*.mp4' -print -quit)"
cmp "$test_dir/originals/TESTCARD.PNG" "$fat_png"
cmp "$test_dir/originals/CLIP.MP4" "$fat_mp4"

exfat_dmg="$test_dir/exfat-deleted.dmg"
xz -dc "$project_dir/Tests/Fixtures/exfat-before-files.dmg.xz" > "$test_dir/exfat-before.dmg"
"$project_dir/Scripts/make-deleted-exfat-fixture.py" \
    "$test_dir/exfat-before.dmg" "$exfat_dmg" \
    --delete TESTCARD.PNG --delete RECOVERY_NOTE.TXT --delete CLIP.MP4
dd if="$exfat_dmg" of="$test_dir/exfat-deleted.raw" \
    bs=512 skip=2048 count=247808 status=none

"$fls" -f exfat -r -d -p "$test_dir/exfat-deleted.raw" > "$test_dir/logs/exfat-fls.txt"
exfat_text_inode="$(awk '/RECOVERY_NOTE.TXT/{gsub(":", "", $3); print $3}' "$test_dir/logs/exfat-fls.txt")"
exfat_png_inode="$(awk '/TESTCARD.PNG/{gsub(":", "", $3); print $3}' "$test_dir/logs/exfat-fls.txt")"
exfat_mp4_inode="$(awk '/CLIP.MP4/{gsub(":", "", $3); print $3}' "$test_dir/logs/exfat-fls.txt")"
mkdir -p "$test_dir/results/exfat-metadata"
"$icat" -r -f exfat "$test_dir/exfat-deleted.raw" "$exfat_text_inode" > "$test_dir/results/exfat-metadata/RECOVERY_NOTE.TXT"
"$icat" -r -f exfat "$test_dir/exfat-deleted.raw" "$exfat_png_inode" > "$test_dir/results/exfat-metadata/TESTCARD.PNG"
"$icat" -r -f exfat "$test_dir/exfat-deleted.raw" "$exfat_mp4_inode" > "$test_dir/results/exfat-metadata/CLIP.MP4"
cmp "$test_dir/originals/RECOVERY_NOTE.TXT" "$test_dir/results/exfat-metadata/RECOVERY_NOTE.TXT"
cmp "$test_dir/originals/TESTCARD.PNG" "$test_dir/results/exfat-metadata/TESTCARD.PNG"
cmp "$test_dir/originals/CLIP.MP4" "$test_dir/results/exfat-metadata/CLIP.MP4"

"$photorec" /log /logname "$test_dir/logs/exfat-photorec.log" \
    /d "$test_dir/results/exfat-photorec" /cmd "$test_dir/exfat-deleted.raw" \
    partition_none,fileopt,everything,disable,txt,enable,png,enable,mov,enable,freespace,search \
    > "$test_dir/logs/exfat-photorec.stdout" 2>&1
exfat_png="$(find "$test_dir/results/exfat-photorec.1" -type f -name '*.png' -print -quit)"
exfat_mp4="$(find "$test_dir/results/exfat-photorec.1" -type f -name '*.mp4' -print -quit)"
cmp "$test_dir/originals/TESTCARD.PNG" "$exfat_png"
cmp "$test_dir/originals/CLIP.MP4" "$exfat_mp4"

clang -Os "$project_dir/Packaging/tool-launcher.c" -o "$launcher"
cancel_image="$test_dir/fat32-cancel-512g.img"
# Sparse: logical 512 GiB, about 128 MiB physically. The large logical scan keeps
# PhotoRec alive long enough to exercise process-group cancellation reliably.
mformat -i "$cancel_image" -C -F -v CANCELTEST -T 1073741824 ::
mkdir -p "$test_dir/results/cancel"
"$launcher" "$photorec" /d "$test_dir/results/cancel" /cmd "$cancel_image" \
    partition_none,fileopt,everything,disable,png,enable,search \
    > "$test_dir/logs/cancel.stdout" 2>&1 &
leader_pid=$!
group_ready=no
for _ in {1..500}; do
    if kill -0 -- "-$leader_pid" 2>/dev/null; then
        kill -STOP -- "-$leader_pid"
        group_ready=yes
        break
    fi
    sleep 0.01
done
[[ "$group_ready" == yes ]]
# The process can disappear between these two signals on a very fast host.
# That race still means cancellation succeeded, so do not fail on ESRCH here.
kill -TERM -- "-$leader_pid" 2>/dev/null || true
kill -CONT -- "-$leader_pid" 2>/dev/null || true
wait "$leader_pid" 2>/dev/null || true
sleep 0.1
if kill -0 "$leader_pid" 2>/dev/null; then
    echo "FAIL: PhotoRec остался после отмены" >&2
    exit 1
fi

echo "PASS: FAT32 metadata content 3/3; PhotoRec content 2/3"
echo "PASS: exFAT metadata content and names 3/3; PhotoRec content 2/3"
echo "PASS: PhotoRec process-group cancellation"
echo "result=$test_dir"
