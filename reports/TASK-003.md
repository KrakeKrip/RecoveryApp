# REPORT TASK-003

## Коммит

Полный хеш итогового коммита сообщается Codex в ответе исполнителя: отчёт входит
в сам итоговый коммит, поэтому хеш коммита невозможно записать внутри него.
Ветка: `glm/task-003-quick-image-cli`, базовый коммит
`10e44281bfa7cdaee5b4ad530bff45fc6f008f10`.

## Архитектура общего image backend

- Новый публичный модульный API `RecoveryCore`
  (`Sources/RecoveryCore/ImageQuickRecovery.swift`, только Foundation и
  Dispatch, без SwiftUI/AppKit/Security):
  - `ImageQuickToolSet` — внедряемые пути `mmls`, `fls`, `icat` и опционального
    `tool-launcher` (dependency injection путей инструментов);
  - `ImageQuickRecovery` — класс с `scan(imageURL:)` и
    `recover(imageURL:outputFolderURL:candidates:)`, кэш-слот процесса, отмена
    группы процессов и безопасные статические помощники;
  - `RecoveryToolLocator` — единое разрешение путей инструментов: переменная
    окружения (`RECOVERYAPP_*_PATH`) → `Bundle.main/Resources/Tools` →
    типизированная ошибка `toolMissing`.
- Перенесены из приложения без изменения поведения и стали публичными:
  `DeletedFileCandidate` (модель кандидата), `DeletedFilesError` (все
  типизированные ошибки, включая новый случай `imageNotRegularFile`),
  `SleuthKitOutputParser` (парсинг `fls` и `mmls`), `uniqueResultURL`
  (безопасное уникальное имя, `.partial` удаляется при любой ошибке).
- Алгоритм образного скана: явные попытки `fls -f fat32`/`-f exfat` без таблицы
  разделов, затем `mmls` → смещения разделов → тот же перебор по каждому
  разделу; восстановление — `icat -r [-o смещение]` во временный `.partial` с
  переименованием после успеха.
- Валидации до запуска: образ существует и является обычным файлом; output
  существует, каталог и доступен для записи; `--output` не совпадает с файлом
  образа; все три инструмента существуют и исполняемы (проверяется на этапе
  разрешения путей).
- Физический путь (Authorization Services, `authopen`,
  `recoveryapp-metadata-helper`, readonly-helper) в Core не переносился и не
  менялся — он остался в `Sources/RecoveryApp/DeletedFilesRecovery.swift` для
  TASK-004.

## Доказательство отсутствия дублирования

- `grep -rn "enum SleuthKitOutputParser|final class ImageQuickRecovery|func
  scanBlocking|func recoverBlocking" Sources/` находит все определения только в
  `Sources/RecoveryCore/ImageQuickRecovery.swift`; в приложении образных
  `scanBlocking`/`recoverBlocking` больше нет.
- `Sources/RecoveryApp/DeletedFilesRecovery.swift` ссылается на Core-типы
  (`ImageQuickRecovery`, `ImageQuickToolSet`, `RecoveryToolLocator`,
  `SleuthKitOutputParser`, `DeletedFileCandidate`, `DeletedFilesError`) и
  делегирует образные вызовы: каждый вызов GUI-методов `scan(imageURL:)` и
  `recover(imageURL:)` создаёт новый экземпляр `ImageQuickRecovery`, но все они
  используют одну и ту же общую реализацию RecoveryCore; сигнатуры вызовов
  `DeletedFilesView` сохранены, SwiftUI-внешний вид не менялся.
- Парсер `mmls`/`fls` в репозитории один; режимы физического накопителя и
  PhotoRec остались в приложении (их перенос — другие задачи очереди).

## Команды и JSON-схемы

```text
recoveryapp-cli quick scan --image IMAGE [--json]
recoveryapp-cli quick recover --image IMAGE --output DIRECTORY --all [--json]
```

- Успех — 0, ошибка выполнения — 1, ошибка аргументов — 2; JSON — только в
  stdout (сортировка ключей `sortedKeys`), диагностика — в stderr;
  человекочитаемый вывод русский. Относительные пути приводятся к абсолютным.
