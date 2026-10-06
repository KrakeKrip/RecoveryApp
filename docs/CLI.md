# Контракт CLI

CLI использует тот же RecoveryCore, что SwiftUI. Сборка и переменные путей
инструментов — в [DEVELOPMENT.md](DEVELOPMENT.md). Ниже `recoveryapp-cli`
означает собранный исполняемый файл; его нужно вызывать по фактическому пути.
ФАЙЛ, ПАПКА, ИМЯ, БАЙТЫ и diskN — заменяемые параметры, не готовый тест флешки.

## Команды

```text
recoveryapp-cli help
recoveryapp-cli version [--json]
recoveryapp-cli drives list [--json]

recoveryapp-cli quick scan --image ФАЙЛ [--json]
recoveryapp-cli quick recover --image ФАЙЛ --output ПАПКА --all [--json]
recoveryapp-cli quick scan --drive diskN --expected-name ИМЯ --expected-size БАЙТЫ [--json]
recoveryapp-cli quick recover --drive diskN --expected-name ИМЯ --expected-size БАЙТЫ --output ПАПКА --all [--json]

recoveryapp-cli deep recover --image ФАЙЛ --output ПАПКА [--jsonl]
recoveryapp-cli deep recover --drive diskN --expected-name ИМЯ --expected-size БАЙТЫ --output ПАПКА [--jsonl]

recoveryapp-cli video repair --reference ФАЙЛ --damaged ФАЙЛ --output ПАПКА [--jsonl]
```

Quick работает с FAT32/exFAT; `recover --all` заново сканирует и извлекает все
найденные записи. Фильтры GUI и выбор отдельных файлов не являются параметрами
этой CLI-команды. Deep сразу запускает PhotoRec и создаёт уникальную папку
сессии внутри назначения; текущие сигнатуры — JPEG/PNG/MOV/MP4.
Video требует два разных читаемых обычных файла и исправный пример.

`--image` и `--drive` взаимоисключающие. Physical принимает только id вида
`diskN`, не `/dev/diskN` или `/dev/rdiskN`; имя и положительный размер в байтах
обязательны и сверяются по свежему обнаружению перед авторизацией. Сначала
получить `drives list`, заново определить ФС и mount point перед реальным тестом.
Не переносить id из старого отчёта. Пароль команда не принимает; его может
запросить macOS. Не запускать physical без разрешения владельца.

Папка назначения должна уже существовать, быть доступной для записи и безопасной
относительно источника. Результат — на другом физическом диске: другой раздел
или образ на том же диске не заменяет отдельный носитель. Video проверяет именно
физический носитель, а не только том. Образные синтетические тесты не доказывают
физический путь authopen.

## Вывод и статусы

| Режим | stdout | stderr |
|---|---|---|
| `--json` (version/drives/quick) | Один итоговый JSON-отчёт | Диагностика |
| `--jsonl` (deep/video) | Построчные JSON-события | Диагностика и вывод инструмента |
| Без машинного флага | Русский итог | Диагностика/ход операции |

Схема отчётов сейчас `schemaVersion: 1`. Quick scan возвращает `candidates`
и источник; recover — `recoveredCount`, `files`, `items`, `statusCounts`.
Пустой скан — код 0, пустой отчёт, но проверки источника и output остаются.

Размерные статусы quick: `sizeMatches`, `incomplete`, `sizeMismatch`,
`sizeUnknown`; `expectedEmpty` зарезервирован для достоверного нуля.
Ноль из `fls -l` трактуется как неизвестный размер. Неизвестные optional-поля
(например actualSize) могут отсутствовать, это не ноль и не JSON null.
Неполный файл сохраняется; совпадение размеров не проверяет содержимое.

Deep JSONL: `started`, `progress`, `completed`, `cancelled`, `error`.
Video JSONL: `started`, `completed`, `cancelled`, `error`, без progress.
Неизвестные измерения опускаются; точного ETA нет. Error содержит стабильный
`code` и понятное `message`. Контракт полей и модели —
`Sources/recoveryapp-cli/CLIReports.swift`.

| Код выхода | Значение |
|---|---|
| 0 | Успех, включая пустой quick/deep результат |
| 1 | Preflight или ошибка выполнения |
| 2 | Ошибка аргументов |
| 130 | Поддерживаемая отмена Ctrl-C (deep/video) |

Для deep/video Ctrl-C завершает дочернюю группу. Найденные PhotoRec файлы остаются
в сессии; недописанный video-результат текущей операции удаляется. Не считать
неполный stdout после ошибки корректным итоговым отчётом. Quick не заявляет
такой же потоковый JSONL/Ctrl-C контракт, как deep/video.
