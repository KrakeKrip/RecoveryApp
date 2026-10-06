# Встроенные инструменты

В arm64-сборку входит `untrunc` с собственными статически собранными библиотеками
FFmpeg 8.1, собранными из прикладываемого архива; фактическая конфигурация
зафиксирована evidence (`docs/build-evidence/TASK-016/`) — без GPL/nonfree
и внешних библиотек, т.е. LGPL 2.1 or later; текст LGPL 2.1 — в
`untrunc/FFMPEG-COPYING.LGPLv2.1.txt`. Точная версия, контрольные суммы и
способ получения исходников — в `untrunc/SOURCE.md`, текст GPL v2 — в
`untrunc/COPYING`.

Все пять встроенных инструментов (Sleuth Kit 4.15.0 — `fls`/`icat`/`mmls`,
PhotoRec 7.2 со статическим libjpeg-turbo 3.2.0, untrunc) пересобраны
контрольными hardened-сценариями из прикладываемых локальных архивов
(TASK-016) вместе с уведомлениями, контрольными суммами, точными исходными
архивами и патчами `/dev/fd/N` (для untrunc — build-only патчем локальной
сборки). Provenance каждого — в `ThirdParty/BUILD-PROVENANCE.json` и
`docs/TOOLCHAIN_PROVENANCE.md`. Инструменты упакованы в `.app`
(`Contents/Resources/Tools/`), их исходные архивы и патчи — в
`Contents/Resources/SourceArchives/`. Это пока не публичный релиз: перед ним
требуется отдельное решение по совместимости лицензий CPL/IPL со способом
распространения GPL-приложения; инженерный аудит находится в
`docs/SLEUTH_KIT_LICENSE_AUDIT.md`, сводный комплектностный чеклист — в
`docs/DISTRIBUTION_CHECKLIST.md`.
Приложение не ищет инструменты в Homebrew или пользовательском `PATH`.
