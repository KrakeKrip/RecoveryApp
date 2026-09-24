@preconcurrency import Foundation
import Darwin
import RecoveryCore

/// Идентичность физического источника для переиспользования quick-сессии:
/// совпадение требует одинаковых `diskN`, точного имени и точного размера —
/// тех же признаков, что сверяет `PhysicalDriveSelector`.
struct PhysicalSourceIdentity: Equatable, Sendable {
    let identifier: String
    let name: String
    let size: Int64

    init(_ drive: ExternalDrive) {
        identifier = drive.identifier
        name = drive.name
        size = drive.size
    }

    func matches(_ drive: ExternalDrive) -> Bool {
        self == PhysicalSourceIdentity(drive)
    }
}

/// Проверка устаревания находок после обновления списка накопителей: если
/// диск с тем же `diskN` изменил имя или размер (или исчез), находки
/// сканирования устарели и должны быть сброшены до всякой авторизации.
enum ScannedSourceRefresh {
    static func outdatedReason(
        scanned: PhysicalSourceIdentity?,
        snapshot: [ExternalDrive]
    ) -> DeletedFilesError? {
        guard let scanned else { return nil }
        guard let current = snapshot.first(where: { $0.id == scanned.identifier }) else {
            return .sourceUnavailable
        }
        return scanned.matches(current) ? nil : .sourceChanged
    }
}

/// Координатор одной физической quick-сессии GUI: для подтверждённого диска
/// создаётся один `PhysicalQuickRecovery` (с его ленивой авторизационной
/// сессией) и переиспользуется для scan и recover того же источника; смена
/// источника, отмена, ошибка или завершение извлечения сбрасывают сессию.
/// Фабрика по умолчанию строит реальный backend Core; подменная фабрика
/// внедряется только в доменных тестах и в GUI не используется.
final class PhysicalQuickSessionCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private let makeRecovery: @Sendable () throws -> PhysicalQuickRecovery
    private var active: (source: PhysicalSourceIdentity, recovery: PhysicalQuickRecovery)?

    init(makeRecovery: @escaping @Sendable () throws -> PhysicalQuickRecovery = {
        try DeletedFilesExecutor.makePhysicalRecovery()
    }) {
        self.makeRecovery = makeRecovery
    }

    /// Существующая сессия переиспользуется только при идентичности
    /// источника; для другого диска создаётся новая сессия.
    func recovery(for drive: ExternalDrive) throws -> PhysicalQuickRecovery {
        lock.lock()
        let existing = active
        lock.unlock()
        if let existing, existing.source.matches(drive) {
            return existing.recovery
        }
        let recovery = try makeRecovery()
        lock.lock()
        active = (PhysicalSourceIdentity(drive), recovery)
        lock.unlock()
        return recovery
    }

    /// Безопасный сброс: ссылка на сессию отбрасывается, авторизационная
    /// сессия освобождается системой при деинициализации.
    func reset() {
        lock.lock()
        active = nil
        lock.unlock()
    }

    /// Остановка текущей операции активной сессии (если она есть).
    func cancelActive() {
        lock.lock()
        let current = active
        lock.unlock()
        current?.recovery.cancel()
    }
}

/// Порядок физической quick-операции до всякого запуска инструмента:
/// повторная сверка выбранного источника по свежему снимку (правила — в
/// `PhysicalDriveSelector.selectDrive`), затем preflight папки результата
/// (`preflightRecoveryOutput`) и только потом получение сессии с её ленивой
/// авторизацией. При любом отказе сессия не запрашивается вовсе.
enum PhysicalQuickOperationPreparation {
    static func prepare(
        selected drive: ExternalDrive,
        snapshot: [ExternalDrive],
        outputFolderURL: URL,
        sessions: PhysicalQuickSessionCoordinator
    ) throws -> PhysicalQuickRecovery {
        let confirmed = try PhysicalDriveSelector.selectDrive(
            identifier: drive.identifier,
            expectedName: drive.name,
            expectedSize: drive.size,
            from: snapshot
        )
        try PhysicalQuickRecovery.preflightRecoveryOutput(
            outputFolderURL: outputFolderURL,
            drive: confirmed
        )
        return try sessions.recovery(for: confirmed)
    }
}

/// Сводка quick-извлечения для карточки результата: число сохранённых файлов
/// не зависит от статусов — проблемные файлы остаются в папке; предупреждение
/// не утверждает побайтную целостность.
struct QuickRecoverySummary: Equatable, Sendable {
    let folder: URL
    let savedCount: Int
    let sizeMatchesCount: Int
    let incompleteCount: Int
    let sizeMismatchCount: Int
    let sizeUnknownCount: Int

    var hasSizeProblems: Bool { incompleteCount > 0 || sizeMismatchCount > 0 }

