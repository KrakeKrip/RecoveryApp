# Документация RecoveryApp

## Для работы над проектом

- [AGENT_GUIDE.md](AGENT_GUIDE.md) — первая точка входа агента.
- [DEVELOPMENT.md](DEVELOPMENT.md) — окружение, сборка, упаковка, уборка.
- [CLI.md](CLI.md) — команды, инструменты и машинный вывод.
- [Архитектура](../ARCHITECTURE.md) — актуальное устройство Core, GUI и CLI.
- [Продукт](../PRODUCT.md), [задачи](../TASKS.md), [решения](../DECISIONS.md)
  и [AGENTS.md](../AGENTS.md) — обязательные документы Git-репозитория.

## Для пользователя

- [USER_GUIDE.md](USER_GUIDE.md) — установка и сценарии восстановления.

## Evidence и ограничения

- [STATUS.md](../STATUS.md) — состояние с историей проверок.
- [Отчёты задач](../reports/) — точные команды и непроверенные сценарии.
- [DISTRIBUTION_CHECKLIST.md](DISTRIBUTION_CHECKLIST.md) — комплектность поставки.
- [SLEUTH_KIT_LICENSE_AUDIT.md](SLEUTH_KIT_LICENSE_AUDIT.md) — открытые вопросы TSK.
- [TOOLCHAIN_PROVENANCE.md](TOOLCHAIN_PROVENANCE.md) — контрольные сборки TASK-016.
- [build-evidence/TASK-016](build-evidence/TASK-016/) — конфигурации и цепочка сборки.
- [DELETED_FILE_EXPERIMENTS.md](DELETED_FILE_EXPERIMENTS.md) и
  [VIDEO_TESTS.md](VIDEO_TESTS.md) — исторические эксперименты, не гарантия продукта.

Актуальный код и новая подтверждённая приёмка имеют приоритет над старым отчётом.
Дата старого эксперимента не означает, что его проверки повторены для нового кода.
Source ZIP предназначен для комплекта исходников: текущий упаковщик не включает
корневые PRODUCT/ARCHITECTURE/TASKS/DECISIONS, tasks и reports. Для продолжения
агентной разработки используйте Git-репозиторий, а не только релизный ZIP.
