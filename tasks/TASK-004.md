# TASK-004 — физический read-only источник и quick CLI

## Статус и ветка

- Статус: `TODO`.
- Ветка: `glm/task-004-physical-quick-cli`.

## Цель

Добавить в `RecoveryCore` и `recoveryapp-cli` быстрый поиск и восстановление с
физического внешнего накопителя через существующую безопасную цепочку:

```text
повторное обнаружение → сверка id/имени/размера → Authorization Services
→ authopen O_RDONLY → metadata helper → /dev/fd/0 → mmls/fls/icat
```

GLM реализует и проверяет код только синтетически. Реальную `Flashka`,
`/dev/diskN` и `/dev/rdiskN` в этой задаче GLM не открывает. Физическую
приёмочную проверку после code review выполнит Codex отдельно.

## Команды CLI

```text
recoveryapp-cli quick scan \
  --drive diskN --expected-name NAME --expected-size BYTES [--json]

recoveryapp-cli quick recover \
  --drive diskN --expected-name NAME --expected-size BYTES \
  --output DIRECTORY --all [--json]
```

- `--image` и `--drive` взаимно исключаются.
- Идентификатор принимается только в виде `disk` + цифры, не `/dev/...`.
- `expected-name` и положительный `expected-size` обязательны для физического
  источника и должны точно совпасть с повторно обнаруженным накопителем.
- Команда `recover` сканирует и восстанавливает в рамках одной авторизационной
  сессии. Нельзя создавать два последовательных системных запроса пароля.
- CLI не принимает пароль, токен авторизации или raw FD через аргументы.

## JSON-контракт

Физический scan:

```json
{
  "schemaVersion": 1,
  "drive": {
    "id": "disk4",
    "name": "Flashka",
    "size": 125829120000,
    "rawDevicePath": "/dev/rdisk4"
  },
  "candidates": []
}
```

Физический recover использует существующую схему `QuickRecoverReport` с
абсолютными путями результата. JSON идёт только в stdout, диагностика и
технический лог — в stderr.

## Обязательные изменения

1. Вынести из `DeletedFilesExecutor` в `RecoveryCore` физический быстрый backend:
   - Authorization Services и внешний authorization form;
   - запуск `recoveryapp-metadata-helper`;
   - scan FAT32/exFAT напрямую и через `mmls` offsets;
   - восстановление через helper/`icat`;
   - преобразование кодов helper 77/74/73/130 в типизированные ошибки;
   - отмену группы процессов.
2. SwiftUI должен делегировать физические quick scan/recover общему Core. Не
   оставлять две реализации физического алгоритма.
3. Не переносить PhotoRec/deep recovery в этой задаче.
4. Перед Authorization Services CLI обязан заново вызвать
   `ExternalDriveDiscovery`, найти ровно тот `diskN` и сверить точные имя и
   размер с переданными ожиданиями. При несовпадении завершиться до запроса
   разрешения с понятной ошибкой `sourceChanged`/`sourceUnavailable`.
5. Native helper продолжает независимо проверять фактический размер уже
   открытого физического устройства и режим `O_RDONLY`.
6. Перед авторизацией `recover` обязан проверить, что output существует,
   доступен для записи и не находится ни в одной точке монтирования исходного
   физического диска. Helper сохраняет собственную повторную проверку.
7. Одна CLI-команда создаёт не более одной Authorization Services сессии.
   `quick recover --drive` использует её и для scan, и для всех `icat`.
8. Путь helper разрешается через `RECOVERYAPP_METADATA_HELPER_PATH` либо
   `Bundle.main/Resources/Tools`; helper должен оставаться отдельным процессом.
9. Расширить разбор аргументов и русскую справку. Неизвестные, повторные,
   конфликтующие или отсутствующие параметры дают код 2.
10. Добавить тестируемую функцию выбора/сверки диска по снимку `[ExternalDrive]`
    без вызова `diskutil` и без системной авторизации.
11. Добавить доменные проверки:
    - корректное совпадение id/имени/размера;
    - диск отсутствует;
    - изменилось имя;
    - изменился размер;
    - запрещён `/dev/rdiskN` вместо `diskN`;
    - конфликт `--image`/`--drive`;
    - обязательность expected-name/expected-size;
    - expected-size не число, ноль или отрицательный;
    - output на исходном mount point отклоняется до авторизации.
