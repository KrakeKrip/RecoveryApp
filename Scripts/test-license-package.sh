#!/bin/zsh
# Автоматический контроль лицензионного комплекта .app (TASK-015).
# Использование: Scripts/test-license-package.sh <путь к RecoveryApp.app>
# Выходит с ошибкой, если обязательный файл отсутствует или побайтно
# отличается от исходника в репозитории.

set -euo pipefail

app_dir="${1:-}"
project_dir="${0:A:h:h}"

fail() {
    print "FAIL: $1" >&2
    exit 1
}

[[ -d "$app_dir" ]] || fail "не передан каталог .app: $0 <RecoveryApp.app>"

# (файл в .app, исходник в репозитории) — побайтное совпадение обязательно.
required_copies=(
    "Contents/Resources/THIRD-PARTY-NOTICES.txt:$project_dir/Packaging/THIRD-PARTY-NOTICES.txt"
    "Contents/Resources/LICENSE:$project_dir/LICENSE"
    "Contents/Resources/Tools/untrunc-COPYING.txt:$project_dir/ThirdParty/untrunc/COPYING"
    "Contents/Resources/Tools/untrunc-SOURCE.md:$project_dir/ThirdParty/untrunc/SOURCE.md"
    "Contents/Resources/Tools/ffmpeg-COPYING.LGPLv2.1.txt:$project_dir/ThirdParty/untrunc/FFMPEG-COPYING.LGPLv2.1.txt"
    "Contents/Resources/Tools/sleuthkit-CPL-1.0.txt:$project_dir/ThirdParty/sleuthkit/CPL-1.0.txt"
    "Contents/Resources/Tools/sleuthkit-IPL-1.0.txt:$project_dir/ThirdParty/sleuthkit/IBM-PUBLIC-LICENSE-1.0.txt"
    "Contents/Resources/Tools/sleuthkit-LICENSES-README.md:$project_dir/ThirdParty/sleuthkit/LICENSES-README.md"
    "Contents/Resources/Tools/sleuthkit-SOURCE.md:$project_dir/ThirdParty/sleuthkit/SOURCE.md"
    "Contents/Resources/Tools/photorec-COPYING.txt:$project_dir/ThirdParty/photorec/COPYING"
    "Contents/Resources/Tools/photorec-SOURCE.md:$project_dir/ThirdParty/photorec/SOURCE.md"
    "Contents/Resources/Tools/libjpeg-turbo-LICENSE.md:$project_dir/ThirdParty/photorec/LIBJPEG-TURBO-LICENSE.md"
    "Contents/Resources/Tools/libjpeg-IJG-README.txt:$project_dir/ThirdParty/photorec/LIBJPEG-IJG-README.txt"
    "Contents/Resources/SourceArchives/sleuthkit-4.15.0-source.tar.gz:$project_dir/outputs/sleuthkit-4.15.0-source.tar.gz"
    "Contents/Resources/SourceArchives/testdisk-7.2-source.tar.bz2:$project_dir/outputs/testdisk-7.2-source.tar.bz2"
    "Contents/Resources/SourceArchives/libjpeg-turbo-3.2.0-source.tar.gz:$project_dir/outputs/libjpeg-turbo-3.2.0-source.tar.gz"
    "Contents/Resources/SourceArchives/untrunc-9d86ec9-source.tar.gz:$project_dir/outputs/untrunc-9d86ec9-source.tar.gz"
    "Contents/Resources/SourceArchives/ffmpeg-8.1-source.tar.xz:$project_dir/outputs/ffmpeg-8.1-source.tar.xz"
    "Contents/Resources/SourceArchives/sleuthkit-preopened-fd.patch:$project_dir/Packaging/sleuthkit-preopened-fd.patch"
    "Contents/Resources/SourceArchives/photorec-dev-fd.patch:$project_dir/Packaging/photorec-dev-fd.patch"
    "Contents/Resources/SourceArchives/untrunc-local-archive-build.patch:$project_dir/Packaging/untrunc-local-archive-build.patch"
    "Contents/Resources/BUILD-PROVENANCE.json:$project_dir/ThirdParty/BUILD-PROVENANCE.json"
)

# Бинарники инструментов: обязательное присутствие.
required_tools=(untrunc fls icat mmls photorec tool-launcher
    recoveryapp-readonly-helper recoveryapp-metadata-helper)

for rel in "${required_copies[@]}"; do
    app_file="${app_dir}/${rel%%:*}"
    repo_file="${rel##*:}"
    [[ -f "$app_file" ]] || fail "отсутствует обязательный файл $app_file"
    cmp -s "$app_file" "$repo_file" \
        || fail "$app_file отличается от $repo_file"
done

for tool in "${required_tools[@]}"; do
    [[ -x "$app_dir/Contents/Resources/Tools/$tool" ]] \
        || fail "отсутствует инструмент $tool"
done

# TASK-016: toolchain-evidence в .app побайтно равны репозиторию.
evidence_src="$project_dir/docs/build-evidence/TASK-016"
[[ -d "$evidence_src" ]] || fail "нет evidence-каталога $evidence_src"
for ev in "$evidence_src"/*(N); do
    name="${ev:t}"
    app_ev="$app_dir/Contents/Resources/BuildEvidence/TASK-016/$name"
    [[ -f "$app_ev" ]] || fail "отсутствует evidence $app_ev"
    cmp -s "$app_ev" "$ev" || fail "evidence $name отличается от репозитория"
done

print "OK: лицензионный комплект $app_dir полон и совпадает с репозиторием"
