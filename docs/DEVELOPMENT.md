# Сборка и разработка

Все команды — из корня Git-репозитория на Apple Silicon Mac. Перед началом
прочитать [правила агента](AGENT_GUIDE.md) и текущее задание.

## Окружение

Для Swift-кода нужны macOS 14+, Swift 6 и Xcode/Command Line Tools. В TASK-016
использовались SDK 26.5 и Apple clang 21; это evidence конкретной сборки, а не
обещание побайтного совпадения на любом SDK. Скрипты Swift принимают
`RECOVERYAPP_SDKROOT`; по умолчанию SDK выбирает `xcrun --show-sdk-path`.

```sh
git rev-parse --show-toplevel
git status --short
swift --version
xcrun --show-sdk-path
./Scripts/test-toolchain-provenance.sh
```

Бинарники arm64 и пять исходных архивов включены в Git. Сборка `.app` использует
готовые инструменты; полная пересборка стороннего кода для обычной Swift-задачи
не нужна. Для интеграционных тестов нужны зависимости конкретного скрипта:
`mtools` (mformat/mmd/mcopy/mdel), Python 3, xz; видео-тестам может требоваться
внешний тестовый FFmpeg. Для контрольных сборок — также make, CMake и инструменты,
указанные в build-сценариях. Сначала читать их preflight, не устанавливать новые
зависимости автоматически. Встроенный статический FFmpeg внутри untrunc не
является отдельной командой `ffmpeg` для создания fixtures.

## Swift и приложение

```sh
./Scripts/test.sh
swift build -c release --product recoveryapp-cli
```

`test.sh` компилирует общий Core и доменный harness, включая нужные GUI-модели.
Это основной доменный набор; один `swift test` не заменяет его и интеграционные
сценарии. Список проверок по риску — в [AGENT_GUIDE.md](AGENT_GUIDE.md).

Сборка приложения в новую уникальную папку:

```sh
app_output="$(mktemp -d /private/tmp/recoveryapp-dev-app.XXXXXX)"
OUTPUT_DIR="$app_output" ./Scripts/build-app.sh
codesign --verify --deep --strict "$app_output/RecoveryApp.app"
./Scripts/test-license-package.sh "$app_output/RecoveryApp.app"
open "$app_output/RecoveryApp.app"
```

Переменные `OUTPUT_DIR`, `BUILD_CACHE_DIR`, `RECOVERYAPP_SDKROOT` позволяют
изолировать вывод, кэш и SDK. `build-app.sh` в release собирает Core и приложение
через swiftc; debug использует SwiftPM. Упаковываются native helpers, инструменты,
лицензии, исходные архивы, патчи и evidence; затем всё подписывается ad-hoc.
В существующем OUTPUT_DIR скрипт заменяет `RecoveryApp.app` — не выбирать папку
чужого/старого релиза.

После UI-правок проверить именно новую `.app`: нужные сценарии, ошибки, отмену,
узкое окно и Finder-кнопки; сохранить evidence. Компиляция и подпись не заменяют
визуальную приёмку. Реальная флешка для этого по умолчанию не нужна.

## CLI без запуска GUI

Инструменты standalone CLI автоматически не ищутся в соседней ThirdParty.
После сборки `.app` выше можно подключить полный комплект, включая helpers:

```sh
cli_bin_dir="$(swift build -c release --product recoveryapp-cli --show-bin-path)"
cli="$cli_bin_dir/recoveryapp-cli"
tools="$app_output/RecoveryApp.app/Contents/Resources/Tools"
export RECOVERYAPP_MMLS_PATH="$tools/mmls"
export RECOVERYAPP_FLS_PATH="$tools/fls"
export RECOVERYAPP_ICAT_PATH="$tools/icat"
export RECOVERYAPP_PHOTOREC_PATH="$tools/photorec"
export RECOVERYAPP_UNTRUNC_PATH="$tools/untrunc"
export RECOVERYAPP_METADATA_HELPER_PATH="$tools/recoveryapp-metadata-helper"
export RECOVERYAPP_READONLY_HELPER_PATH="$tools/recoveryapp-readonly-helper"
export RECOVERYAPP_TOOL_LAUNCHER_PATH="$tools/tool-launcher"
"$cli" help
"$cli" version --json
```

Для образного quick достаточно путей mmls/fls/icat (возможен прямой путь к
ThirdParty); для проверки production-отмены использовать комплект с лончером.
Команды источников и назначения — в [CLI.md](CLI.md). Physical-команды могут
запросить системное разрешение; не запускать их при запрете владельца.

## Упаковка

Создавать новый OUTPUT_DIR: package-сценарии заменяют одноимённый выходной файл.
Не пересобирать старые релизы поверх. Пример нового комплекта:

```sh
package_output="$(mktemp -d /private/tmp/recoveryapp-package-output.XXXXXX)"
OUTPUT_DIR="$package_output" ./Scripts/package-zip.sh
OUTPUT_DIR="$package_output" ./Scripts/package-dmg.sh
OUTPUT_DIR="$package_output" ./Scripts/package-source.sh
./Scripts/test-source-package.sh
```

ZIP/DMG приложения собирают `.app` сами. Можно задать `APP_ARCHIVE_NAME`,
`DMG_NAME`, `SOURCE_ARCHIVE_NAME`. DMG использует vendored dmgbuild, включает
Applications, фон и русскую инструкцию. Защитные findings этого build-tool
остаются открытыми; упаковка не является доказательством его безопасности.

Проверки комплектности и подписи не доказывают отсутствие Gatekeeper-блокировки
на другом Mac и не дают юридического разрешения на распространение. Упаковщик
исходников не включает очередь/задания/отчёты и корневые продуктовые документы;
для работы агентов нужен Git checkout. Старые архивы не обновляются после
изменения README автоматически.

## Provenance и сторонние инструменты

```sh
./Scripts/test-toolchain-provenance.sh --selftest
python3 Scripts/verify-ffmpeg-config.py --help
```

`ThirdParty/BUILD-PROVENANCE.json` фиксирует SHA-256 входов, бинарников, рецептов
и evidence. Обычные изменения приложения не должны менять эти файлы.
`build-sleuthkit.sh`, `build-photorec.sh`, `build-untrunc.sh` — отдельные
контрольные сборки, не быстрый способ «починить тест». Перед ними прочитать
[TOOLCHAIN_PROVENANCE.md](TOOLCHAIN_PROVENANCE.md) и текущее задание.

`finalize-toolchain-provenance.py` **изменяет эталонные pins**, а не проверяет
их. Не запускать для устранения mismatch: сначала установить причину,
проверить новую сборку и получить решение координатора. Перегенерация хеша сама
по себе ничего не доказывает.

## Уборка и отчёт

Скрипты могут оставлять `work/`, `.build/`, fixtures и тестовые результаты.
Зафиксировать собственные пути до запуска, затем убрать только свои временные
данные после проверки. Уникальные OUTPUT_DIR не удалять, если это передаваемый
артефакт; перенести в новый именованный каталог dist по заданию. Не очищать
`outputs/`, `dist/`, `.mimosa/` и пользовательские результаты целиком.

Для docs-only работы достаточно проверки фактов, ссылок и diff. Не писать
«все тесты PASS», если они не выполнялись в текущей задаче.
