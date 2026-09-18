#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
output_dir="${OUTPUT_DIR:-$project_dir/outputs}"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_dir/Packaging/Info.plist")"
dmg_name="${DMG_NAME:-RecoveryApp-arm64-v${version}-lab.dmg}"
build_dir="$(mktemp -d /private/tmp/recoveryapp-dmg-build.XXXXXX)"
trap 'rm -rf "$build_dir"' EXIT

OUTPUT_DIR="$build_dir" "$project_dir/Scripts/build-app.sh"
codesign --verify --deep --strict "$build_dir/RecoveryApp.app"

mkdir -p "$output_dir"
rm -f "$output_dir/$dmg_name"
PYTHONPATH="$project_dir/ThirdParty/BuildTools/python" \
    python3 -m dmgbuild \
    -s "$project_dir/Packaging/DMG/settings.py" \
    -D "application=$build_dir/RecoveryApp.app" \
    -D "instruction=$project_dir/Packaging/ПЕРВЫЙ ЗАПУСК.txt" \
    -D "background=$project_dir/Packaging/DMG/background.png" \
    -D "volume_icon=$project_dir/Packaging/RecoveryApp.icns" \
    RecoveryApp \
    "$output_dir/$dmg_name"

hdiutil verify "$output_dir/$dmg_name"
echo "$output_dir/$dmg_name"
