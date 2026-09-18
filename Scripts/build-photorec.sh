#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
testdisk_archive="$project_dir/outputs/testdisk-7.2-source.tar.bz2"
jpeg_archive="$project_dir/outputs/libjpeg-turbo-3.2.0-source.tar.gz"
build_root="$(mktemp -d "$project_dir/work/photorec-build.XXXXXX")"
jpeg_source="$build_root/libjpeg-source"
jpeg_build="$build_root/libjpeg-build"
jpeg_install="$build_root/libjpeg-install"
photorec_source="$build_root/photorec-source"

test -f "$testdisk_archive"
test -f "$jpeg_archive"
[[ "$(shasum -a 256 "$testdisk_archive" | awk '{print $1}')" == \
    "f8343be20cb4001c5d91a2e3bcd918398f00ae6d8310894a5a9f2feb813c283f" ]]
[[ "$(shasum -a 256 "$jpeg_archive" | awk '{print $1}')" == \
    "6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e" ]]

mkdir -p "$jpeg_source" "$jpeg_build" "$jpeg_install" "$photorec_source"
tar -xzf "$jpeg_archive" -C "$jpeg_source" --strip-components=1
tar -xjf "$testdisk_archive" -C "$photorec_source" --strip-components=1
patch -d "$photorec_source" -p1 < "$project_dir/Packaging/photorec-dev-fd.patch"

cmake -S "$jpeg_source" -B "$jpeg_build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DENABLE_SHARED=FALSE \
    -DWITH_SIMD=TRUE \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_INSTALL_PREFIX="$jpeg_install"
cmake --build "$jpeg_build" --parallel 8
cmake --install "$jpeg_build"

(
    cd "$photorec_source"
    ./configure \
        --disable-qt --disable-dfxml --enable-missing-uuid-ok \
        --without-ext2fs --without-ntfs --without-ntfs3g \
        --without-reiserfs --without-ewf --without-zlib --without-uuid \
        --with-jpeg \
        --with-jpeg-lib="$jpeg_install/lib" \
        --with-jpeg-includes="$jpeg_install/include" \
        CC=clang \
        CFLAGS='-O2 -arch arm64 -mmacosx-version-min=14.0' \
        LDFLAGS='-arch arm64 -mmacosx-version-min=14.0'
    make -C src -j8 photorec
)

cp "$photorec_source/src/photorec" \
    "$project_dir/ThirdParty/photorec/bin/arm64/photorec"
cp "$jpeg_source/LICENSE.md" \
    "$project_dir/ThirdParty/photorec/LIBJPEG-TURBO-LICENSE.md"
cp "$jpeg_source/README.ijg" \
    "$project_dir/ThirdParty/photorec/LIBJPEG-IJG-README.txt"
codesign --force --sign - --timestamp=none \
    "$project_dir/ThirdParty/photorec/bin/arm64/photorec"

"$project_dir/ThirdParty/photorec/bin/arm64/photorec" /version
shasum -a 256 "$project_dir/ThirdParty/photorec/bin/arm64/photorec"
echo "build=$build_root"
