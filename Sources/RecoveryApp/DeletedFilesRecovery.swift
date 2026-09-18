@preconcurrency import Foundation
import Darwin
import Security

struct DeletedFileCandidate: Identifiable, Hashable, Sendable {
    let id: String
    let path: String
    let inode: String
    let partitionOffset: Int64
    let filesystemType: String

    init(
        id: String,
        path: String,
        inode: String,
        partitionOffset: Int64,
        filesystemType: String = ""
    ) {
        self.id = id
        self.path = path
        self.inode = inode
        self.partitionOffset = partitionOffset
        self.filesystemType = filesystemType
    }

    var displayName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    var folder: String {
        let value = (path as NSString).deletingLastPathComponent
        return value.isEmpty || value == "." ? "Корень накопителя" : value
    }

    var typeDescription: String {
        let ext = (displayName as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "Файл" : ext
    }
}

struct DeepRecoveryResult: Sendable {
    let outputDirectory: URL
    let recoveredFiles: [URL]
}

enum DeletedFilesError: LocalizedError, Equatable {
    case imageMissing
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

    var errorDescription: String? {
        switch self {
        case .imageMissing:
            "Выбранный образ больше недоступен."
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
            "Операция остановлена. Уже готовые файлы сохранены."
        case .nothingSelected:
            "Выберите хотя бы один файл для восстановления."
        }
    }
}

enum SleuthKitOutputParser {
    static func deletedFiles(
        from output: String,
        partitionOffset: Int64,
        filesystemType: String = ""
    ) -> [DeletedFileCandidate] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = String(rawLine)
            guard let tab = line.firstIndex(of: "\t") else { return nil }
            let metadata = String(line[..<tab])
            let path = String(line[line.index(after: tab)...])
            guard metadata.contains("*"), !metadata.hasPrefix("d/d") else { return nil }
            guard let star = metadata.firstIndex(of: "*") else { return nil }
            let afterStar = metadata[metadata.index(after: star)...]
                .trimmingCharacters(in: .whitespaces)
            guard afterStar.hasSuffix(":"), !path.isEmpty else { return nil }
            let inode = String(afterStar.dropLast())
            return DeletedFileCandidate(
                id: "\(partitionOffset):\(inode):\(path)",
                path: path,
                inode: inode,
                partitionOffset: partitionOffset,
                filesystemType: filesystemType
            )
        }
    }

    static func partitionOffsets(from output: String) -> [Int64] {
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

final class DeletedFilesExecutor: @unchecked Sendable {
    private struct ToolResult {
        let status: Int32
        let terminationReason: Process.TerminationReason
        let output: String
    }

    /// Keeps the Authorization Services session alive until authopen has
    /// consumed its external form. Releasing the AuthorizationRef earlier
    /// revokes the credentials associated with this process and makes
    /// authopen display a second authentication dialog.
    private final class ReadOnlyAuthorization: @unchecked Sendable {
        let externalForm: Data
        private let reference: AuthorizationRef

        init(device: String) throws {
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

    private let lock = NSLock()
    private var process: Process?
    private var cancellationMarkerURL: URL?

    func scan(
        imageURL: URL,
        onOutput: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> [DeletedFileCandidate] {
        guard FileManager.default.fileExists(atPath: imageURL.path) else {
            throw DeletedFilesError.imageMissing
        }
        let fls = try Self.toolURL(named: "fls", environmentKey: "RECOVERYAPP_FLS_PATH")
        let mmls = try Self.toolURL(named: "mmls", environmentKey: "RECOVERYAPP_MMLS_PATH")

        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { [self] in
                try scanBlocking(imageURL: imageURL, fls: fls, mmls: mmls, onOutput: onOutput)
            }.value
        } onCancel: { [self] in
            cancel()
        }
    }

    func scan(
        drive: ExternalDrive,
        onOutput: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> [DeletedFileCandidate] {
        let authorization = try ReadOnlyAuthorization(device: drive.rawDevicePath)
        let helper = try Self.toolURL(
            named: "recoveryapp-metadata-helper",
            environmentKey: "RECOVERYAPP_METADATA_HELPER_PATH"
        )
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { [self] in
                try scanDriveBlocking(
                    drive: drive,
                    helper: helper,
                    authorization: authorization,
                    onOutput: onOutput
                )
            }.value
        } onCancel: { [self] in
            cancel()
        }
    }

    func recover(
        imageURL: URL,
        outputFolderURL: URL,
        candidates: [DeletedFileCandidate],
        onOutput: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> [URL] {
        guard !candidates.isEmpty else { throw DeletedFilesError.nothingSelected }
        try Self.validateOutputFolder(outputFolderURL)
        guard FileManager.default.fileExists(atPath: imageURL.path) else {
            throw DeletedFilesError.imageMissing
        }
        let icat = try Self.toolURL(named: "icat", environmentKey: "RECOVERYAPP_ICAT_PATH")

        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { [self] in
                try recoverBlocking(
                    imageURL: imageURL,
                    outputFolderURL: outputFolderURL,
                    candidates: candidates,
                    icat: icat,
                    onOutput: onOutput
                )
            }.value
        } onCancel: { [self] in
            cancel()
        }
    }

    func recover(
        drive: ExternalDrive,
        outputFolderURL: URL,
        candidates: [DeletedFileCandidate],
        onOutput: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> [URL] {
        guard !candidates.isEmpty else { throw DeletedFilesError.nothingSelected }
        try Self.validateOutputFolder(outputFolderURL)
        guard !drive.contains(outputFolderURL) else { throw DeletedFilesError.outputOnSource }
        let authorization = try ReadOnlyAuthorization(device: drive.rawDevicePath)
        let helper = try Self.toolURL(
            named: "recoveryapp-metadata-helper",
            environmentKey: "RECOVERYAPP_METADATA_HELPER_PATH"
        )
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { [self] in
                try recoverDriveBlocking(
                    drive: drive,
                    outputFolderURL: outputFolderURL,
                    candidates: candidates,
                    helper: helper,
                    authorization: authorization,
                    onOutput: onOutput
                )
            }.value
        } onCancel: { [self] in
            cancel()
        }
    }

    func deepRecover(
        imageURL: URL,
        outputFolderURL: URL,
        onSessionReady: @escaping @MainActor @Sendable (URL) -> Void = { _ in },
        onOutput: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> DeepRecoveryResult {
        try Self.validateOutputFolder(outputFolderURL)
        guard FileManager.default.fileExists(atPath: imageURL.path) else {
            throw DeletedFilesError.imageMissing
        }
        let photorec = try Self.toolURL(
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
        try Self.validateOutputFolder(outputFolderURL)
        guard !drive.contains(outputFolderURL) else {
            throw DeletedFilesError.outputOnSource
        }
        let authorization = try ReadOnlyAuthorization(device: drive.rawDevicePath)
        let helper = try Self.toolURL(
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
        lock.unlock()
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

    private func scanBlocking(
        imageURL: URL,
        fls: URL,
        mmls: URL,
        onOutput: @escaping @MainActor @Sendable (String) -> Void
    ) throws -> [DeletedFileCandidate] {
        try checkCancelled()
        emit("Проверка файловой системы без таблицы разделов…\n", onOutput)
        let direct = try runTool(fls, arguments: ["-r", "-d", "-p", imageURL.path])
        if direct.status == 0 {
            return SleuthKitOutputParser.deletedFiles(from: direct.output, partitionOffset: 0)
        }

        try checkCancelled()
        emit("Обнаружение разделов в образе…\n", onOutput)
        let partitions = try runTool(mmls, arguments: [imageURL.path])
        guard partitions.status == 0 else { throw DeletedFilesError.unsupportedImage }
        let offsets = SleuthKitOutputParser.partitionOffsets(from: partitions.output)
        guard !offsets.isEmpty else { throw DeletedFilesError.unsupportedImage }

        var found: [DeletedFileCandidate] = []
        var recognizedFileSystem = false
        for offset in offsets {
            try checkCancelled()
            emit("Проверка раздела со смещением \(offset) секторов…\n", onOutput)
            let result = try runTool(
                fls,
                arguments: ["-o", String(offset), "-r", "-d", "-p", imageURL.path]
            )
            if result.status == 0 {
                recognizedFileSystem = true
                found.append(contentsOf: SleuthKitOutputParser.deletedFiles(
                    from: result.output,
                    partitionOffset: offset
                ))
            }
        }
        guard recognizedFileSystem else { throw DeletedFilesError.unsupportedImage }
        return Array(Set(found)).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func scanDriveBlocking(
        drive: ExternalDrive,
        helper: URL,
        authorization: ReadOnlyAuthorization,
        onOutput: @escaping @MainActor @Sendable (String) -> Void
    ) throws -> [DeletedFileCandidate] {
        try checkCancelled()
        let common = [drive.rawDevicePath, String(drive.size)]
        emit("Источник: \(drive.displayName) (\(drive.rawDevicePath), только чтение).\n", onOutput)
        emit("Проверка файловой системы без таблицы разделов…\n", onOutput)
        if let direct = try scanDriveFileSystem(
            helper: helper,
            commonArguments: common,
            offset: 0,
            authorization: authorization
        ) {
            return direct
        }

        try checkCancelled()
        emit("Обнаружение разделов на накопителе…\n", onOutput)
        let partitions = try runTool(
            helper,
            arguments: ["mmls"] + common,
            standardInput: authorization.externalForm
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
            if let result = try scanDriveFileSystem(
                helper: helper,
                commonArguments: common,
                offset: offset,
                authorization: authorization
            ) {
                recognizedFileSystem = true
                found.append(contentsOf: result)
            }
        }
        guard recognizedFileSystem else { throw DeletedFilesError.unsupportedImage }
        return Array(Set(found)).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func scanDriveFileSystem(
        helper: URL,
        commonArguments: [String],
        offset: Int64,
        authorization: ReadOnlyAuthorization
    ) throws -> [DeletedFileCandidate]? {
        for filesystemType in ["fat32", "exfat"] {
            let result = try runTool(
                helper,
                arguments: ["fls"] + commonArguments + [String(offset), filesystemType],
                standardInput: authorization.externalForm
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
        imageURL: URL,
        outputFolderURL: URL,
        candidates: [DeletedFileCandidate],
        icat: URL,
        onOutput: @escaping @MainActor @Sendable (String) -> Void
    ) throws -> [URL] {
        var results: [URL] = []
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
                    icat,
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
                results.append(resultURL)
            } catch {
                try? FileManager.default.removeItem(at: partialURL)
                throw error
            }
        }
        return results
    }

    private func recoverDriveBlocking(
        drive: ExternalDrive,
        outputFolderURL: URL,
        candidates: [DeletedFileCandidate],
        helper: URL,
        authorization: ReadOnlyAuthorization,
        onOutput: @escaping @MainActor @Sendable (String) -> Void
    ) throws -> [URL] {
        var results: [URL] = []
        for (index, candidate) in candidates.enumerated() {
            try checkCancelled()
            let resultURL = Self.uniqueResultURL(suggestedName: candidate.displayName, folder: outputFolderURL)
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
                    standardInput: authorization.externalForm
                )
                try outputHandle.synchronize()
                try outputHandle.close()
                try Self.classifyToolOutput(result.output, outputFolderURL: outputFolderURL)
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

    private func deepRecoverBlocking(
        imageURL: URL,
        outputFolderURL: URL,
        photorec: URL,
        onSessionReady: @escaping @MainActor @Sendable (URL) -> Void,
        onOutput: @escaping @MainActor @Sendable (String) -> Void
    ) throws -> DeepRecoveryResult {
        try checkCancelled()
        let sessionURL = Self.uniqueResultURL(
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
        try Self.classifyToolOutput(result.output, outputFolderURL: outputFolderURL)
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
        let sessionURL = Self.uniqueResultURL(
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
        try Self.classifyToolOutput(result.output, outputFolderURL: outputFolderURL)
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
        let launcher = try Self.launcherURL()
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

    static func uniqueResultURL(
        suggestedName: String,
        folder: URL,
        fileManager: FileManager = .default
    ) -> URL {
        let cleaned = suggestedName.replacingOccurrences(of: "/", with: "_")
        let original = cleaned.isEmpty ? "recovered_file" : cleaned
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

    private static func validateOutputFolder(_ url: URL, fileManager: FileManager = .default) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw DeletedFilesError.outputFolderMissing }
        guard fileManager.isWritableFile(atPath: url.path) else {
            throw DeletedFilesError.outputFolderNotWritable
        }
    }

    private static func classifyToolOutput(
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

    private static func toolURL(named name: String, environmentKey: String) throws -> URL {
        if let override = ProcessInfo.processInfo.environment[environmentKey] {
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

    private static func launcherURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["RECOVERYAPP_TOOL_LAUNCHER_PATH"] {
            let url = URL(fileURLWithPath: override)
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw DeletedFilesError.toolMissing("tool-launcher")
            }
            return url
        }
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Tools/tool-launcher"),
              FileManager.default.isExecutableFile(atPath: url.path) else {
            throw DeletedFilesError.toolMissing("tool-launcher")
        }
        return url
    }
}
