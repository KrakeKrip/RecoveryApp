#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
output_dir="${OUTPUT_DIR:-$project_dir/outputs}"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_dir/Packaging/Info.plist")"
archive_name="${SOURCE_ARCHIVE_NAME:-RecoveryApp-source-v${version}-lab.zip}"
stage_dir="$(mktemp -d /private/tmp/recoveryapp-source-package.XXXXXX)"
stage_project="$stage_dir/RecoveryApp"
trap 'rm -rf "$stage_dir"' EXIT

mkdir -p "$stage_project/outputs"
for item in AGENTS.md Package.swift README.md STATUS.md LICENSE GLM Sources Tests Scripts Packaging docs ThirdParty; do
    COPYFILE_DISABLE=1 ditto --norsrc --noextattr \
        "$project_dir/$item" "$stage_project/$item"
done
for archive in \
    ffmpeg-8.1-source.tar.xz \
    untrunc-9d86ec9-source.tar.gz \
    sleuthkit-4.15.0-source.tar.gz \
    testdisk-7.2-source.tar.bz2 \
    libjpeg-turbo-3.2.0-source.tar.gz; do
    cp "$project_dir/outputs/$archive" "$stage_project/outputs/$archive"
done

find "$stage_project" -name .DS_Store -delete
find "$stage_project" -exec touch -h -t 202001010000 {} +
mkdir -p "$output_dir"
rm -f "$output_dir/$archive_name"
(
    cd "$stage_dir"
    COPYFILE_DISABLE=1 /usr/bin/zip -X -q -r "$archive_name" RecoveryApp
)
cp "$stage_dir/$archive_name" "$output_dir/$archive_name"
unzip -tq "$output_dir/$archive_name"
echo "$output_dir/$archive_name"
