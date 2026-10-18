# Исправление переходов главного экрана, 2026-10-18

Ветка `codex/fix-sonoma-home-navigation`, база main
`57c9446b3c7ae36297f20acd58ab664936da1152`. Задание:
`tasks/FIX-SONOMA-NAVIGATION.md`. Статус REVIEW до приёмки на macOS 14.5.
Владелец отдельно разрешил main и новый Latest до этой приёмки.

## Наблюдение и реализация

На пользовательском видео: запуск после подтверждения macOS, нажатия карточки
не открывают раздел. Пользователь указал M2 и macOS 14.5. Это не доказывает
конкретный дефект SwiftUI, но recovery-инструменты не запускаются при выборе
раздела. Изменена только маршрутизация GUI: NavigationStack с явным путём,
value destination вместо optional-item presentation, прямоугольная зона клика.
`selectedFeature` остаётся единственным хранилищем; `navigationPath` — адаптер,
native Back очищает тот же выбор. Документация Apple описывает этот паттерн:
https://developer.apple.com/documentation/swiftui/navigationstack
Это не ссылка на доказательство конкретного бага Sonoma.

Изменённые файлы: Sources/RecoveryApp/AppModel.swift, RootView.swift,
Tests/UnitHarness/main.swift, README.md, ARCHITECTURE.md, DECISIONS.md,
STATUS.md, TASKS.md, tasks/FIX-SONOMA-NAVIGATION.md и этот отчёт.
RecoveryCore, CLI, helpers, ThirdParty, иконка, версия и build не менялись.

## Проверки

Все shell-команды из корня проекта; SDK:
`/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`.
Собственные кэши и staging: `/private/tmp/recoveryapp-navigation.WvNbTJ`.

1. `RECOVERYAPP_SDKROOT=... BUILD_CACHE_DIR=.../tests ./Scripts/test.sh` — exit 0,
   PASS: 321 domain checks (308 + 13 навигационных: оба маршрута, пустой путь,
   Back, повторный выбор, замена раздела, test-screen входы).
2. `RECOVERYAPP_SDKROOT=... BUILD_CACHE_DIR=.../cli ./Scripts/test-cli.sh` — exit 0,
   все 8 групп PASS, обнаружено 0 внешних накопителей. ld предупреждает об
   отсутствующих каталогах Developer/Library/Frameworks и Developer/usr/lib;
   сборка и выполнение тестов завершились успешно.
3. `RECOVERYAPP_SDKROOT=... BUILD_CACHE_DIR=.../build OUTPUT_DIR=dist/NAVIGATION-20261018
   ./Scripts/build-app.sh` — exit 0. `file` — Mach-O arm64;
   `codesign --verify --deep --strict dist/NAVIGATION-20261018/RecoveryApp.app` — 0.
4. GUI новой .app (полный путь, без RECOVERYAPP_TEST_SCREEN), macOS 27.2:
   видео → native Back → файлы → Back → пустая область карточки файлов → Back
   → текст «Исправить видео» → Back. Все переходы подтвердились AX-деревом;
   оба экрана проверены визуально. Скриншоты в dist/NAVIGATION-20261018:
   home-screen.png, video-screen.png, deleted-screen.png. Тестовая копия закрыта.
5. `./Scripts/test-license-package.sh dist/NAVIGATION-20261018/RecoveryApp.app` — 0,
   комплект полон и совпадает с репозиторием.
6. ZIP через `COPYFILE_DISABLE=1 ditto -c -k --sequesterRsrc --keepParent ...`;
   `unzip -tq` — 0. DMG создан напрямую `python3 -m dmgbuild` с прежними
   Packaging/DMG/settings.py и новой .app (не повторная сборка).
   `hdiutil verify` — VALID. Собственный DMG подключён read-only/nobrowse в
   собственный tmp mount: строгая подпись вложенной .app — 0, cmp бинарника
   с проверенной .app — 0, ссылка «Программы» ведёт в /Applications;
   отключён только этот собственный тестовый образ.
7. Финальный source ZIP создаётся Scripts/package-source.sh с уникальным именем;
   CRC, исключения VCS/кэшей и совпадение изменённых источников проверяются перед
   загрузкой. SHA-256 четырёх распространяемых файлов — в SHA256SUMS.txt релиза.

## Граница результата

Новая упаковка v0.8.1-lab.2; приложение остаётся 0.8.1 (13). Старые релизы
не перезаписываются. Нет Developer ID или нотариализации. Без повторения
полного recovery-регресса: алгоритмы не менялись. Физические устройства,
authopen, системные пароли, пользовательские результаты не использовались.
macOS 14.5 недоступна локально; устранение именно исходной ошибки ждёт
проверки друга. Баг runtime/точный механизм не объявляются доказанными.

## Уборка

После упаковки удаляется только собственный /private/tmp/recoveryapp-navigation.WvNbTJ
с кэшами и staging. Готовые .app, DMG, ZIP приложения/исходников, SHA и снимки
сохраняются в отдельном dist/NAVIGATION-20261018. Старые dist, .mimosa и
outputs/physical-quick-no-name-20260922 не затронуты. Исходное пользовательское
видео не копируется в репозиторий и не загружается на GitHub.
