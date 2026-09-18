# PhotoRec 7.2 с libjpeg-turbo 3.2.0

- Проект: TestDisk & PhotoRec
- Версия: 7.2, February 2024
- Исходный архив: `https://www.cgsecurity.org/testdisk-7.2.tar.bz2`
- SHA-256 архива: `f8343be20cb4001c5d91a2e3bcd918398f00ae6d8310894a5a9f2feb813c283f`
- Лицензия: GNU GPL v2 or later; копия находится в `COPYING`.

Лабораторный arm64-бинарник собран `clang` с deployment target macOS 14 и без
необязательных библиотек ext2fs, NTFS, EWF, zlib и UUID. libjpeg-turbo 3.2.0
собран для arm64 статически и включён в `photorec`; динамические зависимости
ограничены системными `libncurses`, `libiconv` и `libSystem`.

- Официальный архив libjpeg-turbo 3.2.0:
  `https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.2.0/libjpeg-turbo-3.2.0.tar.gz`
- SHA-256 архива: `6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e`
- Лицензионные тексты: `LIBJPEG-TURBO-LICENSE.md` и
  `LIBJPEG-IJG-README.txt`.

Ключевые параметры PhotoRec: `--with-jpeg`, `--with-jpeg-lib=<static-lib-dir>`,
`--with-jpeg-includes=<include-dir>`. Команда `/version` подтверждает
`libjpeg: libjpeg-turbo-3.2.0`.

SHA-256 `bin/arm64/photorec`:
`3b6715057edde09ce591bae618af975ce42b3f9c089fb7b9b6e66d1b199f3ea3`.
