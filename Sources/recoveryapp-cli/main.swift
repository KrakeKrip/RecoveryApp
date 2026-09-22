import Foundation
import RecoveryCore

let cliArguments = Array(CommandLine.arguments.dropFirst())

func writeErrorLine(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    print(String(decoding: data, as: UTF8.self))
}

/// Пользовательские пути приводятся к абсолютным: контракт JSON требует
/// абсолютные source/outputDirectory.
func absoluteFileURL(_ path: String) -> URL {
    let url = URL(fileURLWithPath: path)
    guard !path.hasPrefix("/") else { return url.standardizedFileURL }
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    return cwd.appendingPathComponent(path).standardizedFileURL
}

func makeImageRecovery() throws -> ImageQuickRecovery {
    ImageQuickRecovery(tools: try ImageQuickToolSet.fromEnvironment())
}

func makePhysicalRecovery() throws -> PhysicalQuickRecovery {
    let helper = try RecoveryToolLocator.toolURL(
        named: "recoveryapp-metadata-helper",
        environmentKey: "RECOVERYAPP_METADATA_HELPER_PATH"
    )
    return PhysicalQuickRecovery(helper: helper, launcher: try? RecoveryToolLocator.launcherURL())
}

// MARK: - deep recover: общий PhotoRec-бэкенд Core, прогресс и Ctrl-C

/// Состояние одного запуска deep recover: задача восстановления для
/// обработчика Ctrl-C, папка сессии и скорость чтения по реальным измерениям.
private final class DeepRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var recoveryTask: Task<DeepRecoveryResult, Error>?
    private var interrupted = false
    private var sessionURL: URL?
    private var lastProcessedBytes: Int64?
    private var lastMeasurementDate: Date?
    private var smoothedSpeed: Double?

    var isInterrupted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return interrupted
    }

    /// Ctrl-C до создания задачи не должен теряться: регистрация отменяет.
    func register(_ task: Task<DeepRecoveryResult, Error>) {
        lock.lock()
        recoveryTask = task
        let alreadyInterrupted = interrupted
        lock.unlock()
        if alreadyInterrupted { task.cancel() }
    }

    func interrupt() {
        lock.lock()
        interrupted = true
        let task = recoveryTask
        lock.unlock()
        task?.cancel()
    }

    func currentSessionURL() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return sessionURL
    }

    func setSessionURL(_ url: URL) {
        lock.lock()
        sessionURL = url
        lock.unlock()
    }

    /// Скорость только по фактам: два последовательных снимка с выросшим
    /// processedBytes. Без измерений — nil, нулём не подменяется.
    func observedSpeed(processedBytes: Int64?, at date: Date) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let processedBytes else { return nil }
        defer {
            lastProcessedBytes = processedBytes
            lastMeasurementDate = date
        }
        guard let previousBytes = lastProcessedBytes,
              let previousDate = lastMeasurementDate,
              processedBytes > previousBytes else { return nil }
        let interval = date.timeIntervalSince(previousDate)
        guard interval > 0 else { return nil }
        let instant = Double(processedBytes - previousBytes) / interval
        let smoothed = smoothedSpeed.map { $0 * 0.65 + instant * 0.35 } ?? instant
        smoothedSpeed = smoothed
        return smoothed
    }
}

/// Обработчики SIGINT/SIGTERM: handler не делает ничего тяжёлого, только
/// отменяет задачу восстановления; далее общий backend останавливает группу
/// PhotoRec/helper через marker-файл или сигнал по группе.
private func installDeepInterruptHandlers(_ fire: @escaping @Sendable () -> Void) {
    for signalNumber in [SIGINT, SIGTERM] {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(
            signal: signalNumber,
            queue: DispatchQueue.global(qos: .userInitiated)
        )
        source.setEventHandler { fire() }
        source.resume()
        // Источники должны жить до конца процесса.
        deepSignalSources.append(source)
    }
}

// Источники должны жить до конца процесса; заполняются один раз при старте.
nonisolated(unsafe) private var deepSignalSources: [DispatchSourceSignal] = []

/// Побайтовый формат для текстового прогресса, как в GUI.
private func deepFormattedBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

