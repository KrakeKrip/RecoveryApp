# Provenance контрольных сборок инструментов (TASK-016)

Дата: 2026-10-06. Ветка: `glm/task-016-toolchain-provenance`, база
`918070bc98af2edda95d5cec79d4c4b9862b5f01`. Машинный манифест:
`ThirdParty/BUILD-PROVENANCE.json`; проверка: `Scripts/test-toolchain-provenance.sh`.

## Что сделано

Все пять встроенных инструментов пересобраны из прикладываемых локальных
архивов hardened-сценариями: проверка SHA-256 входов до распаковки (отказ
при расхождении), чистая распаковка в собственном каталоге
`work/TASK-016/`, патч ровно один раз (отказ при `.rej`/`.orig`),
arm64 + deployment target 14.0, запись toolchain- и configure-evidence в
`docs/build-evidence/TASK-016/`, изолированный staging (`STAGE_DIR`) до
замены рабочих бинарников. После синтетической проверки кандидаты
установлены в `ThirdParty/*/bin/arm64` (команда установки и SHA до/после
подписи — в отчёте и манифесте). Прежние бинарники сохранены в
`dist/TASK-016-baseline-binaries/baseline/` (не коммитится).

Toolchain: Apple clang 21.0.0 (clang-2100.3.34.2), GNU Make 3.81,
CMake 4.4.3, SDK 26.5 (`MacOSX26.5.sdk`), `MACOSX_DEPLOYMENT_TARGET=14.0`.

## Sleuth Kit 4.15.0 — fls / icat / mmls

- Входы: `outputs/sleuthkit-4.15.0-source.tar.gz`
  (`3a8c1e7d…`), `Packaging/sleuthkit-preopened-fd.patch` (`259dfdb6…`).
- Конфигурация: `./configure --disable-java --disable-shared --enable-static
  --without-afflib --without-libewf --without-libvhdi --without-libvmdk`,
  `CFLAGS/CXXFLAGS='-O2 -arch arm64'`, `LDFLAGS='-arch arm64'`.
- Динамические зависимости (`otool -L`): системные `libz.1`, `libsqlite3`,
  `libSystem`, `libc++`. Прямой линковки libtsk в RecoveryApp нет.
- Результат: свежая сборка побайтно совпала с заменённым бинарником
  (fls `57c0c9ec…`, icat `af59a7f4…`, mmls `17968b5e…`); контрольная
  пересборка №2 дала те же SHA — детерминизм подтверждён двумя
  независимыми сборками. После ad-hoc подписи установлены как
  `283ea6fa…` / `a92a65f1…` / `89e87e67…`.
- Вывод: provenance fls/icat/mmls ДОКАЗАН цепочкой «архив+патч+конфигурация
  → бинарник» и побайтным совпадением.

## PhotoRec 7.2 + libjpeg-turbo 3.2.0

- Входы: `outputs/testdisk-7.2-source.tar.bz2` (`f8343be2…`),
  `outputs/libjpeg-turbo-3.2.0-source.tar.gz` (`6f30092c…`),
  `Packaging/photorec-dev-fd.patch` (`23f884ce…`).
- Конфигурация: libjpeg-turbo — CMake Release/`ENABLE_SHARED=FALSE`/
  `WITH_SIMD=TRUE`/arm64/14.0; PhotoRec — `./configure --disable-qt
  --disable-dfxml --enable-missing-uuid-ok --without-ext2fs --without-ntfs
  --without-ntfs3g --without-reiserfs --without-ewf --without-zlib
  --without-uuid --with-jpeg …`.
- Динамические зависимости: системные `libncurses.5.4`, `libiconv`,
  `libSystem`. libjpeg-turbo — статически.
- Результат: unsigned кандидат `d5c50c86…`; после ad-hoc подписи
  `32479bc9…` — ПОБАЙТНО совпал с заменённым бинарником (тот же toolchain,
  та же подпись): воспроизводимость подтверждена. Provenance ДОКАЗАН.

## untrunc (снимок 9d86ec9) + FFmpeg 8.1

