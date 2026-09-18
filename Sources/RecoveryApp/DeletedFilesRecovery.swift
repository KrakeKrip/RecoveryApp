@preconcurrency import Foundation
import Darwin
import RecoveryCore

struct DeepRecoveryResult: Sendable {
    let outputDirectory: URL
    let recoveredFiles: [URL]
}

/// Режимы физического накопителя и глубокого поиска PhotoRec. Быстрые режимы
/// (образ и физический накопитель) живут в RecoveryCore
/// (`ImageQuickRecovery`, `PhysicalQuickRecovery`) и отсюда только
/// делегируются, чтобы GUI и CLI не имели двух копий алгоритмов.
final class DeletedFilesExecutor: @unchecked Sendable {
    private struct ToolResult {
        let status: Int32
        let terminationReason: Process.TerminationReason
        let output: String
    }

    private let lock = NSLock()
    private var process: Process?
    private var cancellationMarkerURL: URL?
    private var imageRecovery: ImageQuickRecovery?
    private var physicalRecovery: PhysicalQuickRecovery?

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
        try ImageQuickRecovery.validateOutputFolder(outputFolderURL)
        guard FileManager.default.fileExists(atPath: imageURL.path) else {
            throw DeletedFilesError.imageMissing
        }
        let photorec = try RecoveryToolLocator.toolURL(
            named: "photorec",
            environmentKey: "RECOVERYAPP_PHOTOREC_PATH"
        )

        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { [self] in
                try deepRecoverBlocking(
                    imageURL: imageURL,
                    outputFolderURL: outputFolderURL,
                    photorec: photorec,
                    onSessionReady: onSessionReady,
                    onOutput: onOutput
                )
            }.value
        } onCancel: { [self] in
            cancel()
        }
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

        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { [self] in
                try deepRecoverDriveBlocking(
                    drive: drive,
                    outputFolderURL: outputFolderURL,
                    helper: helper,
                    authorization: authorization,
                    onSessionReady: onSessionReady,
                    onOutput: onOutput
                )
            }.value
        } onCancel: { [self] in
            cancel()
        }
    }

    func cancel() {
        lock.lock()
        let runningProcess = process
        let cancellationMarkerURL = cancellationMarkerURL
        let activeImageRecovery = imageRecovery
        let activePhysicalRecovery = physicalRecovery
        lock.unlock()
        activeImageRecovery?.cancel()
        activePhysicalRecovery?.cancel()
        if let cancellationMarkerURL {
            _ = FileManager.default.createFile(
                atPath: cancellationMarkerURL.path,
                contents: Data()
            )
            return
        }
        guard let runningProcess, runningProcess.isRunning else { return }
        let pid = runningProcess.processIdentifier
        if kill(-pid, SIGTERM) != 0 { kill(pid, SIGTERM) }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) {
            if kill(-pid, 0) == 0 {
                kill(-pid, SIGKILL)
            } else if kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
        }
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

    private static func makePhysicalRecovery() throws -> PhysicalQuickRecovery {
        let helper = try RecoveryToolLocator.toolURL(
            named: "recoveryapp-metadata-helper",
            environmentKey: "RECOVERYAPP_METADATA_HELPER_PATH"
        )
        let launcher = try RecoveryToolLocator.launcherURL()
        return PhysicalQuickRecovery(helper: helper, launcher: launcher)
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

    private func deepRecoverBlocking(
        imageURL: URL,
        outputFolderURL: URL,
        photorec: URL,
        onSessionReady: @escaping @MainActor @Sendable (URL) -> Void,
        onOutput: @escaping @MainActor @Sendable (String) -> Void
    ) throws -> DeepRecoveryResult {
        try checkCancelled()
        let sessionURL = ImageQuickRecovery.uniqueResultURL(
            suggestedName: "PhotoRec-Recovery",
            folder: outputFolderURL
        )
        try FileManager.default.createDirectory(
            at: sessionURL,
            withIntermediateDirectories: false
        )
        notifySessionReady(sessionURL, onSessionReady)
        let baseURL = sessionURL.appendingPathComponent("Recovered")
        let logURL = sessionURL.appendingPathComponent("photorec.log")
        emit("PhotoRec сканирует весь образ по сигнатурам JPEG, PNG и MOV/MP4. Исходные имена и папки не сохраняются.\n", onOutput)

        let result = try runTool(
            photorec,
            arguments: [
                "/log", "/logname", logURL.path,
                "/d", baseURL.path,
                "/cmd", imageURL.path,
                "partition_none,fileopt,everything,disable,jpg,enable,png,enable,mov,enable,search"
            ]
        )
        if !result.output.isEmpty {
            emit(LogSanitizer.photoRecSummary(result.output) + "\n", onOutput)
        }
        if result.terminationReason == .uncaughtSignal || Task.isCancelled {
            throw DeletedFilesError.cancelled
        }
        try ImageQuickRecovery.classifyToolOutput(result.output, outputFolderURL: outputFolderURL)
        guard result.status == 0 else {
            throw DeletedFilesError.toolFailed("PhotoRec", result.status)
        }

        let outputDirectories = try Self.photoRecOutputDirectories(
            baseURL: baseURL,
            fileManager: .default
        )
        guard !outputDirectories.isEmpty else {
            throw DeletedFilesError.toolFailed("PhotoRec", 0)
        }
        let recoveredFiles = outputDirectories.flatMap {
            Self.regularFilesRecursively(in: $0, fileManager: .default)
        }
        emit("PhotoRec создал файлов: \(recoveredFiles.count).\n", onOutput)
        return DeepRecoveryResult(
            outputDirectory: sessionURL,
            recoveredFiles: recoveredFiles
        )
    }

    private func deepRecoverDriveBlocking(
        drive: ExternalDrive,
        outputFolderURL: URL,
        helper: URL,
        authorization: ReadOnlyAuthorization,
        onSessionReady: @escaping @MainActor @Sendable (URL) -> Void,
        onOutput: @escaping @MainActor @Sendable (String) -> Void
    ) throws -> DeepRecoveryResult {
        try checkCancelled()
        let sessionURL = ImageQuickRecovery.uniqueResultURL(
            suggestedName: "RecoveryApp-восстановление",
            folder: outputFolderURL
        )
        try FileManager.default.createDirectory(
            at: sessionURL,
            withIntermediateDirectories: false
        )
        notifySessionReady(sessionURL, onSessionReady)
        let markerURL = sessionURL.appendingPathComponent(".recoveryapp-stop")
        lock.lock()
        cancellationMarkerURL = markerURL
        lock.unlock()
        defer {
            lock.lock()
            cancellationMarkerURL = nil
            lock.unlock()
        }

        emit("Источник: \(drive.displayName) (\(drive.rawDevicePath), только чтение).\n", onOutput)
        emit("macOS может запросить пароль администратора для read-only доступа.\n", onOutput)
        let result = try runTool(
            helper,
            arguments: [drive.rawDevicePath, sessionURL.path, String(drive.size)],
            standardInput: authorization.externalForm
        )
        if !result.output.isEmpty {
            emit(LogSanitizer.photoRecSummary(result.output) + "\n", onOutput)
        }
        if result.status == 130 || Task.isCancelled {
            throw DeletedFilesError.cancelled
        }
        if result.status == 77 {
            throw DeletedFilesError.authorizationDenied
        }
        if result.status == 74 {
            throw DeletedFilesError.sourceChanged
        }
        if result.terminationReason == .uncaughtSignal {
            throw DeletedFilesError.cancelled
        }
        try ImageQuickRecovery.classifyToolOutput(result.output, outputFolderURL: outputFolderURL)
        guard result.status == 0 else {
            throw DeletedFilesError.toolFailed("PhotoRec", result.status)
        }

        let baseURL = sessionURL.appendingPathComponent("Recovered")
        let outputDirectories = try Self.photoRecOutputDirectories(
            baseURL: baseURL,
            fileManager: .default
        )
        let recoveredFiles = outputDirectories.flatMap {
            Self.regularFilesRecursively(in: $0, fileManager: .default)
        }
        emit("PhotoRec создал файлов: \(recoveredFiles.count).\n", onOutput)
        return DeepRecoveryResult(
            outputDirectory: sessionURL,
            recoveredFiles: recoveredFiles
        )
    }

    private func runTool(
        _ tool: URL,
        arguments: [String],
        standardOutput: FileHandle? = nil,
        standardInput: Data? = nil
    ) throws -> ToolResult {
        let launcher = try RecoveryToolLocator.launcherURL()
        let launchedProcess = Process()
        let combinedPipe = Pipe()
        let errorPipe = Pipe()
        launchedProcess.executableURL = launcher
        launchedProcess.arguments = [tool.path] + arguments
        if let standardOutput {
            launchedProcess.standardOutput = standardOutput
            launchedProcess.standardError = errorPipe
        } else {
            launchedProcess.standardOutput = combinedPipe
            launchedProcess.standardError = combinedPipe
        }
        let inputPipe = standardInput == nil ? nil : Pipe()
        launchedProcess.standardInput = inputPipe ?? FileHandle.nullDevice

        lock.lock()
        process = launchedProcess
        lock.unlock()
        defer {
            lock.lock()
            process = nil
            lock.unlock()
        }

        do {
            try launchedProcess.run()
        } catch {
            throw DeletedFilesError.launchFailed(error.localizedDescription)
        }
        if let standardInput, let inputPipe {
            inputPipe.fileHandleForWriting.write(standardInput)
            try? inputPipe.fileHandleForWriting.close()
        }
        // Drain the pipe while the child is still running. Waiting first can
        // deadlock when fls produces more output than the pipe buffer holds.
        let data = standardOutput == nil
            ? combinedPipe.fileHandleForReading.readDataToEndOfFile()
            : errorPipe.fileHandleForReading.readDataToEndOfFile()
        launchedProcess.waitUntilExit()
        return ToolResult(
            status: launchedProcess.terminationStatus,
            terminationReason: launchedProcess.terminationReason,
            output: String(decoding: data, as: UTF8.self)
        )
    }

    private func checkCancelled() throws {
        if Task.isCancelled { throw DeletedFilesError.cancelled }
    }

    private func emit(
        _ text: String,
        _ callback: @escaping @MainActor @Sendable (String) -> Void
    ) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await callback(text)
            semaphore.signal()
        }
        semaphore.wait()
    }

    private func notifySessionReady(
        _ url: URL,
        _ callback: @escaping @MainActor @Sendable (URL) -> Void
    ) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await callback(url)
            semaphore.signal()
        }
        semaphore.wait()
    }

    static func photoRecOutputDirectory(
        baseURL: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let result = try photoRecOutputDirectories(
            baseURL: baseURL,
            fileManager: fileManager
        ).last else {
            throw DeletedFilesError.toolFailed("PhotoRec", 0)
        }
        return result
    }

    static func photoRecOutputDirectories(
        baseURL: URL,
        fileManager: FileManager = .default
    ) throws -> [URL] {
        let parent = baseURL.deletingLastPathComponent()
        let prefix = baseURL.lastPathComponent + "."
        let directories = try fileManager.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            url.lastPathComponent.hasPrefix(prefix) &&
                ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
        }
        return directories.sorted { left, right in
            let leftNumber = Int(left.lastPathComponent.dropFirst(prefix.count)) ?? 0
            let rightNumber = Int(right.lastPathComponent.dropFirst(prefix.count)) ?? 0
            return leftNumber < rightNumber
        }
    }

    static func regularFilesRecursively(
        in directory: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { return nil }
            return url
        }
    }
}
