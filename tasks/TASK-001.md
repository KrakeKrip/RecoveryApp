# TASK-001 — фундамент RecoveryCore и RecoveryCLI

## Статус и ветка

- Статус: `TODO`.
- Ветка: `glm/task-001-cli-foundation`.

## Цель

Создать минимальный CLI backend и общий модуль обнаружения накопителей без
изменения восстановления, helper-процессов или SwiftUI.

## Обязательные изменения

1. Добавить library target `RecoveryCore`.
2. Перенести туда без изменения поведения `ExternalDrive`,
   `ExternalDriveError`, `ExternalDriveParser` и `ExternalDriveDiscovery`.
3. Подключить `RecoveryApp` к `RecoveryCore` и сохранить текущую работу GUI.
4. Добавить executable product и target `recoveryapp-cli`.
5. Реализовать команды:

   ```text
   recoveryapp-cli version
   recoveryapp-cli version --json
   recoveryapp-cli drives list
   recoveryapp-cli drives list --json
   recoveryapp-cli help
   ```

6. Человекочитаемый вывод должен быть русским.
7. JSON формировать через `JSONEncoder`, не конкатенацией строк.
8. `drives list` использует общий `ExternalDriveDiscovery` и ничего не открывает
   на чтение или запись.
9. Неизвестная команда возвращает ненулевой код и подсказку в stderr.
10. Добавить тестируемый разбор аргументов без внешних зависимостей.
11. Добавить `Scripts/test-cli.sh` с детерминированными проверками `version`,
    `help`, ошибочной команды и JSON. Флешка для теста не требуется.

## JSON-схемы

```json
{"schemaVersion":1,"appVersion":"0.8.1","build":"13"}
```

```json
{"schemaVersion":1,"drives":[{"id":"disk4","name":"Flashka","size":125829120000,"rawDevicePath":"/dev/rdisk4","mountPoints":["/Volumes/Flashka"]}]}
```

Массив дисков может быть пустым; порядок ключей не является контрактом.

## Запрещено

- Не исправлять `/dev/fd/N` и не пересобирать Sleuth Kit.
- Не менять native helper, PhotoRec, `untrunc` или recovery-поведение.
- Не использовать реальный raw-диск.
- Не менять SwiftUI-внешний вид, версию, иконку или упаковку.
- Не добавлять сеть, телеметрию, автообновление или внешние Swift-пакеты.

## Обязательные проверки

```sh
./Scripts/test.sh
./Scripts/test-cli.sh
swift build -c release --product recoveryapp-cli
./Scripts/build-app.sh
codesign --verify --deep --strict dist/RecoveryApp.app
```

Если нужен обход SDK из README, записать точную команду в отчёт.

## Git и отчёт

1. Работать только в `glm/task-001-cli-foundation`.
2. Создать `reports/TASK-001.md` по `reports/TEMPLATE.md`.
3. Поменять в `TASKS.md` только статус TASK-001 с `TODO` на `REVIEW`.
4. Сделать один итоговый коммит:

   ```text
   TASK-001: add RecoveryCore and CLI foundation
   ```

5. Прислать Codex полный хеш коммита.
6. Не сливать ветку в `main` и не начинать TASK-002.

## Критерии приёмки

- Diff ограничен заданием.
- GUI собирается и использует общий `ExternalDrive`.
- CLI не дублирует парсер дисков.
- JSON соответствует схеме, ошибочные аргументы дают ненулевой exit code.
- Все обязательные проверки проходят, отчёт соответствует коммиту.

