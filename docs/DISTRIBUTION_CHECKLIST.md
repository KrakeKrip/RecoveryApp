# Комплектностный чеклист лабораторной поставки (TASK-015)

Дата аудита: 2026-10-06. Ветка: `glm/task-015-license-package-audit`.
Это инженерная проверка комплектности поставки, а не юридическое заключение и
не разрешение на публичный или коммерческий релиз. Тексты условий лицензий
приводятся только по их официальным полным версиям; инженерная интерпретация
отделена от нерешённых юридических вопросов (см. «Оставшиеся вопросы»).

Методология: версии подтверждены metadata сборки (`Packaging/Info.plist`,
`SOURCE.md`, recipes `Scripts/build-*.sh`), статическим разбором бинарников
(`otool -L`, `strings` — recovery-бинарники не запускались), сверкой SHA-256
исходных архивов с записями и с внешними источниками, побайтным сравнением
(`cmp`) включённых лицензий с файлами исходных архивов, dry-run патча на
чистых исходниках. Внешние проверки выполнены 2026-10-06 по официальным
сайтам (ссылки ниже).

## Сводная таблица компонентов

| # | Компонент | Роль | Версия (evidence) | Лицензия | Notices в .app | Исходники в .app | Статус |
|---|---|---|---|---|---|---|---|
| 1 | RecoveryApp + RecoveryCore (GUI, статическая библиотека) | основной исполняемый файл `Contents/MacOS/RecoveryApp` | 0.8.1 (13), `Packaging/Info.plist` | GPL-2 (`LICENSE`) | `Resources/LICENSE` (добавлено в TASK-015) | `Sources/` в source ZIP | PASS |
| 2 | `tool-launcher`, `recoveryapp-readonly-helper`, `recoveryapp-metadata-helper` | собственные C-процессы (`execv`, read-only, проверка размера) | собираются `build-app.sh` из `Packaging/*.c` | GPL-2 (`LICENSE`) | `Resources/LICENSE` | `Packaging/*.c` в source ZIP | PASS |
| 3 | `recoveryapp-cli` | CLI для тестов/автоматизации; в `.app` НЕ входит | общий `RecoveryCore` | GPL-2 | — (не поставляется в `.app`) | `Sources/` в source ZIP | PASS |
| 4 | Sleuth Kit 4.15.0 — `fls`, `mmls` | отдельные CLI-процессы (быстрый поиск/извлечение), запуск через `tool-launcher` (`execv`), без линковки libtsk | 4.15.0: `SOURCE.md`; релиз GitHub `sleuthkit-4.15.0` существует | CPL 1.0 + mixed (см. `LICENSES-README.md`) | `sleuthkit-CPL-1.0.txt`, `sleuthkit-LICENSES-README.md`, `sleuthkit-SOURCE.md` | `SourceArchives/sleuthkit-4.15.0-source.tar.gz` + `sleuthkit-preopened-fd.patch` | WARNING (provenance бинарников) |
| 5 | Sleuth Kit 4.15.0 — `icat` | отдельный CLI-процесс (извлечение) | как выше | IBM Public License 1.0 + mixed | `sleuthkit-IPL-1.0.txt` | как выше | WARNING (provenance бинарников) |
| 6 | PhotoRec 7.2 | отдельный CLI-процесс (глубокий сигнатурный поиск) | 7.2: `AC_INIT([testdisk],[7.2])` в архиве; cgsecurity.org подтверждает 7.2 (2024-02-22) | GPL v2 or later (`photorec-COPYING.txt`) | `photorec-COPYING.txt`, `photorec-SOURCE.md` | `SourceArchives/testdisk-7.2-source.tar.bz2` + `photorec-dev-fd.patch` (добавлено в TASK-015) | WARNING (provenance бинарника) |
| 7 | libjpeg-turbo 3.2.0 | статически внутри `photorec` | 3.2.0: строка в бинарнике; релиз GitHub подтверждён | BSD-3-clause + IJG | `libjpeg-turbo-LICENSE.md`, `libjpeg-IJG-README.txt` (побайтно из архива) | `SourceArchives/libjpeg-turbo-3.2.0-source.tar.gz` | PASS (комплектность файлов); фактическая статическая связь с бинарником photorec — в рамках WARNING строки 6 |
| 8 | untrunc | отдельный CLI-процесс (исправление видео) | коммит `9d86ec9ef2ff…` подтверждён на GitHub; в бинарнике строка `v1-9d86ec9` (версия, не конфигурация) | GPL-2 (`untrunc-COPYING.txt`) | `untrunc-COPYING.txt`, `untrunc-SOURCE.md` | `SourceArchives/untrunc-9d86ec9-source.tar.gz` | UNVERIFIED (связь бинарника с архивом/коммитом) |
| 9 | FFmpeg 8.1 | статически внутри `untrunc` (`libavformat`, `libavcodec`, `libavutil`) | 8.1: строка в бинарнике `ffmpeg '8.1'`; ffmpeg.org подтверждает ветку 8.1 | LGPL-2.1-or-later — условно по рецепту; фактическая конфигурация бинарника не доказана | `ffmpeg-COPYING.LGPLv2.1.txt` (добавлено в TASK-015) | `SourceArchives/ffmpeg-8.1-source.tar.xz` + рецепт в Makefile архива untrunc | UNVERIFIED (фактические configure-флаги бинарника) |
| 10 | dmgbuild 1.6.7, ds_store 1.3.3, mac_alias 2.2.3 (Python) | только среда сборки DMG (`Scripts/package-dmg.sh`); в `.app` и DMG не попадают | `ThirdParty/BuildTools/README.md`; лицензии `ThirdParty/BuildTools/licenses/` | MIT | — (не поставляются) | попадают в source ZIP через `ThirdParty/BuildTools` (без `__pycache__`) | PASS (build-tool) |
| 11 | системные библиотеки macOS (`libz`, `libsqlite3`, `libncurses.5.4`, `libiconv`, `libc++`, `libSystem`) | динамические зависимости поставляемых CLI | `otool -L` | предоставляются macOS | поставка не требуется | поставка не требуется | PASS (N/A) |

