# REPORT TASK-009

## Коммит

Полный хеш итогового коммита передаётся Codex отдельным коротким сообщением:
отчёт входит в сам коммит и не может содержать собственный хеш. Ветка:
`glm/task-009-gui-deep-video-acceptance`, базовый коммит
`3c2fcb4ece0787aa81db0d25cb724e0da7cb3571` (= `main` на момент старта).

## Аудит перед запуском

- `git status` чистый, кроме заранее известной нетрекаемой
  `outputs/physical-quick-no-name-20260922/` (не открывалась и не менялась).
- Версии/SHA-256 использованных встроенных инструментов:
  - PhotoRec 7.2 — `32479bc9d1aa32afe074a584651e637474a9ef4cd76e9610f7c255b353f5f70d`
  - untrunc `v1-9d86ec9` (ffmpeg 8.1) — `cda6c307caed260f6840aefdd4f7516a6003f85dbd3e9e27d9a3d40c2645b853`
  - mmls/fls/icat — `17968b5e…`, `57c0c9ec…`, `af59a7f4…` (полные значения в
    выводе команды ниже).
- Запущенных экземпляров RecoveryApp перед стартом не было (`pgrep` пуст).
- Уборочные действия выполнялись только над каталогами/томами, созданными
  этим прогоном (см. «Временные пути и уборка»).

## Сборка

- `OUTPUT_DIR="$(mktemp -d /private/tmp/recoveryapp-t009-app.XXXXXX)"
  ./Scripts/build-app.sh` — exit 0.
- `.app`: `/private/tmp/recoveryapp-t009-app.F636AW/RecoveryApp.app`
  (временный, удалён после проверки), CFBundleShortVersionString 0.8.1,
  CFBundleVersion 13, `Mach-O 64-bit executable arm64`,
  `codesign --verify --deep --strict` — OK. Прежние `dist/RecoveryApp.app`
  и `dist/TASK-008/` не затронуты.

## Синтетические фикстуры

Рабочий каталог: `/private/tmp/recoveryapp-t009-work` (уникальный, удалён
после проверки).

- **RAM-диск 1 (deep)**: `hdiutil attach -nomount ram://98304` → `/dev/disk4`;
  принадлежность доказана сравнением plist-снимков `hdiutil info` до/после:
  устройство появилось только в этом прогоне с `image-path == ram://98304`.
  Отформатирован APFS (`T009DEEP`), фактическая точка монтирования
  `/Volumes/T009DEEP` найдена через `diskutil info/list` (контейнер disk5).
  Маркер владения `.t009-owner`.
- **Образ deep**: `mformat` FAT32 65536 секторов (32 МиБ) на RAM-диске;
  записаны и удалены синтетические `CARD.JPG` (mjpeg), `CARD.PNG`, `CLIP.MP4`
  (H.264/AAC). SHA-256 эталонов: JPG `ef261358…7abe3`, PNG `3fc0e4ee…000b0`,
  MP4 `9126f26c…df210f`.
- **RAM-диск 2 (входы видео)**: тот же протокол доказательства → `/dev/disk6`,
  APFS `T009VID` (контейнер disk7), точка монтирования `/Volumes/T009VID`;
  идентичность RAM-носителя сверена по системным метаданным (`hdiutil info`
  plist: `ram://98304` этого прогона). Входы:
  - `reference.mp4` — 465 344 Б, SHA-256 `6d3fd05f39e97b864224064553eccc163cfe930cc890d7e171af17c88fe5c438`
  - `damaged.mp4` (moov отрезан, `dd count=$((offset-4))`) — 460 632 Б,
    SHA-256 `593ffdd7479f15c8a612986bbe1b5f1ebef181dd91295e96f0f47580b4269ee7`
- Папки результата: `…/deep-out` и `…/video-out` — на внутреннем диске
  (не на RAM-носителях), как требует политика носителя.

## GUI-сценарий 1: глубокий PhotoRec (настоящий запуск инструмента)

