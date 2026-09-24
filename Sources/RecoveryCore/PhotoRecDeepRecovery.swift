@preconcurrency import Foundation

/// Итог одной сессии глубокого восстановления PhotoRec. Общий тип для GUI и
/// CLI: папка сессии сохраняется при отмене, найденные файлы перечисляются в
/// каталогах `Recovered.*` внутри неё.
public struct DeepRecoveryResult: Sendable {
    public let outputDirectory: URL
    public let recoveredFiles: [URL]

    public init(outputDirectory: URL, recoveredFiles: [URL]) {
        self.outputDirectory = outputDirectory
        self.recoveredFiles = recoveredFiles
    }
}

/// Снимок фактического прогресса PhotoRec по файлам сессии: число найденных
/// файлов, объём результата, размер журнала и счётчики чтения. Значения,
/// которые пока нельзя достоверно определить, остаются `nil`, а не нулём.
public struct PhotoRecProgressSnapshot: Sendable, Equatable {
    public let fileCount: Int
    public let resultBytes: Int64
    public let logSize: Int64
    public let processedBytes: Int64?
    public let totalBytes: Int64?

    public static let empty = PhotoRecProgressSnapshot(
        fileCount: 0,
        resultBytes: 0,
        logSize: 0,
        processedBytes: nil,
        totalBytes: nil
    )

    public init(
        fileCount: Int,
        resultBytes: Int64,
        logSize: Int64,
        processedBytes: Int64?,
        totalBytes: Int64?
    ) {
        self.fileCount = fileCount
        self.resultBytes = resultBytes
        self.logSize = logSize
        self.processedBytes = processedBytes
        self.totalBytes = totalBytes
    }
}

/// Общий PhotoRec-бэкенд глубокого восстановления для GUI и CLI. Владеет
/// запуском PhotoRec/readonly-helper, уникальной папкой сессии, поиском
/// результатов, снимками прогресса и отменой. Источник не открывается
/// напрямую: образ читает PhotoRec, физический накопитель — только
/// существующий read-only helper через переданную авторизационную сессию.
public final class PhotoRecDeepRecovery: @unchecked Sendable {
    private struct ToolResult {
        let status: Int32
        let terminationReason: Process.TerminationReason
        let output: String
    }

    private let photorec: URL?
    private let launcher: URL?
    private let lock = NSLock()
    private var process: Process?
    private var cancellationMarkerURL: URL?
    /// Запрос отмены запоминается навсегда: он мог прийти до запуска
    /// дочернего процесса или в окне между регистрацией Process и run(),
    /// когда отменять ещё нечего. Экземпляр одноразовый: после cancel()
    /// следующий recover на нём не запускает процессы.
    private var cancellationRequested = false

    /// `photorec` требуется только образному режиму: физический источник
    /// обслуживает read-only helper, запускающий photorec из своей папки.
    public init(photorec: URL?, launcher: URL?) {
        self.photorec = photorec
        self.launcher = launcher
    }

    // MARK: - Запуск восстановления

