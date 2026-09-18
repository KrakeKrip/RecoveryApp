# The Sleuth Kit 4.15.0 — лабораторный кандидат

- Проект: The Sleuth Kit
- Версия: 4.15.0, April 2026
- Исходный архив: `https://github.com/sleuthkit/sleuthkit/releases/download/sleuthkit-4.15.0/sleuthkit-4.15.0.tar.gz`
- SHA-256 архива: `3a8c1e7d18a9b81f3e5e8aa78313974aceaafc6e051d636bc92cd7168286eca9`
- Используемые кандидаты: отдельные CLI `fls`, `icat` и `mmls`.

Сборка arm64 выполнена с deployment target macOS 14, без Java, AFF, EWF, VHDI
и VMDK. Бинарники используют только системные `libz`, `libsqlite3`, `libSystem`
и `libc++`.

Для безопасной работы через уже авторизованный `/dev/fd/N` применён минимальный
патч `Packaging/sleuthkit-preopened-fd.patch`: первая операция чтения всегда
выполняет явный `lseek`, поскольку определение размера может сдвинуть общий
offset дублированного дескриптора. Исходный путь сборки записан в
`Scripts/build-sleuthkit.sh`.

- SHA-256 `bin/arm64/fls`: `870cca4f65046b89d2b7f309f496d28ca694005c9f80b8b0218b9d8d8a52066c`
- SHA-256 `bin/arm64/icat`: `dfb91f42530165710e1feba75dd948e38c0b9bffd6bcbef97ac1cb934571e46a`
- SHA-256 `bin/arm64/mmls`: `cc4183fcb1b95b62acf7defc75e8785313f864db8f4b0e08f5c80fbb18dc9883`

TSK содержит код под несколькими лицензиями. `fls` отмечен как CPL 1.0,
`icat` — IBM Public License 1.0; обзор и тексты лицензий сохранены рядом.
До публичной поставки нужен отдельный аудит того, достаточно ли распространения
этих программ как независимых исполняемых файлов рядом с GPL-приложением.
