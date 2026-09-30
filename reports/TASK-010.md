# TASK-010 — отчёт Codex, 30 сентября 2026

Статус: REVIEW. Ветка: `codex/task-010-physical-quick-gui`.
База: `63d129166c00d2016ab141dcb6c11c8ccab66046`.
Итоговый хеш передаётся отдельно после коммита: собственный хеш невозможно
включить в содержимое этого же коммита.

## Реализовано

`Sources/RecoveryApp/DeletedFilesView.swift`: выбор папки quick-результата
через NSOpenPanel с canChooseDirectories=true, canChooseFiles=false,
canCreateDirectories=true. Отмена не меняет папку; существующая проверка
назначения в ViewModel/Core остаётся без изменений. Авторизация, helper,
O_RDONLY, размер устройства, CLI, версия и иконка не менялись.
Также обновлены TASKS.md, STATUS.md и этот отчёт.

SwiftUI fileImporter показывал неактивную кнопку подтверждения папки.
После замены на NSOpenPanel удалось выбрать новый каталог /private/tmp.
Каталог в /Users/atlhnv/Codex по-прежнему нельзя было подтвердить: причина
не установлена, нельзя считать все ошибки выбора папки исправленными.
Периодические timeout/noWindowsAvailable при автоматизации исчезали после
перепривязки к пути /tmp вместо /private/tmp; sample показал основной поток
приложения в нормальном цикле событий, а не зависшим. Это ограничение
автоматизации, не доказанный дефект восстановления.

## Согласие и источник

Пользователь подключил носитель и отдельно ответил «давай» на запрос
read-only quick scan конкретного NO NAME и восстановления максимум одного
файла. Перед запуском повторно выполнены diskutil info disk4 и disk4s4.

- Внешний физический USB TS2GJF150, NO NAME.
- /dev/disk4, /dev/rdisk4; размер 2055208960 байт.
- MBR; /dev/disk4s4, FAT32, /Volumes/NO NAME; смещение 63 сектора.
- Назначение: /private/tmp/RecoveryApp-TASK010-results-20260930.wHfzmR,
  внутренний APFS SSD (physical store disk0s2), свободно около 94,5 ГБ
  до теста. Папка новая, пустая, вне исходного диска.
- Пароль не вводился и не сохранялся агентом. UI показывал получение
  системного доступа, затем завершил scan. Число диалогов не установлено:
  отдельный вопрос пользователю пока не получил ответа.

## Проверено в GUI

Открыта именно новая arm64 .app 0.8.1 (13), без тестовых подмен инструментов.
Диск явно выбран. Scan: 71 находка, понятный текст завершения без сырых кодов.
В таблице клавиатурой выбран один служебный файл с ненулевым размером;
перед извлечением UI показывал «Выбрано: 1 из 71».
Recover: один файл, фактически 8224 байта; карточка сообщает совпадение
размеров (sizeMatches) и предупреждает, что это не проверка целостности.
Кнопка «Открыть папку» открыла Finder с URL именно текущего каталога и
одним объектом. Карточка визуально проверена, подробный лог раскрывается.
Имена и содержимое восстановленных файлов в отчёт не включены.
Файл не открывали, не хешировали и не сравнивали содержимое.

`diskutil info /dev/disk4s4` после теста: та же ФС, точка монтирования,
размер и свободное место 2049806336 байт, как до теста. Это дополнительное
наблюдение, не доказательство отсутствия любых записей. Источник нормально
смонтирован macOS read/write; приложение читает через read-only helper.
`pgrep -fl 'recoveryapp-metadata-helper|/authopen|/Tools/(fls|icat|mmls)'`
после завершения: код 1, работающих дочерних инструментов нет.

## Проверки и команды

Использован совместимый SDK /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk.

- `OUTPUT_DIR=/private/tmp/recoveryapp-task010.4qgvgX/fixed BUILD_CACHE_DIR=/private/tmp/recoveryapp-task010.4qgvgX/cache RECOVERYAPP_SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ./Scripts/build-app.sh`:
  release-сборка и подпись проходят.
- `BUILD_CACHE_DIR=/private/tmp/recoveryapp-task010.4qgvgX/test-cache RECOVERYAPP_SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ./Scripts/test.sh`:
  PASS: 237 domain checks. В sandbox проверка resolver не могла определить
  физический носитель; повтор вне sandbox прошёл. Это не скрытый PASS
  первого прогона.
- `codesign --verify --deep --strict /private/tmp/recoveryapp-task010.4qgvgX/fixed/RecoveryApp.app`:
  код 0.
- `file /private/tmp/recoveryapp-task010.4qgvgX/fixed/RecoveryApp.app/Contents/MacOS/RecoveryApp`: Mach-O 64-bit executable arm64.
- `/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' -c 'Print :CFBundleVersion' /private/tmp/recoveryapp-task010.4qgvgX/fixed/RecoveryApp.app/Contents/Info.plist`:
  0.8.1, 13.
- `BUILD_CACHE_DIR=/private/tmp/recoveryapp-task010.4qgvgX/cli-cache RECOVERYAPP_SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ./Scripts/test-cli.sh`:
  все 8 проверок PASS, код 0. Сборка содержит предупреждения о ненайденных
  каталогах preview Command Line Tools, но завершается успешно.
- `git diff --check`: код 0.
- GUI: выбор папки → выбор диска → scan → один выбор → recover → карточка
  → Finder → подробный лог, через native UI automation.
- Проверка только числа и размера файлов через `perl`/stat: 1, 8224 байта;
  содержимое не читалось.

## Результаты и уборка

Результат скопирован без перезаписи в постоянную папку:
`/Users/atlhnv/Codex/RecoveryApp-test-results/TASK010-20260930.blHdpl/`.
Оригинальная папка результата /private/tmp также сохранена; это не кэш.
Пользовательские `.mimosa/`, outputs/physical-quick-no-name-20260922/,
старые dist и релизные архивы не изменялись.
Собственные временные сборки и кэши расположены только в
/private/tmp/recoveryapp-task010.4qgvgX; после завершения тестового приложения
этот точный каталог удаляется целиком. Оба каталога результатов вне него.

## Пока не проверено

Число системных запросов, выбор назначения вне /tmp, exFAT через физический
GUI, отмена/отключение при данном прогоне, целостность файла, реальные фото
и видео, другая машина/чистый первый запуск. Большой носитель и физический
deep PhotoRec не использовались. Полная матрица TASK-008 не повторялась:
изменён только диалог назначения. TASK-011 не начиналась.