12. Добавить `Scripts/test-physical-quick-cli-contract.sh`. Он не должен
    открывать физический диск или вызывать окно разрешения. Сценарий проверяет
    parser, JSON-кодирование моделей, synthetic matcher и существующий helper
    на обычных образах.
13. Обновить `ARCHITECTURE.md` и `STATUS.md` фактическими результатами. Явно
    отметить: код физического CLI реализован, но реальный `authopen` после
    исправления Sleuth Kit ещё не проверен.

## Неприкосновенные требования безопасности

- Не менять режим `authopen`: только чтение.
- Не передавать пароль через stdin, argv, environment или файлы.
- Не ослаблять проверку `O_RDONLY`, размера устройства и output-on-source.
- Не принимать raw-путь от пользователя как источник.
- Sleuth Kit остаётся отдельным CLI, прямого линкования нет.
- Не записывать ничего на источник.

## Запрещено исполнителю GLM

- Не обращаться к реальным `/dev/diskN` и `/dev/rdiskN`.
- Не запускать команды с `--drive` на подключённом накопителе.
- Не использовать, не размонтировать и не изменять Flashka.
- Не вызывать реальный системный запрос Authorization Services.
- Не менять native helper, патч или бинарники Sleuth Kit без отдельного
  согласования с Codex. Если реализация требует их изменения — остановиться.
- Не менять PhotoRec, `untrunc`, UI, иконку, DMG, версию или build.
- Не добавлять сеть, телеметрию, обновления и внешние зависимости.

## Обязательные проверки GLM

```sh
git diff --check
./Scripts/test.sh
./Scripts/test-cli.sh
./Scripts/test-quick-image-cli.sh
./Scripts/test-physical-quick-cli-contract.sh
./Scripts/test-metadata-helper.sh
./Scripts/test-sleuthkit-preopened-fd.sh
./Scripts/test-deleted-recovery.sh
swift build -c release --product recoveryapp-cli
./Scripts/build-app.sh
codesign --verify --deep --strict dist/RecoveryApp.app
```

Ни одна из проверок GLM не должна обращаться к физическому накопителю.

## Разрешённая область diff

- `Package.swift`, только если требуется системный framework для Core.
- `Sources/RecoveryCore/`.
- `Sources/recoveryapp-cli/`.
- Необходимые части `Sources/RecoveryApp/DeletedFilesRecovery.swift` и
  `UserFacingFailure.swift` для делегирования Core.
- `Tests/UnitHarness/main.swift`.
- `Scripts/test.sh`, `Scripts/test-cli.sh` при необходимости.
- Новый `Scripts/test-physical-quick-cli-contract.sh`.
- `ARCHITECTURE.md`, `STATUS.md`, `TASKS.md`, `reports/TASK-004.md`.

Другие файлы не менять без предварительного объяснения координатору.

## Git и отчёт

1. Работать только в `glm/task-004-physical-quick-cli` от указанного
   координатором коммита `main`.
2. Создать `reports/TASK-004.md` по шаблону.
3. Поменять только TASK-004: `TODO` → `REVIEW`.
4. Сделать один итоговый коммит:

   ```text
   TASK-004: add physical read-only quick recovery CLI
   ```

5. Прислать полный хеш. Не сливать `main` и не начинать TASK-005.

## Критерии приёмки кода

- Физический алгоритм один и находится в Core; GUI и CLI делегируют ему.
- До разрешения сверяются disk id, имя и размер.
- Helper повторно проверяет O_RDONLY, размер и output-on-source.
- На CLI-команду приходится не более одной авторизационной сессии.
- Image CLI из TASK-003 не сломан.
- Все синтетические проверки проходят, diff ограничен задачей.
- Отчёт не выдаёт синтетические проверки за доказательство реальной Flashka.

## Отдельная приёмка Codex после code review

После получения коммита Codex:

1. заново определит точный внешний диск, имя, размер, файловую систему и mount;
2. проверит, что output находится на внутреннем диске;
3. запустит только короткий read-only `quick scan --drive`;
4. подтвердит один системный запрос, работу `/dev/fd/0` и отсутствие записи;
5. остановится без полного прохода, если короткой проверки достаточно.

До этой отдельной проверки физический путь считается реализованным, но не
подтверждённым на реальном устройстве.
