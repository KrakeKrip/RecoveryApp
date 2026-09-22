@preconcurrency import Foundation
import Darwin
import RecoveryCore

/// Тонкий GUI-адаптер над RecoveryCore. Все алгоритмы живут в Core:
/// быстрые режимы — в `ImageQuickRecovery` и `PhysicalQuickRecovery`,
/// глубокий PhotoRec — в `PhotoRecDeepRecovery` (общий с CLI). Здесь только
/// выбор инструментов и сохранение прежних пользовательских callbacks.
final class DeletedFilesExecutor: @unchecked Sendable {
    private let lock = NSLock()
    private var imageRecovery: ImageQuickRecovery?
    private var physicalRecovery: PhysicalQuickRecovery?
    private var deepRecovery: PhotoRecDeepRecovery?

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
        let recovery = try Self.makePhysicalRecovery()
        replacePhysicalRecovery(recovery)
        return try await recovery.scan(drive: drive, onOutput: onOutput)
    }

    func recover(
        imageURL: URL,
        outputFolderURL: URL,
        candidates: [DeletedFileCandidate],
        onOutput: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> [URL] {
        let recovery = try Self.makeImageRecovery()
        replaceImageRecovery(recovery)
        return try await recovery.recover(
            imageURL: imageURL,
            outputFolderURL: outputFolderURL,
            candidates: candidates,
            onOutput: onOutput
        )
    }

    func recover(
        drive: ExternalDrive,
        outputFolderURL: URL,
        candidates: [DeletedFileCandidate],
        onOutput: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> [URL] {
        guard !candidates.isEmpty else { throw DeletedFilesError.nothingSelected }
        let recovery = try Self.makePhysicalRecovery()
        replacePhysicalRecovery(recovery)
        return try await recovery.recover(
            drive: drive,
            outputFolderURL: outputFolderURL,
            candidates: candidates,
            onOutput: onOutput
        )
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
        try ImageQuickRecovery.validateOutputFolder(outputFolderURL)
        guard !drive.contains(outputFolderURL) else {
            throw DeletedFilesError.outputOnSource
        }
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
        let activePhysicalRecovery = physicalRecovery
        lock.unlock()
        activeDeepRecovery?.cancel()
        activeImageRecovery?.cancel()
        activePhysicalRecovery?.cancel()
    }

    // MARK: - Инструменты

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

    private static func makePhysicalRecovery() throws -> PhysicalQuickRecovery {
        let helper = try RecoveryToolLocator.toolURL(
            named: "recoveryapp-metadata-helper",
            environmentKey: "RECOVERYAPP_METADATA_HELPER_PATH"
        )
        let launcher = try RecoveryToolLocator.launcherURL()
        return PhysicalQuickRecovery(helper: helper, launcher: launcher)
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
        try ImageQuickRecovery.validateOutputFolder(outputFolderURL)
        let backend = try makeDeepRecovery(requirePhotorec: requirePhotorec)
        replaceDeepRecovery(backend)
        return try await run(backend)
    }

    private func replaceImageRecovery(_ recovery: ImageQuickRecovery) {
        lock.lock()
        imageRecovery = recovery
        lock.unlock()
    }

    private func replacePhysicalRecovery(_ recovery: PhysicalQuickRecovery) {
        lock.lock()
        physicalRecovery = recovery
        lock.unlock()
    }

    private func replaceDeepRecovery(_ recovery: PhotoRecDeepRecovery) {
        lock.lock()
        deepRecovery = recovery
        lock.unlock()
    }
}
