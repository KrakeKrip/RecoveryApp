#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
source_archive="$project_dir/outputs/sleuthkit-4.15.0-source.tar.gz"
build_root="${SLEUTHKIT_BUILD_DIR:-$project_dir/work/sleuthkit-build}"
source_dir="$build_root/source"
destination="$project_dir/ThirdParty/sleuthkit/bin/arm64"

rm -rf "$build_root"
mkdir -p "$source_dir" "$destination"
tar -xzf "$source_archive" -C "$source_dir" --strip-components=1
patch -d "$source_dir" -p1 < "$project_dir/Packaging/sleuthkit-preopened-fd.patch"

(
    cd "$source_dir"
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
            --without-libvmdk
    make -j"$(sysctl -n hw.logicalcpu)"
)

cp "$source_dir/tools/fstools/fls" "$destination/fls"
cp "$source_dir/tools/fstools/icat" "$destination/icat"
cp "$source_dir/tools/vstools/mmls" "$destination/mmls"
shasum -a 256 "$destination/fls" "$destination/icat" "$destination/mmls"