- Входы: `outputs/untrunc-9d86ec9-source.tar.gz` (`a46bbb00…`),
  `outputs/ffmpeg-8.1-source.tar.xz` (`b072aed6…`), новый build-only патч
  `Packaging/untrunc-local-archive-build.patch` (`fc4a2b22…`).
- Сеть исключена: build-only патч заменяет правило Makefile, скачивающее
  FFmpeg с ffmpeg.org, на распаковку локального архива `FF_ARCHIVE`
  (отказ при отсутствии) и фиксирует строку версии `archive-9d86ec9`
  (сборка из архива, не из git-клона; прежний бинарник содержал
  `v1-9d86ec9`, полученный из git-метаданных клона). Патч меняет только
  сборочный рецепт, не код восстановления.
- Конфигурация FFmpeg — фактическая: `config.h` и `ffbuild/config.mak`
  сохранены в evidence (`untrunc-ffmpeg-config.h`/`.mak`,
  `untrunc-ffmpeg-config-summary.txt`). Проверки: `CONFIG_GPL`/`CONFIG_NONFREE`
  не установлены; внешние библиотеки не включены (x264/z/bz2/lzma/
  audiotoolbox/videotoolbox отсутствуют) — согласуется с `otool -L`
  кандидата: только системные `libSystem`, `libiconv`, `libc++`.
- Линковка именно со свежими библиотеками: дерево собирается с нуля в
  очищенном каталоге; FFmpeg распаковывается и собирается в том же дереве,
  из которого линкуется untrunc (`-Lffmpeg-8.1/libav*`); других копий
  libav* нет. `untrunc-link-evidence.txt` содержит команду линковки и
  состав динамических зависимостей.
- Результат после исправления Codex: `5a2d981c…` (кандидат до codesign) →
  после ad-hoc подписи `32174ade…`.
  С прежним бинарником `cda6c307…` побайтное совпадение НЕ заявляется
  (другая строка версии и другой путь сборки — git-клон против архива).
- Provenance нового бинарника ДОКАЗАН цепочкой; связь архива untrunc с
  коммитом 9d86ec9 остаётся UNVERIFIED (см. DISTRIBUTION_CHECKLIST.md).

## Замена рабочих бинарников

Кандидаты устанавливались только после сборки и проверок. SHA до/после
подписи и старые/новые значения — в `ThirdParty/BUILD-PROVENANCE.json` и
`reports/TASK-016.md`. Резервные копии прежних бинарников —
`dist/TASK-016-baseline-binaries/baseline/`. Новые dist-артефакты (`.app`,
source ZIP) собирались после замены; старые каталоги dist не
перезаписывались.

## Границы

- Не заявляется побайтная воспроизводимость untrunc (нет двух независимых
  сборок с идентичным результатом).
- TASK-016 не включала повторную оценку условий агрегирования и оформление
  уведомлений; они выполнены отдельно 2026-10-07 (см. checklist).
  Findings vendored dmgbuild и чистая установка на другом Mac остаются открыты.
- Синтетические проверки не доказывают работу на реальных носителях.

## Исправления Codex 2026-10-07

Начальная сборка GLM обнаруживала SDL2 из Homebrew и системные интеграции;
её summary ошибочно отрицал auto-detect. Действующий untrunc пересобран с
--disable-autodetect/--disable-sdl2. Generated config проверяется отдельным
guard (включённые GPL/nonfree/SDL2 отклоняются); фактические configuration и
license сохраняются. Действительная команда линковки и SHA свежих libav*.a
извлекаются сценарием, без ручного дописывания. Нормализация текстового
evidence удаляет только конечные пробелы/пустые строки; SHA сырых generated
конфигов сохранён в untrunc-raw-config-sha256.txt.

Manifest теперь фиксирует SHA всех evidence и рецептов. Checker отвергает
изменение бинарника, архива, evidence, рецепта, удаление evidence и пустые
обязательные ссылки. finalize-toolchain-provenance.py — явная обслуживающая
команда после проверенной сборки, не часть проверки: её запуск обновляет
эталонные pins и не является доказательством правильности сам по себе.
