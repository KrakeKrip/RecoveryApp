# The Sleuth Kit 4.15.0 — лабораторный кандидат

- Проект: The Sleuth Kit
- Версия: 4.15.0, April 2026
- Исходный архив: `https://github.com/sleuthkit/sleuthkit/releases/download/sleuthkit-4.15.0/sleuthkit-4.15.0.tar.gz`
- SHA-256 архива: `3a8c1e7d18a9b81f3e5e8aa78313974aceaafc6e051d636bc92cd7168286eca9`
- Используемые кандидаты: отдельные CLI `fls`, `icat` и `mmls`.

Сборка arm64 выполнена с deployment target macOS 14, без Java, AFF, EWF, VHDI
и VMDK. Бинарники используют только системные `libz`, `libsqlite3`, `libSystem`
и `libc++` (проверено `otool -L`; статическая линковка libtsk в другие
исполняемые файлы отсутствует — libtsk собирается только для сборки этих CLI).

Для безопасной работы через уже авторизованный `/dev/fd/N` применён минимальный
патч `Packaging/sleuthkit-preopened-fd.patch`. Он затрагивает три файла исходного
кода: `tsk/img/raw.c` (чтение образа через `raw_open_readonly()` вместо прямого
`open()` и явный `lseek` перед первым чтением, потому что определение размера
может сдвинуть общий offset дублированного дескриптора),
`tsk/util/file_system_utils.h` (объявление) и `tsk/util/file_system_utils.c`
(функция `raw_open_readonly()`: для пути `/dev/fd/N` возвращается `dup()`
унаследованного уже прочитанного read-only дескриптора, обычные пути открываются
`open(..., O_RDONLY ...)`). Патч применяется однократно к чистому архиву 4.15.0
командой из `Scripts/build-sleuthkit.sh`
(`patch -d <source> -p1 < Packaging/sleuthkit-preopened-fd.patch`);
`patch --dry-run` на чистом архиве 4.15.0 проходит без отклонений
(проверено 2026-10-06). Иной функциональности патч не добавляет.

- SHA-256 `bin/arm64/fls`: `57c0c9ecf8f2dc4aed9ae6582b63bb00a38e5f457f3a2e1b0cb71e42278e8d26`
- SHA-256 `bin/arm64/icat`: `af59a7f431007bf9753c9089cee89de67f15db146626245bc8e66f854afe5db9`
- SHA-256 `bin/arm64/mmls`: `17968b5e06ec5bda56e762f0a929e499f6fb5d8d119bba7edfc99639a6a817b4`

Значения SHA-256 обновлены 2026-10-06 (TASK-015): бинарники пересобраны и
повторно ad-hoc подписаны 2026-09-18 после предыдущей записи, поэтому прежние
суммы устарели. Побайтное совпадение текущих бинарников с результатом
контрольной пересборки из архива и патча не проверялось (пересборка в TASK-015
не выполнялась) — см. `docs/DISTRIBUTION_CHECKLIST.md`.

TSK содержит код под несколькими лицензиями. `fls` отмечен как CPL 1.0,
`icat` — IBM Public License 1.0; обзор (`LICENSES-README.md`) и полные тексты
(`CPL-1.0.txt`, `IBM-PUBLIC-LICENSE-1.0.txt`) побайтно совпадают с
`licenses/` исходного архива 4.15.0. До публичной поставки нужен отдельный
аудит того, достаточно ли распространения этих программ как независимых
исполняемых файлов рядом с GPL-приложением.
