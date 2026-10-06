# REPORT TASK-015

## База и ветка

- Ветка: `glm/task-015-license-package-audit`, создана от актуального `main`
  = `d1bddcc2fc3fc726abf158b9fde2d1b675619f06` (коммит, содержащий файл
  задания `tasks/TASK-015.md`).
- TASK-013/TASK-014 не выполнялись (отложены пользователем); Mimosa не
  менялась; Sources/UI/алгоритмы/версия/иконка/DMG-упаковка не менялись.

## Изменённые файлы

- Созданы:
  - `docs/DISTRIBUTION_CHECKLIST.md` — сводный комплектностный чеклист
    (таблица 11 групп компонентов, evidence, SHA-256, PASS/WARNING/UNVERIFIED,
    оставшиеся вопросы, вывод о комплектности файлов);
  - `Scripts/test-license-package.sh` — автоматический контроль состава
    лицензионного комплекта `.app` (побайтные сравнения + обязательные
    бинарники);
  - `Scripts/test-source-package.sh` (раунд ревью) — регрессионный тест
    рекурсивных исключений упаковки на синтетическом проекте
    (`.git`-каталоги и `.git`-файл worktree/submodule, `.mimosa`,
    `__pycache__`, `*.pyc`, `.DS_Store`); проверка запрета по полному
    компоненту пути (раунд r2→r3);
  - `ThirdParty/untrunc/FFMPEG-COPYING.LGPLv2.1.txt` — полный текст LGPL 2.1,
    извлечён без изменений из `COPYING.LGPLv2.1` исходного архива FFmpeg 8.1;
  - `reports/TASK-015.md` (этот файл);
  - `reports/assets/` — не создавались (GUI-приёмка задачей не выполнялась).
- Изменены:
  - `Scripts/build-app.sh` — три пропущенных обязательных файла: копировать
    `Packaging/photorec-dev-fd.patch` в `SourceArchives` (photorec собран из
    изменённых исходников — GPL обязан прикладывать патч), `LICENSE` (GPL-2
    RecoveryApp) в `Contents/Resources/LICENSE`, LGPL-текст FFmpeg в
    `Tools/ffmpeg-COPYING.LGPLv2.1.txt`;
  - `Scripts/package-source.sh` — исключить `__pycache__`/`*.pyc` и
    рекурсивно `.git`/`.mimosa` — файлы И каталоги, по имени без `-type d`
    (уточнение раунда r2→r3: git worktree/submodule оставляет обычный файл
    `.git`); параметр `SOURCE_PROJECT_DIR` для синтетического прогона;
  - `TASKS.md`, `tasks/TASK-015.md` — статус TODO → REVIEW (раунд ревью);
  - `ThirdParty/sleuthkit/SOURCE.md` — фактические SHA-256 бинарников
    (записи устарели: пересборка/переподпись 2026-09-18), точное описание
    патча (3 файла, `dup()` + явный `lseek`), сухой прогон патча, отметка
    UNVERIFIED по побайтному provenance;
  - `ThirdParty/photorec/SOURCE.md` — фактический SHA-256 бинарника
    (обновлён), версия через `AC_INIT`, описание патча
    `photorec-dev-fd.patch`, отметка UNVERIFIED;
  - `ThirdParty/untrunc/SOURCE.md` — добавлен SHA-256 архива исходников;
    LGPL FFmpeg — условно по рецепту, фактические configure-флаги и связь
    бинарника с архивом — UNVERIFIED (раунд ревью);
  - `ThirdParty/README.md` — устаревшее «PhotoRec остаётся вне `.app`»
    заменено установленным фактом; конфигурация FFmpeg — по рецепту
    (раунд ревью);
  - `docs/SLEUTH_KIT_LICENSE_AUDIT.md` — уточнено описание патча (3 файла,
    два изменения), добавлен раздел обновления TASK-015 (обновление SHA,
    UNVERIFIED provenance, побайтная идентичность лицензий архиву); удалено
    разрешающее утверждение о необязательности юридического заключения для
    некоммерческого релиза (раунд ревью).

## Выполненный аудит — краткие результаты

### Инвентаризация компонентов (полностью — в `docs/DISTRIBUTION_CHECKLIST.md`)

- `.app` содержит: RecoveryApp (GPL-2) + RecoveryCore (статически), три
  собственных C-helper'а, Sleuth Kit 4.15.0 (`fls`/`icat`/`mmls`, CPL 1.0 /
  IPL 1.0 / mixed), PhotoRec 7.2 (GPL-2+, статический libjpeg-turbo 3.2.0 —
  BSD-3 + IJG), untrunc (GPL-2, статический FFmpeg 8.1 — LGPL-2.1-or-later).