## Контрольные суммы (фактические, 2026-10-06)

### Исходные архивы (`outputs/` → `.app/Contents/Resources/SourceArchives/`)

| Архив | SHA-256 | Совпадение с записью |
|---|---|---|
| `sleuthkit-4.15.0-source.tar.gz` | `3a8c1e7d18a9b81f3e5e8aa78313974aceaafc6e051d636bc92cd7168286eca9` | да (`ThirdParty/sleuthkit/SOURCE.md`) |
| `testdisk-7.2-source.tar.bz2` | `f8343be20cb4001c5d91a2e3bcd918398f00ae6d8310894a5a9f2feb813c283f` | да (`ThirdParty/photorec/SOURCE.md`) |
| `libjpeg-turbo-3.2.0-source.tar.gz` | `6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e` | да (`ThirdParty/photorec/SOURCE.md`) |
| `untrunc-9d86ec9-source.tar.gz` | `a46bbb0013b274cd239b0fe037cdf175e6865d62119e78f6f8d8684efbeaa8dc` | запись добавлена в TASK-015 |
| `ffmpeg-8.1-source.tar.xz` | `b072aed6871998cce9b36e7774033105ca29e33632be5b6347f3206898e0756a` | да (`ThirdParty/untrunc/SOURCE.md`) |

### Патчи и лицензионные тексты

| Файл | SHA-256 |
|---|---|
| `Packaging/sleuthkit-preopened-fd.patch` | `259dfdb6e63c8868f5ff4ae2a5ae855d9c441d8c835d5f265317654418b461ff` |
| `Packaging/photorec-dev-fd.patch` | `23f884cec48f10d43ed0d2c8ec011f29243819a5fa6294ab0da87e78e842d72b` |
| `ThirdParty/untrunc/FFMPEG-COPYING.LGPLv2.1.txt` (из архива FFmpeg 8.1 без изменений) | `246041b6ecf9bc32d718a62c57877c78b5eb397b6467e74ed7ae2626ab189c30` |
| `LICENSE` (GPL-2, RecoveryApp) | `d9310978058cc0def11befd94c85e484350322c746ed4dec3f3e03b04e60d295` |

