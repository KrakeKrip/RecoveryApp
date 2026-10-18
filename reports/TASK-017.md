# TASK-017 — потоковые находки quick и сохранение во время поиска

Дата: 2026-10-18. Исполнитель и ревьюер: Codex, по прямому запросу владельца.
Ветка: `codex/task-017-live-quick-recovery`, база main
`8e99a6f7da08dd73a13e8dd0dafc8517969a6fd2`.
Пользователь прямо разрешил main и новый пакет; пакет v0.8.1-lab.3 назначается
Latest, приложение остаётся 0.8.1 (13), версия/build не повышались.

## Реализовано

- Общий Core runner с stdout-only PTY для fls (line buffering без патча TSK),
  отдельным параллельным stderr drain и липкой ранней отменой. Один процесс
  на runner; попытка повторного одновременного run отклоняется. stdin не PTY.
- Общий байтовый декодер строк: разделённый UTF-8, табуляции метаданных,
  финальный хвост, suppression повторных ID. Новые optional callbacks
  onCandidates/onRecovered в image/physical backend, прежний финальный CLI
  JSON/текстовый контракт сохранён. Сырой полный stdout fls не копится.
- Независимые scan/save workers. Физический save worker разделяет только
  авторизационные права, но не process/raw file description; helper открывает
  собственный O_RDONLY FD. Preflight/повторная сверка/helper-барьеры сохранены.
- UI получает живой список, выбор и фильтры до конца scan. Новые находки не
  выбираются автоматически. Snapshot группы фиксируется при нажатии, не
  расширяется поздними строками или сменой фильтра. Один save batch одновременно.
- Успешно опубликованные файлы отмечаются сразу и не запускаются повторно;
  сводка агрегирует несколько групп, в том числе при ошибке следующего файла.
  Отмена scan/save независима. Найденное доступно после остановки scan;
  незавершённый текущий partial удаляется, готовые файлы остаются.
- Поколение скана отсекает устаревшие callbacks. Подмена источника отменяет
  связанные операции/очищает находки, но сохранённые файлы доступны из сводки.
  Источник/назначение нельзя поменять при активных операциях. Новый scan
  сбрасывает старую отменённую физическую сессию. Выход с экрана отменяет работу.
- Карточка этапа больше не остаётся на «Получаем доступ» во время сканирования;
  нет выдуманного процента, скорости или ETA. Отмена сохранения не обещает,
  что все найденные записи уже извлечены.
- Обновлены README, PRODUCT, ARCHITECTURE, DECISIONS, STATUS, TASKS,
  docs/USER_GUIDE.md, docs/CLI.md. Предыдущая навигационная задача отмечена DONE
  по сообщению пользователя: переходы работают на M2 / 14.5 (не тест recovery).

Файлы реализации: Sources/RecoveryCore/QuickToolProcess.swift (новый),
ImageQuickRecovery.swift, PhysicalQuickRecovery.swift; Sources/RecoveryApp/
DeletedFilesRecovery.swift, DeletedFilesViewModel.swift, DeletedFilesView.swift.
Тесты: Tests/UnitHarness/main.swift, Tests/Fixtures/streaming-quick-tools.c (новый),
Scripts/test-deleted-recovery.sh. Задание tasks/TASK-017.md и этот отчёт.
Packaging/helpers/TSK-патчи/ThirdParty/иконка/сетевой план не менялись.

## Команды и результаты

Из корня `/Users/atlhnv/RecoveryApp`. Все fixture-данные синтетические;
собственный staging/cache `/private/tmp/recoveryapp-streaming.2H2YK7`.
Общая переменная SDK: `RECOVERYAPP_SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`.

- `BUILD_CACHE_DIR=/private/tmp/recoveryapp-streaming.2H2YK7/harness ./Scripts/test.sh`
  — финально exit 0, **PASS: 373 domain checks** (321 + 52). Среди новых:
  byte-by-byte UTF-8, дубли/EOF, C printf без fflush и isatty stdout,
  ранний callback при gate-блокированном fls, одновременное извлечение,
  независимая отмена в обе стороны, ранний cancel, 320-КБ stderr flood,
  partial-success callback, .partial cleanup, live ViewModel/Executor,
  фильтры/ошибки порога/блокировка источника, несколько групп, отсутствие
  повторного save, сохранение после остановки scan, корректный этап при
  завершении scan во время save и корректное сообщение отмены без ложного успеха.
- `BUILD_CACHE_DIR=/private/tmp/recoveryapp-streaming.2H2YK7/cli ./Scripts/test-cli.sh`
  — 0, все 8 групп PASS (drives list только обнаруживает устройства, не читает
  содержимое). SwiftPM ld warnings о каталогах Developer/Library/Frameworks
  и Developer/usr/lib не препятствуют сборке/выполнению.
- `BUILD_CACHE_DIR=/private/tmp/recoveryapp-streaming.2H2YK7/cli QUICK_IMAGE_TEST_DIR=/tmp/recoveryapp-streaming.2H2YK7/quick-final ./Scripts/test-quick-image-cli.sh`
  — 0, все группы PASS, реальные TSK FAT32/exFAT, cmp результатов, пустой скан,
  статусы размеров, усечённый результат, повтор без перезаписи и ошибки CLI.