- `recoveryapp-cli` в `.app` не входит; dmgbuild 1.6.7 / ds_store 1.3.3 /
  mac_alias 2.2.3 (MIT) — только среда сборки DMG (`Scripts/package-dmg.sh`),
  в `.app` не попадают, в source ZIP входят через `ThirdParty/BuildTools` с
  лицензиями и без `__pycache__`.

### Найденные и исправленные пропуски упаковки

1. `photorec-dev-fd.patch` отсутствовал в SourceArchives `.app` —
   photorec-бинарник собран из изменённых исходников. Исправлено
   (build-app.sh), подтверждено в собранной `.app`.
2. Текст лицензии самого RecoveryApp (GPL-2, `LICENSE`) отсутствовал в `.app`.
   Исправлено.
3. Текст LGPL 2.1 для статического FFmpeg отсутствовал в `.app`. Исправлено
   (копия из архива FFmpeg 8.1, без изменений).
4. Source ZIP содержал кэши `__pycache__`/`*.pyc` из BuildTools. Исправлено
   (package-source.sh), подтверждено на новом ZIP.

### Устаревшие записи (исправлены как документация)

- SHA-256 `fls`/`icat`/`mmls` и `photorec` в SOURCE.md не совпадали с
  фактическими бинарниками (пересобраны/переподписаны после записи: mtime
  2026-09-18 и 2026-09-14 = времени патчей). Записи обновлены на фактические;
  побайтный provenance к контрольной пересборке честно помечен UNVERIFIED.
- SHA-256 архива исходников untrunc нигде не был записан — добавлен.

### Sleuth Kit — чеклист (детали в checklist)

- `patch -d <source> -p1 --dry-run` на чистом архиве 4.15.0 (уникальный
  временный каталог `/tmp/tsk015-*/`) — патч применяется без отклонений
  (3 файла: `tsk/img/raw.c`, `tsk/util/file_system_utils.{h,c}`); полная
  пересборка TSK не выполнялась.
- `CPL-1.0.txt`, `IBM-PUBLIC-LICENSE-1.0.txt`, `LICENSES-README.md` побайтно
  идентичны `licenses/` архива (`cmp`); IBM copyright-строка сохранена.
- `otool -L` Swift-исполняемого файла собранной `.app` не содержит libtsk;
  статическая линковка исключена составом команд `swiftc` (входы сборки
  проверены).

### FFmpeg / libjpeg

- Конфигурация FFmpeg — upstream `FF_CONFIG_FLAGS` из Makefile архива
  untrunc: без `--enable-gpl`/`--enable-nonfree` → LGPL-2.1+;
  перекрёстно согласовано с `otool -L untrunc` (нет libz/bz2/lzma/AVFoundation).
- Версии в бинарниках подтверждены строками без запуска: untrunc —
  `v1-9d86ec9` + `ffmpeg '8.1'`; photorec — `3.2.0` libjpeg-turbo.
- Лицензионные тексты photorec/untrunc/libjpeg побайтно идентичны архивам.

### Внешние проверки (официальные сайты, 2026-10-06)

- ffmpeg.org/download.html — ветка 8.1 существует (текущий 8.1.3 от
  2026-09-21; поставляется ровно 8.1);
- github.com/sleuthkit/sleuthkit/releases/tag/sleuthkit-4.15.0 — релиз
  существует (список assets не отрисовался — имя не подтверждено внешне);
- github.com/libjpeg-turbo/libjpeg-turbo/releases/tag/3.2.0 — релиз и имя
  tarball подтверждены;
- cgsecurity.org/wiki/TestDisk_Download — 7.2 (2024-02-22), tarball
  `testdisk-7.2.tar.bz2`;
- github.com/anthwlock/untrunc и коммит `9d86ec9ef2ff…` («hvc1: restore CRA
  seek points») подтверждены.

## Проверка упаковки (точные команды и результаты)

