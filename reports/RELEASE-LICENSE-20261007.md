# Повторная лицензионная проверка и пакет 2026-10-07

Ветка: `codex/release-license-notices`, база `c9876d2fff37aa7f2250c83dc0501e2e1e84219b`.
Прямая работа Codex по запросу владельца, не новая задача GLM.
Версия не менялась: 0.8.1 (13), arm64, macOS 14+.
Публичный GitHub Release не создан. Старые dist/outputs сохранены.

## Реализовано

- Во всех пяти изменённых сторонних файлах добавлены комментарии автора
  RecoveryApp project и даты 2026-10-07: PhotoRec hdaccess.c,
  TSK raw.c/file_system_utils.c/.h, untrunc Makefile. Функциональные
  строки существующих патчей не менялись.
- THIRD-PARTY-NOTICES.txt: отдельные лицензии компонентов, IBM copyright,
  явная благодарность IJG, статическое использование FFmpeg, Contributors
  warranty/liability, авторство локальных изменений, путь получения
  соответствующих исходников и право модификации/перелинковки.
- Build-app включает notices; license checker требует побайтного совпадения.
  Инструкция первого запуска указывает, как открыть notices внутри `.app`.
- Контрольные SHA патчей и recipes/evidence обновлены после пересборки
  и сравнения бинарников. Рабочие бинарники ThirdParty не заменялись:
  все пять подписанных кандидатов побайтно совпали с ними.
- Устаревшие provenance/лицензионные блокеры отделены от ограничений
  зрелости продукта. Отсутствие формального заключения юриста не считается
  само по себе условием лицензий; оценка не является юридической гарантией.

## Изменённые файлы

