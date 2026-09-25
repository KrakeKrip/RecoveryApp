# Очередь задач RecoveryApp

Статусы: `TODO`, `IN PROGRESS`, `REVIEW`, `DONE`, `BLOCKED`.

| Задача | Статус | Ветка | Назначение |
|---|---|---|---|
| TASK-001 | DONE | `glm/task-001-cli-foundation` | Общий RecoveryCore и минимальный CLI |
| TASK-002 | DONE | `glm/task-002-sleuthkit-fd` | Пересборка Sleuth Kit и регрессия унаследованного read-only FD |
| TASK-003 | DONE | `glm/task-003-quick-image-cli` | RecoveryCore и CLI быстрого восстановления из образа |
| TASK-004 | DONE | `glm/task-004-physical-quick-cli` | Физический read-only источник и CLI через `authopen`; короткая приёмка Flashka пройдена |
| TASK-004B | DONE | `codex/task-004b-empty-results` | Диагностика пустых/неполных результатов и точный текст отмены поиска |
| TASK-004C | DONE | `glm/task-004c-size-aware-quick-recovery` | Сверять ожидаемый и фактический размер quick-результатов; принят коммит `d141e57ff5020119fe0d8c3ac7bf57faa198afd6` |
| TASK-005 | DONE | `glm/task-005-cli-photorec` | CLI глубокого PhotoRec с прогрессом и отменой; принят коммит `118efde68c89ef6d7f6eead8d2ca0282feefee5f` |
| TASK-006 | DONE | `glm/task-006-cli-video-repair` | Общий RecoveryCore для untrunc и CLI восстановления видео с отменой; принят коммит `1e258dfbab52f797df517cad5178069caf9bc9ff` |
| TASK-007 | DONE | `glm/task-007-swiftui-core-parity` | GUI использует общий Core и защищает находки при подмене источника; принят коммит `7f1a2fd7ce2fb8f2d5a117ad9ff83aa9505e1ed0` |
| TASK-008 | DONE | `glm/task-008-regression-package` | Синтетическая и GUI-регрессия, лабораторные DMG/ZIP 0.8.1; принят коммит `f192ceb6bbecb8a8cf4b4e23a9c7e44513351415` |
| TASK-009 | TODO | `glm/task-009-gui-deep-video-acceptance` | Сквозная GUI-приёмка глубокого поиска и исправления видео на синтетических данных, без физических накопителей и системной авторизации |

Статус `DONE` выставляет только Codex после независимого ревью коммита.