private func deepFormattedElapsed(_ seconds: TimeInterval) -> String {
    let total = Int(seconds)
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
    return String(format: "%d:%02d", minutes, secs)
}

private func deepHumanProgress(
    snapshot: PhotoRecProgressSnapshot,
    elapsed: TimeInterval,
    speed: Double?
) -> String {
    var parts = ["Прошло \(deepFormattedElapsed(elapsed))"]
    if let processed = snapshot.processedBytes,
       let total = snapshot.totalBytes,
       total > 0 {
        parts.append("прочитано \(deepFormattedBytes(processed)) из \(deepFormattedBytes(total))")
    }
    if let speed, speed > 0 {
        parts.append("\(deepFormattedBytes(Int64(speed)))/с")
    }
    parts.append("найдено файлов: \(snapshot.fileCount)")
    if snapshot.resultBytes > 0 {
        parts.append("результат \(deepFormattedBytes(snapshot.resultBytes))")
    }
    return parts.joined(separator: " • ") + "\n"
}

private func isDeepCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let deletedError = error as? DeletedFilesError, deletedError == .cancelled { return true }
    return false
}

/// Уже найденные PhotoRec файлы в папке сессии — для события cancelled.
/// Папка сессии при отмене не удаляется.
private func deepCancelledFiles(sessionURL: URL?) -> [URL] {
    guard let sessionURL else { return [] }
    let baseURL = sessionURL.appendingPathComponent("Recovered")
    let directories = (try? PhotoRecDeepRecovery.photoRecOutputDirectories(baseURL: baseURL)) ?? []
    return directories.flatMap { PhotoRecDeepRecovery.regularFilesRecursively(in: $0) }
}

private enum ResolvedDeepSource {
    case image(URL)
    case drive(ExternalDrive, ReadOnlyAuthorization, URL)
}