- Сборка `.app` (SDK 26.5, уникальные каталоги):
  `OUTPUT_DIR=$(mktemp -d /tmp/recoveryapp-t015-lab.XXXXXX)
  BUILD_CACHE_DIR=$LAB_DIR/build-cache
  RECOVERYAPP_SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
  ./Scripts/build-app.sh` — exit 0.
  - `lipo -archs` → `arm64`; `Info.plist` → 0.8.1 / 13;
  - `codesign --verify --deep --strict` → OK (строгая ad-hoc);
  - `otool -L Contents/MacOS/RecoveryApp` → нет libtsk/avcodec/avformat/avutil;
  - `Contents/Resources/SourceArchives/` — 7 файлов (5 архивов + 2 патча,
    включая добавленный `photorec-dev-fd.patch`); побайтно идентичны
    `outputs/` (`cmp`);
  - `Tools/*-SOURCE.md` побайтно идентичны `ThirdParty/*/SOURCE.md`;
  - `Resources/LICENSE` и `Tools/ffmpeg-COPYING.LGPLv2.1.txt` на месте.
- `Scripts/test-license-package.sh <.app>` — положительный сценарий: OK
  (19 обязательных копий побайтно, 8 бинарников на месте).
  Негативный сценарий: из временной копии `.app` удалён
  `SourceArchives/photorec-dev-fd.patch` — проверка завершилась отказом
  (`FAIL: отсутствует обязательный файл …`, exit != 0). Shell syntax всех
  трёх скриптов (`zsh -n`) — OK.
- Source ZIP: `OUTPUT_DIR=$LAB_DIR
  SOURCE_ARCHIVE_NAME=RecoveryApp-source-v0.8.1-lab-task015-audit.zip
  ./Scripts/package-source.sh` — exit 0; `unzip -tq` — «No errors detected».
  ZIP не содержит `.git`, `.mimosa`, `__pycache__`, `*.pyc`, пользовательских
  outputs (только 5 исходных архивов, побайтно равных `outputs/`).
  Побайтное сравнение распаковки с репозиторием: 14 ключевых файлов
  (документы, скрипты, патчи, LGPL-текст, LICENSE, FindingsFilter.swift с
  изменениями TASK-012) — идентичны.
- Пересборка ZIP после финальных правок: все изменения документов/скриптов
  внесены ДО упаковки, ZIP собран последним и проверен (последующий diff
  исходников отсутствует). `.app` собирается после изменения входящих
  notices (build-app.sh/SOURCE.md) и проверена после этого.
- Recovery-регресс (`test.sh` и др.) не выполнялся: изменения — только
  документация, notices и узкие правки упаковочных скриптов; `Sources/`
  не менялись (заявляю это явно, регресс не повторялся).

## Артефакты (пути, размеры, SHA-256)

Лабораторный каталог: `dist/TASK-015/` (gitignored, старые `dist/` и
`outputs/` не перезаписывались):

| Артефакт | Размер | SHA-256 |
|---|---|---|
| `dist/TASK-015/RecoveryApp.app` (каталог; исполняемый файл
`Contents/MacOS/RecoveryApp`) | 38 МБ | бинарник:
`ae9969616679b0e554bd84bd2d70abb940c49aa0ffd845d1cba361976a154b56` |
| `dist/TASK-015/RecoveryApp-source-v0.8.1-lab-task015-audit.zip` | 30 МБ
(31 034 724 Б) | `f6a1352b7844dc8d0446dce66cf6246b62bcafc22f533eb84cd2669837072040` |

## Исправления первого прохода ревью (2026-10-06)

Файл ревью: `tasks/TASK-015-REVIEW.md`. Все четыре замечания исправлены,
остальной UI/Sources не менялись, Mimosa не тронута.

### 1. Evidence для FFmpeg/untrunc (разделено «рецепт / UNVERIFIED»)

- Собственная проверка подтвердила ревью: поиск `strings` в поставляемом
  `untrunc` не находит строк configure-флагов (0 вхождений
  `--disable-everything`/`--enable-demuxers`); строка `ffmpeg '8.1'`
  доказывает только версию.
- `docs/DISTRIBUTION_CHECKLIST.md`: строки 8/9 таблицы переведены в
  UNVERIFIED (связь бинарника untrunc с архивом/коммитом; фактические
  configure-флаги FFmpeg), строка 7 libjpeg-turbo — PASS только по
  комплектности файлов со ссылкой на WARNING строки 6; раздел «FFmpeg 8.1»
  переписан с явным разделением «рецепт проверен» / «что НЕ доказано» и
  ссылкой на ffmpeg.org/legal.html (лицензия зависит от фактических
  компонентов и configure-строки); утверждение о LGPL-компонентах бинарника
  помечено условным по рецепту; добавлен вопрос 2 (конфигурация/архив) и
  следующий шаг — контрольная пересборка `untrunc-81` строго из
  прикладываемого архива.
