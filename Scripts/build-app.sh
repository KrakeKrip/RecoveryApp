#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
configuration="${CONFIGURATION:-release}"
arch="${ARCHS:-arm64}"
output_dir="${OUTPUT_DIR:-$project_dir/dist}"
final_app_dir="$output_dir/RecoveryApp.app"
stage_dir="$(mktemp -d /private/tmp/recoveryapp-app-build.XXXXXX)"
app_dir="$stage_dir/RecoveryApp.app"
cache_dir="${BUILD_CACHE_DIR:-$project_dir/work/swift-build}"
sdk_root="${RECOVERYAPP_SDKROOT:-$(xcrun --show-sdk-path)}"

cleanup() {
    rm -rf "$stage_dir"
}
trap cleanup EXIT

cd "$project_dir"
mkdir -p "$cache_dir/module-cache"
export SDKROOT="$sdk_root"
export CLANG_MODULE_CACHE_PATH="$cache_dir/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$cache_dir/module-cache"
build_args=(--disable-sandbox --scratch-path "$cache_dir" -c "$configuration" --arch "$arch")
if [[ "$configuration" == "release" ]]; then
    mkdir -p "$cache_dir/release"
    core_dir="$cache_dir/release"
    # RecoveryCore — отдельный модуль, как в Package.swift, поэтому он собирается
    # раньше и подключается через swiftmodule и статическую библиотеку.
    swiftc \
        -O \
        -parse-as-library \
        -sdk "$sdk_root" \
        -target "$arch-apple-macos14.0" \
        -emit-module \
        -emit-module-path "$core_dir/RecoveryCore.swiftmodule" \
        -module-name RecoveryCore \
        "$project_dir"/Sources/RecoveryCore/*.swift
    swiftc \
        -O \
        -parse-as-library \
        -sdk "$sdk_root" \
        -target "$arch-apple-macos14.0" \
        -emit-library -static \
        -o "$core_dir/libRecoveryCore.a" \
        "$project_dir"/Sources/RecoveryCore/*.swift
    swiftc \
        -O \
        -parse-as-library \
        -sdk "$sdk_root" \
        -target "$arch-apple-macos14.0" \
        -I "$core_dir" \
        -L "$core_dir" \
        -lRecoveryCore \
        "$project_dir"/Sources/RecoveryApp/*.swift \
        -o "$core_dir/RecoveryApp"
    binary_path="$core_dir/RecoveryApp"
else
    swift build "${build_args[@]}"
    binary_path="$(swift build --disable-sandbox --scratch-path "$cache_dir" -c "$configuration" --arch "$arch" --show-bin-path)/RecoveryApp"
fi
test -x "$binary_path"

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources/Tools" \
    "$app_dir/Contents/Resources/SourceArchives"
cp "$binary_path" "$app_dir/Contents/MacOS/RecoveryApp"
cp "$project_dir/Packaging/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/Packaging/RecoveryApp.icns" "$app_dir/Contents/Resources/RecoveryApp.icns"
cp "$project_dir/ThirdParty/untrunc/bin/arm64/untrunc" "$app_dir/Contents/Resources/Tools/untrunc"
cp "$project_dir/ThirdParty/untrunc/COPYING" "$app_dir/Contents/Resources/Tools/untrunc-COPYING.txt"
cp "$project_dir/ThirdParty/untrunc/SOURCE.md" "$app_dir/Contents/Resources/Tools/untrunc-SOURCE.md"
cp "$project_dir/ThirdParty/sleuthkit/bin/arm64/fls" "$app_dir/Contents/Resources/Tools/fls"
cp "$project_dir/ThirdParty/sleuthkit/bin/arm64/icat" "$app_dir/Contents/Resources/Tools/icat"
cp "$project_dir/ThirdParty/sleuthkit/bin/arm64/mmls" "$app_dir/Contents/Resources/Tools/mmls"
cp "$project_dir/ThirdParty/sleuthkit/SOURCE.md" "$app_dir/Contents/Resources/Tools/sleuthkit-SOURCE.md"
cp "$project_dir/ThirdParty/sleuthkit/CPL-1.0.txt" "$app_dir/Contents/Resources/Tools/sleuthkit-CPL-1.0.txt"
cp "$project_dir/ThirdParty/sleuthkit/IBM-PUBLIC-LICENSE-1.0.txt" "$app_dir/Contents/Resources/Tools/sleuthkit-IPL-1.0.txt"
cp "$project_dir/ThirdParty/sleuthkit/LICENSES-README.md" "$app_dir/Contents/Resources/Tools/sleuthkit-LICENSES-README.md"
cp "$project_dir/ThirdParty/photorec/bin/arm64/photorec" "$app_dir/Contents/Resources/Tools/photorec"
cp "$project_dir/ThirdParty/photorec/COPYING" "$app_dir/Contents/Resources/Tools/photorec-COPYING.txt"
cp "$project_dir/ThirdParty/photorec/SOURCE.md" "$app_dir/Contents/Resources/Tools/photorec-SOURCE.md"
cp "$project_dir/ThirdParty/photorec/LIBJPEG-TURBO-LICENSE.md" "$app_dir/Contents/Resources/Tools/libjpeg-turbo-LICENSE.md"
cp "$project_dir/ThirdParty/photorec/LIBJPEG-IJG-README.txt" "$app_dir/Contents/Resources/Tools/libjpeg-IJG-README.txt"
cp "$project_dir/ThirdParty/untrunc/FFMPEG-COPYING.LGPLv2.1.txt" "$app_dir/Contents/Resources/Tools/ffmpeg-COPYING.LGPLv2.1.txt"
# photorec собран из изменённых исходников (/dev/fd/N) — GPL требует прикладывать
# патч рядом с исходными архивами.
cp "$project_dir/Packaging/photorec-dev-fd.patch" "$app_dir/Contents/Resources/SourceArchives/"
# Текст лицензии самого RecoveryApp (GPL-2) поставляется вместе с бинарником.
cp "$project_dir/LICENSE" "$app_dir/Contents/Resources/LICENSE"
cp "$project_dir/outputs/testdisk-7.2-source.tar.bz2" "$app_dir/Contents/Resources/SourceArchives/"
cp "$project_dir/outputs/libjpeg-turbo-3.2.0-source.tar.gz" "$app_dir/Contents/Resources/SourceArchives/"
cp "$project_dir/outputs/sleuthkit-4.15.0-source.tar.gz" "$app_dir/Contents/Resources/SourceArchives/"
cp "$project_dir/Packaging/sleuthkit-preopened-fd.patch" "$app_dir/Contents/Resources/SourceArchives/"
cp "$project_dir/outputs/untrunc-9d86ec9-source.tar.gz" "$app_dir/Contents/Resources/SourceArchives/"
cp "$project_dir/outputs/ffmpeg-8.1-source.tar.xz" "$app_dir/Contents/Resources/SourceArchives/"
# TASK-016: build-only патч untrunc (локальный архив FFmpeg вместо сети) и
# манифест/toolchain-evidence контрольных сборок.
cp "$project_dir/Packaging/untrunc-local-archive-build.patch" "$app_dir/Contents/Resources/SourceArchives/"
cp "$project_dir/ThirdParty/BUILD-PROVENANCE.json" "$app_dir/Contents/Resources/BUILD-PROVENANCE.json"
mkdir -p "$app_dir/Contents/Resources/BuildEvidence"
cp -R "$project_dir/docs/build-evidence/TASK-016" "$app_dir/Contents/Resources/BuildEvidence/TASK-016"
clang -Os "$project_dir/Packaging/tool-launcher.c" -o "$app_dir/Contents/Resources/Tools/tool-launcher"
clang -Os "$project_dir/Packaging/recoveryapp-readonly-helper.c" \
    -o "$app_dir/Contents/Resources/Tools/recoveryapp-readonly-helper"
clang -Wall -Wextra -Werror -Os "$project_dir/Packaging/recoveryapp-metadata-helper.c" \
    -o "$app_dir/Contents/Resources/Tools/recoveryapp-metadata-helper"

xattr -cr "$app_dir"
codesign --force --sign - --timestamp=none "$app_dir/Contents/Resources/Tools/untrunc"
codesign --force --sign - --timestamp=none "$app_dir/Contents/Resources/Tools/fls"
codesign --force --sign - --timestamp=none "$app_dir/Contents/Resources/Tools/icat"
codesign --force --sign - --timestamp=none "$app_dir/Contents/Resources/Tools/mmls"
codesign --force --sign - --timestamp=none "$app_dir/Contents/Resources/Tools/photorec"
codesign --force --sign - --timestamp=none "$app_dir/Contents/Resources/Tools/tool-launcher"
codesign --force --sign - --timestamp=none "$app_dir/Contents/Resources/Tools/recoveryapp-readonly-helper"
codesign --force --sign - --timestamp=none "$app_dir/Contents/Resources/Tools/recoveryapp-metadata-helper"
xattr -cr "$app_dir"
codesign --force --sign - --timestamp=none "$app_dir"
codesign --verify --deep --strict "$app_dir"

mkdir -p "$output_dir"
rm -rf "$final_app_dir"
COPYFILE_DISABLE=1 ditto --norsrc --noextattr "$app_dir" "$final_app_dir"
codesign --verify --deep --strict "$final_app_dir"

echo "$final_app_dir"