### Поставляемые бинарники (`ThirdParty/*/bin/arm64/`)

| Бинарник | SHA-256 (фактический) | Совпадение с записью |
|---|---|---|
| `sleuthkit/fls` | `57c0c9ecf8f2dc4aed9ae6582b63bb00a38e5f457f3a2e1b0cb71e42278e8d26` | запись обновлена в TASK-015 |
| `sleuthkit/icat` | `af59a7f431007bf9753c9089cee89de67f15db146626245bc8e66f854afe5db9` | запись обновлена в TASK-015 |
| `sleuthkit/mmls` | `17968b5e06ec5bda56e762f0a929e499f6fb5d8d119bba7edfc99639a6a817b4` | запись обновлена в TASK-015 |
| `photorec/photorec` | `32479bc9d1aa32afe074a584651e637474a9ef4cd76e9610f7c255b353f5f70d` | запись обновлена в TASK-015 |
| `untrunc/untrunc` | `cda6c307caed260f6840aefdd4f7516a6003f85dbd3e9e27d9a3d40c2645b853` | да (`ThirdParty/untrunc/SOURCE.md`) |

## sleuthkit-4.15.0-source.tar.gz: сверка чеклиста пункт за пунктом

- Самостоятельные CLI: `fls`, `icat`, `mmls` — отдельные arm64 Mach-O
  (`otool -L`: только системные `libz`, `libsqlite3`, `libSystem`, `libc++`).
  PASS.
- Прямая линковка libtsk в RecoveryApp: отсутствует. `otool -L` исполняемого
  файла `RecoveryApp` не содержит libtsk (проверено на собранной `.app`);
  `build-sleuthkit.sh` собирает libtsk статически только внутри этих CLI;
  Swift-таргеты не получают ни заголовков, ни объектов TSK (состав команд
  `swiftc` в `Scripts/build-app.sh`/`Scripts/test.sh`). Отсутствие динамики
  само по себе не доказывает отсутствие статики — поэтому проверены и входы
  сборки. PASS.
- Полные CPL 1.0 / IPL 1.0 / обзор лицензий: `CPL-1.0.txt`,
  `IBM-PUBLIC-LICENSE-1.0.txt`, `LICENSES-README.md` в
  `ThirdParty/sleuthkit/` побайтно совпадают с `licenses/cpl1.0.txt`,
  `licenses/IBM-LICENSE`, `licenses/README.md` исходного архива (`cmp`). PASS.
- IBM copyright-строка: сохранена в `LICENSES-README.md`
  («Copyright (c) 1997,1998,1999, International Business Machines…»). PASS.
- Disclaimer-формулировки (гарантии/ответственность upstream): обязательство
  распространителя указано в этом документе и в пункте 2 выше; отдельного
  файла-дисклеймера в `.app` нет — тексты лицензий CPL/IPL содержат
  соответствующие разделы 5/6/7. WARNING (см. «Оставшиеся вопросы»).
- Точный исходный архив: `sleuthkit-4.15.0-source.tar.gz`, SHA-256 совпадает
  с записью; релиз `sleuthkit-4.15.0` на GitHub существует (проверено
  2026-10-06, список из 6 assets недоступен для чтения — имя конкретного
  asset подтверждением не считается). PASS с оговоркой.
- Патч `Packaging/sleuthkit-preopened-fd.patch` (SHA выше): изменённые файлы —
  `tsk/img/raw.c`, `tsk/util/file_system_utils.h`,
  `tsk/util/file_system_utils.c`; изменения — `raw_open_readonly()` с `dup()`
  унаследованного дескриптора для `/dev/fd/N` и явный `lseek` перед первым
  чтением. `patch -d <source> -p1 --dry-run` на чистом архиве 4.15.0 —
  применяется без отклонений (проверено 2026-10-06). Рецепт однократного
  применения: `Scripts/build-sleuthkit.sh` (распаковка архива,
  `patch -p1`, configure-флаги `--disable-java --disable-shared
  --enable-static --without-afflib --without-libewf --without-libvhdi
  --without-libvmdk`). Патч включён в `.app` (SourceArchives) и в source ZIP.
  PASS.
