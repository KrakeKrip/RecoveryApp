# TASK-018 — крупный постоянный глубокий поиск

Исполнитель Codex, 2026-10-18. Ветка codex/task-018-deep-search-action.

Изменены DeletedFilesView.swift, DeletedFilesViewModel.swift,
Tests/UnitHarness/main.swift, ARCHITECTURE.md, STATUS.md, TASKS.md,
tasks/TASK-018.md и этот отчёт. Версия 0.8.1 (13) не менялась.

Карточка deep расположена над процессом и находками; крупная кнопка с иконкой
не скрывается при quick. Диалог рекомендует сначала завершить quick и предлагает
продолжить его либо остановить и начать deep. Отмена диалога ничего не отменяет.
Переход ожидает cleanup quick task; повторный запуск/новый save запрещены.
Активный save не останавливается молча, показано пояснение. Уход отменяет переход.
Источник, папка, авторизация и read-only helpers не изменены. Записанные файлы
и находки не удаляются.

Проверки:

- `RECOVERYAPP_SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk BUILD_CACHE_DIR=/private/tmp/recoveryapp-deep-ui.jiofOT/harness ./Scripts/test.sh`
  — PASS: 384 domain checks (exit 0); добавлены проверки доступности
  deep при quick, ожидания отмены, старта deep и блокировки save во время перехода.
- `RECOVERYAPP_SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk BUILD_CACHE_DIR=/private/tmp/recoveryapp-deep-ui.jiofOT/build OUTPUT_DIR=dist/TASK-018 ./Scripts/build-app.sh`
- `codesign --verify --deep --strict dist/TASK-018/RecoveryApp.app`
- `git diff --check`.

Финальная сборка и строгая подпись — exit 0. Diff без whitespace-ошибок.

GUI: изолированная RecoveryAppDeepUITest.app с отдельным bundle ID; основной
код новой сборки, fls заменён управляемой C fixture исключительно в тестовой
копии. Синтетический sparse IMG 1 МиБ. Настоящие клики: quick → ранняя находка
при работающем процессе → крупная кнопка deep доступна → диалог → «Продолжить
быстрый поиск» оставляет quick работающим → повторный диалог → подтверждение
останавливает quick → реальный bundled PhotoRec завершает synthetic IMG с 0
файлов. Визуально проверена карточка в окне, текст диалога подтверждён AX.
После GUI добавлены только guard нового save во время перехода и его тесты;
раскладка/тексты не менялись. Тестовая копия закрыта, пользовательская не тронута.

Первая сборка была прервана компилятором из-за обновления исходника во время
сборки; повторная прошла. В новом тесте исправлены восстановление environment
и пропущенный путь синтетического icat, затем прогон повторён.

Не проверены реальные диски, auth-диалоги, 14.5, другой Mac. Пакет GitHub
не публиковался, main не менялся. Временные тестовые данные/кэши удаляются после
проверок, финальная .app остаётся в dist/TASK-018. Старые результаты и .mimosa
не тронуты.
