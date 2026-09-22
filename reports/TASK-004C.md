# REPORT TASK-004C

## Коммит

Полный хеш итогового коммита сообщается Codex в ответе исполнителя: отчёт входит
в сам итоговый коммит, поэтому хеш коммита невозможно записать внутри него.
Ветка: `glm/task-004c-size-aware-quick-recovery`, базовый коммит
`63fd5a2521c6cf554b8c52ed06a61902591b56fa`.

## Реализовано

- `DeletedFileCandidate` получил необязательный `expectedSize: Int64?`
  (значение по умолчанию `nil` — прежние инициализаторы и вызовы совместимы).
- Парсер `SleuthKitOutputParser.deletedFiles` понимает оба формата `fls`:
  короткий (размер неизвестен, `expectedSize == nil`) и длинный `fls -l`
  (минимум 8 колонок: имя, четыре времени, размер, gid, uid; размер — всегда
  третья колонка с конца). Лишние табуляции и пробелы внутри имени не ломают
  разбор: имя восстанавливается как всё до четырёх временных колонок.
  Инод, путь, смещение, тип ФС и фильтрация каталогов сохранены.
- Ожидаемый размер поступает из `fls -l` в обоих quick-режимах: образный скан
  добавляет `-l` к `fls`; физический `recoveryapp-metadata-helper.c` добавляет
  `-l` к своему запуску `fls` — это единственное изменение helper; authopen,
  `O_RDONLY`, проверка размера устройства, output-on-source и передача FD
  не менялись. Sleuth Kit по-прежнему отдельные процессы.
- Новый публичный API RecoveryCore: `RecoveredFileSizeStatus`
  (`expectedEmpty`/`sizeMatches`/`incomplete`/`sizeMismatch`/`sizeUnknown`),
  `RecoveredFileSizeClassifier`, `RecoveredFileResult` (URL, expectedSize,
  actualSize, статус) и `recoverDetailed()` в `ImageQuickRecovery` и
  `PhysicalQuickRecovery`. Классификация выполняется после публикации файла по
  фактическому размеру на диске; нулевой исходный размер с нулевым результатом —
  `expectedEmpty` (нормальное состояние); короткий результат сохраняется в
  папке и помечается `incomplete`; `.partial` удаляется только при ошибке или
  отмене до публикации.
- `recover() -> [URL]` сохранён как тонкая обёртка над `recoverDetailed` —
  GUI (`DeletedFilesExecutor`) и раскладка SwiftUI не менялись.
- CLI JSON `quick recover --json` содержит прежние `schemaVersion`,
  `outputDirectory`, `recoveredCount`, `files` и добавляет `items`
  (построчные `path`/`expectedSize`/`actualSize`/`status`) и `statusCounts`
  (пять агрегатов; сумма равна `recoveredCount`). Scan-JSON кандидатов дополнен
  `expectedSize`. Текстовый режим перечисляет статусы и предупреждает о
  неполных и несовпадающих размерах, а также напоминает, что сверка размеров
  не является проверкой целостности содержимого.
- Справка CLI и `STATUS.md`/`ARCHITECTURE.md` обновлены фактами.

## Файлы

- Созданы:
  - `reports/TASK-004C.md`
- Изменены:
  - `Sources/RecoveryCore/ImageQuickRecovery.swift` — expectedSize, long-парсер,
    классификатор, `recoverDetailed`, `-l` в образном скане
  - `Sources/RecoveryCore/PhysicalQuickRecovery.swift` — `recoverDetailed` с
    классификацией (helper добавляет `-l` на своей стороне)
  - `Packaging/recoveryapp-metadata-helper.c` — только `-l` в двух запусках fls
  - `Sources/recoveryapp-cli/CLIReports.swift` — `expectedSize` в кандидатах,
    `RecoveredFileItemReport`, `StatusCountsReport`, расширенный
    `QuickRecoverReport`
  - `Sources/recoveryapp-cli/main.swift` — recover через `recoverDetailed`,
    статусы в JSON и текстовом выводе
  - `Tests/UnitHarness/main.swift` — +17 проверок (96 → 113)
  - `Scripts/test-quick-image-cli.sh` — статусы, пустой файл, усечение, ошибка
    icat, отсутствие `.partial`
  - `Scripts/test-physical-quick-cli-contract.sh` — проверка размера из
    helper `fls -l` и совпадения его с фактическим результатом
  - `ARCHITECTURE.md`, `STATUS.md` — факты; `TASKS.md` — только статус
    TASK-004C `TODO` → `REVIEW`
- Удалены: нет. `outputs/physical-quick-no-name-20260922/` не тронут.

## Проверки

| Команда | Результат | Вывод |
|---|---|---|
| `./Scripts/test.sh` | PASS | `PASS: 113 domain checks` (было 96; +17) |
| `./Scripts/test-cli.sh` | PASS | прежний контракт CLI не сломан |
| `./Scripts/test-quick-image-cli.sh` | PASS | 14 групп PASS, см. ниже |
| `./Scripts/test-physical-quick-cli-contract.sh` | PASS | включая новые проверки размера helper `fls -l` |
| `./Scripts/test-deleted-recovery.sh` | PASS | FAT32 3/3, exFAT 3/3 metadata + PhotoRec + отмена |
| `swift build -c release --product recoveryapp-cli` | PASS | `Build complete! (18,62 с)` |
| `./Scripts/build-app.sh` | PASS | `dist/RecoveryApp.app` собрана |
| `codesign --verify --deep --strict dist/RecoveryApp.app` | PASS | строгая проверка подписи, код 0 |
| `git diff --check 63fd5a2..HEAD` | PASS | пусто |

