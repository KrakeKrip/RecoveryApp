# REPORT TASK-004

## Приёмка Codex — 2026-09-22

Проверен коммит GLM `956560a9317d19ea4fab921fe27601d603a629cb`:
`git diff --check` чист; повторно прошли `Scripts/test.sh` (95 проверок),
`Scripts/test-physical-quick-cli-contract.sh`, `Scripts/test-cli.sh` и
`swift build -c release --product recoveryapp-cli`. Отдельно на подключённой
Flashka заново установлены `disk4`/`/dev/rdisk4`, размер 125829120000 байт,
exFAT и `/Volumes/Flashka`. Короткий read-only `quick scan --drive` прошёл
авторизацию с одним системным запросом (число подтвердил пользователь),
обнаружил раздел на смещении 2048 и запустил `fls` через `/dev/fd/0` без
прежнего `Permission denied`. Поиск остановлен до полного прохода; процессов
CLI/helper/`fls` после остановки не осталось. Физическое восстановление файлов,
полный JSON-результат и запуск GUI этим тестом не проверялись.

Ниже сохранён исходный отчёт GLM о синтетических проверках до этой приёмки.

## Коммит

Полный хеш итогового коммита сообщается Codex в ответе исполнителя: отчёт входит
в сам итоговый коммит, поэтому хеш коммита невозможно записать внутри него.
Ветка: `glm/task-004-physical-quick-cli`, базовый коммит
`1f586029c13d43231197c9b1ca5d782069d83fed`.

## Устройство общего физического backend в RecoveryCore

Новый файл `Sources/RecoveryCore/PhysicalQuickRecovery.swift` (Foundation +
Security, без SwiftUI/AppKit):

- `ReadOnlyAuthorization` — Authorization Services сессия, перенесена из
  приложения дословно и стала публичной: создаёт право
  `sys.openfile.readonly.<rawDevicePath>`, держит `AuthorizationRef` живым до
  поглощения внешней формы authopen и публикует только `externalForm: Data`.
  Пароль, токен или raw FD наружу не отдаются.
- `PhysicalDriveSelector.selectDrive(identifier:expectedName:expectedSize:from:)`
  — чистая функция выбора/сверки по снимку `[ExternalDrive]`: без diskutil и
  без авторизации. Порядок проверок: формат идентификатора (только `disk` +
  цифры; `/dev/rdiskN` отклоняется) → `expectedSize > 0` → наличие `diskN` в
  снимке (`sourceUnavailable`) → точное имя (`sourceChanged`) → точный размер
  (`sourceChanged`).
- `PhysicalQuickRecovery` — алгоритм физического быстрого режима:
  - авторизационная сессия создаётся лениво при первом вызове helper и живёт
    на экземпляре; все последующие helper-вызовы (mmls, fls по каждому
    смещению, icat по каждому файлу) переиспользуют ту же внешнюю форму прав;
  - запуск `recoveryapp-metadata-helper` отдельным процессом: `mmls`, `fls`
    (fat32/exfat, прямое чтение и по смещениям разделов), `icat` во временный
    `.partial` с переименованием после успеха;
  - коды helper 77 → `authorizationDenied`, 74 → `sourceChanged`,
    73 → `outputOnSource`, 130/signal → `cancelled`, иначе
    `toolFailed`;
  - отмена группы процессов через tool-launcher (`kill(-pid)`), у CLI без
    лончера — прямое завершение процесса.
- Независимые проверки helper не менялись и не ослаблялись:
  `Packaging/recoveryapp-metadata-helper.c` в diff не входит. Helper по-прежнему
  сам проверяет `O_RDONLY`, фактический размер устройства против ожидаемого и
  запрет результата на исходном устройстве.

## Как GUI и CLI используют одну реализацию

- `DeletedFilesExecutor.scan(drive:)` и `.recover(drive:)` теперь создают
  `PhysicalQuickRecovery` (helper через `RECOVERYAPP_METADATA_HELPER_PATH` или
  `Bundle.main/Tools`, лончер обязателен для отмены групп) и делегируют вызовы.
  Собственные `scanDriveBlocking`, `scanDriveFileSystem`, `recoverDriveBlocking`,
  `mapHelperFailure` и приватный класс авторизации из приложения удалены —
  `grep` подтверждает: `scanDriveBlocking`/`recoverDriveBlocking`/`mapHelperFailure`
  существуют только в `Sources/RecoveryCore/PhysicalQuickRecovery.swift`.
- CLI `quick scan/recover --drive` используют тот же класс. Экземпляр один на
  команду, поэтому recover переиспользует сессию scan.
- Deep-режим PhotoRec (GUI) в Core не переносился: он остался в
  `DeletedFilesExecutor`, но использует публичный Core-класс
  `ReadOnlyAuthorization`.

## Повторная сверка disk id, имени и размера