- Пути инструментов: `RECOVERYAPP_MMLS_PATH`, `RECOVERYAPP_FLS_PATH`,
  `RECOVERYAPP_ICAT_PATH` (опционально `RECOVERYAPP_TOOL_LAUNCHER_PATH`; без
  лончера CLI запускает инструменты напрямую).
- Разбор аргументов расширен в `CommandLineParser` без внешних зависимостей:
  обязательные `--image`/`--output`/`--all` проверяются, неизвестные,
  повторные и неприменимые параметры (`--output`/`--all` в `scan`, отсутствие
  `--all` в `recover`) дают код 2; `--image` и `--output` не принимают другой
  известный параметр CLI как значение (`quick scan --image --json` — код 2,
  «отсутствует значение»).
- Справка `help` дополнена quick-командами.

## Проверки

| Команда | Результат | Вывод |
|---|---|---|
| `git diff --check` | PASS | пусто (проверено и до коммита на staged-состоянии, и по диапазону базы) |
| `./Scripts/test.sh` | PASS | `PASS: 61 domain checks` (было 39, добавлено 22) |
| `./Scripts/test-cli.sh` | PASS | все 8 проверок прежнего контракта CLI |
| `./Scripts/test-quick-image-cli.sh` | PASS | 8 строк `PASS`, см. детали ниже |
| `./Scripts/test-deleted-recovery.sh` | PASS | FAT32 metadata 3/3 + PhotoRec 2/3; exFAT metadata 3/3 + PhotoRec 2/3; отмена группы процессов |
| `swift build -c release --product recoveryapp-cli` | PASS | `Build complete! (18,01 с)` |
| `./Scripts/build-app.sh` | PASS | собрана и подписана `dist/RecoveryApp.app` |
| `codesign --verify --deep --strict dist/RecoveryApp.app` | PASS | код 0 |
| `swift build -c debug` (дополнительно, весь пакет) | PASS | `Build complete! (25,04 с)` — GUI-таргет собирается через SwiftPM с общим Core |

## Результаты FAT32 (синтетический образ `mformat`/`mcopy`/`mdel`)

- `quick scan --json`: найдены ровно 2 удалённые записи
  (`_ECOVERY.TXT`, `DOCS/_EPORT.TXT` — короткие имена 8.3 у удалённых записей
  FAT32), `filesystemType: "fat32"`, `partitionOffset: 0`, `source` —
  абсолютный путь, stderr пуст.
- `quick recover --all --json`: `recoveredCount: 2`, оба файла существуют в
  папке результата, пути абсолютные.
- Точное побайтное сравнение (`cmp`, код 0 для каждой пары):
  `originals/RECOVERY.TXT` = `result/_ECOVERY.TXT`;
  `originals/REPORT.TXT` = `result/_EPORT.TXT`.

Пример `quick scan --json` (FAT32):

```json
{"candidates":[{"displayName":"_ECOVERY.TXT","filesystemType":"fat32","inode":"5","partitionOffset":0,"path":"_ECOVERY.TXT"},{"displayName":"_EPORT.TXT","filesystemType":"fat32","inode":"37","partitionOffset":0,"path":"DOCS/_EPORT.TXT"}],"schemaVersion":1,"source":"/abs/fat32-deleted.img"}
```

Пример `quick recover --all --json` (FAT32):

```json
{"files":["/abs/result/_EPORT.TXT","/abs/result/_ECOVERY.TXT"],"outputDirectory":"/abs/result","recoveredCount":2,"schemaVersion":1}
```

## Результаты GPT/exFAT (зафиксированная фикстура + генератор удалённых записей)

- `mmls` внутри скана нашёл раздел со смещением 2048 секторов; найдена
  удалённая запись `RECOVERY_NOTE.TXT`, `filesystemType: "exfat"`,
  `partitionOffset: 2048`, инод `426`.
- Точное побайтное сравнение: эталон извлечён встроенным
  `icat -r -f exfat -o 2048` из исходной (до удаления) фикстуры по тому же
  иноду, `cmp` с восстановленным файлом — код 0.

Пример `quick scan --json` (GPT/exFAT):

```json
{"candidates":[{"displayName":"RECOVERY_NOTE.TXT","filesystemType":"exfat","inode":"426","partitionOffset":2048,"path":"RECOVERY_NOTE.TXT"}],"schemaVersion":1,"source":"/abs/exfat-deleted.dmg"}
```