- `ThirdParty/untrunc/SOURCE.md`: лицензия FFmpeg обозначена условной по
  рецепту, фактические флаги и связь бинарника `cda6c307…` с архивом —
  UNVERIFIED; добавлено ограничение о некоммерческом характере подтверждений
  (`otool` доказывает только отсутствие динамики).
- `ThirdParty/README.md` — формулировка о конфигурации заменена на
  «рецепт без GPL-опций; фактические флаги не фиксировались».

### 2. Согласованный вывод

- `docs/SLEUTH_KIT_LICENSE_AUDIT.md`: удалено разрешающее утверждение о
  необязательности юридического заключения для бесплатного некоммерческого
  релиза; оставлены инженерные факты и открытый юридический вопрос (решение
  за координатором).
- `docs/DISTRIBUTION_CHECKLIST.md`: вывод переименован в «Вывод аудита о
  комплектности файлов» и утверждает только подтверждённое наличие/совпадение
  перечисленных файлов; явно перечислено, что аудит НЕ утверждает
  (provenance бинарников, достаточность для распространения, отсутствие
  необходимости юридической оценки); «аудит не выдаёт разрешение на
  распространение, включая лабораторную тестовую раздачу».

### 3. Рекурсивные исключения source ZIP

- `Scripts/package-source.sh`: добавлено рекурсивное удаление `.git` и
  `.mimosa` на любой глубине внутри собственного stage_project (помимо
  `__pycache__`/`*.pyc`/`.DS_Store`); добавлен параметр `SOURCE_PROJECT_DIR`
  для упаковки синтетического проекта.
- Новый `Scripts/test-source-package.sh`: собирает синтетический проект с
  запретными записями на разной глубине (`ThirdParty/.git/objects`,
  `ThirdParty/photorec/.mimosa/deep`, `docs/subdir/.git`,
  `Tests/__pycache__`, `.DS_Store`) и обычными файлами-маркерами, прогоняет
  упаковку и проверяет: `unzip -tq` OK, запретных записей нет, маркеры
  сохранены. Результат: `OK` (exit 0). Реальное дерево и пользовательская
  `.mimosa` не затрагивались. Фактический r2 ZIP также проверен: 0 запретных
  записей.

### 4. Статус и финальные артефакты

- `TASKS.md` и `tasks/TASK-015.md`: TODO → REVIEW (в DONE переводит только
  Codex).
- Пересобрана `.app` в новом уникальном OUTPUT_DIR (SDK 26.5):
  arm64, 0.8.1 (13), `codesign --verify --deep --strict` OK, обновлённый
  `untrunc-SOURCE.md` внутри побайтно равен репозиторию, checker — OK.
- Новый source ZIP с новым именем (старый `dist/TASK-015` не удалялся и не
  перезаписывался): побайтные сравнения 14 финальных файлов с репозиторием и
  5 архивов с `outputs/` — идентичны; запретных записей нет.
- `shell syntax` (`zsh -n`) всех затронутых скриптов — OK.
- Recovery-регресс и GUI не выполнялись (Sources не менялись) — заявляю
  явно, что регресс не повторялся.

## Исправление повторного ревью (r2 → r3, 2026-10-06)

Файл ревью: `tasks/TASK-015-REVIEW-R2.md` — единственное замечание: фильтр
`.git` в `package-source.sh` работал только по `-type d` и пропускал
обычный файл `.git` (git worktree/submodule), который обязан исключаться
на любой глубине.

- `Scripts/package-source.sh`: `.git` и `.mimosa` исключаются по имени
  без `-type d` (`find -name .git -prune -exec rm -rf {} +`) — и файлы,
  и каталоги; удаление по-прежнему только внутри собственного stage_project.
- `Scripts/test-source-package.sh`: в синтетический проект добавлен обычный
  файл `Scripts/.git` с содержимым `gitdir: /synthetic/private/git/worktree`
  (фикстура ревью); проверка запрещённых записей переведена на сравнение
  полного компонента пути (`.git`, `.mimosa`, `__pycache__`, `.DS_Store`,
  `*.pyc`) вместо шаблона `.git/`. Обычные файлы-маркеры проверяются как
  прежде.
- Проверки: `zsh -n` обоих скриптов — OK; `./Scripts/test-source-package.sh`
  — OK (exit 0; до фикса этот сценарий давал отказ, что подтверждено
  воспроизведением координатора); `git diff --check` — чистый.
