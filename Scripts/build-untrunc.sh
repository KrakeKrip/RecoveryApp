#!/bin/zsh
# TASK-016: контрольная сборка untrunc (снимок 9d86ec9) со статическим
# FFmpeg 8.1 ИСКЛЮЧИТЕЛЬНО из прикладываемых локальных архивов: без git-клона
# и без сетевых загрузок (build-only патч Packaging/untrunc-local-archive-build.patch
# заменяет правило скачивания). Проверка SHA-256 всех входов до сборки,
# однократный патч, запись конфигурационных evidence FFmpeg.
#
# По умолчанию результат копируется в ThirdParty/untrunc/bin/arm64.
# Если задан STAGE_DIR, кандидат складывается туда — для проверки
# до замены рабочего бинарника.

set -euo pipefail

project_dir="${0:A:h:h}"
untrunc_archive="$project_dir/outputs/untrunc-9d86ec9-source.tar.gz"
ffmpeg_archive="$project_dir/outputs/ffmpeg-8.1-source.tar.xz"
patch_file="$project_dir/Packaging/untrunc-local-archive-build.patch"
expected_untrunc_sha="a46bbb0013b274cd239b0fe037cdf175e6865d62119e78f6f8d8684efbeaa8dc"
expected_ffmpeg_sha="b072aed6871998cce9b36e7774033105ca29e33632be5b6347f3206898e0756a"
expected_patch_sha="fc4a2b22c91c2da065ba5f6d12e2822a8f976aa52b4c1cece292a6427f4e4c68"
destination="$project_dir/ThirdParty/untrunc/bin/arm64"
stage_dir="${STAGE_DIR:-}"
# Фиксированный собственный рабочий каталог внутри проекта.
build_root="$project_dir/work/TASK-016/untrunc-build"
evidence_dir="$project_dir/docs/build-evidence/TASK-016"

fail() {
    print "FAIL(untrunc): $1" >&2
    exit 1
}

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

mkdir -p "$evidence_dir"

# 1. Входы: SHA до распаковки, отказ при изменении.
[[ "$(sha256 "$untrunc_archive")" == "$expected_untrunc_sha" ]] \
    || fail "SHA-256 архива untrunc изменился: $untrunc_archive"
[[ "$(sha256 "$ffmpeg_archive")" == "$expected_ffmpeg_sha" ]] \
    || fail "SHA-256 архива FFmpeg изменился: $ffmpeg_archive"
[[ "$(sha256 "$patch_file")" == "$expected_patch_sha" ]] \
    || fail "SHA-256 build-only патча изменился: $patch_file"

# 2. Toolchain evidence.
toolchain_out="$evidence_dir/untrunc-toolchain.txt"
{
    print "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    print "MACOSX_DEPLOYMENT_TARGET=14.0"
    print "sdk_path: $(xcrun --show-sdk-path)"
    print "sdk_version: $(xcrun --show-sdk-version)"
    clang --version | sed 's/^/clang: /'
    make --version | head -1 | sed 's/^/make: /'
    print "build_command: make untrunc-81 IS_RELEASE=1 NJOBS=<cpu>"
    print "build-only patch: Packaging/untrunc-local-archive-build.patch (сеть запрещена, VER=archive-9d86ec9)"
} > "$evidence_dir/untrunc-toolchain.txt"

# 3. Чистая распаковка: untrunc-исходники + патч + локальный FFmpeg.
rm -rf "$build_root"
mkdir -p "$build_root/source"
# Архив untrunc НЕ имеет обёртки-каталога: Makefile лежит на верхнем
# уровне, поэтому распаковка без --strip-components.
tar -xzf "$untrunc_archive" -C "$build_root/source"
patch -d "$build_root/source" -p1 < "$patch_file" \
    > "$evidence_dir/untrunc-patch.txt" 2>&1 \
    || fail "build-only патч завершился с ошибкой (см. untrunc-patch.txt)"
[[ -z "$(find "$build_root/source" -name '*.rej' -o -name '*.orig' 2>/dev/null)" ]] \
    || fail "патч оставил .rej/.orig — однократное чистое применение нарушено"
# FFmpeg распаковывается ВНУТРЬ дерева исходников: архив содержит
# обёртку ffmpeg-8.1/, Makefile собирает ffmpeg-8.1 именно отсюда
# (link -L$(FF_DIR)/libav*), рядом нет других копий библиотек —
# линковка возможна только со свежесобранными .a.
tar -xJf "$ffmpeg_archive" -C "$build_root/source"
# Проверенный архив кладётся рядом: правило Makefile требует его как
# prerequisite и распаковывает само (сеть не используется).
cp "$ffmpeg_archive" "$build_root/source/ffmpeg-8.1.tar.xz"
[[ -x "$build_root/source/ffmpeg-8.1/configure" ]] \
    || fail "ffmpeg-8.1/configure отсутствует после распаковки локального архива"

