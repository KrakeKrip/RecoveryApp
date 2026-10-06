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
| TASK-009 | DONE | `glm/task-009-gui-deep-video-acceptance` | GUI-приёмка PhotoRec и untrunc на синтетике; принят коммит `38cb1e660a86960819e9b0d4ca974d7d25e71d00` |
| TASK-010 | REVIEW | `codex/task-010-physical-quick-gui` | GUI FAT32: 71 находка, один результат 8224 байта, карточка и Finder; выбор Загрузок и папки Codex проверен; пользователь предположительно наблюдал два запроса, причина ещё не установлена |
| TASK-011 | DONE | `codex/task-011-ui-package-check` | Codex проверил три основных экрана текущей 0.8.1 (13), создал отдельный DMG и проверил целостность, вложенную подпись и оформление Finder; другой Mac не проверен |

| TASK-012 | REVIEW | `glm/task-012-findings-filters` | Общие фильтры типа, имени и размера для быстрого поиска; безопасный выбор только видимых находок |
| TASK-013 | TODO | пока не назначена | Следующий этап после TASK-012: явная проверка восстановленных фото/видео, отдельно от сверки размеров; задание ещё не выдано |

Статус `DONE` выставляет только Codex после независимого ревью коммита.