- Приложение запущено с `RECOVERYAPP_TEST_DISK_IMAGE` (образ на RAM-диске) и
  `RECOVERYAPP_TEST_DELETED_OUTPUT` (внутренний диск); пути `photorec` и
  `tool-launcher` — реальные встроенные/собранного лончера. Имитаций
  успеха/ошибки не использовалось.
- В GUI открыт раздел «Удалённые файлы», нажат «Глубокий поиск PhotoRec» →
  диалог подтверждения → «Запустить PhotoRec». PhotoRec 7.2 выполнил полный
  проход до завершения (наблюдалась итоговая карточка).
- Итог: карточка «Глубокий поиск завершён. Найдено и сохранено файлов: 3.»;
  папка сессии `…/deep-out/PhotoRec-Recovery` с `Recovered.1` и
  `photorec.log` внутри сессии.
- Найденные файлы (`f0001041.jpg` 22 786 Б, `f0001086.png` 26 672 Б,
  `f0001139.mp4` 204 742 Б) побайтно совпали с синтетическими эталонами
  (`cmp` — JPG/PNG/MP4 BYTE-EXACT).
- Кнопка «Открыть папку» → Finder открыл окно `PhotoRec-Recovery`
  (проверено по имени окна Finder).
- «Подробный лог» раскрылся; содержит: «Запуск глубокого сигнатурного
  поиска PhotoRec…», сводку PhotoRec 7.2, «PhotoRec создал файлов: 3.»,
  «Готово: …/PhotoRec-Recovery». Переполнения лога в этом прогоне не было —
  проблема прокрутки не воспроизводилась и не исследовалась глубже.
- Скриншот карточки: `reports/assets/TASK-009/deep-result-card.jpg`.
- Успех этой фикстуры не означает восстанавливаемость произвольных реальных
  файлов (фрагментация/перезапись не моделировались).

## GUI-сценарий 2: исправление видео (настоящий запуск untrunc)

- Приложение перезапущено с `RECOVERYAPP_TEST_REFERENCE`/`_DAMAGED`
  (RAM-диск 2) и `RECOVERYAPP_TEST_OUTPUT` (внутренний диск); пути `untrunc`
  и `tool-launcher` реальные.
- Нажато «Начать восстановление»: встроенный untrunc `v1-9d86ec9` (ffmpeg 8.1)
  реально выполнился (виден в логе приложения) и завершился успешно.
- Итог: карточка «Видео восстановлено. Готовый файл сохранён отдельно.
  Исходное повреждённое видео не изменялось.»
- Результат: `…/video-out/damaged_recovered.mp4`, 464 476 Б (непустой);
  `ffprobe` — 2 потока (видео+аудио), длительность 4,040272 с. Совместимость
  с иными кодеками не утверждаю.
- Кнопка «Показать файл» → Finder открыл `video-out` с выделенным
  `damaged_recovered.mp4` (проверено через выбор Finder).
- SHA-256 входов после восстановления совпали с до/после первого прогона
  (`INPUTS UNCHANGED`, сравнение файлов контрольных сумм).
- Повторный запуск: создан `damaged_recovered_2.mp4` (464 476 Б,
  SHA-256 идентичен первому), прежний `damaged_recovered.mp4` не перезаписан
  (mtime/имя сохранены). Входы по-прежнему неизменны.
- Скриншот карточки: `reports/assets/TASK-009/video-result-card.jpg`.

## Изменения кода

Код не менялся: оба сценария прошли без дефектов; лог-панель в этом прогоне
не переполнялась (дефект прокрутки не воспроизведён). Доменные/CLI-тесты и
release-пересборка после правок не требуются; полный регресс TASK-008 не
повторялся (изменений кода нет). Точечные проверки целостности дерева ниже.

## Проверки: фактически выполненные команды

Ниже — команды **как они исполнялись в сессии TASK-009** (взяты из записи
сессии, не реконструированы по памяти); их вывод наблюдался в ходе сессии и
цитируется в предыдущих разделах. Временный каталог
`/private/tmp/recoveryapp-t009-work` и временная `.app` удалены после
проверки, поэтому побайтные сравнения и ffprobe повторно выполнить нельзя —
это честно зафиксировано. После последнего изменения кода (изменений не
было) повторялись только узкие проверки формата снимков и состояния дерева —
их вывод актуален на момент коммита.