# 4. Сборка: arm64, deployment target 14.0, прежний минимальный рецепт.
(
    cd "$build_root/source"
    export MACOSX_DEPLOYMENT_TARGET=14.0
    make untrunc-81 IS_RELEASE=1 NJOBS="$(sysctl -n hw.logicalcpu)" \
        FF_CONFIG_FLAGS="--disable-doc --disable-everything --enable-decoders --disable-vdpau --enable-demuxers --enable-protocol=file --disable-avdevice --disable-swresample --disable-swscale --disable-avfilter --disable-xlib --disable-vaapi --disable-zlib --disable-bzlib --disable-lzma --disable-audiotoolbox --disable-videotoolbox --disable-libdrm --disable-autodetect --disable-sdl2" \
        FF_ARCHIVE="$build_root/source/ffmpeg-8.1.tar.xz" \
        > "$evidence_dir/untrunc-make-output.txt" 2>&1 \
        || fail "make untrunc-81 завершился с ошибкой"
)

ff_dir="$build_root/source/ffmpeg-8.1"

# 5. Конфигурационные evidence FFmpeg (малые текстовые файлы).
# В FFmpeg 8.1 config.mak генерируется в ffbuild/, config.h — в корне.
cp "$ff_dir/config.h" "$evidence_dir/untrunc-ffmpeg-config.h"
cp "$ff_dir/ffbuild/config.mak" "$evidence_dir/untrunc-ffmpeg-config.mak"
python3 "$project_dir/Scripts/verify-ffmpeg-config.py" "$ff_dir/config.h" "$ff_dir/ffbuild/config.mak" \
    > "$evidence_dir/untrunc-ffmpeg-config-summary.txt" || fail "FFmpeg configuration guard failed"

# 6. Доказательство линковки со свежими библиотеками этой сборки:
#    дерево собрано с нуля в очищенном каталоге; .a собраны в том же
#    make-прогоне непосредственно перед линковкой untrunc.
{
    print "Свежие статические библиотеки этой сборки (timestamps):"
    ls -l "$ff_dir"/libavformat/libavformat.a "$ff_dir"/libavcodec/libavcodec.a \
          "$ff_dir"/libavutil/libavutil.a
    print "Команда линковки untrunc (из журнала make):"
    link_command="$(grep -E '(^|[[:space:]])-o untrunc-81([[:space:]]|$)' "$evidence_dir/untrunc-make-output.txt" | tail -1)"
    [[ -n "$link_command" ]] || fail "missing actual linker command"
    for library in avformat avcodec avutil; do
        [[ "$link_command" == *"-Lffmpeg-8.1/lib${library}"* ]] || fail "unexpected library location: $library"
        shasum -a 256 "$ff_dir/lib${library}/lib${library}.a"
    done
    print -r -- "$link_command"
    print "otool -L кандидата (динамические зависимости):"
    otool -L "$build_root/source/untrunc-81"
} > "$evidence_dir/untrunc-link-evidence.txt"

# 7. Кандидат: изолированный staging или замена ThirdParty.
if [[ -n "$stage_dir" ]]; then
    mkdir -p "$stage_dir"
    cp "$build_root/source/untrunc-81" "$stage_dir/untrunc"
else
    mkdir -p "$destination"
    cp "$build_root/source/untrunc-81" "$destination/untrunc"
    stage_dir="$destination"
fi

{
    print "untrunc_archive_sha256=$expected_untrunc_sha"
    print "ffmpeg_archive_sha256=$expected_ffmpeg_sha"
    print "build_only_patch_sha256=$expected_patch_sha"
    print "deploy_target=14.0 sdk=$(xcrun --show-sdk-version)"
} >> "$toolchain_out"
shasum -a 256 "$stage_dir/untrunc"
# Keep only the configure summary and actual link command, not a huge make log.
awk 'NR <= 60 || /(^|[[:space:]])-o untrunc-81([[:space:]]|$)/' \
    "$evidence_dir/untrunc-make-output.txt" > "$evidence_dir/untrunc-make-output.txt.small"
mv "$evidence_dir/untrunc-make-output.txt.small" "$evidence_dir/untrunc-make-output.txt"
shasum -a 256 "$ff_dir/config.h" "$ff_dir/ffbuild/config.mak" \
    > "$evidence_dir/untrunc-raw-config-sha256.txt"
perl -0777 -pi -e 's/[ \t]+(?=\r?$)//mg; s/\n+\z/\n/' "$evidence_dir"/untrunc-*.txt "$evidence_dir"/untrunc-ffmpeg-config.mak