README.md, STATUS.md, TASKS.md; Packaging/THIRD-PARTY-NOTICES.txt,
Packaging/ПЕРВЫЙ ЗАПУСК.txt, три Packaging/*.patch; Scripts/build-app.sh,
build-photorec.sh, build-sleuthkit.sh, build-untrunc.sh, test-license-package.sh;
ThirdParty/BUILD-PROVENANCE.json, ThirdParty/untrunc/SOURCE.md;
docs/AGENT_GUIDE.md, DISTRIBUTION_CHECKLIST.md, SLEUTH_KIT_LICENSE_AUDIT.md,
TOOLCHAIN_PROVENANCE.md; контрольные build-evidence/TASK-016 журналы/config SHA;
этот отчёт. Sources/ и лицензии upstream не менялись.

## Проверки

Во всех следующих командах cwd — `/Users/atlhnv/RecoveryApp`.
Для сборок `STAGE_DIR=/private/tmp/recoveryapp-notices.KyyP3E/candidates`:

1. `./Scripts/build-photorec.sh`, `./Scripts/build-sleuthkit.sh`,
   `./Scripts/build-untrunc.sh` — успешные контрольные сборки из локальных
   архивов, только staging. SHA до подписи совпали с TASK-016.
2. `codesign --force --sign - --timestamp=none` каждого кандидата,
   `cmp` со своим `ThirdParty/*/bin/arm64/*` — все пять совпали побайтно.
3. `python3 Scripts/finalize-toolchain-provenance.py --unsigned-untrunc
   5a2d981cf0b6a4275c9f59f455976f4ad45b2f44b0df079b532c3497ec5a69dc`
   — явное обновление pins ПОСЛЕ проверки (не доказательство само по себе).
4. `./Scripts/test-toolchain-provenance.sh --selftest` — PASS основного
   контроля и восьми отрицательных случаев.
5. `python3 Scripts/verify-ffmpeg-config.py --selftest` и проверка фактических
   `docs/build-evidence/TASK-016/untrunc-ffmpeg-config.h` / `.mak` — PASS;
   external optional dependencies disabled, system integrations none.
6. `BUILD_CACHE_DIR=/private/tmp/recoveryapp-notices.KyyP3E/swift-test
   ./Scripts/test.sh` — `PASS: 308 domain checks`.
7. `./Scripts/test-source-package.sh` — PASS рекурсивных исключений.
8. `OUTPUT_DIR=$PWD/dist/RELEASE-20261007-notices
   BUILD_CACHE_DIR=/private/tmp/recoveryapp-notices.KyyP3E/swift-app
   ./Scripts/build-app.sh` — готовая `.app`; строгая подпись и arm64.
9. `./Scripts/test-license-package.sh dist/RELEASE-20261007-notices/RecoveryApp.app`
   — PASS. Отрицательный случай на собственном пустом missing-notice.app:
   отказ на отсутствующем THIRD-PARTY-NOTICES.txt, не ложный успех.
10. `OUTPUT_DIR=$PWD/dist/RELEASE-20261007-notices
    BUILD_CACHE_DIR=/private/tmp/recoveryapp-notices.KyyP3E/swift-app
    DMG_NAME=RecoveryApp-arm64-v0.8.1-lab-20261007.dmg ./Scripts/package-dmg.sh`
    — сборка и `hdiutil verify` успешны.
11. `hdiutil attach -readonly -nobrowse -mountpoint
    /private/tmp/recoveryapp-notices.KyyP3E/mounted <новый DMG>` — read-only
    монтирование; license checker и `codesign --verify --deep --strict`
    вложенной `.app` успешны; readlink Программы = /Applications;
    main-бинарник DMG совпал с новой standalone `.app`. Затем собственный
    образ отключён через `hdiutil detach <точка монтирования>`.
12. `OUTPUT_DIR=$PWD/dist/RELEASE-20261007-notices
    BUILD_CACHE_DIR=/private/tmp/recoveryapp-notices.KyyP3E/swift-app
    APP_ARCHIVE_NAME=RecoveryApp-arm64-v0.8.1-lab-20261007.zip
    ./Scripts/package-zip.sh` — архив готов; CRC и notices проверены.
13. `OUTPUT_DIR=$PWD/dist/RELEASE-20261007-notices
    SOURCE_ARCHIVE_NAME=RecoveryApp-source-v0.8.1-lab-20261007-final.zip
    ./Scripts/package-source.sh` — готовый ZIP, CRC без ошибок. Дополнительный
    ZIP-разбор сверил 88 файлов кода/recipes/patches/docs и ВСЕ evidence
    побайтно с деревом; приватных VCS/Mimosa/cache entries нет.
14. `zsh -n` пяти изменённых shell-сценариев, `git diff --check` — чисто.

Повторная сверка upstream untrunc до изменений: официальный
https://codeload.github.com/anthwlock/untrunc/tar.gz/9d86ec9ef2ffed1bf8131abe80742c0574db52b6
и локальный архив имеют одинаковый набор 53 файлов и SHA-256 содержимого
каждого файла. Равенство gzip/tar-метаданных не утверждается.

## Артефакты

В `dist/RELEASE-20261007-notices/`: новая RecoveryApp.app, DMG, ZIP приложения,
соответствующий final source ZIP и SHA256SUMS.txt.
Три публикуемых архива: около 30/28/30 МБ. Все точные SHA — в SHA256SUMS.txt.
Исходники должны сопровождать этот же бинарный релиз.

## Непроверенное и ограничения

Ни GUI, ни физические накопители/authopen в этой работе не запускались:
интерфейс не менялся, сторонние подписанные инструменты побайтно прежние.
Recovery runtime-регрессия всей матрицы отдельно не повторялась — повторены
доменный harness и упаковочные/provenance-проверки. Главный Swift-бинарник
новой `.app` не побайтно идентичен TASK-016 (другой сборочный каталог), хотя
Sources/ не менялись; побайтная воспроизводимость GUI не заявляется.
Finder-оформление нового DMG визуально не перепроверялось: настройки и фон
не менялись, содержимое и ссылка Applications проверены на read-only mount.
Нет Developer ID/нотариализации, второго Mac, массовой приёмки.
Findings dmgbuild остаются открытыми; создание DMG не доказывает безопасность
build-tool. Не является юридическим заключением по всем возможным условиям.

## Уборка

Собственные три дерева work/TASK-016/*-build и /private/tmp/recoveryapp-notices.KyyP3E
удалены после сверки и сохранения evidence. Предварительный source ZIP этого
прогона удалён после проверки final ZIP. Остальные work, старые dist,
outputs/physical-quick-no-name-20260922/ и .mimosa не изменялись.
