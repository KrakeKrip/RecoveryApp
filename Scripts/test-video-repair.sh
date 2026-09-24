#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
# VIDEO_FIXTURE_DIR задаёт только корень: тест создаёт внутри него
# уникальный подкаталог запуска и никогда не удаляет сам корень, поэтому
# повторный запуск и случайное указание пользовательской папки безопасны.
fixture_root="${VIDEO_FIXTURE_DIR:-$project_dir/work/tests/video-e2e}"
fixture_dir="$fixture_root/run-$RANDOM-$$"
tool="$project_dir/ThirdParty/untrunc/bin/arm64/untrunc"

command -v ffmpeg >/dev/null || { echo "Для теста нужен ffmpeg" >&2; exit 1; }
command -v ffprobe >/dev/null || { echo "Для теста нужен ffprobe" >&2; exit 1; }
test -x "$tool"

mkdir -p "$fixture_dir/output"

ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i testsrc2=size=640x360:rate=30 \
    -f lavfi -i sine=frequency=440:sample_rate=48000 \
    -t 5 -c:v libx264 -pix_fmt yuv420p -g 30 -c:a aac -b:a 128k \
    "$fixture_dir/reference.mp4"

ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i testsrc2=size=640x360:rate=30 \
    -f lavfi -i sine=frequency=660:sample_rate=48000 \
    -t 5 -c:v libx264 -pix_fmt yuv420p -g 30 -c:a aac -b:a 128k \
    "$fixture_dir/original.mp4"

moov_offset="$(LC_ALL=C grep -abo moov "$fixture_dir/original.mp4" | tail -1 | cut -d: -f1)"
test -n "$moov_offset"
dd if="$fixture_dir/original.mp4" of="$fixture_dir/damaged.mp4" \
    bs=1 count="$((moov_offset - 4))" status=none

shasum -a 256 "$fixture_dir/reference.mp4" "$fixture_dir/damaged.mp4" > "$fixture_dir/before.sha256"
start_seconds="$SECONDS"
"$tool" -n -dst "$fixture_dir/output/recovered.mp4" \
    "$fixture_dir/reference.mp4" "$fixture_dir/damaged.mp4" \
    > "$fixture_dir/untrunc.log" 2>&1
elapsed_seconds="$((SECONDS - start_seconds))"
shasum -a 256 "$fixture_dir/reference.mp4" "$fixture_dir/damaged.mp4" > "$fixture_dir/after.sha256"
cmp "$fixture_dir/before.sha256" "$fixture_dir/after.sha256"

stream_count="$(ffprobe -v error -show_entries stream=index -of csv=p=0 "$fixture_dir/output/recovered.mp4" | wc -l | tr -d ' ')"
duration="$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$fixture_dir/output/recovered.mp4")"
[[ "$stream_count" == "2" ]]

echo "PASS: synthetic repair"
echo "duration=$duration"
echo "streams=$stream_count"
echo "elapsed_seconds=$elapsed_seconds"
echo "result=$fixture_dir/output/recovered.mp4"