Доменные проверки (в `test.sh`, +17): длинный формат извлекает размер (0 и
26672), фильтрует каталоги, сохраняет инод и путь; короткий формат даёт
`expectedSize == nil`; имена с пробелами и табуляциями разбираются, размер
находится; классификатор проверен на всех пяти статусах плюс нулевой источник
с непустым результатом → `sizeMismatch`.

Детали `test-quick-image-cli.sh` (полностью синтетический):

- FAT32 (2 текстовых файла + пустой файл, все удалены): scan JSON даёт
  `expectedSize` по каждой записи; recover публикует 3 файла, побайтное
  сравнение `cmp` с эталонами — 3/3; пустой файл получает `expectedEmpty`;
  статус каждой позиции перепроверяется python-зеркалом классификатора;
  сумма `statusCounts` равна `recoveredCount`.
- Повторный запуск: `_2`-имена, прежние файлы не изменены, содержимое снова
  побайтно совпадает.
- GPT/exFAT (фикстура, удалены RECOVERY_NOTE.TXT 229 байта и TESTCARD.PNG
  26672 байта): scan JSON показывает реальные ожидаемые размеры; recover —
  `sizeMatches` по обоим; побайтное сравнение с эталоном `icat` из исходной
  фикстуры — 2/2.
- Усечение: shim-`icat` (реальный `icat`, вывод ограничен 4096 байтами) —
  TESTCARD.PNG публикуется со статусом `incomplete`
  (`expectedSize: 26672, actualSize: 4096`), RECOVERY_NOTE.TXT —
  `sizeMatches`; короткий файл сохранён; текстовый режим предупреждает
  «извлечены не полностью» и печатает напоминание про целостность.
- Ошибка: shim-`icat` с кодом 1 — CLI завершается кодом 1, `.partial`
  отсутствует; после успешных восстановлений `.partial` также отсутствует.
- Ошибочные/конфликтующие аргументы — код 2; ошибки выполнения (включая
  отсутствие `RECOVERYAPP_FLS_PATH`) — код 1.

Контракт физического helper (на обычном образе, без authopen): helper `fls -l`
показывает ожидаемый размер записи; `icat` восстанавливает побайтно; фактический
размер результата равен размеру из `fls -l`; подмена размера источника по-прежнему
даёт код 74.

## Пример JSON восстановления

```json
{"files":["/abs/result/RECOVERY_NOTE.TXT","/abs/result/TESTCARD.PNG"],"items":[{"actualSize":229,"expectedSize":229,"path":"/abs/result/RECOVERY_NOTE.TXT","status":"sizeMatches"},{"actualSize":4096,"expectedSize":26672,"path":"/abs/result/TESTCARD.PNG","status":"incomplete"}],"outputDirectory":"/abs/result","recoveredCount":2,"schemaVersion":1,"statusCounts":{"expectedEmpty":0,"incomplete":1,"sizeMatches":1,"sizeMismatch":0,"sizeUnknown":0}}
```

## Не проверено

- Размерная сверка на физическом накопителе не выполнялась (запрещено
  заданием): физический путь покрыт только контрактом helper на обычных
  образах. Поведение на реальной Flashka/NO NAME после этого изменения —
  предмет отдельной приёмки.
- `fls -l` для части удалённых записей показывает размер 0, когда TSK не
  заполняет метаданные записи (наблюдалось и на реальной флешке, и
  синтетически); такие результаты классифицируются по нулевому ожиданию.
  Отличить «истинный ноль» от «метаданные недоступны» по выводу `fls` нельзя.
- Совпадение размеров не проверяет целостность содержимого; побайтная
  сверка возможна только с эталоном и в CLI не выполняется.
- GUI в рантайме не перезапускался: UI не менялся, обёртка `recover() -> [URL]`
  сохранена; проверены сборка `.app` и подпись.
- Reproducible-упаковка — вне обязательных проверок задачи.

## Риски и отклонения от задания

- Отклонений нет: diff ограничен разрешёнными файлами; helper изменён только
  добавлением `-l` в два запуска fls; PhotoRec, untrunc, UI, версия/build,
  сеть не затронуты; зависимости не добавлялись.
- Разбор длинного формата опирается на стабильность формата `fls -l`
  (размер третьей колонкой с конца); нечисловая колонка трактуется как
  неизвестный размер без отказа.

## Временные данные и уборка

- После проверок удалены `work/` (тестовые образы и результаты, кэши SwiftPM),
  `.build/`, `photorec.ses` и `/tmp/flslab` (экспериментальный образ для
  изучения формата `fls -l`).
- Сохранены: `Tests/Fixtures/`, архивы `outputs/` (кроме пользовательской
  папки ничего не удалено), `outputs/physical-quick-no-name-20260922/`
  (не открывалась и не изменялась), встроенные бинарники,
  `dist/RecoveryApp.app`.
- Физические накопители не использовались; системные разрешения не
  запрашивались; содержимое пользовательских файлов не открывалось и не
  публиковалось.