/// Глубокое восстановление: запуск PhotoRec через общий backend Core,
/// потоковый JSONL или русский текст, Ctrl-C с кодом 130.
private func runDeepRecover(
    source: QuickSource,
    output: String,
    jsonl: Bool
) async -> Int32 {
    let outputURL = absoluteFileURL(output)
    let startedAt = Date()
    let state = DeepRunState()
    let emitter = DeepEventEmitter(jsonl: jsonl)

    // 1. Разрешение источника и preflight папки результата до всякого
    //    запуска процессов и до Authorization Services.
    let resolved: ResolvedDeepSource
    do {
        switch source {
        case .image(let image):
            let imageURL = absoluteFileURL(image)
            try ImageQuickRecovery.validateRegularImage(imageURL)
            try ImageQuickRecovery.validateOutputFolder(outputURL)
            resolved = .image(imageURL)
        case .drive(let identifier, let expectedName, let expectedSize):
            let discovered = try await ExternalDriveDiscovery().load()
            let drive = try PhysicalDriveSelector.selectDrive(
                identifier: identifier,
                expectedName: expectedName,
                expectedSize: expectedSize,
                from: discovered
            )
            try PhysicalQuickRecovery.preflightRecoveryOutput(outputFolderURL: outputURL, drive: drive)
            // Одна сессия авторизации на команду; системный запрос происходит
            // здесь, один раз, после успешной сверки источника и папки.
            let authorization = try ReadOnlyAuthorization(device: drive.rawDevicePath)
            let helper = try RecoveryToolLocator.toolURL(
                named: "recoveryapp-readonly-helper",
                environmentKey: "RECOVERYAPP_READONLY_HELPER_PATH"
            )
            resolved = .drive(drive, authorization, helper)
        }
    } catch {
        emitter.jsonLine(DeepErrorEvent(
            code: deepErrorCode(for: error),
            message: error.localizedDescription
        ))
        if !jsonl { emitter.diagnostic("Ошибка: \(error.localizedDescription)\n") }
        return 1
    }

    let photorec: URL?
    switch resolved {
    case .image:
        // Лончер делает дочерний процесс лидером своей группы: без него
        // безопасная отмена группы невозможна.
        photorec = try? RecoveryToolLocator.toolURL(
            named: "photorec",
            environmentKey: "RECOVERYAPP_PHOTOREC_PATH"
        )
        if photorec == nil {
            let error = DeletedFilesError.toolMissing("photorec")
            emitter.jsonLine(DeepErrorEvent(
                code: deepErrorCode(for: error),
                message: error.localizedDescription
            ))
            if !jsonl { emitter.diagnostic("Ошибка: \(error.localizedDescription)\n") }
            return 1
        }
    case .drive:
        photorec = nil
    }
    let launcher = try? RecoveryToolLocator.launcherURL()
    let backend = PhotoRecDeepRecovery(photorec: photorec, launcher: launcher)

    let sourceReport: DeepSourceReport
    switch resolved {
    case .image(let imageURL):
        sourceReport = .image(path: imageURL.path)
    case .drive(let drive, _, _):
        sourceReport = .drive(
            id: drive.id,
            name: drive.name,
            size: drive.size,
            rawDevicePath: drive.rawDevicePath
        )
    }

    installDeepInterruptHandlers { [state] in state.interrupt() }

    // 2. Задача восстановления; события started/progress/completed/cancelled.
    let recoveryTask = Task<DeepRecoveryResult, Error> { [emitter] in
        let onSessionReady: @MainActor @Sendable (URL) -> Void = { url in
            state.setSessionURL(url)
            emitter.jsonLine(DeepStartedEvent(
                source: sourceReport,
                sessionDirectory: url.path
            ))
        }
        switch resolved {
        case .drive(let drive, let authorization, let helper):
            return try await backend.recover(
                drive: drive,
                authorization: authorization,
                outputFolderURL: outputURL,
                helper: helper,
                onSessionReady: onSessionReady,
                onOutput: { text in emitter.diagnostic(text) }
            )
        case .image(let imageURL):
            return try await backend.recover(
                imageURL: imageURL,
                outputFolderURL: outputURL,
                onSessionReady: onSessionReady,
                onOutput: { text in emitter.diagnostic(text) }
            )
        }
    }
    state.register(recoveryTask)

    // 3. Живой прогресс по фактическим метрикам каждые 2 секунды.
    let progressPump = Task.detached(priority: .utility) { [emitter] in
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { break }
            guard let session = state.currentSessionURL() else { continue }
            let snapshot = PhotoRecDeepRecovery.progressSnapshot(at: session)
            let now = Date()
            let speed = state.observedSpeed(processedBytes: snapshot.processedBytes, at: now)
            if jsonl {
                emitter.jsonLine(DeepProgressEvent(
                    elapsedSeconds: (now.timeIntervalSince(startedAt) * 10).rounded() / 10,
                    foundFiles: snapshot.fileCount,
                    resultBytes: snapshot.resultBytes,
                    processedBytes: snapshot.processedBytes,
                    totalBytes: snapshot.totalBytes,
                    readBytesPerSecond: speed
                ))
            } else {
                emitter.diagnostic(deepHumanProgress(
                    snapshot: snapshot,
                    elapsed: now.timeIntervalSince(startedAt),
                    speed: speed
                ))
            }
        }
    }

    // 4. Итог: completed (код 0), cancelled (код 130) или error (код 1).
    let result: DeepRecoveryResult
    do {
        result = try await recoveryTask.value
    } catch {
        progressPump.cancel()
        if isDeepCancellation(error) {
            let files = deepCancelledFiles(sessionURL: state.currentSessionURL())
            emitter.jsonLine(DeepCancelledEvent(
                sessionDirectory: state.currentSessionURL()?.path,
                foundFiles: files.count,
                files: files.map(\.path)
            ))
            if !jsonl {
                if let session = state.currentSessionURL() {
                    emitter.textLine("Операция остановлена. Найдено файлов: \(files.count), они сохранены в папке сессии: \(session.path)")
                } else {
                    emitter.textLine("Операция остановлена.")
                }
            }
            return 130
        }
        emitter.jsonLine(DeepErrorEvent(
            code: deepErrorCode(for: error),
            message: error.localizedDescription
        ))
        if !jsonl { emitter.diagnostic("Ошибка: \(error.localizedDescription)\n") }
        return 1
    }
    progressPump.cancel()
    emitter.jsonLine(DeepCompletedEvent(
        sessionDirectory: result.outputDirectory.path,
        recoveredCount: result.recoveredFiles.count,
        files: result.recoveredFiles.map(\.path)
    ))
    if !jsonl {
        emitter.textLine("Глубокий поиск завершён. PhotoRec создал файлов: \(result.recoveredFiles.count).")
        emitter.textLine("Папка сессии: \(result.outputDirectory.path)")
    }
    return 0
}

