#!/bin/zsh
# TASK-016: контрольная сборка The Sleuth Kit 4.15.0 из прикладываемого
# локального архива с обязательной проверкой SHA-256 входов до распаковки,
# однократным применением патча и записью toolchain-evidence.
#
# По умолчанию результаты копируются в ThirdParty/sleuthkit/bin/arm64
# (как раньше). Если задан STAGE_DIR, кандидаты складываются туда —
# для проверки до замены рабочих бинарников.

set -euo pipefail

project_dir="${0:A:h:h}"
source_archive="$project_dir/outputs/sleuthkit-4.15.0-source.tar.gz"
patch_file="$project_dir/Packaging/sleuthkit-preopened-fd.patch"
expected_archive_sha="3a8c1e7d18a9b81f3e5e8aa78313974aceaafc6e051d636bc92cd7168286eca9"
expected_patch_sha="f0867d74d9f0385ee47c3d42df4c1988d5c8c74c6e60cd14956d3ea258468594"
destination="$project_dir/ThirdParty/sleuthkit/bin/arm64"
stage_dir="${STAGE_DIR:-}"
# Рабочий каталог — фиксированный собственный путь внутри проекта;
# произвольные пути из окружения не удаляются.
build_root="$project_dir/work/TASK-016/sleuthkit-build"
evidence_dir="$project_dir/docs/build-evidence/TASK-016"

fail() {
    print "FAIL(sleuthkit): $1" >&2
    exit 1
}

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

mkdir -p "$evidence_dir"

# 1. Входы: проверка SHA до распаковки.
[[ "$(sha256 "$source_archive")" == "$expected_archive_sha" ]] \
    || fail "SHA-256 архива TSK изменился: $source_archive"
[[ "$(sha256 "$patch_file")" == "$expected_patch_sha" ]] \
    || fail "SHA-256 патча изменился: $patch_file"

# 2. Toolchain evidence (SDK, compiler, make).
toolchain_out="$evidence_dir/sleuthkit-toolchain.txt"
{
    print "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    print "MACOSX_DEPLOYMENT_TARGET=14.0"
    print "sdk_path: $(xcrun --show-sdk-path)"
    print "sdk_version: $(xcrun --show-sdk-version)"
    clang --version | sed 's/^/clang: /'
    make --version | head -1 | sed 's/^/make: /'
} > "$toolchain_out"

# 3. Чистая распаковка и однократный патч.
rm -rf "$build_root"
mkdir -p "$build_root/source"
tar -xzf "$source_archive" -C "$build_root/source" --strip-components=1
patch -d "$build_root/source" -p1 < "$patch_file" \
    > "$evidence_dir/sleuthkit-patch.txt" 2>&1 \
    || fail "патч завершился с ошибкой (см. docs/build-evidence/TASK-016/sleuthkit-patch.txt)"
[[ -z "$(find "$build_root/source" -name '*.rej' -o -name '*.orig' 2>/dev/null)" ]] \
    || fail "патч оставил .rej/.orig — однократное чистое применение нарушено"

# 4. Сборка: arm64, deployment target 14.0, прежние функциональные флаги.
{
    print "configure: ./configure --disable-java --disable-shared --enable-static --without-afflib --without-libewf --without-libvhdi --without-libvmdk"
    print "CFLAGS='-O2 -arch arm64' CXXFLAGS='-O2 -arch arm64' LDFLAGS='-arch arm64'"
} > "$evidence_dir/sleuthkit-configure.txt"
(
    cd "$build_root/source"
    env \
        MACOSX_DEPLOYMENT_TARGET=14.0 \
        CFLAGS='-O2 -arch arm64' \
        CXXFLAGS='-O2 -arch arm64' \
        LDFLAGS='-arch arm64' \
        ./configure \
            --disable-java \
            --disable-shared \
            --enable-static \
            --without-afflib \
            --without-libewf \
            --without-libvhdi \
            --without-libvmdk \
        > "$evidence_dir/sleuthkit-configure-output.txt" 2>&1 \
        || fail "configure завершился с ошибкой"
    make -j"$(sysctl -n hw.logicalcpu)" \
        > "$evidence_dir/sleuthkit-make-output.txt" 2>&1 \
        || fail "make завершился с ошибкой"
)

# 5. Кандидаты: изолированный staging или замена ThirdParty.
if [[ -n "$stage_dir" ]]; then
    mkdir -p "$stage_dir"
    cp "$build_root/source/tools/fstools/fls" "$stage_dir/fls"
    cp "$build_root/source/tools/fstools/icat" "$stage_dir/icat"
    cp "$build_root/source/tools/vstools/mmls" "$stage_dir/mmls"
else
    mkdir -p "$destination"
    cp "$build_root/source/tools/fstools/fls" "$destination/fls"
    cp "$build_root/source/tools/fstools/icat" "$destination/icat"
    cp "$build_root/source/tools/vstools/mmls" "$destination/mmls"
    stage_dir="$destination"
fi

{
    print "sleuthkit 4.15.0; archive_sha256=$expected_archive_sha"
    print "patch_sha256=$expected_patch_sha"
    print "deploy_target=14.0 sdk=$(xcrun --show-sdk-version)"
} >> "$toolchain_out"
shasum -a 256 "$stage_dir/fls" "$stage_dir/icat" "$stage_dir/mmls"
