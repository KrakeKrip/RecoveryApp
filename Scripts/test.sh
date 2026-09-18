#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
cache_dir="${BUILD_CACHE_DIR:-$project_dir/work/swift-test}"
sdk_root="${RECOVERYAPP_SDKROOT:-$(xcrun --show-sdk-path)}"

cd "$project_dir"
mkdir -p "$cache_dir/module-cache"
export SDKROOT="$sdk_root"
export CLANG_MODULE_CACHE_PATH="$cache_dir/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$cache_dir/module-cache"
swiftc \
    -sdk "$sdk_root" \
    -target arm64-apple-macos14.0 \
    Sources/RecoveryApp/AppModel.swift \
    Sources/RecoveryApp/VideoRepair.swift \
    Sources/RecoveryApp/ExternalDrive.swift \
    Sources/RecoveryApp/LogSanitizer.swift \
    Sources/RecoveryApp/DeletedFilesRecovery.swift \
    Sources/RecoveryApp/UserFacingFailure.swift \
    Tests/UnitHarness/main.swift \
    -o "$cache_dir/RecoveryAppUnitTests"
"$cache_dir/RecoveryAppUnitTests"
