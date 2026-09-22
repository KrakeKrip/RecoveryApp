@preconcurrency import Foundation

public struct DeletedFileCandidate: Identifiable, Hashable, Sendable {
    public let id: String
    public let path: String
    public let inode: String
    public let partitionOffset: Int64
    public let filesystemType: String
    /// Ожидаемый размер из колонки размера `fls -l`; nil, когда источник
    /// размера недоступен (короткий формат или неразбираемая колонка).
    public let expectedSize: Int64?

    public init(
        id: String,
        path: String,
        inode: String,
        partitionOffset: Int64,
        filesystemType: String = "",
        expectedSize: Int64? = nil
    ) {
        self.id = id
        self.path = path
        self.inode = inode
        self.partitionOffset = partitionOffset
        self.filesystemType = filesystemType
        self.expectedSize = expectedSize
    }

    public var displayName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    public var folder: String {
        let value = (path as NSString).deletingLastPathComponent
        return value.isEmpty || value == "." ? "Корень накопителя" : value
    }

    public var typeDescription: String {
        let ext = (displayName as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "Файл" : ext
    }
}

public enum DeletedFilesError: LocalizedError, Equatable {
    case imageMissing
    case imageNotRegularFile
    case invalidDriveSource(String)
    case outputFolderMissing
    case outputFolderNotWritable
    case outputOnSource
    case sourceUnavailable
    case sourceChanged
    case authorizationDenied
    case toolMissing(String)
    case unsupportedImage
    case launchFailed(String)
    case toolFailed(String, Int32)
    case outputSpaceExhausted
    case sourceReadFailed
    case cancelled
    case nothingSelected

    public var errorDescription: String? {
        switch self {
        case .imageMissing:
            "Выбранный образ больше недоступен."
        case .imageNotRegularFile:
            "Выбранный путь не является обычным файлом образа."
        case .invalidDriveSource(let detail):
            "Источник задан неверно: \(detail)."
        case .outputFolderMissing:
            "Папка результата больше недоступна."
        case .outputFolderNotWritable:
            "Нет доступа для записи в папку результата."
        case .outputOnSource:
            "Папка результата находится на исходном накопителе. Выберите другой диск."
        case .sourceUnavailable:
            "Выбранный накопитель отключён. Подключите его и обновите список."
        case .sourceChanged:
            "На месте выбранного накопителя обнаружено другое устройство. Выберите накопитель заново."
        case .authorizationDenied:
            "macOS не предоставила доступ только для чтения. Повторите запуск и подтвердите системный запрос."
        case .toolMissing(let name):
            "Встроенный инструмент \(name) отсутствует или повреждён."
        case .unsupportedImage:
            "Не удалось найти поддерживаемую файловую систему или раздел с удалёнными записями."
        case .launchFailed(let message):
            "Не удалось запустить инструмент: \(message)"
        case .toolFailed(let name, let code):
            "\(name) завершился с кодом \(code). Откройте подробный лог."
        case .outputSpaceExhausted:
            "В папке результата закончилось свободное место."
        case .sourceReadFailed:
            "Накопитель стал недоступен во время чтения. Подключите его заново."
        case .cancelled:
            "Операция остановлена."
        case .nothingSelected:
            "Выберите хотя бы один файл для восстановления."
        }
    }
}

public enum SleuthKitOutputParser {
    public static func deletedFiles(
        from output: String,
        partitionOffset: Int64,
        filesystemType: String = ""
    ) -> [DeletedFileCandidate] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = String(rawLine)
            guard let tab = line.firstIndex(of: "\t") else { return nil }
            let metadata = String(line[..<tab])
            let rest = String(line[line.index(after: tab)...])
            guard metadata.contains("*"), !metadata.hasPrefix("d/d") else { return nil }
            guard let star = metadata.firstIndex(of: "*") else { return nil }
            let afterStar = metadata[metadata.index(after: star)...]
                .trimmingCharacters(in: .whitespaces)
            guard afterStar.hasSuffix(":"), !rest.isEmpty else { return nil }
            let inode = String(afterStar.dropLast())

