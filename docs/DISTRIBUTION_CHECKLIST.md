# Комплектностный чеклист лабораторной поставки (TASK-015)

Исходный аудит: 2026-10-06 (TASK-015). Повторная проверка: 2026-10-07.
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
| 4 | Sleuth Kit 4.15.0 — `fls`, `mmls` | отдельные CLI-процессы (быстрый поиск/извлечение), запуск через `tool-launcher` (`execv`), без линковки libtsk | 4.15.0: `SOURCE.md`; релиз GitHub `sleuthkit-4.15.0` существует | CPL 1.0 + mixed (см. `LICENSES-README.md`) | `sleuthkit-CPL-1.0.txt`, `sleuthkit-LICENSES-README.md`, `sleuthkit-SOURCE.md` | `SourceArchives/sleuthkit-4.15.0-source.tar.gz` + `sleuthkit-preopened-fd.patch` | PASS — provenance доказан контрольной пересборкой TASK-016 (побайтное совпадение) |
| 5 | Sleuth Kit 4.15.0 — `icat` | отдельный CLI-процесс (извлечение) | как выше | IBM Public License 1.0 + mixed | `sleuthkit-IPL-1.0.txt` | как выше | PASS — provenance TASK-016 |
| 6 | PhotoRec 7.2 | отдельный CLI-процесс (глубокий сигнатурный поиск) | 7.2: `AC_INIT([testdisk],[7.2])` в архиве; cgsecurity.org подтверждает 7.2 (2024-02-22) | GPL v2 or later (`photorec-COPYING.txt`) | `photorec-COPYING.txt`, `photorec-SOURCE.md` | `SourceArchives/testdisk-7.2-source.tar.bz2` + `photorec-dev-fd.patch` | PASS — provenance доказан контрольной пересборкой TASK-016 (побайтное совпадение после подписи) |
| 7 | libjpeg-turbo 3.2.0 | статически внутри `photorec` | 3.2.0: строка в бинарнике; релиз GitHub подтверждён | BSD-3-clause + IJG | `libjpeg-turbo-LICENSE.md`, `libjpeg-IJG-README.txt` (побайтно из архива) | `SourceArchives/libjpeg-turbo-3.2.0-source.tar.gz` | PASS (комплектность файлов); статическая связь подтверждена сборкой TASK-016 |
| 8 | untrunc | отдельный CLI-процесс (исправление видео) | `archive-9d86ec9` (TASK-016, строка в бинарнике); коммит `9d86ec9ef2ff…` подтверждён на GitHub; содержимое архива сверено с коммитом 2026-10-07 | GPL-2 (`untrunc-COPYING.txt`) | `untrunc-COPYING.txt`, `untrunc-SOURCE.md` | `SourceArchives/untrunc-9d86ec9-source.tar.gz` | PASS — provenance доказан контрольной сборкой TASK-016; содержимое архива сверено с коммитом 2026-10-07 |
| 9 | FFmpeg 8.1 | статически внутри `untrunc` (`libavformat`, `libavcodec`, `libavutil`) | 8.1: строка в бинарнике `ffmpeg '8.1'`; ffmpeg.org подтверждает ветку 8.1 | LGPL-2.1-or-later — подтверждено фактической конфигурацией сборки TASK-016 (`config.h`/`config.mak` в evidence: без GPL/nonfree, без внешних библиотек) | `ffmpeg-COPYING.LGPLv2.1.txt` | `SourceArchives/ffmpeg-8.1-source.tar.xz` + рецепт (Makefile + build-only патч) | PASS — фактическая конфигурация нового бинарника зафиксирована evidence |
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
| `Packaging/sleuthkit-preopened-fd.patch` | `f0867d74d9f0385ee47c3d42df4c1988d5c8c74c6e60cd14956d3ea258468594` |
| `Packaging/photorec-dev-fd.patch` | `47e3d5bc4c0dec549a0bb1723ac075d5c6dd02dbb3e1f5e9bf0bed245ae981d5` |
| `ThirdParty/untrunc/FFMPEG-COPYING.LGPLv2.1.txt` (из архива FFmpeg 8.1 без изменений) | `246041b6ecf9bc32d718a62c57877c78b5eb397b6467e74ed7ae2626ab189c30` |
| `LICENSE` (GPL-2, RecoveryApp) | `d9310978058cc0def11befd94c85e484350322c746ed4dec3f3e03b04e60d295` |

### Поставляемые бинарники (`ThirdParty/*/bin/arm64/`, после контрольной пересборки TASK-016)