Сборка `.app` (исполнено в сессии):

```bash
export SDKROOT="$(xcrun --show-sdk-path)"
APP_OUT="$(mktemp -d /private/tmp/recoveryapp-t009-app.XXXXXX)"
OUTPUT_DIR="$APP_OUT" ./Scripts/build-app.sh > /tmp/t9build.log 2>&1; echo "build=$?"      # build=0
/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" \
    -c "Print CFBundleVersion" "$APP/Contents/Info.plist"                                # 0.8.1, 13
file "$APP/Contents/MacOS/RecoveryApp"                                                   # arm64
codesign --verify --deep --strict "$APP" && echo "CODESIGN STRICT OK"                    # OK
```

Доказательство принадлежности RAM-дисков (исполнено в сессии, для обоих
дисков):

```bash
hdiutil info -plist > "$T9/ram1-before.plist"
RAM1_DEV=$(hdiutil attach -nomount ram://98304 2>/dev/null | awk 'NR==1{print $1}')
hdiutil info -plist > "$T9/ram1-after.plist"
python3 - "$RAM1_DEV" 98304 "$T9/ram1-before.plist" "$T9/ram1-after.plist" <<'PY'
# проверка: dev есть в after, image-path == "ram://98304", dev нет в before
PY
# вывод: RAM1 VERIFIED: /dev/disk4 = ram://98304; аналогично RAM2: /dev/disk6
diskutil eraseVolume APFS T009DEEP /dev/disk4
# фактическая точка монтирования: diskutil info -plist + diskutil list -plist
# RAM1_MNT=/Volumes/T009DEEP; RAM2_MNT=/Volumes/T009VID
```

Фикстуры и эталонные суммы (исполнено в сессии):

```bash
ffmpeg -y -f lavfi -i 'testsrc2=size=640x360:rate=1:duration=1' -frames:v 1 \
    -c:v mjpeg -q:v 2 "$T9/CARD.JPG"
ffmpeg -y -f lavfi -i 'testsrc2=size=640x360:rate=1:duration=1' -frames:v 1 "$T9/CARD.PNG"
ffmpeg -y -f lavfi -i 'testsrc2=size=640x360:rate=25:duration=2' \
    -f lavfi -i 'sine=frequency=440:duration=2' -c:v libx264 -pix_fmt yuv420p \
    -c:a aac -movflags +faststart -y "$T9/CLIP.MP4"
mformat -i "$RAM1_MNT/deep.img" -C -F -v T009DEEP -T 65536 ::
mcopy -i "$RAM1_MNT/deep.img" "$T9/CARD.JPG" ::/CARD.JPG   # и PNG, MP4
mdel  -i "$RAM1_MNT/deep.img" ::/CARD.JPG ::/CARD.PNG ::/CLIP.MP4
shasum -a 256 "$T9/CARD.JPG" "$T9/CARD.PNG" "$T9/CLIP.MP4" | tee "$T9/reference.sha256"
```

Проверка результатов PhotoRec (исполнено в сессии; каталог удалён после —
повтор невозможен):

```bash
R="$T9/deep-out/PhotoRec-Recovery/Recovered.1"
ls -la "$R"
cmp "$T9/CARD.JPG" "$R/f0001041.jpg" && echo "JPG BYTE-EXACT"   # OK
cmp "$T9/CARD.PNG" "$R/f0001086.png" && echo "PNG BYTE-EXACT"   # OK
cmp "$T9/CLIP.MP4" "$R/f0001139.mp4" && echo "MP4 BYTE-EXACT"   # OK
```

Проверка видео (исполнено в сессии; каталог удалён после — повтор
невозможен):