Перед Authorization Services команда CLI заново вызывает
`ExternalDriveDiscovery().load()` (свежий снимок `diskutil list -plist external
physical`) и передаёт его в `PhysicalDriveSelector.selectDrive` вместе с
`--drive`, `--expected-name`, `--expected-size`. Несовпадение завершает команду
типизированной ошибкой до создания сессии: отсутствующий диск —
`sourceUnavailable`, иное имя или размер — `sourceChanged`. Malformed
идентификатор и неположительный размер отсекаются ещё парсером (код 2) и
дублируются в селекторе типизированной ошибкой `invalidDriveSource`.

## Где происходит независимая проверка O_RDONLY и размера

После Authorization Services и `authopen O_RDONLY` metadata helper
самостоятельно: сравнивает фактический размер открытого устройства
(`DKIOCGETBLOCKCOUNT/BLOCKSIZE`) с переданным ожидаемым (код 74 при
несовпадении), проверяет `F_GETFL` на `O_RDONLY` (код 75), повторно проверяет
запрет результата на исходном устройстве через `statfs` (код 73), переносит
дескриптор на stdin и передаёт инструментам `/dev/fd/0`.

## Предотвращение записи результата на источник

- До Authorization Services: публичный
  `PhysicalQuickRecovery.preflightRecoveryOutput(outputFolderURL:drive:)`
  проверяет, что папка существует, является каталогом и доступна для записи,
  затем `drive.contains(output)` по точкам монтирования снимка
  (`outputOnSource`). CLI вызывает preflight в порядке: обнаружение → сверка
  диска → preflight → создание `PhysicalQuickRecovery` → scan → recover, то
  есть до создания сессии и скана.
- `recover` повторяет те же проверки вторым защитным барьером.
- Helper повторно проверяет `statfs` каталога результата против
  `/dev/diskN` источника (код 73) на каждый вызов `icat`.
- Запись на источник отсутствует: инструменты получают только read-only fd.

## Доказательство одной Authorization Services сессии на CLI-команду

Структурное (синтетическое, без системного запроса):

1. Единственная точка создания сессии — `obtainAuthorization(device:)`; она
   создаёт `ReadOnlyAuthorization` один раз и кэширует на экземпляре
   (двойная проверка под блокировкой), все helper-вызовы берут
   `authorization.externalForm` из кэша. Создание возможно только из
   `scanBlocking`/`recoverBlocking` — то есть после сверки диска и проверок
   output.
2. CLI `quick recover --drive` создаёт ровно один экземпляр
   `PhysicalQuickRecovery` и вызывает на нём scan и recover — сессия одна на
   команду по построению; второго пути создания сессии в коде нет.
3. Контроль в контрактном сценарии: команда с корректными `--drive`-аргументами
   и заведомо несверяемым именем завершается кодом 1 с пустым stdout —
   сверка и отказ происходят до Authorization Services, диалог не вызывается;
   отрицательные аргумент-сценарии (код 2) не доходят даже до обнаружения.
4. Preflight выхода проверен доменно на синтетическом снимке с реальным
   каталогом монтирования внутри temp: output внутри точки монтирования даёт
   `outputOnSource`, несуществующий — `outputFolderMissing`, корректный вывод
   вне источника проходит; preflight — чистые проверки файловой системы и
   снимка, Authorization Services в нём не участвует.

Системный запрос фактически один на команду будет подтверждён отдельной
приёмкой Codex на реальном накопителе.

## JSON-контракт

Физический scan (`--json`, stdout, `sortedKeys`):

```json
{"candidates":[{"displayName":"…","filesystemType":"exfat","inode":"426","partitionOffset":2048,"path":"RECOVERY_NOTE.TXT"}],"drive":{"id":"disk4","name":"Flashka","size":125829120000,"rawDevicePath":"/dev/rdisk4"},"schemaVersion":1}
```

Физический recover использует существующую схему `QuickRecoverReport`:

```json
{"files":["/abs/result/RECOVERY_NOTE.TXT"],"outputDirectory":"/abs/result","recoveredCount":1,"schemaVersion":1}
```

Пустой `candidates`/`files` допустим. Диагностика и технический прогресс
физического режима выводятся в stderr; stdout остаётся чистым.

## Все выполненные проверки

| Команда | Результат | Вывод |
|---|---|---|
| `./Scripts/test.sh` | PASS | `PASS: 95 domain checks` (было 65; +11 селектор/JSON, +4 валидных quick, +12 ошибочных, +3 preflight) |
| `./Scripts/test-cli.sh` | PASS | прежний контракт CLI не сломан |
| `./Scripts/test-quick-image-cli.sh` | PASS | 9 строк PASS — image CLI из TASK-003 работает |
| `./Scripts/test-physical-quick-cli-contract.sh` | PASS | 7 групп PASS, см. ниже |
| `./Scripts/test-metadata-helper.sh` | PASS | helper: FAT32, GPT/exFAT, отказ при подмене размера (74) |
| `./Scripts/test-sleuthkit-preopened-fd.sh` | PASS | унаследованный FD: все проверки |
| `./Scripts/test-deleted-recovery.sh` | PASS | FAT32 3/3, exFAT 3/3 metadata + PhotoRec + отмена |
| `swift build -c release --product recoveryapp-cli` | PASS | `Build complete! (18,33 с)` |
| `./Scripts/build-app.sh` | PASS | `dist/RecoveryApp.app` собрана и подписана |
| `codesign --verify --deep --strict dist/RecoveryApp.app` | PASS | код 0 |
| `git diff --check 1f586029..HEAD` | PASS | пусто (проверено по завершении) |