- Бинарники собраны из изменённых источников — модификация не скрыта:
  явно указана в `sleuthkit-SOURCE.md` в `.app` и в этом документе. PASS.

## FFmpeg 8.1: рецепт проверен, фактическая конфигурация бинарника UNVERIFIED

Что проверено (рецепт):
- Цель `untrunc-81` в `Makefile` архива `untrunc-9d86ec9-source.tar.gz`
  задаёт `FF_CONFIG_FLAGS`: `--disable-doc --disable-everything
  --enable-decoders --disable-vdpau --enable-demuxers --enable-protocol=file
  --disable-avdevice --disable-swresample --disable-swscale
  --disable-avfilter --disable-xlib --disable-vaapi --disable-zlib
  --disable-bzlib --disable-lzma --disable-audiotoolbox
  --disable-videotoolbox`. Опции `--enable-gpl`, `--enable-nonfree` и GPL-
  библиотеки (x264 и т.п.) в рецепте не включены — то есть РЕЦЕПТ
  соответствует конфигурации LGPL-2.1-or-later. Архив FFmpeg 8.1 и рецепт
  включены в поставку; по `https://ffmpeg.org/legal.html` лицензия
  распространяемых компонентов FFmpeg зависит от фактических используемых
  компонентов и configure-строки — checklist обязан описывать configure
  line: он описан выше как рецепт.

Что НЕ доказано (UNVERIFIED):
- Фактические configure-флаги, с которыми собран поставляемый бинарник
  `untrunc` (SHA-256 `cda6c307…`). В бинарнике нет build/config metadata:
  поиск `strings` не находит ни строки configure-флагов, ни иных отметок
  конфигурации; строка `ffmpeg '8.1'` доказывает версию, но не флаги.
- Связь бинарника именно с этим архивом и этим рецептом (побайтная
  воспроизводимость сборки не проверялась; сборка выполнялась из
  git-клона, а не из прикладываемого архива — см. ограничение идентичности
  архива коммиту ниже).
- Отсутствие динамических зависимостей (`otool -L`) доказывает только
  отсутствие динамики; статически включённые компоненты им не исключаются.

Следствие: утверждение «компоненты FFmpeg в поставляемом бинарнике —
LGPL-2.1-or-later» остаётся УСЛОВНЫМ по рецепту и не является установленным
фактом о бинарнике. Полный текст LGPL 2.1 включён без изменений
(`ffmpeg-COPYING.LGPLv2.1.txt` в `.app`; исходник — `COPYING.LGPLv2.1`
архива FFmpeg 8.1); архив содержит также COPYING.GPLv2/v3. Следующий шаг для
снятия UNVERIFIED: контрольная пересборка `untrunc-81` строго из
прикладываемого архива (или сборка с выводом configure-строки в
сопроводительный файл) и сверка с поставляемым бинарником.

Ограничение идентичности архива untrunc: побайтное совпадение
`untrunc-9d86ec9-source.tar.gz` с `git archive` коммита `9d86ec9` офлайн не
проверялось (локального клона нет); содержимое согласовано с рецептом сборки.

## Внешние проверки (официальные источники, дата 2026-10-06)

- FFmpeg: `https://ffmpeg.org/download.html` — ветка 8.1 существует; текущий
  релиз ветки 8.1.3 (2026-09-21). Поставляется ровно 8.1 (архив с SHA выше) —
  обновление до 8.1.3 не входило в задачу.
- Sleuth Kit: `https://github.com/sleuthkit/sleuthkit/releases/tag/sleuthkit-4.15.0`
  — релиз существует (апрель, автор bcarrier); список assets на странице не
  отрисовался, поэтому имя `sleuthkit-4.15.0.tar.gz` внешне не подтверждено.
- libjpeg-turbo: `https://github.com/libjpeg-turbo/libjpeg-turbo/releases/tag/3.2.0`
  — релиз существует, официальный tarball `libjpeg-turbo-3.2.0.tar.gz`.
- TestDisk & PhotoRec: `https://www.cgsecurity.org/wiki/TestDisk_Download` —
  7.2 (2024-02-22), source tarball `testdisk-7.2.tar.bz2`.
