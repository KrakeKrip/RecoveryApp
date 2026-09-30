# TASK-011 — проверка интерфейса и упаковки

Статус: DONE. Исполнитель: Codex. Дата: 2026-09-30.
Ветка: `codex/task-011-ui-package-check`.
База и коммит проверенного кода: `7e1d53128c6433f84746d87a1868c2d0139b4924`.
Итоговый хеш коммита передаётся отдельно: записать собственный хеш внутрь этого же коммита невозможно.

## Изменённые файлы

- `tasks/TASK-011.md`
- `TASKS.md`
- `STATUS.md`
- `reports/TASK-011.md`

Код приложения, версия 0.8.1 (13), иконка и архитектура безопасности не изменялись.

## Проверено

Собрана новая release `.app` с SDK `/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`. Через GUI запущено именно новое приложение: визуально проверены главный экран, экран восстановления удалённых файлов и экран восстановления видео, переходы назад и состояние кнопок до выбора источника. Реальное восстановление в этой задаче не запускалось; пользовательские файлы не открывались.

Команды запускались из `/Users/atlhnv/RecoveryApp`:

```sh
env RECOVERYAPP_SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk BUILD_CACHE_DIR=/private/tmp/recoveryapp-package-check.E80f67/cache OUTPUT_DIR=/Users/atlhnv/Codex/RecoveryApp-lab-20260930.7Pgf3S ./Scripts/build-app.sh
zsh -n Scripts/package-dmg.sh
env RECOVERYAPP_SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk BUILD_CACHE_DIR=/private/tmp/recoveryapp-package-check.E80f67/cache OUTPUT_DIR=/Users/atlhnv/Codex/RecoveryApp-lab-20260930.7Pgf3S DMG_NAME=RecoveryApp-arm64-v0.8.1-lab-20260930.dmg ./Scripts/package-dmg.sh
hdiutil verify /Users/atlhnv/Codex/RecoveryApp-lab-20260930.7Pgf3S/RecoveryApp-arm64-v0.8.1-lab-20260930.dmg
codesign --verify --deep --strict /Users/atlhnv/Codex/RecoveryApp-lab-20260930.7Pgf3S/RecoveryApp.app
codesign --verify --deep --strict /private/tmp/recoveryapp-package-check.E80f67/mounted/RecoveryApp.app
cmp /Users/atlhnv/Codex/RecoveryApp-lab-20260930.7Pgf3S/RecoveryApp.app/Contents/MacOS/RecoveryApp /private/tmp/recoveryapp-package-check.E80f67/mounted/RecoveryApp.app/Contents/MacOS/RecoveryApp
env OUTPUT_DIR=/Users/atlhnv/Codex/RecoveryApp-lab-20260930.7Pgf3S SOURCE_ARCHIVE_NAME=RecoveryApp-source-v0.8.1-lab-20260930.zip ./Scripts/package-source.sh
unzip -tq /Users/atlhnv/Codex/RecoveryApp-lab-20260930.7Pgf3S/RecoveryApp-source-v0.8.1-lab-20260930.zip
unzip -p /Users/atlhnv/Codex/RecoveryApp-lab-20260930.7Pgf3S/RecoveryApp-source-v0.8.1-lab-20260930.zip RecoveryApp/STATUS.md | cmp - STATUS.md
```

Все перечисленные проверки завершились кодом 0. Вложенный бинарник DMG побайтно совпадает с приложением, проверенным через GUI. Вложенный Info.plist подтверждает 0.8.1 (13), бинарник — Mach-O arm64. Ссылка «Программы» ведёт на `/Applications`. Инструкция первого запуска совпадает с `Packaging/ПЕРВЫЙ ЗАПУСК.txt`, использует официальный путь «Всё равно открыть» и не предлагает отключать Gatekeeper.

DMG открыт через Finder: проверены существующий сливовый фон, расположение приложения, ссылки «Программы», стрелки и инструкции. Новое оформление в этой задаче не создавалось. Оба подключения созданного DMG были только для чтения.

## Артефакты

Папка: `/Users/atlhnv/Codex/RecoveryApp-lab-20260930.7Pgf3S`.

- `RecoveryApp-arm64-v0.8.1-lab-20260930.dmg`, SHA-256: `f3977de4e1cbe807cf8290455b8d4c0c679db73a10d922dad3d00d91e9933a05`.
- `RecoveryApp-source-v0.8.1-lab-20260930.zip`, SHA-256: `8c5b878d94eea2db7890eb6f2db099144adcc65fafab01ad668222c6c05fd94f`.
- Свежая `RecoveryApp.app` сохранена рядом.

## Не проверено и ограничения

- Первый запуск с карантином на другом Mac, Developer ID и нотариализация отсутствуют. Это лабораторная сборка, не готовность к массовой публикации.
- Полный набор восстановления и доменный harness в этой задаче не повторялись: код не менялся. Предыдущие результаты не выдаются за новый прогон.
- Физические носители, authopen и число системных запросов не проверялись. Пользователь отложил выяснение возможного повторного запроса пароля; исправление этой проблемы не заявляется. TASK-010 остаётся REVIEW.
- Окончательная публичная лицензионная приёмка и расширенные реальные испытания остаются отдельными этапами.

## Уборка

Удаляются только два подключения собственного DMG и временный каталог `/private/tmp/recoveryapp-package-check.E80f67` с кэшем этой проверки. Релизные артефакты сохранены. `.mimosa/`, `outputs/physical-quick-no-name-20260922/`, прежние релизы и результаты пользователя не изменялись.