## Повторный запуск без перезаписи

- Второй `quick recover --all --json` по тому же образу и папке создал
  `_ECOVERY_2.TXT` и `_EPORT_2.TXT` (`recoveredCount: 2`), первые файлы не
  изменились; все четыре файла побайтно совпадают с эталонами (`cmp` — 4/4).
- Правило именования — существующее правило проекта (`имя_2.расширение`),
  теперь живёт в Core и покрыто харнессом.

## Проверка опасных имён

Доменный харнесс (11 новых проверок имён и парсера в дополнение к quick-кейсам):

- `..`, `.` и пустое имя заменяются на `recovered_file`;
- `/` и `\` заменяются на `_` (`dir/..\evil` → `dir_.._evil`, имя остаётся
  плоским файлом);
- `uniqueResultURL(suggestedName: "..", folder:)` возвращает путь внутри папки
  результата, `lastPathComponent` не равен `..` — выход за пределы output
  невозможен;
- повторный вызов для существующего имени даёт `RECOVERY_2.TXT` без перезаписи.

## Ошибочные сценарии (из `test-quick-image-cli.sh`)

- Код 2: `quick scan` без `--image`; `--image` без значения; `--all`/`--output`
  в `scan`; `recover` без `--output`; `recover` без `--all`; `recover` без
  `--image`; неизвестная подкоманда `quick show`; неизвестный параметр `--yaml`.
- Код 1: несуществующий образ; образ-каталог (новая ошибка
  `imageNotRegularFile`); несуществующая папка результата; `--output`,
  совпадающий с файлом образа; отсутствие `RECOVERYAPP_FLS_PATH` при недоступном
  bundle-фолбэке (toolMissing).

## Не проверено

- Физический накопитель, `/dev/rdiskN`, `authopen`, Authorization Services и
  metadata helper не использовались и не менялись — это TASK-004; CLI `quick`
  физический источник не принимает.
- GUI-сценарий образного режима в запущенном приложении не перепроверялся:
  UI не менялся, изменён только бэкенд; проверены сборка `.app`, подпись и
  полный синтетический регресс.
- PhotoRec/deep-режим CLI не затрагивался (другие задачи очереди); его
  регресс выполнен существующим `test-deleted-recovery.sh` и сборкой.
- Другие файловые системы (NTFS и т.п.): образный скан теперь явно перебирает
  fat32/exfat, как документировано в `PRODUCT.md` для быстрого режима; прежнее
  поведение авто-детекта прочих ФС образа сужено до заявленных границ продукта
  (сознательное изменение, зафиксировано здесь).
- Reproducible-упаковка (две упаковки с одинаковым SHA-256) не проверялась —
  не входит в обязательные проверки TASK-003.

## Риски и отклонения от задания

- Отклонений от задания нет: diff ограничен разрешённой областью
  (`Sources/RecoveryCore/`, `Sources/recoveryapp-cli/`, два необходимых файла
  `Sources/RecoveryApp/` для подключения общего Core, `Tests/UnitHarness`,
  новый сценарий, `STATUS.md`, `TASKS.md`, отчёт). `Package.swift` и
  `Scripts/test.sh`/`test-cli.sh` не потребовалось менять.
- Сужение авто-детекта ФС до fat32/exfat в образном скане описано выше и
  соответствует границам быстрого режима; поведение для FAT32/exFAT образов не
  изменилось, подтверждено регрессами.
- В `DeletedFilesExecutor` (приложение) остался собственный раннер процессов
  для физического режима и PhotoRec — он обслуживает только неперенесённые
  пути и будет устранён при последующих переносах в Core.

## Временные данные и уборка

- После проверок удалены `work/` (каталоги тестов с образами, кэши SwiftPM) и
  `.build/`, а также `photorec.ses` — контрольная точка от запуска
  `test-deleted-recovery.sh` в корне репозитория.
- Сохранены `Tests/Fixtures/`, архивы `outputs/`, встроенные бинарники и
  проверенное приложение `dist/RecoveryApp.app`.
- Физические накопители не использовались; системные разрешения не
  запрашивались; все данные синтетические.