| Бинарник | SHA-256 (ad-hoc подписан) | Совпадение с записью |
|---|---|---|
| `sleuthkit/fls` | `283ea6fa94d08f2e61e80ae3141642e8e81dd41db7b269890533589ab8080791` | да (`ThirdParty/BUILD-PROVENANCE.json`) |
| `sleuthkit/icat` | `a92a65f1bc52fdead9c22259689ea7602e870e12f83dc2fb01abc0fb466fb757` | да (`ThirdParty/BUILD-PROVENANCE.json`) |
| `sleuthkit/mmls` | `89e87e674eb66c0c655645e36d12a829910527c118434f4c4b1f4f76c7814341` | да (`ThirdParty/BUILD-PROVENANCE.json`) |
| `photorec/photorec` | `32479bc9d1aa32afe074a584651e637474a9ef4cd76e9610f7c255b353f5f70d` | да (`ThirdParty/BUILD-PROVENANCE.json`) |
| `untrunc/untrunc` | `32174ade355b61312640103717c65b6806708da1f590ee0982e5fb686999dc4e` | да (`ThirdParty/BUILD-PROVENANCE.json`) |

Контрольная пересборка TASK-016: TSK и PhotoRec воспроизведены побайтно
(две независимые сборки; ld-подпись arm64 детерминирована, PhotoRec — после
ad-hoc подписи); untrunc пересобран из прикладываемого архива без сети,
фактическая конфигурация FFmpeg зафиксирована evidence. Прежние бинарники
(TASK-015: fls `57c0c9ec…`, icat `af59a7f4…`, mmls `17968b5e…`, untrunc
`cda6c307…`) сохранены в `dist/TASK-016-baseline-binaries/baseline/`; для
них provenance не заявляется. Машинный манифест:
`ThirdParty/BUILD-PROVENANCE.json`, человекочитаемая цепочка:
`docs/TOOLCHAIN_PROVENANCE.md`.

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
- Уведомления о гарантиях/ответственности upstream, авторстве изменений
  и исходниках теперь включены в `Contents/Resources/THIRD-PARTY-NOTICES.txt`;
  исходные тексты лицензий не изменялись.
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

## FFmpeg 8.1: фактическая конфигурация зафиксирована контрольной сборкой TASK-016

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

Обновление TASK-016 с исправлением Codex: поставляемый бинарник untrunc (`32174ade…`, строка
версии `archive-9d86ec9`) пересобран из прикладываемого архива hardened
сценарием; фактическая конфигурация FFmpeg этой сборки зафиксирована
evidence — `config.h` и `ffbuild/config.mak` в
`docs/build-evidence/TASK-016/`: `CONFIG_GPL`/`CONFIG_NONFREE` не
установлены, внешние библиотеки не включены. Утверждение «компоненты
FFmpeg в действующем бинарнике — LGPL-2.1-or-later» теперь опирается на
зафиксированную конфигурацию, а не только на рецепт. Побайтная
воспроизводимость untrunc не заявляется; прежний бинарник (`cda6c307…`,
собран из git-клона) сохранён в baseline и для него provenance не
заявляется. Полный текст LGPL 2.1 включён без изменений
(`ffmpeg-COPYING.LGPLv2.1.txt` в `.app`; исходник — `COPYING.LGPLv2.1`
архива FFmpeg 8.1); архив содержит также COPYING.GPLv2/v3. Codex 2026-10-07
явно отключил autodetect и SDL2; generated configuration проверяется guard.
Первоначальная сборка GLM обнаруживала SDL2 и системные интеграции, её summary
был ошибочным. Действующая сборка их не обнаруживает; все evidence/рецепты
теперь проверяются по SHA. Независимо остаётся ограничение идентичности
исходного архива git-коммиту, описанное ниже.

Проверка идентичности untrunc 2026-10-07: содержимое всех 53 файлов архива
совпадает с официальным codeload-снимком коммита
`9d86ec9ef2ffed1bf8131abe80742c0574db52b6`: пути и SHA-256 каждого файла
одинаковы. Префиксы/метаданные tar.gz не являются исходным кодом.

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

## Повторная оценка условий поставки — 2026-10-07

1. Provenance всех пяти инструментов подтверждён. Контрольные сборки после
   добавления датированных комментариев дали те же бинарники до подписи,
   что сборки TASK-016; после той же ad-hoc подписи все пять файлов также
   побайтно совпали с установленными. Манифест обновлён после этой проверки.