    static func make(
        folder: URL,
        results: [RecoveredFileResult]
    ) -> QuickRecoverySummary {
        var matches = 0
        var incomplete = 0
        var mismatch = 0
        var unknown = 0
        for result in results {
            switch result.status {
            case .sizeMatches, .expectedEmpty: matches += 1
            case .incomplete: incomplete += 1
            case .sizeMismatch: mismatch += 1
            case .sizeUnknown: unknown += 1
            }
        }
        return QuickRecoverySummary(
            folder: folder,
            savedCount: results.count,
            sizeMatchesCount: matches,
            incompleteCount: incomplete,
            sizeMismatchCount: mismatch,
            sizeUnknownCount: unknown
        )
    }

    /// Заголовок карточки: безоговорочный успех — только когда проблем
    /// размеров нет; неполные и несовпадающие дают спокойное предупреждение.
    var title: String {
        if savedCount == 0 {
            return "Восстанавливать нечего"
        }
        if hasSizeProblems {
            return "Восстановление завершено с предупреждениями"
        }
        return "Восстановление завершено"
    }

    /// Пояснение карточки: точные счётчики по статусам; совпадение размеров
    /// не выдаётся за проверку целостности содержимого.
    var message: String {
        if savedCount == 0 {
            return "Удалённые файлы не найдены — сохранять нечего."
        }
        var parts = ["Сохранено файлов: \(savedCount)."]
        if hasSizeProblems {
            var warnings: [String] = []
            if incompleteCount > 0 {
                warnings.append("извлечены не полностью: \(incompleteCount)")
            }
            if sizeMismatchCount > 0 {
                warnings.append("размер отличается от метаданных: \(sizeMismatchCount)")
            }
            parts.append("Проблемные файлы: " + warnings.joined(separator: ", ") + " — они сохранены в папке и доступны.")
        }
        if sizeUnknownCount > 0 {
            parts.append("Размер \(sizeUnknownCount) файл(ов) не удалось сверить с метаданными — это не доказывает их неполноту.")
        }
        if !hasSizeProblems && sizeUnknownCount == 0 {
            parts.append("Размеры сохранённых файлов совпали с данными метаданных.")
        }
        parts.append("Совпадение размеров не является проверкой целостности содержимого.")
        return parts.joined(separator: " ")
    }
}

/// Тонкий GUI-адаптер над RecoveryCore. Все алгоритмы живут в Core:
/// быстрые режимы — в `ImageQuickRecovery` и `PhysicalQuickRecovery`,
/// глубокий PhotoRec — в `PhotoRecDeepRecovery` (общий с CLI). Здесь только
/// выбор инструментов, одна физическая quick-сессия на источник и прежние
/// пользовательские callbacks.
final class DeletedFilesExecutor: @unchecked Sendable {
    private let lock = NSLock()
    private let physicalSessions: PhysicalQuickSessionCoordinator
    private var imageRecovery: ImageQuickRecovery?
    private var deepRecovery: PhotoRecDeepRecovery?

    init(physicalSessions: PhysicalQuickSessionCoordinator = PhysicalQuickSessionCoordinator()) {
        self.physicalSessions = physicalSessions
    }

