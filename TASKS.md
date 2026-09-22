# Очередь задач RecoveryApp

Статусы: `TODO`, `IN PROGRESS`, `REVIEW`, `DONE`, `BLOCKED`.

| Задача | Статус | Ветка | Назначение |
|---|---|---|---|
| TASK-001 | DONE | `glm/task-001-cli-foundation` | Общий RecoveryCore и минимальный CLI |
| TASK-002 | DONE | `glm/task-002-sleuthkit-fd` | Пересборка Sleuth Kit и регрессия унаследованного read-only FD |
| TASK-003 | DONE | `glm/task-003-quick-image-cli` | RecoveryCore и CLI быстрого восстановления из образа |
| TASK-004 | DONE | `glm/task-004-physical-quick-cli` | Физический read-only источник и CLI через `authopen`; короткая приёмка Flashka пройдена |
| TASK-004B | DONE | `codex/task-004b-empty-results` | Диагностика пустых/неполных результатов и точный текст отмены поиска |
| TASK-004C | TODO | `glm/task-004c-size-aware-quick-recovery` | Сверять ожидаемый и фактический размер quick-результатов |
| TASK-005 | TODO | — | CLI PhotoRec, прогресс и остановка |
| TASK-006 | TODO | — | CLI восстановления видео |
| TASK-007 | TODO | — | Перевод SwiftUI на общий RecoveryCore |
| TASK-008 | TODO | — | Полная регрессия и актуальная упаковка 0.8.1 |

Статус `DONE` выставляет только Codex после независимого ревью коммита.