2. Патчи PhotoRec, untrunc и TSK добавляют уведомления об авторстве
   RecoveryApp project и дате 2026-10-07 в каждый изменённый файл.
   Функциональный код патчей не изменён; исходные copyright notices сохранены.
3. `Packaging/THIRD-PARTY-NOTICES.txt` включён в `.app`: IBM copyright,
   благодарность IJG, статическое использование FFmpeg, разделение лицензий,
   гарантии/ответственность Contributors, авторство патчей и доступ к исходникам.
   Лицензии требуют содержания уведомлений, а не имени файла DISCLAIMER.
4. Соответствующий ZIP исходников нужно прикладывать к ТОМУ ЖЕ релизу рядом
   с бинарниками. В нём есть полный код untrunc и FFmpeg плюс рецепты,
   позволяющие пересобрать и перелинковать статический executable с изменённой
   библиотекой (LGPL-2.1 §6(a)); динамическая линковка не единственный вариант.
5. Содержимое архива untrunc соответствует указанному коммиту. Требование
   двух побайтно одинаковых независимых сборок не заменяет условий лицензии
   и не объявляется обязательным для публикации.
6. По проверенным интерфейсам TSK (обычные CLI-аргументы, текст/байты,
   без линковки или общих внутренних структур) модель соответствует аргументам
   GNU GPL FAQ для отдельных программ. Это инженерная оценка, не судебная
   гарантия; отсутствие формального заключения юриста не объявляется само
   по себе блокером. При изменении интеграции повторить оценку.
7. Другой Mac, отсутствие Developer ID/нотариализации и findings dmgbuild —
   реальные ограничения установки/безопасности, а не лицензионные запреты.
   Публиковать можно рассматривать только как тестовый prerelease с оговорками,
   после проверки конкретного нового комплекта и решения владельца.

Источники условий: GPL v2 §2(a), §3; LGPL-2.1 §6; CPL/IPL §3;
https://www.gnu.org/licenses/gpl-faq.en.html#MereAggregation;
https://opensource.org/license/CPL-1.0;
https://opensource.org/license/ipl-1.0; https://ffmpeg.org/legal.html.

## История ограничений TASK-015/016 (не текущий список блокеров)

1. **Provenance TSK и PhotoRec — доказан контрольной пересборкой TASK-016.**
   Ранее (TASK-015) он был UNVERIFIED. Оба hardened-сценария проверяют
   SHA входов, применяют патч однократно и пишут toolchain-evidence;
   свежие сборки побайтно совпали с заменёнными бинарниками (TSK —
   детерминизм ld-подписи, подтверждён двумя независимыми сборками;
   PhotoRec — после ad-hoc подписи), записи манифеста зафиксированы как
   эталонные. Прежние бинарники сохранены в baseline-каталоге без заявлений
   об их происхождении.
2. **Конфигурация FFmpeg — зафиксирована контрольной сборкой TASK-016;
   связь архива untrunc с коммитом `9d86ec9` остаётся UNVERIFIED.**
   Действующий бинарник untrunc пересобран строго из прикладываемого архива
   (build-only патч запрещает сети), фактические `config.h`/`config.mak`
   сохранены в evidence и подтверждают LGPL-конфигурацию без GPL/nonfree и
   внешних библиотек. Побайтная идентичность архива коммиту офлайн не
   проверялась (нет локального клона); побайтная воспроизводимость untrunc
   не заявляется.
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
исходные архивы пяти компонентов и три патча; включённые копии побайтно
совпадают с исходниками репозитория и архивами.

Обновление TASK-016: все пять встроенных инструментов пересобраны из
прикладываемых источников; для действующих бинарников provenance доказан
цепочкой «архив + патч + конфигурация + toolchain → бинарник»
(`ThirdParty/BUILD-PROVENANCE.json`, `docs/TOOLCHAIN_PROVENANCE.md`);
манифест и evidence включены в комплект и проверяются
`Scripts/test-toolchain-provenance.sh`.

Что этот аудит НЕ утверждает (исторические формулировки уточнены 2026-10-07):

- юридическое заключение о любых лицензиях, патентах и юрисдикциях;
- готовность массового релиза или чистую установку на другом Mac;
- отсутствие security-проблем в vendored dmgbuild по факту создания DMG.

Общего запрета на комплект независимых программ не установлено; публикация
остается отдельным решением владельца, а соответствующий ZIP исходников и
уведомления должны сопровождать новый бинарный пакет.