/// Вывод машинных событий и диагностики deep recover. stdout в режиме --jsonl
/// содержит только по одному валидному JSON-объекту на строку; запись через
/// FileHandle сохраняет потоковый вывод при длительной операции.
private final class DeepEventEmitter: @unchecked Sendable {
    private let jsonl: Bool

    init(jsonl: Bool) {
        self.jsonl = jsonl
    }

    func jsonLine<T: Encodable>(_ value: T) {
        guard jsonl else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    func diagnostic(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    func textLine(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }
}

/// Технический прогресс физического режима — в stderr, stdout остаётся чистым.
let progressToStderr: @MainActor @Sendable (String) -> Void = { text in
    FileHandle.standardError.write(Data(text.utf8))
}

func printCandidates(_ candidates: [DeletedFileCandidate]) {
    if candidates.isEmpty {
        print("Удалённые файлы не найдены.")
        return
    }
    print("Найдено удалённых файлов: \(candidates.count).")
    for candidate in candidates {
        let offset = candidate.partitionOffset > 0
            ? "смещение \(candidate.partitionOffset)"
            : "без таблицы разделов"
        let size = candidate.expectedSize != nil
            ? ", ожидаемый размер \(candidate.expectedSize!)"
            : ", размер неизвестен"
        print("  [\(candidate.filesystemType), \(offset)\(size)] \(candidate.path)")
    }
}

func printRecoveryOutcome(_ results: [RecoveredFileResult]) {
    print("Восстановлено файлов: \(results.count).")
    for result in results {
        print("  [\(result.status.rawValue)] \(result.url.path)")
    }
    let incomplete = results.filter { $0.status == .incomplete }
    let mismatched = results.filter { $0.status == .sizeMismatch }
    let unknown = results.filter { $0.status == .sizeUnknown }
    if !incomplete.isEmpty {
        print("Внимание: \(incomplete.count) извлечены не полностью — фактический размер меньше ожидаемого из метаданных.")
    }
    if !mismatched.isEmpty {
        print("Внимание: \(mismatched.count) файл(ов) больше ожидаемого размера из метаданных.")
    }
    if !unknown.isEmpty {
        print("Размер источника неизвестен для \(unknown.count) файл(ов) — размерная сверка невозможна.")
    }
    print("Совпадение размеров не является проверкой целостности содержимого.")
}

/// Пустой результат скана — нормальный код 0: проверки папки и источника
/// выполняются, восстановление не запускается, JSON отдаёт пустой отчёт.
func printEmptyRecovery(json: Bool, outputDirectory: String) throws {
    if json {
        try printJSON(QuickRecoverReport(outputDirectory: outputDirectory, results: []))
    } else {
        print("Удалённые файлы не найдены — восстанавливать нечего.")
    }
}

do {
    switch try CommandLineParser.parse(cliArguments) {
    case .help:
        print(CommandLineHelp.usage)
    case .version(let json):
        if json {
            try printJSON(
                VersionReport(
                    schemaVersion: 1,
                    appVersion: ProductInfo.appVersion,
                    build: ProductInfo.build
                )
            )
        } else {
            print("RecoveryApp \(ProductInfo.appVersion), сборка \(ProductInfo.build)")
        }
    case .drivesList(let json):
        let drives = try await ExternalDriveDiscovery().load()
        if json {
            try printJSON(DrivesReport(schemaVersion: 1, drives: drives.map { DriveReport($0) }))
        } else if drives.isEmpty {
            print("Внешние накопители не найдены.")
        } else {
            print("Внешние накопители:")
            for drive in drives {
                print("  \(drive.cliSummaryLine)")
            }
        }
    case .quickScan(let source, let json):
        switch source {
        case .image(let image):
            let imageURL = absoluteFileURL(image)
            let candidates = try await makeImageRecovery().scan(imageURL: imageURL)
            if json {
                try printJSON(QuickScanReport(
                    schemaVersion: 1,
                    source: imageURL.path,
                    candidates: candidates.map { QuickCandidateReport($0) }
                ))
            } else {
                printCandidates(candidates)
            }
        case .drive(let identifier, let expectedName, let expectedSize):
            // Повторное обнаружение и сверка id/имени/размера выполняются
            // до Authorization Services.
            let discovered = try await ExternalDriveDiscovery().load()
            let drive = try PhysicalDriveSelector.selectDrive(
                identifier: identifier,
                expectedName: expectedName,
                expectedSize: expectedSize,
                from: discovered
            )
            let candidates = try await makePhysicalRecovery().scan(
                drive: drive,
                onOutput: progressToStderr
            )
            if json {
                try printJSON(PhysicalQuickScanReport(
                    schemaVersion: 1,
                    drive: DriveIdentityReport(drive),
                    candidates: candidates.map { QuickCandidateReport($0) }
                ))
            } else {
                print("Накопитель: \(drive.id) · \(drive.name) — \(drive.rawDevicePath).")
                printCandidates(candidates)
            }
        }
    case .quickRecover(let source, let output, let json):
        let outputURL = absoluteFileURL(output)
        switch source {
        case .image(let image):
            let imageURL = absoluteFileURL(image)
            let recovery = try makeImageRecovery()
            let candidates = try await recovery.scan(imageURL: imageURL)
            if candidates.isEmpty {
                // Пустой результат — нормальный код 0; папка результата всё
                // равно проверяется до отчёта.
                try ImageQuickRecovery.validateOutputFolder(outputURL)
                try printEmptyRecovery(json: json, outputDirectory: outputURL.path)
            } else {
                let results = try await recovery.recoverDetailed(
                    imageURL: imageURL,
                    outputFolderURL: outputURL,
                    candidates: candidates
                )
                if json {
                    try printJSON(QuickRecoverReport(
                        outputDirectory: outputURL.path,
                        results: results
                    ))
                } else {
                    printRecoveryOutcome(results)
                }
            }
        case .drive(let identifier, let expectedName, let expectedSize):
            // Повторное обнаружение и сверка — до Authorization Services;
            // preflight папки результата — до создания сессии и скана.
            // Один экземпляр PhysicalQuickRecovery держит одну сессию
            // для scan и всех icat этой команды.
            let discovered = try await ExternalDriveDiscovery().load()
            let drive = try PhysicalDriveSelector.selectDrive(
                identifier: identifier,
                expectedName: expectedName,
                expectedSize: expectedSize,
                from: discovered
            )
            try PhysicalQuickRecovery.preflightRecoveryOutput(
                outputFolderURL: outputURL,
                drive: drive
            )
            let recovery = try makePhysicalRecovery()
            let candidates = try await recovery.scan(drive: drive, onOutput: progressToStderr)
            let results: [RecoveredFileResult] = candidates.isEmpty
                ? []
                : try await recovery.recoverDetailed(
                    drive: drive,
                    outputFolderURL: outputURL,
                    candidates: candidates,
                    onOutput: progressToStderr
                )
            if json {
                try printJSON(QuickRecoverReport(
                    outputDirectory: outputURL.path,
                    results: results
                ))
            } else if results.isEmpty {
                print("Удалённые файлы не найдены — восстанавливать нечего.")
            } else {
                printRecoveryOutcome(results)
            }
        }
    case .deepRecover(let source, let output, let jsonl):
        // Глубокий режим сам управляет кодами выхода: 0 успех, 1 ошибка,
        // 130 остановка по Ctrl-C.
        exit(await runDeepRecover(source: source, output: output, jsonl: jsonl))
    }
} catch let error as CLIUsageError {
    writeErrorLine(CommandLineHelp.description(for: error))
    writeErrorLine(CommandLineHelp.usage)
    exit(2)
} catch {
    writeErrorLine("Ошибка: \(error.localizedDescription)")
    exit(1)
}
