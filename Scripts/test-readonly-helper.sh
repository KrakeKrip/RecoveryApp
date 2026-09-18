#!/bin/zsh
set -euo pipefail
unsetopt BG_NICE

project_dir="${0:A:h:h}"
test_dir="${READONLY_HELPER_TEST_DIR:-$project_dir/work/tests/readonly-helper-$RANDOM-$$}"
tools_dir="$test_dir/tools"
helper="$tools_dir/recoveryapp-readonly-helper"
photorec="$tools_dir/photorec"

for command_name in clang ffmpeg mformat mcopy mdel; do
    command -v "$command_name" >/dev/null || {
        echo "Для теста нужен $command_name" >&2
        exit 1
    }
done

mkdir -p "$tools_dir" "$test_dir/originals" "$test_dir/result" "$test_dir/cancel"
clang -Wall -Wextra -Werror -Os \
    "$project_dir/Packaging/recoveryapp-readonly-helper.c" -o "$helper"
cp "$project_dir/ThirdParty/photorec/bin/arm64/photorec" "$photorec"

ffmpeg -hide_banner -loglevel error -f lavfi \
    -i 'testsrc2=size=640x360:rate=1:duration=1' -frames:v 1 -y \
    "$test_dir/originals/PHOTO.PNG"
ffmpeg -hide_banner -loglevel error \
    -f lavfi -i 'testsrc2=size=640x360:rate=25:duration=2' \
    -f lavfi -i 'sine=frequency=440:duration=2' \
    -c:v libx264 -pix_fmt yuv420p -c:a aac -movflags +faststart -y \
    "$test_dir/originals/CLIP.MP4"

image="$test_dir/deleted.img"
mformat -i "$image" -C -F -v HELPERTEST -T 262144 ::
mcopy -i "$image" "$test_dir/originals/PHOTO.PNG" ::/PHOTO.PNG
mcopy -i "$image" "$test_dir/originals/CLIP.MP4" ::/CLIP.MP4
mdel -i "$image" ::/PHOTO.PNG ::/CLIP.MP4

"$helper" "$image" "$test_dir/result" "$(stat -f %z "$image")" > "$test_dir/helper.stdout" 2>&1
png_result="$(find "$test_dir/result" -type f -name '*.png' -print -quit)"
mp4_result="$(find "$test_dir/result" -type f -name '*.mp4' -print -quit)"
test -n "$png_result"
test -n "$mp4_result"
cmp "$test_dir/originals/PHOTO.PNG" "$png_result"
cmp "$test_dir/originals/CLIP.MP4" "$mp4_result"

cancel_image="$test_dir/cancel-512g.img"
mformat -i "$cancel_image" -C -F -v CANCELTEST -T 1073741824 ::
"$helper" "$cancel_image" "$test_dir/cancel" "$(stat -f %z "$cancel_image")" \
    > "$test_dir/cancel.stdout" 2>&1 &
helper_pid=$!
sleep 0.2
touch "$test_dir/cancel/.recoveryapp-stop"
set +e
wait "$helper_pid"
helper_status=$?
set -e
test "$helper_status" -eq 130
! rg -q "Can't create photorec.ses|Read-only file system" \
    "$test_dir/cancel.stdout"

echo "PASS: read-only helper recovered PNG/MP4 exactly and cancelled cleanly"

mkdir -p "$test_dir/replaced-source"
set +e
"$helper" "$image" "$test_dir/replaced-source" "1" \
    > "$test_dir/replaced-source.stdout" 2>&1
replaced_status=$?
set -e
test "$replaced_status" -eq 74
rg -q 'selected source device has changed' "$test_dir/replaced-source.stdout"
echo "PASS: helper rejects a replaced source device"

progress_tools="$test_dir/progress-tools"
progress_result="$test_dir/progress-result"
mkdir -p "$progress_tools" "$progress_result"
cp "$helper" "$progress_tools/recoveryapp-readonly-helper"
cp "$project_dir/Tests/Fixtures/fake-photorec-progress.sh" "$progress_tools/photorec"
chmod +x "$progress_tools/photorec"
"$progress_tools/recoveryapp-readonly-helper" "$image" "$progress_result" "$(stat -f %z "$image")" \
    > "$test_dir/progress.stdout" 2>&1 &
progress_pid=$!
for attempt in {1..15}; do
    if test -f "$progress_result/.recoveryapp-progress" && \
        rg -q '^processed=33554432$' "$progress_result/.recoveryapp-progress"; then
        break
    fi
    sleep 0.1
done
test -f "$progress_result/.recoveryapp-progress"
rg -q '^processed=33554432$' "$progress_result/.recoveryapp-progress"
rg -q '^total=134217728$' "$progress_result/.recoveryapp-progress"
touch "$progress_result/.recoveryapp-stop"
set +e
wait "$progress_pid"
progress_status=$?
set -e
test "$progress_status" -eq 130
echo "PASS: helper exports real PhotoRec sector progress"
echo "result=$test_dir"
