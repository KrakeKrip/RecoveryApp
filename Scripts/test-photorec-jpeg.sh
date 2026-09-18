#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
test_dir="${PHOTOREC_JPEG_TEST_DIR:-$project_dir/work/tests/photorec-jpeg-$RANDOM-$$}"
photorec="$project_dir/ThirdParty/photorec/bin/arm64/photorec"

for command_name in ffmpeg mformat mcopy mdel; do
    command -v "$command_name" >/dev/null || {
        echo "Для теста нужен $command_name" >&2
        exit 1
    }
done

test -x "$photorec"
mkdir -p "$test_dir/originals" "$test_dir/results" "$test_dir/logs"

ffmpeg -hide_banner -loglevel error -f lavfi \
    -i 'testsrc2=size=800x600:rate=1:duration=1' -frames:v 1 -q:v 2 -y \
    "$test_dir/originals/RECOVERY_PHOTO.JPG"

image="$test_dir/fat32-jpeg-deleted.img"
mformat -i "$image" -C -F -v JPEGTEST -T 262144 ::
mcopy -i "$image" "$test_dir/originals/RECOVERY_PHOTO.JPG" ::/PHOTO.JPG
mdel -i "$image" ::/PHOTO.JPG

version_output="$("$photorec" /version 2>&1)"
print -r -- "$version_output" | grep -F 'libjpeg: libjpeg-turbo-3.2.0' >/dev/null

"$photorec" /log /logname "$test_dir/logs/photorec.log" \
    /d "$test_dir/results/recovered" /cmd "$image" \
    partition_none,fileopt,everything,disable,jpg,enable,search \
    > "$test_dir/logs/photorec.stdout" 2>&1

recovered="$(find "$test_dir/results/recovered.1" -type f \
    \( -name '*.jpg' -o -name '*.jpeg' \) -print -quit)"
test -n "$recovered"
cmp "$test_dir/originals/RECOVERY_PHOTO.JPG" "$recovered"

echo "PASS: PhotoRec recovered JPEG with exact content"
echo "result=$test_dir"
