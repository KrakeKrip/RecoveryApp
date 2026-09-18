#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
source_dir="${UNTRUNC_SOURCE_DIR:-$project_dir/work/vendor/untrunc}"
commit="9d86ec9ef2ffed1bf8131abe80742c0574db52b6"
ffmpeg_archive="/tmp/ffmpeg-8.1.tar.xz"
ffmpeg_sha256="b072aed6871998cce9b36e7774033105ca29e33632be5b6347f3206898e0756a"
destination="$project_dir/ThirdParty/untrunc/bin/arm64/untrunc"

if [[ ! -d "$source_dir/.git" ]]; then
    mkdir -p "${source_dir:h}"
    git clone https://github.com/anthwlock/untrunc.git "$source_dir"
fi

git -C "$source_dir" fetch origin "$commit"
git -C "$source_dir" checkout --detach "$commit"

if [[ -f "$ffmpeg_archive" ]]; then
    actual_sha256="$(shasum -a 256 "$ffmpeg_archive" | awk '{print $1}')"
    [[ "$actual_sha256" == "$ffmpeg_sha256" ]] || {
        echo "Неверная SHA-256 загруженного FFmpeg 8.1" >&2
        exit 1
    }
fi

make -C "$source_dir" untrunc-81 IS_RELEASE=1 NJOBS="${BUILD_JOBS:-4}"
mkdir -p "${destination:h}"
cp "$source_dir/untrunc-81" "$destination"
chmod +x "$destination"
file "$destination"
otool -L "$destination"
shasum -a 256 "$destination"