- `BUILD_CACHE_DIR=/private/tmp/recoveryapp-streaming.2H2YK7/cli PHYSICAL_CONTRACT_TEST_DIR=/tmp/recoveryapp-streaming.2H2YK7/physical-fixtures-r2 ./Scripts/test-physical-quick-cli-contract.sh`
  — 0, только синтетика; отказ до авторизации, helper recovery/cmp, размер 74.
- `METADATA_HELPER_TEST_DIR=/private/tmp/recoveryapp-streaming.2H2YK7/metadata ./Scripts/test-metadata-helper.sh`
  — 0, FAT32/exFAT cmp и отказ при подмене размера.
- `SLEUTHKIT_FD_TEST_DIR=/private/tmp/recoveryapp-streaming.2H2YK7/fd ./Scripts/test-sleuthkit-preopened-fd.sh`
  — 0, все проверки /dev/fd/9, /dev/fd/0, chmod 000 dup-discriminator,
  GPT/exFAT, недопустимого FD. Только обычные синтетические файлы.
- `DELETED_FIXTURE_DIR=/private/tmp/recoveryapp-streaming.2H2YK7/deleted-r2 ./Scripts/test-deleted-recovery.sh`
  — 0: FAT32 metadata 3/3, PhotoRec 2/3; exFAT metadata 3/3, PhotoRec 2/3;
  process-group cancellation. Встроенный sparse cancellation fixture собственный,
  не пользовательский накопитель; удаляется вместе с tmp после проверки.
- `BUILD_CACHE_DIR=/private/tmp/recoveryapp-streaming.2H2YK7/build OUTPUT_DIR=/Users/atlhnv/RecoveryApp/dist/STREAMING-20261018-release ./Scripts/build-app.sh`
  — 0, финальная arm64 release .app. `codesign --verify --deep --strict ...` — 0.
  `./Scripts/test-license-package.sh dist/STREAMING-20261018-release/RecoveryApp.app`
  — 0, комплект полон и совпадает с репозиторием.
- `zsh -n Scripts/test-deleted-recovery.sh`, `git diff --check` — 0.

### Два исправленных сбоя тестовой инфраструктуры

1. Первый запуск quick-image с `/private/tmp/...` дал расхождение канонического
   пути JSON `/tmp/...` с буквальным аргументом теста. Код/контракт не менялись;
   повтор с `/tmp/...` прошёл (то же содержимое каталога через symlink).
2. Старый deleted-recovery сравнивал свежесгенерированный MP4 с файлом из
   статичного exFAT fixture. ffprobe показал encoder Lavf/Lavc63.1.101 в
   fixture и 63.1.102 на host; различие на байте 520, а извлечение до и после
   удаления из исходного образа совпало побайтно. Исправлен только эталон:
   извлекаем точные оригиналы из before-образа до его изменения. Это доказательство
   сохранения данных fixture, не независимая проверка всех декодированных кадров.

## GUI-приёмка

macOS 27.2. Текущая `/Applications/RecoveryApp.app` с пользовательским scan
не закрывалась и не менялась. Изолированная копия с отдельным bundle ID
org.recoveryapp.streaming-test использовала основной executable до последней
Core-правки эксклюзивного создания `.partial` (UI не менялся); две
собственные копии после `codesign --remove-signature` сравнились `cmp` (0).
Только fls/icat внутри тестовой копии подменены управляемым C fixture для
воспроизводимой задержки, stdout buffering и 10-байтовых результатов.
В публикуемой .app стоят реальные неизменённые ThirdParty-инструменты.

Проверено реальными кликами, не автопереходом/подменой состояния:
главный экран → файлы → отдельный synthetic.img → пустая папка → scan;
первая находка видна при работающем scan; фильтр «Фото»; выбор; save при scan;
отмена только save (поиск продолжает идти); повтор; готовый файл при scan;
поздний MOV приходит без автоселекции и сохраняет активный фильтр; сброс;
«Выбрать все» выбирает только ещё не сохранённый MOV; save второй группы;
общий итог 2, оба статуса «Сохранён». Файлы synthetic-only, не реальные медиа.
Тестовая копия закрыта. Скриншоты reports/assets/TASK-017/:
live-list.png, concurrent.png, saved-while-searching.png, two-batches-saved.png.

## Упаковка и границы

DMG создаётся из финальной проверенной .app через прежний dmgbuild/settings,
ZIP — ditto; source ZIP — Scripts/package-source.sh с уникальным именем.
Финальные CRC/codesign/cmp/SHA и серверные digest сверяются перед публикацией;
тег выпуска указывает на финальный main. Контрольные суммы — SHA256SUMS.txt
того же релиза. Старые релизы не перезаписываются.

НЕ ПРОВЕРЕНО: новый совместный физический scan/save, фактическое число системных
диалогов, новый режим на macOS 14.5, отключение физического диска во время двух
операций, длительный стресс на очень больших списках. Никакой гарантии целостности
по одному совпадению размеров. Нет Developer ID/нотариализации. Отдельная сеть,
телеметрия и OTA остаются будущим этапом. Видео-repair regression отдельно
не повторялся: этот backend не изменён. Правила источника не ослаблялись.

## Уборка

После выпуска удаляются только собственный `/private/tmp/recoveryapp-streaming.2H2YK7`
с кэшами/фикстурами/GUI-копией и две промежуточные сборки этой задачи
dist/STREAMING-20261018 и dist/STREAMING-20261018-final. Финальные артефакты
остаются в dist/STREAMING-20261018-release. Не тронуты старые dist, `.mimosa`,
outputs/physical-quick-no-name-20260922 и восстановленные пользовательские файлы.
