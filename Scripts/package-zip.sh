#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
output_dir="${OUTPUT_DIR:-$project_dir/outputs}"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_dir/Packaging/Info.plist")"
archive_name="${APP_ARCHIVE_NAME:-RecoveryApp-arm64-v${version}-lab.zip}"
stage_dir="$(mktemp -d /private/tmp/recoveryapp-package.XXXXXX)"
trap 'rm -rf "$stage_dir"' EXIT

OUTPUT_DIR="$stage_dir" "$project_dir/Scripts/build-app.sh"
find "$stage_dir/RecoveryApp.app" -exec touch -h -t 202001010000 {} +
codesign --verify --deep --strict "$stage_dir/RecoveryApp.app"
mkdir -p "$output_dir"
rm -f "$output_dir/$archive_name"
(
    cd "$stage_dir"
    COPYFILE_DISABLE=1 /usr/bin/zip -X -q -r "$archive_name" RecoveryApp.app
)
cp "$stage_dir/$archive_name" "$output_dir/$archive_name"
echo "$output_dir/$archive_name"