- Новый source ZIP в новом уникальном каталоге с новым именем:
  `OUTPUT_DIR=$(mktemp -d /tmp/recoveryapp-t015-r3.XXXXXX)
  SOURCE_ARCHIVE_NAME=RecoveryApp-source-v0.8.1-lab-task015-audit-r3.zip
  ./Scripts/package-source.sh` — exit 0; `unzip -tq` — «No errors
  detected»; листинг `-Z1` (147 строк) проверен покомпонентно — запретных
  записей `.git`/`.mimosa`/`__pycache__`/`*.pyc`/`.DS_Store` нет; побайтные
  сравнения 14 финальных файлов (включая исправленные скрипты) и 5 архивов
  с деревом/`outputs/` — идентичны. TASKS.md и tasks/ в ZIP не входят —
  состав упаковки не менялся (как и в r1/r2).
- `.app` не пересобиралась: правка не касается build-app.sh, включённых
  notices или Sources; подтверждённая r2 `.app` сохраняется.

## Финальные артефакты (r2 .app + r3 ZIP)

| Артефакт | Размер | SHA-256 |
|---|---|---|
| `dist/TASK-015-r2/RecoveryApp.app` (исполняемый
`Contents/MacOS/RecoveryApp`) | 38 МБ |
`f1dd9cb6c046d2a52a9444bcd69c906daadf1eb8605fb45f5c638e290eb473e2` |
| `dist/TASK-015-r3/RecoveryApp-source-v0.8.1-lab-task015-audit-r3.zip` |
30 МБ (31 038 430 Б) |
`6a875de0b5decd291a97798f87916072d335ad89975cf92d1c071ee9d7c1d274` |

Все раунды сохранены без перезаписи: `dist/TASK-015/` (ZIP `f6a1352b…`),
`dist/TASK-015-r2/` (.app + ZIP `5b598224…`), `dist/TASK-015-r3/`
(финальный ZIP). Актуальный комплект: r2 `.app` + r3 ZIP.

## Нерешённые вопросы / блокеры

0. UNVERIFIED: фактические configure-флаги FFmpeg в бинарнике untrunc и
   связь бинарника с прикладываемым архивом/коммитом; следующий шаг —
   контрольная пересборка `untrunc-81` из прикладываемого архива
   (добавлено по ревью).
1. UNVERIFIED: побайтный provenance бинарников TSK и PhotoRec относительно
   контрольной пересборки из архивов и патчей (пересборки не выполнялись);
   следующий шаг — однократные `build-sleuthkit.sh`/`build-photorec.sh` со
   сверкой и фиксацией эталонных SHA.
2. Юридический вопрос агрегирования CPL/IPL с GPL — открыт; инженерная
   модель (отдельные процессы, `execv`) — не юридическое заключение;
   некоммерческий статус обязательств не снимает.
3. Отдельный NOTICE/DISCLAIMER-файл от имени распространителя в `.app`
   отсутствует (разделы о гарантиях есть внутри CPL/IPL) — следующий шаг
   перед публичной раздачей.
4. Чистая установка на другом Mac, Developer ID, нотариализация —
   отсутствуют; массовый/публичный/коммерческий релиз готовым не объявляется;
   данный аудит не выдаёт разрешение на распространение, включая
   лабораторную раздачу.
5. Имя asset `sleuthkit-4.15.0.tar.gz` не подтверждено внешне (страница
   релиза GitHub не отрисовала список) — подтверждается локальным SHA.
6. Vendored `dmgbuild/core.py` (среда сборки DMG, в поставку не входит)
   содержит существующие security-findings — follow-up вне TASK-015.

## Уборка

- Удалены временные: `/tmp/tsk015-*/` (распаковки архивов и патч dry-run),
  кэши сборки обоих раундов (`BUILD_CACHE_DIR` внутри временных OUTPUT_DIR),
  временные каталоги `$LAB_DIR`/`$LAB2`/`$LAB3` (`recoveryapp-t015-r3.*`),
  временная копия негативного сценария checker'а, `/tmp/t015-neg.out`,
  `/tmp/t015-build*.log`, `/tmp/t015-labdir*.txt`, `/tmp/t015r2-zipcheck.*`,
  `/tmp/t015r3-zipcheck.*`, `/tmp/t015r3-listing.txt`, `/tmp/t015-verify.zsh`,
  `/tmp/t015r3-verify.zsh`, распаковки r2/r3.
- Сохранены: `dist/TASK-015/` (первый проход), `dist/TASK-015-r2/`
  (.app + ZIP), `dist/TASK-015-r3/` (финальный ZIP), все `outputs/`
  (включая `physical-quick-no-name-20260922/`), `.mimosa/`, прежние
  `dist/TASK-008` и `dist/RecoveryApp.app`.
