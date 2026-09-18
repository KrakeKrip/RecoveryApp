@preconcurrency import Foundation
import Security

/// Удерживает Authorization Services сессию живой, пока authopen не поглотил
/// внешнюю форму прав. Раннее освобождение AuthorizationRef отзывает права и
/// приводит ко второму системному запросу пароля.
public final class ReadOnlyAuthorization: @unchecked Sendable {
    public let externalForm: Data
    private let reference: AuthorizationRef

    public init(device: String) throws {
        var authorization: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &authorization) == errAuthorizationSuccess,
              let authorization else {
            throw DeletedFilesError.authorizationDenied
        }

        reference = authorization
        let rightName = "sys.openfile.readonly.\(device)"
        let status = rightName.withCString { name in
            var item = AuthorizationItem(
                name: name,
                valueLength: 0,
                value: nil,
                flags: 0
            )
            return withUnsafeMutablePointer(to: &item) { itemPointer in
                var rights = AuthorizationRights(count: 1, items: itemPointer)
                let flags: AuthorizationFlags = [
                    .interactionAllowed,
                    .extendRights,
                    .preAuthorize
                ]
                return AuthorizationCopyRights(
                    authorization,
                    &rights,
                    nil,
                    flags,
                    nil
                )
            }
        }
        guard status == errAuthorizationSuccess else {
            AuthorizationFree(authorization, [])
            throw DeletedFilesError.authorizationDenied
        }

        var external = AuthorizationExternalForm()
        guard AuthorizationMakeExternalForm(authorization, &external) == errAuthorizationSuccess else {
            AuthorizationFree(authorization, [])
            throw DeletedFilesError.authorizationDenied
        }
        externalForm = withUnsafeBytes(of: &external) { Data($0) }
    }

    deinit {
        AuthorizationFree(reference, [])
    }
}

/// Выбор и сверка диска по уже полученному снимку `[ExternalDrive]`:
/// без diskutil и без системной авторизации — для тестируемости.
public enum PhysicalDriveSelector {
    public static func isValidDriveIdentifier(_ value: String) -> Bool {
        guard value.hasPrefix("disk") else { return false }
        let suffix = value.dropFirst(4)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }

    public static func selectDrive(
        identifier: String,
        expectedName: String,
        expectedSize: Int64,
        from drives: [ExternalDrive]
    ) throws -> ExternalDrive {
        guard isValidDriveIdentifier(identifier) else {
            throw DeletedFilesError.invalidDriveSource(
                "идентификатор \(identifier); разрешается disk с номером, например disk4"
            )
        }
        guard expectedSize > 0 else {
            throw DeletedFilesError.invalidDriveSource("ожидаемый размер должен быть положительным числом")
        }
        guard let drive = drives.first(where: { $0.id == identifier }) else {
            throw DeletedFilesError.sourceUnavailable
        }
        guard drive.name == expectedName else {
            throw DeletedFilesError.sourceChanged
        }
        guard drive.size == expectedSize else {
            throw DeletedFilesError.sourceChanged
        }
        return drive
    }
}

/// Быстрый поиск и восстановление удалённых записей с физического внешнего
/// накопителя через существующую безопасную цепочку: Authorization Services →
/// authopen O_RDONLY → metadata helper (проверка O_RDONLY и размера) →
/// `/dev/fd/0` → `mmls`/`fls`/`icat`. Один экземпляр класса держит одну
/// авторизационную сессию и переиспользует её внешнюю форму для всех вызовов
/// helper: команда scan+recover создаёт ровно один системный запрос.
public final class PhysicalQuickRecovery: @unchecked Sendable {
    private struct ToolResult {
        let status: Int32
        let terminationReason: Process.TerminationReason
        let output: String
    }

    private let helper: URL
    private let launcher: URL?
    private let lock = NSLock()
    private var process: Process?
    private var authorization: ReadOnlyAuthorization?

    public init(helper: URL, launcher: URL?) {
        self.helper = helper
        self.launcher = launcher
    }