Детали `test-physical-quick-cli-contract.sh` (полностью синтетический):

- контракт аргументов — код 2: `--drive` без expected-имени/размера,
  `/dev/rdisk4` вместо `disk4`, не-число/ноль/отрицательный expected-size,
  конфликт `--image`+`--drive`, `--expected-*` с `--image`, recover без `--all`,
  `--output` в scan, `--drive`/`--expected-name` без значения;
- корректные `--drive`-аргументы проходят парсер, повторное обнаружение
  выполняется, заведомо несверяемое ожидание отвергается до Authorization
  Services с кодом 1 и пустым stdout;
- доменные проверки Core (matcher диска, JSON-кодирование моделей, опасные
  имена) — через `Scripts/test.sh` (92 проверки);
- metadata helper на обычном синтетическом образе: fls находит удалённую
  запись, icat восстанавливает побайтно (`cmp` — код 0), подмена размера даёт
  код 74 — authopen для regular-файла не нужен, системный запрос не возникает.

## Реальный `authopen` и Flashka не проверялись

- Ни одна проверка GLM не обращалась к `/dev/diskN`, `/dev/rdiskN`, Flashka и
  не вызывала системный запрос Authorization Services.
- Физический `quick scan --drive` на реальном накопителе, один системный
  запрос, работа `/dev/fd/0` через helper и отсутствие записи — предмет
  отдельной приёмки Codex после code review. До неё физический путь считается
  реализованным, но не подтверждённым.

## Не проверено

- Всё перечисленное выше про реальный `authopen` и Flashka.
- Deep-режим PhotoRec через CLI не добавлялся и в Core не переносился.
- Поведение GUI в рантайме не перепроверялось: изменён только бэкенд,
  UI не менялся; проверены сборка `.app`, подпись и синтетические регрессы.
- Воспроизводимость упаковки — вне обязательных проверок задачи.

## Изменённые файлы

- Созданы:
  - `Sources/RecoveryCore/PhysicalQuickRecovery.swift`
  - `Scripts/test-physical-quick-cli-contract.sh`
  - `reports/TASK-004.md`
- Изменены:
  - `Sources/RecoveryCore/ImageQuickRecovery.swift` — новый случай
    `DeletedFilesError.invalidDriveSource(String)`
  - `Sources/RecoveryApp/DeletedFilesRecovery.swift` — делегирование
    физических scan/recover в Core, удалены перенесённые алгоритмы и
    приватная авторизация
  - `Sources/RecoveryApp/UserFacingFailure.swift` — маппинг
    `invalidDriveSource`
  - `Sources/recoveryapp-cli/CommandLineParser.swift` — `--drive`,
    `--expected-name`, `--expected-size`, конфликт с `--image`, новые ошибки
  - `Sources/recoveryapp-cli/CLIReports.swift` — `DriveIdentityReport`,
    `PhysicalQuickScanReport`, справка, тексты ошибок
  - `Sources/recoveryapp-cli/main.swift` — физические ветки scan/recover,
    прогресс в stderr
  - `Scripts/test.sh` — в список компиляции добавлен `CLIReports.swift`
  - `Tests/UnitHarness/main.swift` — +27 проверок (селектор, JSON, парсер)
  - `ARCHITECTURE.md`, `STATUS.md` — фактические результаты
  - `TASKS.md` — только статус TASK-004 `TODO` → `REVIEW`

## Риски и отклонения от задания

- Отклонений нет: diff ограничен разрешённой областью. `Package.swift` не
  менялся (Security линкуется автоматически).
- Проверка «одна сессия» синтетически структурная (единственная точка создания
  и кэш на экземпляре); фактическое число системных запросов подтверждается
  только на реальном носителе.
- Повторное обнаружение в CLI выполняет `diskutil list -plist external
  physical` — read-only чтение метаданных; в тестах GLM диск не подключался,
  сверка завершалась `sourceUnavailable`/`sourceChanged` детерминированно.
- Сверка имени чувствительна к регистру и точному совпадению тома — приёмка
  Codex должна передавать имя и размер ровно из свежего `drives list --json`.

## Временные данные и уборка

- После проверок удалены `work/` (каталоги тестов, кэши SwiftPM), `.build/` и
  `photorec.ses`; сохранены `Tests/Fixtures/`, архивы `outputs/`, встроенные
  бинарники и `dist/RecoveryApp.app`.
- Физические накопители не использовались; системные разрешения не
  запрашивались; все тестовые данные синтетические.
