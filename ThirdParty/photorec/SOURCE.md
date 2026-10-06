# PhotoRec 7.2 с libjpeg-turbo 3.2.0

- Проект: TestDisk & PhotoRec
- Версия: 7.2, February 2024 (`AC_INIT([testdisk],[7.2],...)` в `configure.ac`
  исходного архива)
- Исходный архив: `https://www.cgsecurity.org/testdisk-7.2.tar.bz2`
- SHA-256 архива: `f8343be20cb4001c5d91a2e3bcd918398f00ae6d8310894a5a9f2feb813c283f`
- Лицензия: GNU GPL v2 or later; копия находится в `COPYING` (побайтно совпадает
  с `COPYING` исходного архива).

Лабораторный arm64-бинарник собран `clang` с deployment target macOS 14 и без
необязательных библиотек ext2fs, NTFS, EWF, zlib и UUID (ключевые `configure`
флаги в `Scripts/build-photorec.sh`). libjpeg-turbo 3.2.0 собран для arm64
статически и включён в `photorec`; динамические зависимости ограничены
системными `libncurses`, `libiconv` и `libSystem` (проверено `otool -L`).

Для запуска через уже авторизованный `/dev/fd/N` применён минимальный патч
`Packaging/photorec-dev-fd.patch`: файл `src/hdaccess.c`, для путей
`/dev/fd/N` используется `dup()` унаследованного read-only дескриптора вместо
повторного `open()`. Патч применяется однократно к чистому архиву 7.2 командой
из `Scripts/build-photorec.sh` (`patch -d <source> -p1 < ...`); бинарник в
`bin/arm64/photorec` собран ИЗ ИЗМЕНЁННОГО исходного кода, патч прикладывается
к поставке рядом с архивом исходников.

- Официальный архив libjpeg-turbo 3.2.0:
  `https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.2.0/libjpeg-turbo-3.2.0.tar.gz`
- SHA-256 архива: `6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e`
- Лицензионные тексты: `LIBJPEG-TURBO-LICENSE.md` (BSD-3-clause libjpeg-turbo)
  и `LIBJPEG-IJG-README.txt` (IJG) — побайтно совпадают с файлами
  `LICENSE.md`/`README.ijg` исходного архива libjpeg-turbo 3.2.0.

Ключевые параметры PhotoRec: `--with-jpeg`, `--with-jpeg-lib=<static-lib-dir>`,
`--with-jpeg-includes=<include-dir>`. Команда `/version` при сборке
подтвердила `libjpeg: libjpeg-turbo-3.2.0`; в самом бинарнике присутствует
строка версии `3.2.0` libjpeg-turbo (проверено статическим просмотром строк).

SHA-256 `bin/arm64/photorec`:
`32479bc9d1aa32afe074a584651e637474a9ef4cd76e9610f7c255b353f5f70d`.

Значение обновлено 2026-10-06 (TASK-015): бинарник был пересобран и повторно
ad-hoc подписан после предыдущей записи, прежняя сумма устарела. Побайтное
совпадение текущего бинарника с результатом контрольной пересборки из архивов
и патча не проверялось (пересборка в TASK-015 не выполнялась) — см.
`docs/DISTRIBUTION_CHECKLIST.md`.