    public func scan(
        drive: ExternalDrive,
        onOutput: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) async throws -> [DeletedFileCandidate] {
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { [self] in
                try scanBlocking(drive: drive, onOutput: onOutput)
            }.value
        } onCancel: { [self] in
            cancel()
        }
    }

    public func recover(
        drive: ExternalDrive,
        outputFolderURL: URL,
        candidates: [DeletedFileCandidate],
        onOutput: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) async throws -> [URL] {
        // Второй защитный барьер: те же проверки выхода непосредственно перед
        // восстановлением; CLI выполняет их же раньше — до Authorization
        // Services — через preflightRecoveryOutput.
        try Self.preflightRecoveryOutput(outputFolderURL: outputFolderURL, drive: drive)
        guard !candidates.isEmpty else { throw DeletedFilesError.nothingSelected }
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { [self] in
                try recoverBlocking(
                    drive: drive,
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
        drive: ExternalDrive,
        onOutput: @escaping @MainActor @Sendable (String) -> Void
    ) throws -> [DeletedFileCandidate] {
        try checkCancelled()
        let common = [drive.rawDevicePath, String(drive.size)]
        emit("Источник: \(drive.displayName) (\(drive.rawDevicePath), только чтение).\n", onOutput)
        emit("Проверка файловой системы без таблицы разделов…\n", onOutput)
        if let direct = try scanFileSystem(
            device: drive.rawDevicePath,
            commonArguments: common,
            offset: 0
        ) {
            return direct
        }

        try checkCancelled()
        emit("Обнаружение разделов на накопителе…\n", onOutput)
        let partitions = try runTool(
            helper,
            arguments: ["mmls"] + common,
            standardInput: try obtainAuthorization(device: drive.rawDevicePath).externalForm
        )
        if partitions.status != 0, !partitions.output.isEmpty {
            emit("Технические сведения mmls:\n\(partitions.output)\n", onOutput)
        }
        try mapHelperFailure(partitions, allowToolFailure: false)
        let offsets = SleuthKitOutputParser.partitionOffsets(from: partitions.output)
        guard !offsets.isEmpty else { throw DeletedFilesError.unsupportedImage }

        var found: [DeletedFileCandidate] = []
        var recognizedFileSystem = false
        for offset in offsets {
            try checkCancelled()
            emit("Проверка раздела со смещением \(offset) секторов…\n", onOutput)
            if let result = try scanFileSystem(
                device: drive.rawDevicePath,
                commonArguments: common,
                offset: offset
            ) {
                recognizedFileSystem = true
                found.append(contentsOf: result)
            }
        }
        guard recognizedFileSystem else { throw DeletedFilesError.unsupportedImage }
        return Array(Set(found)).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func scanFileSystem(
        device: String,
        commonArguments: [String],
        offset: Int64
    ) throws -> [DeletedFileCandidate]? {
        for filesystemType in ["fat32", "exfat"] {
            let result = try runTool(
                helper,
                arguments: ["fls"] + commonArguments + [String(offset), filesystemType],
                standardInput: try obtainAuthorization(device: device).externalForm
            )
            if result.status == 0 {
                return SleuthKitOutputParser.deletedFiles(
                    from: result.output,
                    partitionOffset: offset,
                    filesystemType: filesystemType
                )
            }
            try mapHelperFailure(result)
        }
        return nil
    }

    private func recoverBlocking(
        drive: ExternalDrive,
        outputFolderURL: URL,
        candidates: [DeletedFileCandidate],
        onOutput: @escaping @MainActor @Sendable (String) -> Void
    ) throws -> [URL] {
        var results: [URL] = []
        for (index, candidate) in candidates.enumerated() {
            try checkCancelled()
            let resultURL = ImageQuickRecovery.uniqueResultURL(
                suggestedName: candidate.displayName,
                folder: outputFolderURL
            )
            let partialURL = resultURL.appendingPathExtension("partial")
            FileManager.default.createFile(atPath: partialURL.path, contents: nil)
            let outputHandle = try FileHandle(forWritingTo: partialURL)
            defer { try? outputHandle.close() }
            emit("[\(index + 1)/\(candidates.count)] \(candidate.path)\n", onOutput)
            do {
                let result = try runTool(
                    helper,
                    arguments: [
                        "icat", drive.rawDevicePath, String(drive.size), outputFolderURL.path,
                        String(candidate.partitionOffset), candidate.inode, candidate.filesystemType
                    ],
                    standardOutput: outputHandle,
                    standardInput: try obtainAuthorization(device: drive.rawDevicePath).externalForm
                )
                try outputHandle.synchronize()
                try outputHandle.close()
                try ImageQuickRecovery.classifyToolOutput(result.output, outputFolderURL: outputFolderURL)
                try mapHelperFailure(result, toolName: "icat", allowToolFailure: false)
                try FileManager.default.moveItem(at: partialURL, to: resultURL)
                results.append(resultURL)
            } catch {
                try? FileManager.default.removeItem(at: partialURL)
                throw error
            }
        }
        return results
    }

    /// Preflight папки результата до Authorization Services: папка существует,
    /// является каталогом, доступна для записи и не лежит в точках монтирования
    /// исходного диска. Только файловая система и снимок диска — никакого
    /// системного запроса; вызывается CLI/GUI до создания сессии и скана,
    /// recover повторяет те же проверки как второй барьер.
    public static func preflightRecoveryOutput(
        outputFolderURL: URL,
        drive: ExternalDrive,
        fileManager: FileManager = .default
    ) throws {
        try ImageQuickRecovery.validateOutputFolder(outputFolderURL, fileManager: fileManager)
        guard !drive.contains(outputFolderURL) else {
            throw DeletedFilesError.outputOnSource
        }
    }

    /// Сессия создаётся лениво при первом обращении к helper и живёт на
    /// экземпляре: scan и все icat одной команды разделяют один системный
    /// запрос. Повторное создание для того же диска не выполняется.
    private func obtainAuthorization(device: String) throws -> ReadOnlyAuthorization {
        lock.lock()
        let existing = authorization
        lock.unlock()
        if let existing { return existing }
        let created = try ReadOnlyAuthorization(device: device)
        lock.lock()
        if let existing = authorization {
            lock.unlock()
            return existing
        }
        authorization = created
        lock.unlock()
        return created
    }

    private func mapHelperFailure(
        _ result: ToolResult,
        toolName: String = "Sleuth Kit",
        allowToolFailure: Bool = true
    ) throws {
        if result.status == 0 { return }
        if result.status == 77 { throw DeletedFilesError.authorizationDenied }
        if result.status == 74 { throw DeletedFilesError.sourceChanged }
        if result.status == 73 { throw DeletedFilesError.outputOnSource }
        if result.status == 130 || result.terminationReason == .uncaughtSignal || Task.isCancelled {
            throw DeletedFilesError.cancelled
        }
        if !allowToolFailure { throw DeletedFilesError.toolFailed(toolName, result.status) }
    }

    // MARK: - Запуск процессов

    private func runTool(
        _ tool: URL,
        arguments: [String],
        standardOutput: FileHandle? = nil,
        standardInput: Data? = nil
    ) throws -> ToolResult {
        let launchedProcess = Process()
        let combinedPipe = Pipe()
        let errorPipe = Pipe()
        if let launcher {
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
}
