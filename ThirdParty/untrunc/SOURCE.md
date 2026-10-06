# untrunc: источник и воспроизводимость

- Репозиторий: <https://github.com/anthwlock/untrunc>
- Коммит: `9d86ec9ef2ffed1bf8131abe80742c0574db52b6` (существует на GitHub,
  «hvc1: restore CRA seek points»; проверено 2026-10-06)
- Версия в бинарнике: `archive-9d86ec9` — сборка TASK-016 из прикладываемого
  архива (build-only патч `Packaging/untrunc-local-archive-build.patch`
  фиксирует строку и запрещает сетевые загрузки). Прежний бинарник содержал
  `v1-9d86ec9`, полученный из git-метаданных клона; смена строки отражает
  фактический источник сборки и не влияет на код.
- Лицензия проекта: GNU GPL v2 (`COPYING` побайтно совпадает с `COPYING`
  исходного архива `untrunc-9d86ec9-source.tar.gz`)
- Архив исходников: `outputs/untrunc-9d86ec9-source.tar.gz`, SHA-256
  `a46bbb0013b274cd239b0fe037cdf175e6865d62119e78f6f8d8684efbeaa8dc`; из
  НЕГО собран действующий бинарник (цепочка в
  `ThirdParty/BUILD-PROVENANCE.json`). Побайтное совпадение архива с
  `git archive` коммита `9d86ec9` офлайн не проверялось — UNVERIFIED.
- FFmpeg: 8.1, собран из `outputs/ffmpeg-8.1-source.tar.xz`
  (`b072aed6…`) тем же проходом; фактическая конфигурация зафисирована
  evidence (`docs/build-evidence/TASK-016/untrunc-ffmpeg-config.h`,
  `untrunc-ffmpeg-config.mak`, `untrunc-ffmpeg-config-summary.txt`):
  `CONFIG_GPL`/`CONFIG_NONFREE` не установлены, внешние библиотеки не
  включены → компоненты FFmpeg в действующем бинарнике под
  LGPL 2.1-or-later. Полный текст LGPL 2.1 — рядом
  (`FFMPEG-COPYING.LGPLv2.1.txt`, без изменений).
- SHA-256 arm64-бинарника (TASK-016, ad-hoc подписан):
  `32174ade355b61312640103717c65b6806708da1f590ee0982e5fb686999dc4e`
  (до подписи: `5a2d981cf0b6a4275c9f59f455976f4ad45b2f44b0df079b532c3497ec5a69dc`)

Бинарник не зависит от Homebrew во время работы (`otool -L`: только системные
`libSystem`, `libiconv`, `libc++`); FFmpeg (libavformat/libavcodec/libavutil)
включён статически из библиотек, собранных в том же очищенном дереве —
команда линковки и зависимости зафиксированы в
`docs/build-evidence/TASK-016/untrunc-link-evidence.txt`.

Полные соответствующие исходники поставляются рядом (архивы untrunc и
FFmpeg + build-only патч + рецепт в `Scripts/build-untrunc.sh` и Makefile
архива) и должны сопровождать любую публичную бинарную версию RecoveryApp.
Побайтная воспроизводимость untrunc не заявляется; provenance действующего
бинарника доказан цепочкой «архив + патч + конфигурация + toolchain →
бинарник» (`docs/TOOLCHAIN_PROVENANCE.md`).

Исправление Codex 2026-10-07: сборка явно добавляет --disable-autodetect и
--disable-sdl2; фактический generated config проверяется verify-ffmpeg-config.py
до публикации кандидата. Строка линковки и SHA свежих libav*.a извлекаются
production-сценарием. Evidence нормализован только по конечным пробелам и
пустым строкам; SHA сырых config.h/config.mak сохранены отдельно.