    /// Глубокий поиск по обычному файлу-образу. PhotoRec запускается с рабочей
    /// папкой сессии, чтобы `photorec.ses` не появлялся в каталоге вызывающего
    /// процесса.
    public func recover(
        imageURL: URL,
        outputFolderURL: URL,
        onSessionReady: @escaping @MainActor @Sendable (URL) -> Void = { _ in },
        onOutput: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) async throws -> DeepRecoveryResult {
        try ImageQuickRecovery.validateOutputFolder(outputFolderURL)
        try ImageQuickRecovery.validateRegularImage(imageURL)
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { [self] in
                try recoverImageBlocking(
                    imageURL: imageURL,
                    outputFolderURL: outputFolderURL,
                    onSessionReady: onSessionReady,
                    onOutput: onOutput
                )
            }.value
        } onCancel: { [self] in
            cancel()
        }
    }

    /// Глубокий поиск по физическому накопителю через существующий
    /// recoveryapp-readonly-helper: helper проверяет O_RDONLY, фактический
    /// размер и запрет результата на источнике, запускает PhotoRec без root и
    /// останавливает дочернюю группу по marker-файлу. Авторизация создаётся
    /// снаружи до этого вызова и передаётся одной сессией.
    public func recover(
        drive: ExternalDrive,
        authorization: ReadOnlyAuthorization,
        outputFolderURL: URL,
        helper: URL,
        onSessionReady: @escaping @MainActor @Sendable (URL) -> Void = { _ in },
        onOutput: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) async throws -> DeepRecoveryResult {
        try PhysicalQuickRecovery.preflightRecoveryOutput(
            outputFolderURL: outputFolderURL,
            drive: drive
        )
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { [self] in
                try recoverDriveBlocking(
                    drive: drive,
                    authorization: authorization,
                    outputFolderURL: outputFolderURL,
                    helper: helper,
                    onSessionReady: onSessionReady,
                    onOutput: onOutput
                )
            }.value
        } onCancel: { [self] in
            cancel()
        }
    }

    /// Отмена: запрос запоминается, поэтому не теряется, даже если придёт до
    /// запуска дочернего процесса или между регистрацией Process и run().
    /// Для физического источника ставится marker-файл, который read-only
    /// helper обрабатывает сам и останавливает всю группу PhotoRec; для
    /// образа группа процессов PhotoRec останавливается сигналами. Уже
    /// найденные файлы и папка сессии не удаляются.
    public func cancel() {
        lock.lock()
        cancellationRequested = true
        let runningProcess = process
        let markerURL = cancellationMarkerURL
        let usesLauncher = launcher != nil
        lock.unlock()
        if let markerURL {
            _ = FileManager.default.createFile(
                atPath: markerURL.path,
                contents: Data()
            )
            scheduleMarkerRetry()
            return
        }
        guard let runningProcess, runningProcess.isRunning else { return }
        let pid = runningProcess.processIdentifier
        if usesLauncher {
            // Лончер делает дочерний процесс лидером собственной группы,
            // поэтому сигнал по группе не задевает вызывающий процесс.
            if kill(-pid, SIGTERM) != 0 { kill(pid, SIGTERM) }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) {
                if kill(-pid, 0) == 0 {
                    kill(-pid, SIGKILL)
                } else if kill(pid, 0) == 0 {
                    kill(pid, SIGKILL)
                }
            }
        } else {
            kill(pid, SIGTERM)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) {
                if kill(pid, 0) == 0 {
                    kill(pid, SIGKILL)
                }
            }
        }
    }

    /// helper стирает stop-файл до входа в свой цикл проверки (у raw-устройства
    /// между запуском и этим стиранием работает authopen). Если запрос отмены
    /// пришёл в этом окне, marker мог быть проглочен. Пока helper работает и
    /// отмена запрошена, marker создаётся заново каждые полсекунды; после
    /// завершения helper (`process == nil`) цепочка обрывается.
    private func scheduleMarkerRetry() {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) { [self] in
            lock.lock()
            let requested = cancellationRequested
            let markerURL = cancellationMarkerURL
            let running = process?.isRunning == true
            lock.unlock()
            guard requested, running, let markerURL else { return }
            _ = FileManager.default.createFile(
                atPath: markerURL.path,
                contents: Data()
            )
            scheduleMarkerRetry()
        }
    }

    // MARK: - Алгоритм

    private func recoverImageBlocking(
        imageURL: URL,
        outputFolderURL: URL,
        onSessionReady: @escaping @MainActor @Sendable (URL) -> Void,
        onOutput: @escaping @MainActor @Sendable (String) -> Void
    ) throws -> DeepRecoveryResult {
        try checkCancelled()
        guard let photorec else {
            throw DeletedFilesError.toolMissing("photorec")
        }
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
            ],
            workingDirectory: sessionURL
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

        return try collectResult(sessionURL: sessionURL, baseURL: baseURL, onOutput: onOutput)
    }

    private func recoverDriveBlocking(
        drive: ExternalDrive,
        authorization: ReadOnlyAuthorization,
        outputFolderURL: URL,
        helper: URL,
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
            // runTool уже завершился, значит helper вышел и сам удалил свой
            // stop-файл; здесь убирается только «висящий» marker, созданный
            // cancel() в окне до запуска helper.
            try? FileManager.default.removeItem(at: markerURL)
        }

        emit("Источник: \(drive.displayName) (\(drive.rawDevicePath), только чтение).\n", onOutput)
        emit("macOS может запросить пароль администратора для read-only доступа.\n", onOutput)
        let result = try runTool(
            helper,
            arguments: [drive.rawDevicePath, sessionURL.path, String(drive.size)],
            workingDirectory: sessionURL,
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
        return try collectResult(sessionURL: sessionURL, baseURL: baseURL, onOutput: onOutput)
    }

    private func collectResult(
        sessionURL: URL,
        baseURL: URL,
        onOutput: @escaping @MainActor @Sendable (String) -> Void
    ) throws -> DeepRecoveryResult {
        // Пустой результат — нормальный исход: PhotoRec завершился без находок.
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

    // MARK: - Снимки прогресса

    /// Фактический прогресс по файлам сессии: найденные файлы, объём
    /// результата, размер журнала и счётчики чтения из `.recoveryapp-progress`
    /// (пишет read-only helper) и `photorec.ses`. Недоступные значения
    /// остаются `nil`; расчёт один для GUI и CLI.
    public static func progressSnapshot(
        at sessionURL: URL,
        fileManager: FileManager = .default
    ) -> PhotoRecProgressSnapshot {
        let logURL = sessionURL.appendingPathComponent("photorec.log")
        let progressURL = sessionURL.appendingPathComponent(".recoveryapp-progress")
        let logSize = ((try? fileManager.attributesOfItem(atPath: logURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
        let extensions = Set(["jpg", "jpeg", "png", "mov", "mp4"])
        var fileCount = 0
        var resultBytes: Int64 = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        if let enumerator = fileManager.enumerator(
            at: sessionURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator where extensions.contains(url.pathExtension.lowercased()) {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                    continue
                }
                fileCount += 1
                resultBytes += Int64(values.fileSize ?? 0)
            }
        }
        let progressValues = progressFileValues(at: progressURL)
        let sessionProcessed = progressValues.flatMap { values in
            photoRecSessionProcessedBytes(
                at: sessionURL.appendingPathComponent("photorec.ses"),
                totalBytes: values.total
            )
        }
        let processedBytes = [progressValues?.processed, sessionProcessed]
            .compactMap { $0 }
            .max()
        return PhotoRecProgressSnapshot(
            fileCount: fileCount,
            resultBytes: resultBytes,
            logSize: logSize,
            processedBytes: processedBytes,
            totalBytes: progressValues?.total
        )
    }

    /// Обработанный объём из `photorec.ses`: blocksize умножается на начало
    /// последнего непрочитанного диапазона. Диапазоны без надёжного blocksize
    /// игнорируются — нулём значение не подменяется.
    public static func photoRecSessionProcessedBytes(at url: URL, totalBytes: Int64) -> Int64? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline)
        guard let headerIndex = lines.firstIndex(where: { $0.contains("blocksize,") }) else { return nil }
        let header = lines[headerIndex]
        let headerFields = header.split(separator: ",")
        guard let blocksizeIndex = headerFields.firstIndex(of: "blocksize"),
              headerFields.indices.contains(blocksizeIndex + 1),
              let blockSize = Int64(headerFields[blocksizeIndex + 1]),
              blockSize > 0 else { return nil }

        var lastRemainingStart: Int64?
        var largestEnd: Int64 = -1
        for line in lines.dropFirst(headerIndex + 1) {
            let bounds = line.split(separator: "-", maxSplits: 1)
            guard bounds.count == 2,
                  let start = Int64(bounds[0]),
                  let end = Int64(bounds[1]),
                  start >= 0,
                  end >= start else { continue }
            if end > largestEnd {
                largestEnd = end
                lastRemainingStart = start
            }
        }
        guard let start = lastRemainingStart else { return nil }
        let processed = start.multipliedReportingOverflow(by: blockSize)
        guard !processed.overflow else { return nil }
        return min(totalBytes, processed.partialValue)
    }

    /// Значения `.recoveryapp-progress`; файл без корректной версии или
    /// несогласованных счётчиков считается отсутствующим.
    public static func progressFileValues(at url: URL) -> (processed: Int64, total: Int64)? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var values: [String: Int64] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let pieces = line.split(separator: "=", maxSplits: 1).map(String.init)
            if pieces.count == 2, let number = Int64(pieces[1]) {
                values[pieces[0]] = number
            }
        }
        guard values["version"] == 1,
              let processed = values["processed"],
              let total = values["total"],
              processed >= 0,
              total > 0,
              processed <= total else { return nil }
        return (processed, total)
    }

    // MARK: - Каталоги результатов

    public static func photoRecOutputDirectory(
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

    public static func photoRecOutputDirectories(
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

    public static func regularFilesRecursively(
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

    // MARK: - Запуск процессов

    private func runTool(
        _ tool: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        standardInput: Data? = nil
    ) throws -> ToolResult {
        let launchedProcess = Process()
        let combinedPipe = Pipe()
        if let launcher {
            // Лончер делает дочерний процесс лидером собственной группы:
            // отмена сигналом по группе не задевает вызывающий процесс.
            launchedProcess.executableURL = launcher
            launchedProcess.arguments = [tool.path] + arguments
        } else {
            launchedProcess.executableURL = tool
            launchedProcess.arguments = arguments
        }
        launchedProcess.currentDirectoryURL = workingDirectory
        launchedProcess.standardOutput = combinedPipe
        launchedProcess.standardError = combinedPipe
        let inputPipe = standardInput == nil ? nil : Pipe()
        launchedProcess.standardInput = inputPipe ?? FileHandle.nullDevice

        lock.lock()
        // Чтение запроса отмены под той же блокировкой, что и регистрация:
        // запрос до этого момента запрещает сам запуск.
        let cancellationWasRequested = cancellationRequested
        process = launchedProcess
        lock.unlock()
        defer {
            lock.lock()
            process = nil
            lock.unlock()
        }

        // Ранний Ctrl-C: запрос запомнен cancel(), дочерний процесс не нужен.
        if cancellationWasRequested {
            throw DeletedFilesError.cancelled
        }

        do {
            try launchedProcess.run()
        } catch {
            throw DeletedFilesError.launchFailed(error.localizedDescription)
        }
        // Окно между регистрацией Process и run(): отмена могла прийти, когда
        // отменять ещё было нечего. Гасим только что запущенный процесс; его
        // гибель от сигнала доходит до вызывающего кода как обычная отмена.
        lock.lock()
        let cancellationArrivedDuringLaunch = cancellationRequested
        lock.unlock()
        if cancellationArrivedDuringLaunch {
            cancel()
        }
        if let standardInput, let inputPipe {
            inputPipe.fileHandleForWriting.write(standardInput)
            try? inputPipe.fileHandleForWriting.close()
        }
        // Drain the pipe while the child is still running. Waiting first can
        // deadlock when the tool produces more output than the pipe buffer holds.
        let data = combinedPipe.fileHandleForReading.readDataToEndOfFile()
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
}
