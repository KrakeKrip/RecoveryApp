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

- SHA-256 `bin/arm64/fls`: `283ea6fa94d08f2e61e80ae3141642e8e81dd41db7b269890533589ab8080791` (ad-hoc подписан)
- SHA-256 `bin/arm64/icat`: `a92a65f1bc52fdead9c22259689ea7602e870e12f83dc2fb01abc0fb466fb757` (ad-hoc подписан)
- SHA-256 `bin/arm64/mmls`: `89e87e674eb66c0c655645e36d12a829910527c118434f4c4b1f4f76c7814341` (ad-hoc подписан)

Значения обновлены 2026-10-06 (TASK-016): бинарники КОНТРОЛЬНО пересобраны
hardened-сценарием `Scripts/build-sleuthkit.sh` (проверка SHA входов,
однократный патч, toolchain-evidence в `docs/build-evidence/TASK-016/`,
isolated staging). Свежая сборка побайтно совпала с предыдущим бинарником
(ld-подпись arm64 детерминирована), вторая независимая сборка дала те же
SHA — provenance fls/icat/mmls доказан цепочкой «архив+патч+конфигурация
→ бинарник» и воспроизводимостью. Подробности: `docs/TOOLCHAIN_PROVENANCE.md`
и `ThirdParty/BUILD-PROVENANCE.json`.

TSK содержит код под несколькими лицензиями. `fls` отмечен как CPL 1.0,
`icat` — IBM Public License 1.0; обзор (`LICENSES-README.md`) и полные тексты
(`CPL-1.0.txt`, `IBM-PUBLIC-LICENSE-1.0.txt`) побайтно совпадают с
`licenses/` исходного архива 4.15.0. До публичной поставки нужен отдельный
аудит того, достаточно ли распространения этих программ как независимых
исполняемых файлов рядом с GPL-приложением.