            // Короткий формат: rest — только имя. Длинный (`fls -l`, минимум
            // 8 колонок): имя, четыре времени, размер, gid, uid — размер
            // всегда третий с конца, поэтому лишние табуляции внутри имени
            // не ломают разбор.
            let columns = rest.split(
                separator: "\t",
                omittingEmptySubsequences: false
            ).map(String.init)
            var path = rest
            var expectedSize: Int64?
            if columns.count >= 8, let size = Int64(columns[columns.count - 3]) {
                expectedSize = size
                path = columns[0..<(columns.count - 7)].joined(separator: "\t")
            }
            guard !path.isEmpty else { return nil }
            return DeletedFileCandidate(
                id: "\(partitionOffset):\(inode):\(path)",
                path: path,
                inode: inode,
                partitionOffset: partitionOffset,
                filesystemType: filesystemType,
                expectedSize: expectedSize
            )
        }
    }

    public static func partitionOffsets(from output: String) -> [Int64] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let fields = rawLine.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 4,
                  fields[0].hasSuffix(":"),
                  fields[1] != "Meta",
                  fields[1] != "-------",
                  let offset = Int64(fields[2]),
                  offset > 0 else { return nil }
            return offset
        }
    }
}

/// Статус соответствия фактического размера результата ожидаемому из
/// метаданных. Совпадение размеров не является побайтной проверкой
/// целостности: метаданные файловой системы могут быть неполными.
public enum RecoveredFileSizeStatus: String, Sendable {
    case expectedEmpty
    case sizeMatches
    case incomplete
    case sizeMismatch
    case sizeUnknown
}

public enum RecoveredFileSizeClassifier {
    public static func status(expectedSize: Int64?, actualSize: Int64) -> RecoveredFileSizeStatus {
        guard let expectedSize else { return .sizeUnknown }
        if expectedSize == 0, actualSize == 0 { return .expectedEmpty }
        if actualSize == expectedSize { return .sizeMatches }
        if actualSize < expectedSize { return .incomplete }
        return .sizeMismatch
    }
}

/// Итог одного опубликованного файла: размерная сверка выполняется после
/// публикации; короткий результат сохраняется и помечается `incomplete`.
public struct RecoveredFileResult: Sendable {
    public let url: URL
    public let expectedSize: Int64?
    public let actualSize: Int64
    public let status: RecoveredFileSizeStatus

    public init(url: URL, expectedSize: Int64?, actualSize: Int64, status: RecoveredFileSizeStatus) {
        self.url = url
        self.expectedSize = expectedSize
        self.actualSize = actualSize
        self.status = status
    }
}

public enum RecoveryToolLocator {
    public static func toolURL(
        named name: String,
        environmentKey: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        if let override = environment[environmentKey] {
            let url = URL(fileURLWithPath: override)
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw DeletedFilesError.toolMissing(name)
            }
            return url
        }
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Tools/\(name)"),
              FileManager.default.isExecutableFile(atPath: url.path) else {
            throw DeletedFilesError.toolMissing(name)
        }
        return url
    }

    public static func launcherURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        try toolURL(named: "tool-launcher", environmentKey: "RECOVERYAPP_TOOL_LAUNCHER_PATH", environment: environment)
    }
}

public struct ImageQuickToolSet: Sendable {
    public let mmls: URL
    public let fls: URL
    public let icat: URL
    /// Лончер создаёт группу процессов для отмены; CLI может работать без него.
    public let launcher: URL?

    public init(mmls: URL, fls: URL, icat: URL, launcher: URL?) {
        self.mmls = mmls
        self.fls = fls
        self.icat = icat
        self.launcher = launcher
    }

    public static func fromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ImageQuickToolSet {
        ImageQuickToolSet(
            mmls: try RecoveryToolLocator.toolURL(named: "mmls", environmentKey: "RECOVERYAPP_MMLS_PATH", environment: environment),
            fls: try RecoveryToolLocator.toolURL(named: "fls", environmentKey: "RECOVERYAPP_FLS_PATH", environment: environment),
            icat: try RecoveryToolLocator.toolURL(named: "icat", environmentKey: "RECOVERYAPP_ICAT_PATH", environment: environment),
            launcher: try? RecoveryToolLocator.launcherURL(environment: environment)
        )
    }
}

/// Быстрый поиск и восстановление удалённых записей из обычного файла-образа
/// через отдельные процессы `fls`, `mmls` и `icat`. Физические накопители и
/// Authorization Services в этот класс не входят.
public final class ImageQuickRecovery: @unchecked Sendable {
    private struct ToolResult {
        let status: Int32
        let terminationReason: Process.TerminationReason
        let output: String
    }

    private let tools: ImageQuickToolSet
    private let lock = NSLock()
    private var process: Process?

    public init(tools: ImageQuickToolSet) {
        self.tools = tools
    }

