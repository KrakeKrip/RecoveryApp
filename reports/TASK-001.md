# REPORT TASK-001

## Коммит

Полный хеш итогового коммита сообщается Codex в ответе исполнителя: отчёт входит
в сам итоговый коммит, поэтому хеш коммита невозможно записать внутри него.
Ветка: `glm/task-001-cli-foundation`, базовый коммит `9bbb5ec15b84e50f95ba4ae9b9fecbad9f662abf`.

## Реализовано

- Добавлен library target `RecoveryCore` (`Sources/RecoveryCore`).
- Перенесены без изменения поведения `ExternalDrive`, `ExternalDriveError`,
  `ExternalDriveParser` и `ExternalDriveDiscovery` (`git mv`), добавлены только
  `public`-модификаторы и `public init()` — обязательное следствие разделения
  модулей; логика не менялась.
- `RecoveryApp` подключён к `RecoveryCore` в `Package.swift`; в
  `DeletedFilesRecovery.swift` и `DeletedFilesView.swift` добавлен только
  `import RecoveryCore`. SwiftUI-код, внешний вид, версия, иконка и упаковка
  не менялись.
- Добавлен executable product и target `recoveryapp-cli`
  (`Sources/recoveryapp-cli`) с командами `version`, `version --json`,
  `drives list`, `drives list --json`, `help`; запуск без аргументов показывает
  справку с кодом 0.
- Человекочитаемый вывод — русский; `--json` формируется через `JSONEncoder`
  (`.sortedKeys`), без конкатенации строк; машинный результат — в stdout,
  диагностика и подсказки — в stderr; пароль CLI не принимает.
- `drives list` использует общий `ExternalDriveDiscovery` и только читает список
  `diskutil list -plist external physical`; содержимое дисков не открывается.
- Неизвестные команда, параметр, подкоманда `drives` и лишние аргументы дают
  код выхода 2 и подсказку в stderr; коды выхода 0/1/2 задокументированы в help.
- Разбор аргументов — чистая тестируемая функция без внешних зависимостей
  (`CommandLineParser.swift`), покрыта 11 новыми юнит-проверками в
  `Tests/UnitHarness/main.swift` (счётчик харнесса 28 → 39).
- Добавлен `Scripts/test-cli.sh`: 8 детерминированных проверок `version`,
  `help`, запуска без аргументов, ошибочной команды, лишнего аргумента и JSON
  обеих схем (включая пустой массив дисков). Флешка не требуется.
- `Scripts/test.sh` и release-ветка `Scripts/build-app.sh` адаптированы к
  разделению модулей: RecoveryCore компилируется `swiftc` в отдельный
  swiftmodule и статическую библиотеку, затем приложение/харнесс линкуются с
  ней. Состав `.app`, подпись и упаковка не менялись.

## Файлы

- Созданы:
  - `Sources/recoveryapp-cli/CommandLineParser.swift`
  - `Sources/recoveryapp-cli/CLIReports.swift`
  - `Sources/recoveryapp-cli/main.swift`
  - `Scripts/test-cli.sh`
  - `reports/TASK-001.md`
- Изменены:
  - `Package.swift` — target `RecoveryCore`, executable `recoveryapp-cli`,
    зависимость `RecoveryApp` от `RecoveryCore`
  - `Sources/RecoveryApp/DeletedFilesRecovery.swift` — только `import RecoveryCore`
  - `Sources/RecoveryApp/DeletedFilesView.swift` — только `import RecoveryCore`
  - `Scripts/test.sh` — двухэтапная сборка (модуль + харнесс)
  - `Scripts/build-app.sh` — release-ветка: двухэтапная сборка (модуль + приложение)
  - `Tests/UnitHarness/main.swift` — `import RecoveryCore`, +11 проверок парсера
  - `TASKS.md` — только статус TASK-001 `TODO` → `REVIEW`
- Перемещены:
  - `Sources/RecoveryApp/ExternalDrive.swift` → `Sources/RecoveryCore/ExternalDrive.swift`
- Удалены: нет.

## Проверки

| Команда | Результат | Вывод |
|---|---|---|
| `./Scripts/test.sh` | PASS | `PASS: 39 domain checks` |
| `./Scripts/test-cli.sh` | PASS | 8 строк `PASS: …`; `Build complete! (16,95 с)`; `PASS: все проверки CLI прошли` |
| `swift build -c release --product recoveryapp-cli` | PASS | `Build complete! (17,30 с)`; обход SDK из README не потребовался |
| `./Scripts/build-app.sh` | PASS | собрана и подписана `/Users/atlhnv/RecoveryApp/dist/RecoveryApp.app` |
| `codesign --verify --deep --strict dist/RecoveryApp.app` | PASS | код выхода 0 |

Дополнительно:

- Смоук-тест релизного бинарника CLI:
  `version --json` → `{"appVersion":"0.8.1","build":"13","schemaVersion":1}`,
  `drives list` → `Внешние накопители не найдены.` (внешних дисков не подключено).
- `swift build -c debug` (полная сборка пакета через SwiftPM) → PASS,
  `Build complete! (25,01 с)`: GUI-таргет собирается с зависимостью от
  `RecoveryCore`.
- Нелетальные предупреждения линкёра CLT `ld: warning: search path … not found`
  наблюдались при SwiftPM-сборках; на результат не влияют.

## Не проверено

- GUI в рантайме не запускался: интерфейс не менялся; проверены только сборка
  `.app` и строгая проверка подписи.
- `drives list` на реальном подключённом накопителе: физический носитель по
  заданию не использовался; на машине внешних дисков не было, поэтому проверен
  пустой массив (его поддержка прямо требует схема JSON).
- `swift test` не запускался: Swift Testing в установленном preview
  Command Line Tools нестабилен (известное ограничение из `STATUS.md`);
  юнит-проверки выполнены независимым харнессом `Scripts/test.sh`.
- Воспроизводимость упаковки (две упаковки с одинаковым SHA-256) не
  проверялась — не входит в обязательные проверки TASK-001.
- Проблема `/dev/fd/N` не исправлялась и не проверялась — вне задания.

## Риски и отклонения от задания

- Отклонений от задания нет.
- Риск дублирования версии: константы 0.8.1/13 в `CLIReports.swift` повторяют
  `Packaging/Info.plist` и требуют ручной синхронизации; вынесение версии в
  общий источник в задание не входило.
- `Tests/RecoveryAppTests` не менялся: он не импортирует перенесённые типы;
  если позже начнёт — потребуется добавить `RecoveryCore` в его зависимости.
- Изменения `Scripts/test.sh` и `Scripts/build-app.sh` ограничены способом
  сборки модуля; release-путь сохранён на «плоском» `swiftc` для детерминизма,
  состав `.app` не менялся.

## Временные данные и уборка

- Юнит-харнесс удаляет свои временные каталоги сам (defer).
- Остались только стандартные каталоги сборки из `.gitignore`:
  `.build/` (SwiftPM), `work/` (кэши скриптов), `dist/RecoveryApp.app`
  (артефакт обязательной проверки). В коммит они не попадают.
- Вне этих каталогов временные файлы не создавались; физические накопители и
  синтетические образы не использовались.
