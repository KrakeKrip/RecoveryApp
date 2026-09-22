# REPORT TASK-005

## Коммит

Полный хеш итогового коммита сообщается Codex в ответе исполнителя: отчёт входит
в сам итоговый коммит, поэтому хеш коммита невозможно записать внутри него.
Ветка: `glm/task-005-cli-photorec`, базовый коммит
`496e2cead97cb646ebcf3e166066056153482b01` (совпадает с `main` на момент старта).

## Реализовано

- Новый общий PhotoRec-бэкенд в `RecoveryCore`
  (`Sources/RecoveryCore/PhotoRecDeepRecovery.swift`) для обоих источников:
  - `recover(imageURL:outputFolderURL:…)` — обычный файл-образ; PhotoRec
    получает прежний набор параметров (`/log`, `/logname`, `/d …/Recovered`,
    `/cmd`, `partition_none,fileopt,everything,disable,jpg,enable,png,enable,
    mov,enable,search`) — совместимость GUI-сценария сохранена;
  - `recover(drive:authorization:outputFolderURL:helper:…)` — физический
    накопитель через существующий `recoveryapp-readonly-helper` без изменений
    helper: `O_RDONLY`, повторная проверка размера, запрет результата на
    источнике, `.recoveryapp-progress`, остановка дочерней группы по
    `.recoveryapp-stop` — всё сохранено;
  - backend владеет запуском процесса, созданием уникальной папки сессии
    внутри выбранной папки результата, поиском результатов (`Recovered.*`),
    снимками прогресса и отменой; тип результата `DeepRecoveryResult` общий
    для GUI и CLI;
  - процессы запускаются с рабочей папкой сессии (`currentDirectoryURL`), а
    helper и сам делает `chdir(session)` своему PhotoRec: `photorec.ses`,
    журнал и marker-файлы не появляются в каталоге вызова CLI;
  - отмена: для физического источника создаётся marker-файл (helper
    останавливает группу сам: SIGINT → SIGTERM → SIGKILL и ждёт завершения);
    для образа — SIGTERM/SIGKILL по группе лончера (без лончера — прямому
    дочернему процессу); папка сессии и найденные файлы не удаляются;
  - расчёты прогресса перенесены из GUI в Core и стали общими:
    `PhotoRecProgressSnapshot`, `progressSnapshot(at:)`,
    `photoRecSessionProcessedBytes`, `progressFileValues`,
    `photoRecOutputDirectories`, `regularFilesRecursively`; недоступные
    значения остаются `nil`, а не нулём; ETA не вычисляется.
- GUI (`DeletedFilesRecovery.swift`) стал тонким адаптером: выбор инструментов,
  делегирование в Core, прежние callbacks (`onSessionReady`, `onOutput`) и
  прежнее поведение; `DeletedFilesView.swift` больше не содержит собственных
  расчётов прогресса — использует `PhotoRecDeepRecovery.progressSnapshot`;
  раскладка SwiftUI и видимый интерфейс не менялись.
- CLI:
  - `deep recover --image ФАЙЛ --output ПАПКА [--jsonl]` и
    `deep recover --drive diskN --expected-name ИМЯ --expected-size БАЙТЫ
    --output ПАПКА [--jsonl]`; без предварительного скана;
  - для физического источника повторное обнаружение, сверка id/имени/размера и
    preflight папки результата выполняются до Authorization Services; одна
    авторизационная сессия на команду; raw-путь `/dev/rdiskN` не принимается;
    пароль CLI не принимает ни в каком виде;
  - `--jsonl`: stdout содержит только по одному валидному JSON-объекту на
    строку (запись через FileHandle — потоковая); события `started`
    (schemaVersion, источник, папка сессии), `progress` (прошедшее время,
    найдено файлов, объём результата; `processedBytes`/`totalBytes`/
    `readBytesPerSecond` — только при реальных измерениях, ключ опускается,
    нулём не подменяется), `completed` (папка сессии, число и пути файлов),
    `cancelled` (папка сессии и уже найденные файлы), `error` (стабильный код
    `deepErrorCode` и понятное сообщение); сообщения и техническая диагностика
    — в stderr; ETA нет;
  - текстовый режим на русском: запуск и диагностика (включая живой прогресс
    «Прошло … • прочитано … • найдено файлов …») в stderr, итог и папка
    сессии в stdout;
  - Ctrl-C/SIGTERM через DispatchSourceSignal: обработчик только отменяет
    задачу, общий backend останавливает группу PhotoRec/helper; итоговое
    событие `cancelled`, код выхода 130; успех — 0 (включая пустой результат:
    `completed` с `recoveredCount: 0`), ошибка выполнения — 1, неверные
    аргументы — 2;
  - справка CLI дополнена deep-командами, JSONL-контрактом, кодами выхода и
    переменными окружения `RECOVERYAPP_PHOTOREC_PATH`,
    `RECOVERYAPP_READONLY_HELPER_PATH`.