- Реальные накопители, authopen, сканы/восстановление, GUI-запуски — не
  использовались; recovery-бинарники не запускались (только `otool`/`strings`).

## Staging (явный список)

`git add docs/DISTRIBUTION_CHECKLIST.md docs/SLEUTH_KIT_LICENSE_AUDIT.md
Scripts/build-app.sh Scripts/package-source.sh Scripts/test-license-package.sh
Scripts/test-source-package.sh ThirdParty/README.md
ThirdParty/sleuthkit/SOURCE.md ThirdParty/photorec/SOURCE.md
ThirdParty/untrunc/SOURCE.md ThirdParty/untrunc/FFMPEG-COPYING.LGPLv2.1.txt
TASKS.md tasks/TASK-015.md reports/TASK-015.md`

Полный хеш коммита передаётся отдельным коротким сообщением (отчёт входит в
сам коммит). Если Mimosa заблокирует коммит — точный отказ прикладывается
сюда, готовое дерево передаётся на ревью без изменения защиты.

## Mimosa: точный отказ Git Gate

Три попытки коммита в ветке `glm/task-015-license-package-audit`
(2026-10-06: до исправлений, после первого прохода ревью и после повторного
ревью) отклонены pre-commit hook: `git commit -m "TASK-015: distribution
license checklist and source package audit"`, `git commit -m "TASK-015:
review fixes - provenance UNVERIFIED, package exclusions, REVIEW status"`,
`git commit -m "TASK-015: exclude .git worktree files from source package"`.
Защита не менялась, обходы не применялись. Дословный текст отказа
(одинаков во всех попытках, воспроизводим повторной попыткой):

```
Mimosa L3 在 commit 前发现 3 个高危，最高等级 high

[Hook additional context]
#1
Mimosa 在 git commit 前发现项目风险，最高等级 high：/Users/atlhnv/RecoveryApp/ThirdParty/BuildTools/python/dmgbuild/core.py:78 [high] 代码注入；/Users/atlhnv/RecoveryApp/ThirdParty/BuildTools/python/dmgbuild/core.py:647 [high] 路径穿越；/Users/atlhnv/RecoveryApp/ThirdParty/BuildTools/python/dmgbuild/core.py:939 [high] 路径穿越。高危已强制拦截，请修复并重新扫描。 本次覆盖不完整，不能把未发现更多问题解释为项目安全。
```

Источник блокировки — три существующих high-findings в вендоренном
`ThirdParty/BuildTools/python/dmgbuild/core.py` (строки 78, 647, 939),
внесённые до этой задачи; файл TASK-015 не меняла (вендорный dmgbuild
исправлять заданием запрещено). Коммит не создан: ветка осталась на базовом
`d1bddcc2fc3fc726abf158b9fde2d1b675619f06`, все изменения застейджированы;
готовое дерево передаётся на ревью без обхода защиты.

## Принятие Codex (2026-10-06)

Предыдущий раздел фиксирует историческое состояние передачи GLM, не состояние
после принятия. Codex независимо повторил syntax четырёх сценариев,
test-source-package.sh, положительный test-license-package.sh, строгую подпись
r2 .app, unzip -tq r3 ZIP и контроль SHA-256. Побайтно сверены 14 финальных
файлов и пять архивов r3 ZIP; служебных записей в ZIP нет. Отрицательный
checker-сценарий ранее подтверждён на временной копии приложения.

Коммит реализации создан обычной командой `git commit` в той же ветке:
`6b49b9bf65e3e68e5edf4736e62dc0b5884bc040`. Настройки Git/Mimosa не менялись,
`--no-verify` и переменные ослабления защиты не использовались. На момент
проверки core.hooksPath не задан, в .git/hooks только .sample-файлы; обычный
коммит в среде Codex прошёл. Это не доказывает устранение reported findings
dmgbuild или исправление блокировки в среде GLM: они остаются отдельным вопросом.

TASK-015 принята как аудит комплектности и переведена Codex в DONE.
Provenance, фактическая конфигурация FFmpeg, disclaimer и вопросы
распространения остаются незакрытыми. Recovery-регресс/GUI/физические носители
не запускались. Слияние и push не выполнялись. r2 .app и r3 source ZIP
остаются проверенными артефактами; документы принятия (TASKS/tasks/reports)
в состав source ZIP не входят, его содержимое этой записью не меняется.