    func scan(
        imageURL: URL,
        onOutput: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> [DeletedFileCandidate] {
        let recovery = try Self.makeImageRecovery()
        replaceImageRecovery(recovery)
        return try await recovery.scan(imageURL: imageURL, onOutput: onOutput)
    }

    func scan(
        drive: ExternalDrive,
        onOutput: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> [DeletedFileCandidate] {
        let recovery = try physicalSessions.recovery(for: drive)
        return try await recovery.scan(drive: drive, onOutput: onOutput)
    }

    func recoverDetailed(
        imageURL: URL,
        outputFolderURL: URL,
        candidates: [DeletedFileCandidate],
        onOutput: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> [RecoveredFileResult] {
        let recovery = try Self.makeImageRecovery()
        replaceImageRecovery(recovery)
        return try await recovery.recoverDetailed(
            imageURL: imageURL,
            outputFolderURL: outputFolderURL,
            candidates: candidates,
            onOutput: onOutput
        )
    }

    /// Физическое извлечение с размерными статусами. Повторная сверка диска
    /// и preflight папки выполняются вызывающей стороной до этого вызова;
    /// Core повторяет preflight вторым барьером, а авторизационная сессия
    /// берётся из координатора (переиспользуется при том же источнике).
    func recoverDetailed(
        drive: ExternalDrive,
        outputFolderURL: URL,
        candidates: [DeletedFileCandidate],
        onOutput: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> [RecoveredFileResult] {
        guard !candidates.isEmpty else { throw DeletedFilesError.nothingSelected }
        let recovery = try physicalSessions.recovery(for: drive)
        return try await recovery.recoverDetailed(
            drive: drive,
            outputFolderURL: outputFolderURL,
            candidates: candidates,
            onOutput: onOutput
        )
    }

    /// Смена источника, отмена, ошибка или завершение извлечения:
    /// физическая quick-сессия сбрасывается безопасно.
    func resetPhysicalSession() {
        physicalSessions.reset()
    }

    func deepRecover(
        imageURL: URL,
        outputFolderURL: URL,
        onSessionReady: @escaping @MainActor @Sendable (URL) -> Void = { _ in },
        onOutput: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> DeepRecoveryResult {
        // Прежнее поведение GUI: образ без каталогов PhotoRec — ошибка
        // инструмента, а не пустой результат.
        let result = try await deepRecoverWithBackend(
            outputFolderURL: outputFolderURL,
            requirePhotorec: true
        ) { backend in
            try await backend.recover(
                imageURL: imageURL,
                outputFolderURL: outputFolderURL,
                onSessionReady: onSessionReady,
                onOutput: onOutput
            )
        }
        let directories = try PhotoRecDeepRecovery.photoRecOutputDirectories(
            baseURL: result.outputDirectory.appendingPathComponent("Recovered")
        )
        guard !directories.isEmpty else {
            throw DeletedFilesError.toolFailed("PhotoRec", 0)
        }
        return result
    }

    func deepRecover(
        drive: ExternalDrive,
        outputFolderURL: URL,
        onSessionReady: @escaping @MainActor @Sendable (URL) -> Void = { _ in },
        onOutput: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> DeepRecoveryResult {
        // Общий preflight Core ДО создания авторизации и запуска helper;
        // backend повторяет его вторым барьером.
        try PhysicalQuickRecovery.preflightRecoveryOutput(
            outputFolderURL: outputFolderURL,
            drive: drive
        )
        let authorization = try ReadOnlyAuthorization(device: drive.rawDevicePath)
        let helper = try RecoveryToolLocator.toolURL(
            named: "recoveryapp-readonly-helper",
            environmentKey: "RECOVERYAPP_READONLY_HELPER_PATH"
        )
        return try await deepRecoverWithBackend(
            outputFolderURL: outputFolderURL,
            requirePhotorec: false
        ) { backend in
            try await backend.recover(
                drive: drive,
                authorization: authorization,
                outputFolderURL: outputFolderURL,
                helper: helper,
                onSessionReady: onSessionReady,
                onOutput: onOutput
            )
        }
    }

    func cancel() {
        lock.lock()
        let activeDeepRecovery = deepRecovery
        let activeImageRecovery = imageRecovery
        lock.unlock()
        activeDeepRecovery?.cancel()
        activeImageRecovery?.cancel()
        // Отмена физической quick-операции останавливает группу процессов
        // активной сессии и сбрасывает её саму.
        physicalSessions.cancelActive()
        physicalSessions.reset()
    }

    // MARK: - Инструменты

    static func makePhysicalRecovery() throws -> PhysicalQuickRecovery {
        let helper = try RecoveryToolLocator.toolURL(
            named: "recoveryapp-metadata-helper",
            environmentKey: "RECOVERYAPP_METADATA_HELPER_PATH"
        )
        let launcher = try RecoveryToolLocator.launcherURL()
        return PhysicalQuickRecovery(helper: helper, launcher: launcher)
    }

    private static func makeImageRecovery() throws -> ImageQuickRecovery {
        let resolved = try ImageQuickToolSet.fromEnvironment()
        // GUI, как и раньше, требует лончер для отмены групп процессов.
        let launcher = try resolved.launcher ?? RecoveryToolLocator.launcherURL()
        return ImageQuickRecovery(
            tools: ImageQuickToolSet(
                mmls: resolved.mmls,
                fls: resolved.fls,
                icat: resolved.icat,
                launcher: launcher
            )
        )
    }

    private func makeDeepRecovery(requirePhotorec: Bool) throws -> PhotoRecDeepRecovery {
        // photorec нужен только образному режиму: физический источник
        // обслуживает read-only helper со своим соседним photorec.
        let photorec = requirePhotorec
            ? try RecoveryToolLocator.toolURL(named: "photorec", environmentKey: "RECOVERYAPP_PHOTOREC_PATH")
            : try? RecoveryToolLocator.toolURL(named: "photorec", environmentKey: "RECOVERYAPP_PHOTOREC_PATH")
        // GUI, как и раньше, требует лончер для отмены групп процессов.
        return PhotoRecDeepRecovery(photorec: photorec, launcher: try RecoveryToolLocator.launcherURL())
    }

    // MARK: - Служебное

    private func deepRecoverWithBackend(
        outputFolderURL: URL,
        requirePhotorec: Bool,
        _ run: @escaping @Sendable (PhotoRecDeepRecovery) async throws -> DeepRecoveryResult
    ) async throws -> DeepRecoveryResult {
        let backend = try makeDeepRecovery(requirePhotorec: requirePhotorec)
        replaceDeepRecovery(backend)
        return try await run(backend)
    }

    private func replaceImageRecovery(_ recovery: ImageQuickRecovery) {
        lock.lock()
        imageRecovery = recovery
        lock.unlock()
    }

    private func replaceDeepRecovery(_ recovery: PhotoRecDeepRecovery) {
        lock.lock()
        deepRecovery = recovery
        lock.unlock()
    }
}
