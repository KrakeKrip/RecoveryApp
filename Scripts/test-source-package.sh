#!/bin/zsh
# Регрессионный тест исключений package-source.sh (TASK-015 ревью):
# синтетический проект с вложенными .git/.mimosa/__pycache__/*.pyc упаковывается
# без запретных записей, обычные файлы сохраняются. Реальное дерево и
# пользовательская .mimosa не затрагиваются.

set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
work="$(mktemp -d /tmp/recoveryapp-source-package-test.XXXXXX)"
synthetic="$work/RecoveryApp"
trap 'rm -rf "$work"' EXIT

fail() {
    print "FAIL: $1" >&2
    exit 1
}

# Каркас синтетического проекта: все позиции из списка копирования.
mkdir -p "$synthetic"/{Sources/RecoveryCore,Tests,Scripts,docs/subdir,Packaging} \
         "$synthetic"/ThirdParty/{sleuthkit/bin/arm64,photorec,BuildTools/python/pkg,BuildTools/licenses}
printf 'x\n' > "$synthetic/AGENTS.md"
printf 'x\n' > "$synthetic/Package.swift"
printf 'x\n' > "$synthetic/README.md"
printf 'x\n' > "$synthetic/STATUS.md"
printf 'x\n' > "$synthetic/LICENSE"
printf 'x\n' > "$synthetic/Sources/RecoveryCore/keep.swift"
printf 'x\n' > "$synthetic/Tests/keep.swift"
printf 'x\n' > "$synthetic/Scripts/keep.sh"
printf 'x\n' > "$synthetic/docs/keep.md"
printf 'x\n' > "$synthetic/docs/subdir/keep.md"
printf 'x\n' > "$synthetic/ThirdParty/sleuthkit/bin/arm64/tool"
printf 'x\n' > "$synthetic/ThirdParty/BuildTools/python/keep.py"
printf 'x\n' > "$synthetic/ThirdParty/BuildTools/licenses/keep-license"
cp "$project_dir/Packaging/Info.plist" "$synthetic/Packaging/Info.plist"

# Запретные записи на разной глубине.
mkdir -p "$synthetic/ThirdParty/.git/objects" "$synthetic/ThirdParty/photorec/.mimosa/deep" \
         "$synthetic/ThirdParty/BuildTools/python/pkg/__pycache__" \
         "$synthetic/docs/subdir/.git/objects" "$synthetic/Tests/__pycache__"
printf 'x\n' > "$synthetic/ThirdParty/.git/config"
printf 'x\n' > "$synthetic/ThirdParty/.git/objects/obj"
printf 'x\n' > "$synthetic/ThirdParty/photorec/.mimosa/state"
printf 'x\n' > "$synthetic/ThirdParty/photorec/.mimosa/deep/state"
printf 'x\n' > "$synthetic/ThirdParty/BuildTools/python/pkg/__pycache__/pkg.cpython.pyc"
printf 'x\n' > "$synthetic/docs/subdir/.git/config"
printf 'x\n' > "$synthetic/Tests/__pycache__/test.cpython.pyc"
printf 'x\n' > "$synthetic/.DS_Store"
# git worktree/submodule оставляет ОБЫЧНЫЙ файл `.git` с путём к служебному
# дереву — он тоже обязан исключаться (ревью r2).
mkdir -p "$synthetic/Scripts/.git-worktree-tmp"
printf 'gitdir: /synthetic/private/git/worktree\n' > "$synthetic/Scripts/.git"

# Заглушки исходных архивов (имена фиксированы сценарием упаковки).
mkdir -p "$synthetic/outputs"
for a in ffmpeg-8.1-source.tar.xz untrunc-9d86ec9-source.tar.gz \
         sleuthkit-4.15.0-source.tar.gz testdisk-7.2-source.tar.bz2 \
         libjpeg-turbo-3.2.0-source.tar.gz; do
    printf 'dummy\n' > "$synthetic/outputs/$a"
done

out_dir="$work/out"
SOURCE_PROJECT_DIR="$synthetic" OUTPUT_DIR="$out_dir" \
    SOURCE_ARCHIVE_NAME="source-package-exclusions-test.zip" \
    "$project_dir/Scripts/package-source.sh" > /dev/null

zip_path="$out_dir/source-package-exclusions-test.zip"
[[ -f "$zip_path" ]] || fail "архив не создан"
unzip -tq "$zip_path" > /dev/null || fail "архив повреждён"

listing="$(unzip -Z1 "$zip_path")"
# Запретное имя должно отсутствовать как полный компонент пути (файл ИЛИ
# каталог): `.git`-файл worktree/submodule не совпадает с шаблоном `.git/`.
forbidden_names=(".git" ".mimosa" "__pycache__" ".DS_Store")
while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    for comp in ${(s:/:)entry}; do
        for name in "${forbidden_names[@]}"; do
            [[ "$comp" == "$name" ]] && fail "в архиве запретная запись $entry"
        done
        [[ "$comp" == *.pyc ]] && fail "в архиве запретная запись $entry"
    done
done <<< "$listing"

for keep in "RecoveryApp/README.md" "RecoveryApp/LICENSE" \
            "RecoveryApp/Sources/RecoveryCore/keep.swift" \
            "RecoveryApp/Scripts/keep.sh" "RecoveryApp/docs/keep.md" \
            "RecoveryApp/docs/subdir/keep.md" \
            "RecoveryApp/ThirdParty/sleuthkit/bin/arm64/tool" \
            "RecoveryApp/ThirdParty/BuildTools/python/keep.py" \
            "RecoveryApp/ThirdParty/BuildTools/licenses/keep-license" \
            "RecoveryApp/outputs/sleuthkit-4.15.0-source.tar.gz"; do
    grep -qx "$keep" <<< "$listing" || fail "в архиве нет обычного файла $keep"
done

print "OK: исключения package-source.sh работают (.git/.mimosa/__pycache__/.pyc на любой глубине), обычные файлы сохранены"