- Новый `Scripts/test-deep-photorec-cli.sh` (см. Проверки).
- `LogSanitizer` перенесён в `RecoveryCore` (переименование + `public`):
  PhotoRec-бэкенд Core сам готовит сводку PhotoRec для `onOutput`, общую для
  GUI и CLI; единственная альтернатива — вторая копия санитайзера, что
  запрещено архитектурой.
- Доменные проверки расширены до 150 (было 115): deep-парсер (10 отклонений и
  3 корректных разбора), кодирование всех пяти JSONL-событий с проверкой
  опущенных ключей через JSONSerialization, снимки прогресса на синтетической
  сессии (`photorec.ses` + `.recoveryapp-progress` + находки), отказ от подмен
  нулём на битых файлах. Счётчик проверок стал вычисляемым — «PASS: N domain
  checks» больше не требует ручной правки константы.

## Файлы

- Созданы:
  - `Sources/RecoveryCore/PhotoRecDeepRecovery.swift`
  - `Scripts/test-deep-photorec-cli.sh`
  - `reports/TASK-005.md`
- Переименованы:
  - `Sources/RecoveryApp/LogSanitizer.swift` → `Sources/RecoveryCore/LogSanitizer.swift`
- Изменены:
  - `Sources/RecoveryApp/DeletedFilesRecovery.swift` — тонкий GUI-адаптер над Core
  - `Sources/RecoveryApp/DeletedFilesView.swift` — расчёты прогресса заменены на Core
  - `Sources/RecoveryApp/VideoRepair.swift` — только `import RecoveryCore`
  - `Sources/recoveryapp-cli/main.swift` — deep recover, сигналы, прогресс, события
  - `Sources/recoveryapp-cli/CommandLineParser.swift` — команда deep, флаг --jsonl
  - `Sources/recoveryapp-cli/CLIReports.swift` — JSONL-события, коды ошибок, справка
  - `Tests/UnitHarness/main.swift` — +35 проверок, ссылки на Core, динамический счётчик
  - `Scripts/test.sh` — LogSanitizer собирается в составе RecoveryCore
  - `ARCHITECTURE.md`, `STATUS.md`, `README.md` — фактами о deep CLI
  - `TASKS.md` — только статус TASK-005 `IN PROGRESS` → `REVIEW`
- Удалены: нет. `outputs/physical-quick-no-name-20260922/` не тронута.

## Проверки

| Команда | Результат | Вывод |
|---|---|---|
| `./Scripts/test.sh` | PASS | `PASS: 150 domain checks` (было 115) |
| `./Scripts/test-cli.sh` | PASS | прежний контракт CLI не сломан |
| `./Scripts/test-quick-image-cli.sh` | PASS | все группы, включая побайтные сравнения |
| `./Scripts/test-physical-quick-cli-contract.sh` | PASS | сверка/отвержение до авторизации сохранены |
| `./Scripts/test-metadata-helper.sh` | PASS | helper GPT/exFAT побайтно, код 74 |
| `./Scripts/test-readonly-helper.sh` | PASS | read-only helper: побайтно, отмена 130, прогресс секторов |
| `./Scripts/test-deleted-recovery.sh` | PASS | FAT32 3/3, exFAT 3/3, отмена группы PhotoRec |
| `./Scripts/test-deep-photorec-cli.sh` | PASS | 13 PASS-строк, детали ниже |
| `swift build --disable-sandbox --scratch-path work/swift-t005 -c release --product recoveryapp-cli` | PASS | `Build complete! (18,04 с)` |
| `OUTPUT_DIR="$(mktemp -d)" ./Scripts/build-app.sh` | PASS | `.app` во временной папке, `dist/RecoveryApp.app` не перезаписывалась |
| `codesign --verify --deep --strict <временная>/RecoveryApp.app` | PASS | строгая ad-hoc-подпись, код 0 |
| `git diff --check 496e2cead97cb646ebcf3e166066056153482b01..HEAD` | PASS | пусто |

Детали `Scripts/test-deep-photorec-cli.sh` (полностью синтетический, только
образы и shim-ы):

- парсер: 17 наборов неверных аргументов — код 2, stdout пуст, справка
  упоминает `deep recover`;
- ошибки выполнения: отсутствующий образ, каталог вместо образа, несуществующая
  папка результата, отсутствие `RECOVERYAPP_PHOTOREC_PATH` — код 1 и событие
  `error` со стабильным кодом (`imageMissing`/`imageNotRegularFile`/
  `outputFolderMissing`/`toolMissing`);
- физический источник: `deep recover --drive disk99999 …` отвергается
  повторным обнаружением до Authorization Services — ровно одно событие
  `error` (`sourceUnavailable`/`sourceChanged`), без `started`, код 1;