- untrunc: `https://github.com/anthwlock/untrunc` — репозиторий существует;
  коммит `9d86ec9ef2ffed1bf8131abe80742c0574db52b6` существует («hvc1: restore
  CRA seek points»).

## Оставшиеся вопросы и блокеры

1. **Побайтный provenance бинарников TSK и PhotoRec — UNVERIFIED.** Записанные
   ранее SHA-256 устарели (бинарники пересобраны/переподписаны 2026-09-14 и
   2026-09-18; записи обновлены в TASK-015). Контрольные пересборки из
   архивов и патчей в TASK-015 не выполнялись (признаны избыточными для
   комплектностного аудита). Следующий шаг: однократная контрольная
   пересборка `Scripts/build-sleuthkit.sh` и `Scripts/build-photorec.sh`,
   функциональная сверка и фиксация новых SHA как эталонных.
2. **Фактическая конфигурация FFmpeg в бинарнике untrunc и связь бинарника с
   архивом/коммитом — UNVERIFIED.** Рецепт (`FF_CONFIG_FLAGS` в Makefile
   архива) соответствует LGPL-конфигурации, но не доказывает флаги
   фактической сборки: в бинарнике нет build/config metadata (строки
   configure-флагов отсутствуют), версия доказывает только версию. Следующий
   шаг: контрольная пересборка `untrunc-81` строго из прикладываемого архива
   (или сборка с записью configure-строки в сопроводительный файл) и сверка.
   Ограничение: побайтная идентичность `untrunc-9d86ec9-source.tar.gz`
   коммиту `9d86ec9` офлайн не проверялась.
3. **Агрегирование CPL/IPL-программ с GPL-приложением — открытый юридический
   вопрос.** Инженерная модель «отдельные процессы, `execv`, без общих
   структур» соответствует аргументации GNU GPL FAQ о separate programs, но
   это не юридическое заключение; некоммерческий статус не снимает
   обязательств и не считается ответом на вопрос.
4. **Disclaimer от имени распространителя** (пункт 2 obligations) не оформлен
   отдельным файлом в `.app`; тексты CPL/IPL содержат собственные разделы об
   отсутствии гарантий. Следующий шаг: отдельный NOTICE/DISCLAIMER-файл
   перед публичной раздачей.
5. **Чистая установка на другом Mac, Developer ID и нотариализация**
   отсутствуют; массовый, публичный или коммерческий релиз не готов.
6. **Vendored `dmgbuild/core.py`** (ThirdParty/BuildTools, только среда
   сборки DMG) содержит существующие security-findings сканера — вне рамок
   TASK-015; отдельный follow-up для Codex (в .app и DMG не попадает).
7. Asset-лист релиза sleuthkit-4.15.0 на GitHub не прочитан (страница не
   отрисовала имена) — имя архива подтверждается локальным SHA и записью в
   SOURCE.md.

## Вывод аудита о комплектности файлов

Что подтверждено этим аудитом (побайтные сравнения и SHA-256, дата
2026-10-06): собранный комплект `.app` и source ZIP **содержит** перечисленные
в таблице файлы — полные тексты применимых лицензий (включая добавленные в
TASK-015 `LICENSE` RecoveryApp и LGPL-2.1 для FFmpeg), уведомления, точные
исходные архивы пяти компонентов и оба патча; включённые копии побайтно
совпадают с исходниками репозитория и архивами.

Что этот аудит НЕ утверждает:

- соответствие поставляемых бинарников приложенным исходникам/рецептам —
  provenance TSK, PhotoRec, untrunc и фактические configure-флаги FFmpeg
  остаются UNVERIFIED (вопросы 1–2);
- комплектность как достаточность для распространения: этот аудит не выдаёт
  разрешение на распространение, включая лабораторную тестовую раздачу;
  решение о раздаче и закрытии открытых вопросов (вопросы 2–5) — за
  координатором;
- отсутствие необходимости юридической оценки по вопросам 2–3.

Статус UNVERIFIED — честный итог аудита в его границах; для его снятия
перечислены конкретные следующие шаги.