```bash
RESULT="$T9/video-out/damaged_recovered.mp4"
test -s "$RESULT" && echo "NON-EMPTY OK"
ffprobe -v error -show_entries stream=index -of csv=p=0 "$RESULT" | wc -l      # 2
ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$RESULT" # 4.040272
shasum -a 256 "$RAM2_MNT/reference.mp4" "$RAM2_MNT/damaged.mp4" \
    > "$T9/video-inputs-after.sha256"
cmp "$T9/video-inputs-before.sha256" "$T9/video-inputs-after.sha256" \
    && echo "INPUTS UNCHANGED"
# после повторного запуска:
ls -la "$T9/video-out/"        # damaged_recovered.mp4 + damaged_recovered_2.mp4
shasum -a 256 "$T9/video-out/"*.mp4   # оба 47db820c…8c7fd — идентичны
shasum -a 256 "$RAM2_MNT/reference.mp4" "$RAM2_MNT/damaged.mp4" \
    > "$T9/video-inputs-after2.sha256"
cmp "$T9/video-inputs-before.sha256" "$T9/video-inputs-after2.sha256" \
    && echo "INPUTS STILL UNCHANGED"
```

Узкие проверки, повторённые сейчас (вывод актуален на момент коммита):

```bash
file reports/assets/TASK-009/deep-result-card.jpg \
     reports/assets/TASK-009/video-result-card.jpg
# обе: JPEG image data … 900x632 (расширения .jpg соответствуют формату)
git diff --check 3c2fcb4ece0787aa81db0d25cb724e0da7cb3571..HEAD   # пусто
git status --short   # чисто, кроме outputs/… и нетрекаемого .mimosa/ (см. уборку)
```

## Не проверено

- Физические накопители, `authopen`, системные запросы пароля/Touch ID —
  не использовались; физическая приёмка остаётся отдельной задачей.
- Первый запуск на «чистом» Mac (Gatekeeper), нотариализация — вне задачи.
- Реальные пользовательские видео/фото — не тестировались; синтетические
  фикстуры не моделируют фрагментацию и перезапись.
- Отмена deep-прохода в GUI и прокрутка переполненного лога — в этом
  прогоне не воспроизводились (отмена группы процессов покрыта
  CLI/helper-тестами TASK-008).
- Совместимость untrunc-результата с иными кодеками/контейнерами — не
  проверялась и не заявляется.

## Временные пути и уборка

- Созданы и удалены после проверки (точные пути):
  `/private/tmp/recoveryapp-t009-app.F636AW` (временная `.app`),
  `/private/tmp/recoveryapp-t009-work` (фикстуры, кэши, логи приложений,
  контрольные суммы), `/tmp/t9build.log`, `/tmp/t9appout.txt`.
- RAM-диски: оба отсоединены по проверенным устройствам этого прогона
  (`disk4`/`disk6` — принадлежность доказана plist-снимками до/после);
  `mount` не содержит `T009*`. `dist/`, `outputs/` (включая пользовательскую
  папку) и системные кэши не тронуты.
- Уборка по замечанию ревью: удалён кэш `work/swift-build` — принадлежность
  TASK-009 подтверждена тем, что (а) запись `work/` целиком удалялась при
  уборке TASK-008 (см. `reports/TASK-008.md`), поэтому каталог мог быть
  создан только после неё; (б) `work/swift-build` датирован 2026-09-25 04:19
  — временем вызова `build-app.sh` этой сессии (для которой `work/swift-build`
  — путь кэша по умолчанию в `Scripts/build-app.sh`, строка
  `cache_dir="${BUILD_CACHE_DIR:-$project_dir/work/swift-build}"`); (в) на
  момент удаления ни один процесс не держал файлы (`pgrep swift/clang` пуст,
  `lsof +D work/swift-build` пуст). Каталог `work/` оставлен пустым.
- Нетрекаемый каталог `.mimosa/` появился в корне проекта вне этой задачи
  (этим прогоном не создавался); он не добавлялся в коммит и не удалялся.
- Сохранены: скриншоты `reports/assets/TASK-009/` (только синтетические
  данные), артефакты `dist/TASK-008/` без изменений.
