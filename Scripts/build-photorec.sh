#!/bin/zsh
# TASK-016: контрольная сборка PhotoRec 7.2 (TestDisk) со статическим
# libjpeg-turbo 3.2.0 из прикладываемых локальных архивов: проверка SHA-256
# входов до распаковки, однократный патч, toolchain-evidence.
#
# По умолчанию результат копируется в ThirdParty/photorec/bin/arm64.
# Если задан STAGE_DIR, кандидат складывается туда — для проверки
# до замены рабочего бинарника.

set -euo pipefail

project_dir="${0:A:h:h}"
testdisk_archive="$project_dir/outputs/testdisk-7.2-source.tar.bz2"
jpeg_archive="$project_dir/outputs/libjpeg-turbo-3.2.0-source.tar.gz"
patch_file="$project_dir/Packaging/photorec-dev-fd.patch"
expected_testdisk_sha="f8343be20cb4001c5d91a2e3bcd918398f00ae6d8310894a5a9f2feb813c283f"
expected_jpeg_sha="6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e"
expected_patch_sha="47e3d5bc4c0dec549a0bb1723ac075d5c6dd02dbb3e1f5e9bf0bed245ae981d5"
destination="$project_dir/ThirdParty/photorec/bin/arm64"
stage_dir="${STAGE_DIR:-}"
# Фиксированный собственный рабочий каталог внутри проекта.
build_root="$project_dir/work/TASK-016/photorec-build"
evidence_dir="$project_dir/docs/build-evidence/TASK-016"

fail() {
    print "FAIL(photorec): $1" >&2
    exit 1
}

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

mkdir -p "$evidence_dir"

# 1. Входы: SHA до распаковки, отказ при изменении.
[[ "$(sha256 "$testdisk_archive")" == "$expected_testdisk_sha" ]] \
    || fail "SHA-256 архива testdisk изменился: $testdisk_archive"
[[ "$(sha256 "$jpeg_archive")" == "$expected_jpeg_sha" ]] \
    || fail "SHA-256 архива libjpeg-turbo изменился: $jpeg_archive"
[[ "$(sha256 "$patch_file")" == "$expected_patch_sha" ]] \
    || fail "SHA-256 патча изменился: $patch_file"

# 2. Toolchain evidence.
toolchain_out="$evidence_dir/photorec-toolchain.txt"
{
    print "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    print "MACOSX_DEPLOYMENT_TARGET=14.0"
    print "sdk_path: $(xcrun --show-sdk-path)"
    print "sdk_version: $(xcrun --show-sdk-version)"
    clang --version | sed 's/^/clang: /'
    cmake --version | head -1 | sed 's/^/cmake: /'
    make --version | head -1 | sed 's/^/make: /'
} > "$evidence_dir/photorec-toolchain.txt"

# 3. Чистая распаковка и однократный патч.
rm -rf "$build_root"
mkdir -p "$build_root"/{libjpeg-source,libjpeg-build,libjpeg-install,photorec-source}
jpeg_source="$build_root/libjpeg-source"
jpeg_build="$build_root/libjpeg-build"
jpeg_install="$build_root/libjpeg-install"
photorec_source="$build_root/photorec-source"
tar -xzf "$jpeg_archive" -C "$jpeg_source" --strip-components=1
tar -xjf "$testdisk_archive" -C "$photorec_source" --strip-components=1
patch -d "$photorec_source" -p1 < "$patch_file" \
    > "$evidence_dir/photorec-patch.txt" 2>&1 \
    || fail "патч завершился с ошибкой (см. docs/build-evidence/TASK-016/photorec-patch.txt)"
[[ -z "$(find "$photorec_source" -name '*.rej' -o -name '*.orig' 2>/dev/null)" ]] \
    || fail "патч оставил .rej/.orig — однократное чистое применение нарушено"

# 4. libjpeg-turbo 3.2.0: статическая arm64-сборка, прежние флаги.
cmake -S "$jpeg_source" -B "$jpeg_build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DENABLE_SHARED=FALSE \
    -DWITH_SIMD=TRUE \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_INSTALL_PREFIX="$jpeg_install" \
    > "$evidence_dir/photorec-cmake-output.txt" 2>&1 \
    || fail "cmake libjpeg завершился с ошибкой"
cmake --build "$jpeg_build" --parallel 8 \
    >> "$evidence_dir/photorec-cmake-output.txt" 2>&1 \
    || fail "сборка libjpeg завершилась с ошибкой"
cmake --install "$jpeg_build" >> "$evidence_dir/photorec-cmake-output.txt" 2>&1 \
    || fail "установка libjpeg завершилась с ошибкой"

# 5. PhotoRec: прежние configure-флаги, deployment target 14.0.
{
    print "cmake libjpeg: -DCMAKE_BUILD_TYPE=Release -DENABLE_SHARED=FALSE -DWITH_SIMD=TRUE -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0"
    print "configure photorec: ./configure --disable-qt --disable-dfxml --enable-missing-uuid-ok --without-ext2fs --without-ntfs --without-ntfs3g --without-reiserfs --without-ewf --without-zlib --without-uuid --with-jpeg --with-jpeg-lib=<install>/lib --with-jpeg-includes=<install>/include CC=clang CFLAGS='-O2 -arch arm64 -mmacosx-version-min=14.0' LDFLAGS='-arch arm64 -mmacosx-version-min=14.0'"
} > "$evidence_dir/photorec-configure.txt"
(
    cd "$photorec_source"
    export MACOSX_DEPLOYMENT_TARGET=14.0
    ./configure \
        --disable-qt --disable-dfxml --enable-missing-uuid-ok \
        --without-ext2fs --without-ntfs --without-ntfs3g \
        --without-reiserfs --without-ewf --without-zlib --without-uuid \
        --with-jpeg \
        --with-jpeg-lib="$jpeg_install/lib" \
        --with-jpeg-includes="$jpeg_install/include" \
        CC=clang \
        CFLAGS='-O2 -arch arm64 -mmacosx-version-min=14.0' \
        LDFLAGS='-arch arm64 -mmacosx-version-min=14.0' \
        > "$evidence_dir/photorec-configure-output.txt" 2>&1 \
        || fail "configure photorec завершился с ошибкой"
    make -C src -j8 photorec \
        >> "$evidence_dir/photorec-configure-output.txt" 2>&1 \
        || fail "make photorec завершился с ошибкой"
)

# 6. Кандидат: изолированный staging или замена ThirdParty.
if [[ -n "$stage_dir" ]]; then
    mkdir -p "$stage_dir"
    cp "$photorec_source/src/photorec" "$stage_dir/photorec"
else
    mkdir -p "$destination"
    cp "$photorec_source/src/photorec" "$destination/photorec"
    cp "$jpeg_source/LICENSE.md" \
        "$project_dir/ThirdParty/photorec/LIBJPEG-TURBO-LICENSE.md"
    cp "$jpeg_source/README.ijg" \
        "$project_dir/ThirdParty/photorec/LIBJPEG-IJG-README.txt"
    codesign --force --sign - --timestamp=none "$destination/photorec"
    stage_dir="$destination"
fi

{
    print "testdisk_sha256=$expected_testdisk_sha"
    print "libjpeg_sha256=$expected_jpeg_sha"
    print "patch_sha256=$expected_patch_sha"
    print "deploy_target=14.0 sdk=$(xcrun --show-sdk-version)"
} >> "$toolchain_out"
shasum -a 256 "$stage_dir/photorec"
