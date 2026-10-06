# untrunc: источник и воспроизводимость

- Репозиторий: <https://github.com/anthwlock/untrunc>
- Коммит: `9d86ec9ef2ffed1bf8131abe80742c0574db52b6` (существует на GitHub,
  «hvc1: restore CRA seek points»; проверено 2026-10-06)
- Версия в выводе: `v1-9d86ec9` (строка присутствует и в самом бинарнике
  вместе с `ffmpeg '8.1'` — статический просмотр строк, запуск не требуется;
  версия доказывает только версию, не конфигурацию сборки)
- Лицензия проекта: GNU GPL v2 (`COPYING` побайтно совпадает с `COPYING`
  исходного архива `untrunc-9d86ec9-source.tar.gz`)
- Архив исходников: `outputs/untrunc-9d86ec9-source.tar.gz`, SHA-256
  `a46bbb0013b274cd239b0fe037cdf175e6865d62119e78f6f8d8684efbeaa8dc`; содержит
  исходники репозитория, включая `Makefile` с рецептом сборки. Побайтное
  совпадение архива с `git archive` коммита `9d86ec9` офлайн не проверялось
  (локального клона нет) — UNVERIFIED, см. `docs/DISTRIBUTION_CHECKLIST.md`.
- FFmpeg: 8.1; LGPL 2.1-or-later — УСЛОВНО по рецепту (`FF_CONFIG_FLAGS` цели
  `untrunc-81` в Makefile архива: без `--enable-gpl`/`--enable-nonfree`).
  Фактические configure-флаги поставляемого бинарника НЕ доказаны: build/
  config metadata в бинарнике нет (строки configure-флагов поиском `strings`
  не находятся), строка `ffmpeg '8.1'` доказывает версию. Связь бинарника
  `cda6c307…` с этим архивом и рецептом — UNVERIFIED до контрольной
  пересборки из прикладываемого архива; см. `docs/DISTRIBUTION_CHECKLIST.md`.
- SHA-256 `ffmpeg-8.1.tar.xz`:
  `b072aed6871998cce9b36e7774033105ca29e33632be5b6347f3206898e0756a`
- SHA-256 arm64-бинарника:
  `cda6c307caed260f6840aefdd4f7516a6003f85dbd3e9e27d9a3d40c2645b853`

Бинарник не зависит от Homebrew во время работы (`otool -L`: только системные
`libSystem`, `libiconv`, `libc++`); отсутствие динамики доказывает только
отсутствие динамических зависимостей, не отсутствие статически включённых
компонентов.

Конфигурация FFmpeg в РЕЦЕПТЕ задаётся целью `untrunc-81` в `Makefile`
исходного архива (`FF_CONFIG_FLAGS`): `--disable-doc --disable-everything
--enable-decoders --disable-vdpau --enable-demuxers --enable-protocol=file
--disable-avdevice --disable-swresample --disable-swscale --disable-avfilter
--disable-xlib --disable-vaapi --disable-zlib --disable-bzlib --disable-lzma
--disable-audiotoolbox --disable-videotoolbox`. Полный текст LGPL 2.1
поставляется рядом (`FFMPEG-COPYING.LGPLv2.1.txt`, извлечён без изменений из
исходного архива FFmpeg 8.1); полный исходный архив FFmpeg входит в поставку.
Если фактическая конфигурация бинарника отличается от рецепта, применимые
лицензии и обязательства по исходникам подлежат пересмотру. Полные
соответствующие исходники должны поставляться рядом с публичной бинарной
версией RecoveryApp или быть доступны по стабильной ссылке на тот же точный
архив.