    public func scan(
        imageURL: URL,
        onOutput: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) async throws -> [DeletedFileCandidate] {
        try Self.validateRegularImage(imageURL)
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { [self] in
                try scanBlocking(imageURL: imageURL, onOutput: onOutput)
            }.value
        } onCancel: { [self] in
            cancel()
        }
    }

    public func recover(
        imageURL: URL,
        outputFolderURL: URL,
        candidates: [DeletedFileCandidate],
        onOutput: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) async throws -> [URL] {
        try await recoverDetailed(
            imageURL: imageURL,
            outputFolderURL: outputFolderURL,
            candidates: candidates,
            onOutput: onOutput
        ).map(\.url)
    }

    /// Детальный восстановительный проход: публикует каждый файл и возвращает
    /// размерную сверку по нему. Короткий результат сохраняется в папке и
    /// помечается `incomplete`; `.partial` удаляется только при ошибке/отмене.
    public func recoverDetailed(
        imageURL: URL,
        outputFolderURL: URL,
        candidates: [DeletedFileCandidate],
        onOutput: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) async throws -> [RecoveredFileResult] {
        guard outputFolderURL.standardizedFileURL.path != imageURL.standardizedFileURL.path else {
            throw DeletedFilesError.outputFolderMissing
        }
        try Self.validateOutputFolder(outputFolderURL)
        try Self.validateRegularImage(imageURL)
        guard !candidates.isEmpty else { throw DeletedFilesError.nothingSelected }
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { [self] in
                try recoverBlocking(
                    imageURL: imageURL,
                    outputFolderURL: outputFolderURL,
                    candidates: candidates,
                    onOutput: onOutput
                )
            }.value
        } onCancel: { [self] in
            cancel()
        }
    }

    public func cancel() {
        lock.lock()
        let runningProcess = process
        lock.unlock()
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

    // MARK: - Алгоритм

    private func scanBlocking(
        imageURL: URL,
        onOutput: @escaping @MainActor @Sendable (String) -> Void
    ) throws -> [DeletedFileCandidate] {
        try checkCancelled()
        emit("Проверка файловой системы без таблицы разделов…\n", onOutput)
        if let direct = try scanFileSystem(imageURL: imageURL, offset: 0) {
            return direct
        }

        try checkCancelled()
        emit("Обнаружение разделов в образе…\n", onOutput)
        let partitions = try runTool(tools.mmls, arguments: [imageURL.path])
        guard partitions.status == 0 else { throw DeletedFilesError.unsupportedImage }
        let offsets = SleuthKitOutputParser.partitionOffsets(from: partitions.output)
        guard !offsets.isEmpty else { throw DeletedFilesError.unsupportedImage }

        var found: [DeletedFileCandidate] = []
        var recognizedFileSystem = false
        for offset in offsets {
            try checkCancelled()
            emit("Проверка раздела со смещением \(offset) секторов…\n", onOutput)
            if let result = try scanFileSystem(imageURL: imageURL, offset: offset) {
                recognizedFileSystem = true
                found.append(contentsOf: result)
            }
        }
        guard recognizedFileSystem else { throw DeletedFilesError.unsupportedImage }
        return Array(Set(found)).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func scanFileSystem(
        imageURL: URL,
        offset: Int64
    ) throws -> [DeletedFileCandidate]? {
        for filesystemType in ["fat32", "exfat"] {
            var arguments = ["-f", filesystemType, "-l", "-r", "-d", "-p"]
            if offset > 0 {
                arguments += ["-o", String(offset)]
            }
            arguments.append(imageURL.path)
            let result = try runTool(tools.fls, arguments: arguments)
            if result.status == 0 {
                return SleuthKitOutputParser.deletedFiles(
                    from: result.output,
                    partitionOffset: offset,
                    filesystemType: filesystemType
                )
            }
        }
        return nil
    }

    private func recoverBlocking(
        imageURL: URL,
        outputFolderURL: URL,
        candidates: [DeletedFileCandidate],
        onOutput: @escaping @MainActor @Sendable (String) -> Void
    ) throws -> [RecoveredFileResult] {
        var results: [RecoveredFileResult] = []
        for (index, candidate) in candidates.enumerated() {
            try checkCancelled()
            let resultURL = Self.uniqueResultURL(
                suggestedName: candidate.displayName,
                folder: outputFolderURL
            )
            let partialURL = resultURL.appendingPathExtension("partial")
            FileManager.default.createFile(atPath: partialURL.path, contents: nil)
            let outputHandle = try FileHandle(forWritingTo: partialURL)
            defer { try? outputHandle.close() }

            emit("[\(index + 1)/\(candidates.count)] \(candidate.path)\n", onOutput)
            var arguments = ["-r"]
            if candidate.partitionOffset > 0 {
                arguments += ["-o", String(candidate.partitionOffset)]
            }
            arguments += [imageURL.path, candidate.inode]

            do {
                let result = try runTool(
                    tools.icat,
                    arguments: arguments,
                    standardOutput: outputHandle
                )
                try outputHandle.synchronize()
                try outputHandle.close()
                guard result.status == 0 else {
                    try? FileManager.default.removeItem(at: partialURL)
                    if result.terminationReason == .uncaughtSignal {
                        throw DeletedFilesError.cancelled
                    }
                    try Self.classifyToolOutput(result.output, outputFolderURL: outputFolderURL)
                    throw DeletedFilesError.toolFailed("icat", result.status)
                }
                try FileManager.default.moveItem(at: partialURL, to: resultURL)
                // Код 0 от icat не гарантирует полноту: сверяем фактический
                // размер с ожидаемым из метаданных и помечаем результат.
                let actualSize = (try? FileManager.default.attributesOfItem(
                    atPath: resultURL.path
                )[.size] as? Int64) ?? 0
                let status = RecoveredFileSizeClassifier.status(
                    expectedSize: candidate.expectedSize,
                    actualSize: actualSize
                )
                results.append(RecoveredFileResult(
                    url: resultURL,
                    expectedSize: candidate.expectedSize,
                    actualSize: actualSize,
                    status: status
                ))
            } catch {
                try? FileManager.default.removeItem(at: partialURL)
                throw error
            }
        }
        return results
    }

    // MARK: - Запуск инструментов

    private func runTool(
        _ tool: URL,
        arguments: [String],
        standardOutput: FileHandle? = nil
    ) throws -> ToolResult {
        let launchedProcess = Process()
        let combinedPipe = Pipe()
        let errorPipe = Pipe()
        if let launcher = tools.launcher {
            launchedProcess.executableURL = launcher
            launchedProcess.arguments = [tool.path] + arguments
        } else {
            launchedProcess.executableURL = tool
            launchedProcess.arguments = arguments
        }
        if let standardOutput {
            launchedProcess.standardOutput = standardOutput
            launchedProcess.standardError = errorPipe
        } else {
            launchedProcess.standardOutput = combinedPipe
            launchedProcess.standardError = combinedPipe
        }
        launchedProcess.standardInput = FileHandle.nullDevice

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

    // MARK: - Общие проверки и безопасные имена

    public static func validateRegularImage(
        _ url: URL,
        fileManager: FileManager = .default
    ) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw DeletedFilesError.imageMissing
        }
        guard !isDirectory.boolValue else { throw DeletedFilesError.imageNotRegularFile }
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            throw DeletedFilesError.imageNotRegularFile
        }
    }

    public static func validateOutputFolder(
        _ url: URL,
        fileManager: FileManager = .default
    ) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw DeletedFilesError.outputFolderMissing }
        guard fileManager.isWritableFile(atPath: url.path) else {
            throw DeletedFilesError.outputFolderNotWritable
        }
    }

    public static func classifyToolOutput(
        _ output: String,
        outputFolderURL: URL
    ) throws {
        let value = output.lowercased()
        if value.contains("no space left") || value.contains("enospc") ||
            value.contains("недостаточно места") {
            throw DeletedFilesError.outputSpaceExhausted
        }
        try validateOutputFolder(outputFolderURL)
        if value.contains("no such device") || value.contains("device not configured") ||
            value.contains("input/output error") || value.contains("i/o error") {
            throw DeletedFilesError.sourceReadFailed
        }
    }

    /// Убирает из имени, полученного из `fls`, возможность выйти за пределы
    /// папки результата: разделители путей и особые имена `.`/`..`.
    public static func safeResultName(_ raw: String) -> String {
        let name = raw
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        return name.isEmpty || name == "." || name == ".." ? "recovered_file" : name
    }

    public static func uniqueResultURL(
        suggestedName: String,
        folder: URL,
        fileManager: FileManager = .default
    ) -> URL {
        let original = safeResultName(suggestedName)
        let ext = (original as NSString).pathExtension
        let stem = (original as NSString).deletingPathExtension
        var candidate = folder.appendingPathComponent(original)
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(stem)_\(index)" : "\(stem)_\(index).\(ext)"
            candidate = folder.appendingPathComponent(name)
            index += 1
        }
        return candidate
    }
}