- JSONL на детерминированном PhotoRec shim (3 находки с интервалом 2 c):
  каждая строка stdout разбирается `json.loads`, события `started` →
  `progress…` → `completed`, монотонный рост `foundFiles`, присутствие
  `elapsedSeconds`, отсутствие ETA-ключей, `completed` перечисляет все три
  файла; `photorec.ses` и журнал только в папке сессии; внутри `--output`
  ровно одна папка сессии; посторонний рабочий каталог вызова пуст;
- текстовый режим: «Глубокий поиск завершён. PhotoRec создал файлов: 3.» и
  «Папка сессии: …» в stdout, живой прогресс («Прошло …», «найдено файлов: 3»)
  в stderr;
- Ctrl-C (SIGINT в работающий CLI с медленным shim): код 130, последняя строка
  stdout — `cancelled` с папкой сессии и найденным файлом, файл остаётся на
  диске, `pgrep` не находит живых shim-процессов, рабочий каталог пуст;
- end-to-end со встроенным PhotoRec 7.2 на синтетическом FAT32 (удалённые PNG
  и MP4): `completed` с `recoveredCount: 2`, оба файла совпадают с оригиналами
  побайтно (`cmp`);
- чистый образ: код 0, `completed` с `recoveredCount: 0` и пустым `files`.

## Не проверено

- GUI в рантайме не запускался: раскладка SwiftUI не менялась, адаптер
  делегирует тем же Core-функциям; проверены сборка `.app` во временную папку
  и строгая ad-hoc-подпись. GUI deep-recovery с новым backend в живом
  приложении не прогонялся.
- Физические накопители не использовались (запрещено заданием): drive-режим
  CLI покрыт только контрактом до Authorization Services и доменными
  проверками; сквозной прогон deep recover с helper на реальном накопителе —
  предмет отдельной приёмки (helper сам проверен `test-readonly-helper.sh` на
  образах, включая отмену и прогресс).
- `readBytesPerSecond` в JSONL при образном режиме не возникает (нет
  измерений `processedBytes`) — по контракту ключ опускается; кодирование
  при наличии измерений проверено доменными тестами.
- Реальный PhotoRec 7.2 на образах в этих прогонах не создавал `photorec.ses`;
  контракт «cwd чист» проверен на реальном PhotoRec, а запись `photorec.ses`
  в папку сессии — на shim-сценарии.
- Отмена по SIGTERM (не SIGINT) обрабатывается тем же обработчиком, отдельно
  не тестировалась.

## Риски и отклонения от задания

- Отклонение 1 (согласуется с заданием): пустой результат образного режима.
  Core возвращает результат с нулём файлов без ошибки; CLI трактует это как
  успех (код 0, `completed`). Прежнее поведение GUI — ошибка
  `toolFailed("PhotoRec", 0)` при отсутствии каталогов PhotoRec — сохранено в
  GUI-адаптере, чтобы не менять пользовательское поведение. GUI и CLI
  используют один алгоритм запуска/отмены, различается только интерпретация
  пустого результата на уровне адаптера.
- Отклонение 2: перенос `LogSanitizer` в `RecoveryCore` (переименование).
  Необходимо, чтобы общий backend выдавал уже очищенную сводку PhotoRec через
  один `onOutput`; без этого пришлось бы дублировать санитайзер.
- Отмена образного режима без `tool-launcher` падает на прямом дочернем
  процессе (`kill(pid)`); полноценная остановка группы гарантируется лончером,
  который обязателен в GUI и есть в сборке `.app`; CLI использует лончер,
  если путь разрешается.
- Разбор `photorec.ses` опирается на формат «blocksize,N» и диапазоны
  «start-end» (унаследован из GUI без изменений); неразбираемый файл даёт
  `nil`, а не ноль.
- Содержимое JSONL-событий рассчитано только на добавление новых ключей;
  переименование существующих полей нарушило бы контракт автоматизаций.

## Временные данные и уборка

- После проверок удалены: `work/` (тестовые образы, результаты, кэши SwiftPM
  всех тестовых сценариев этой задачи), `photorec.ses` в корне проекта
  (оставлен прогоном существующего `test-deleted-recovery.sh`), временные
  логи в `/tmp`, временная папка сборки `.app` в `/private/tmp` (удалена
  скриптом сборки и вручную).
- Сохранены: `Tests/Fixtures/`, `ThirdParty/`, `dist/RecoveryApp.app`
  (существующая сборка не перезаписывалась), `outputs/` — включая
  `outputs/physical-quick-no-name-20260922/` (не открывалась и не менялась).
- Физические накопители не использовались; системные разрешения не
  запрашивались; содержимое пользовательских файлов не открывалось и не
  публиковалось.
