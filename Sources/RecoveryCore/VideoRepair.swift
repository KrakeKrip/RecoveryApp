@preconcurrency import Foundation
import Darwin

public enum VideoRepairError: LocalizedError {
    /// Включая совпадение через symlink и жёсткие ссылки: входы сверяются
    /// по разрешённому пути и по фактической паре «том + инод».
    case sameInputFiles
    case inputMissing
    case inputNotRegularFile
    case inputNotReadable
    case outputFolderMissing
    case outputFolderNotWritable
    case outputFolderIsFile
    /// Результат оказался на том же физическом томе, где лежит исходное видео.
    case resultOnSourceVolume
    /// Том результата или источника не удалось надёжно определить: операция
    /// отказывает ради безопасности вместо записи в неизвестное место.
    case volumeIdentityUnknown
    case toolMissing
    case launchFailed(String)
    case toolFailed(Int32)
    case outputSpaceExhausted
    case cancelled
    case resultMissing

    public var errorDescription: String? {
        switch self {
        case .sameInputFiles: "Исправный пример и повреждённое видео должны быть разными файлами."
        case .inputMissing: "Один из выбранных файлов больше недоступен."
        case .inputNotRegularFile: "Входом должен быть обычный видеофайл, а не папка или устройство."
        case .inputNotReadable: "macOS не разрешила чтение одного из выбранных файлов."
        case .outputFolderMissing: "Папка результата больше недоступна."
        case .outputFolderNotWritable: "Нет доступа для записи в папку результата."
        case .outputFolderIsFile: "Путь результата указывает на файл. Выберите отдельную папку."
        case .resultOnSourceVolume: "Результат нельзя сохранять на том же носителе, где лежат исходные видео. Выберите папку на другом диске."
        case .volumeIdentityUnknown: "Не удалось надёжно определить носитель результата. Для безопасности выберите папку на другом диске и повторите попытку."
        case .toolMissing: "Встроенный инструмент untrunc отсутствует или повреждён."
        case .launchFailed(let message): "Не удалось запустить untrunc: \(message)"
        case .toolFailed(let code): "untrunc завершился с кодом \(code). Откройте подробный лог."
        case .outputSpaceExhausted: "В папке результата закончилось свободное место."
        case .cancelled: "Операция остановлена. Доступные результаты сохранены."
        case .resultMissing: "untrunc завершился без ошибки, но файл результата не найден."
        }
    }
}

/// Поставщик идентификатора физического тома для пути (обычно `st_dev`).
/// Возвращает `nil`, когда том надёжно определить нельзя — валидация в этом
/// случае отказывает операцию. Переопределяется только в доменных тестах;
/// производственные CLI и GUI всегда используют системную реализацию.
public typealias VideoVolumeDeviceProvider = @Sendable (URL) -> UInt64?

/// Системный источник идентификатора тома: `st_dev` по разрешённому пути.
public func systemVolumeDevice(for url: URL) -> UInt64? {
    var status = stat()
    guard stat(url.resolvingSymlinksInPath().standardizedFileURL.path, &status) == 0 else {
        return nil
    }
    return UInt64(status.st_dev)
}

/// Фактическая идентичность файла: физический том и инод. Совпадение
/// означает, что входы — один и тот же файл даже через разные имена.
private struct VideoFileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
}

public struct VideoRepairRequest: Sendable {
    public let referenceURL: URL
    public let damagedURL: URL
    public let outputFolderURL: URL

    public init(referenceURL: URL, damagedURL: URL, outputFolderURL: URL) {
        self.referenceURL = referenceURL
        self.damagedURL = damagedURL
        self.outputFolderURL = outputFolderURL
    }

    /// Preflight до запуска untrunc: входы существуют, являются обычными
    /// читаемыми файлами и не указывают на один и тот же файл (включая
    /// symlink и жёсткие ссылки); папка результата существует, доступна для
    /// записи, не является файлом и находится на другом томе, чем исходные
    /// видео. Неизвестный том — безопасный отказ.
    public func validate(
        fileManager: FileManager = .default,
        volumeDevice: VideoVolumeDeviceProvider? = nil
    ) throws {
        let deviceProvider = volumeDevice ?? systemVolumeDevice(for:)
        let referenceIdentity = Self.fileIdentity(of: referenceURL, fileManager: fileManager)
        let damagedIdentity = Self.fileIdentity(of: damagedURL, fileManager: fileManager)
        let samePath = referenceURL.resolvingSymlinksInPath().standardizedFileURL.path
            == damagedURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard !samePath, referenceIdentity == nil || referenceIdentity != damagedIdentity else {
            throw VideoRepairError.sameInputFiles
        }

        try Self.validateInput(referenceURL, fileManager: fileManager)
        try Self.validateInput(damagedURL, fileManager: fileManager)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: outputFolderURL.path, isDirectory: &isDirectory) else {
            throw VideoRepairError.outputFolderMissing
        }
        guard isDirectory.boolValue else { throw VideoRepairError.outputFolderIsFile }
        guard fileManager.isWritableFile(atPath: outputFolderURL.path) else {
            throw VideoRepairError.outputFolderNotWritable
        }

        guard let referenceDevice = deviceProvider(referenceURL),
              let damagedDevice = deviceProvider(damagedURL),
              let outputDevice = deviceProvider(outputFolderURL) else {
            throw VideoRepairError.volumeIdentityUnknown
        }
        guard outputDevice != referenceDevice, outputDevice != damagedDevice else {
            throw VideoRepairError.resultOnSourceVolume
        }
    }

    /// Имя результата без перезаписи существующих файлов: `_recovered`,
    /// `_recovered_2` и далее. Для запуска используйте `reserveResultURL` —
    /// он атомарно резервирует имя и безопасен при параллельном запуске.
    public func resultURL(fileManager: FileManager = .default) -> URL {
        var candidate = outputFolderURL
            .appendingPathComponent("\(Self.resultStem(of: damagedURL))_recovered")
            .appendingPathExtension(Self.resultExtension(of: damagedURL))
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = outputFolderURL
                .appendingPathComponent("\(Self.resultStem(of: damagedURL))_recovered_\(index)")
                .appendingPathExtension(Self.resultExtension(of: damagedURL))
            index += 1
        }
        return candidate
    }

    /// Атомарное резервирование имени результата: `O_CREAT | O_EXCL`
    /// гарантирует, что параллельный запуск получит другое имя, а чужие
    /// файлы не перезаписываются. Возвращает путь и дескриптор
    /// плейсхолдера (закройте его); untrunc заполняет файл содержимым.
    public func reserveResultURL(fileManager: FileManager = .default) -> (url: URL, descriptor: Int32) {
        let stem = Self.resultStem(of: damagedURL)
        let ext = Self.resultExtension(of: damagedURL)
        var names = ["\(stem)_recovered.\(ext)"]
        var index = 2
        while index < 10_000 {
            names.append("\(stem)_recovered_\(index).\(ext)")
            index += 1
        }
        for name in names {
            let candidate = outputFolderURL.appendingPathComponent(name)
            let descriptor = open(candidate.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if descriptor >= 0 {
                return (candidate, descriptor)
            }
        }
        // Практически недостижимо: все 10 000 имён заняты. Резерв Магистра
        // без O_EXCL нельзя считать безопасным, поэтому последнее имя
        // резервируется обычным созданием — конфликте имён здесь уже нет.
        let fallback = outputFolderURL.appendingPathComponent("\(stem)_recovered_10000.\(ext)")
        let descriptor = open(fallback.path, O_CREAT | O_WRONLY, 0o644)
        return (fallback, descriptor)
    }

    private static func resultStem(of damagedURL: URL) -> String {
        damagedURL.deletingPathExtension().lastPathComponent
    }

    private static func resultExtension(of damagedURL: URL) -> String {
        damagedURL.pathExtension.isEmpty ? "mp4" : damagedURL.pathExtension
    }

    private static func validateInput(_ url: URL, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            throw VideoRepairError.inputMissing
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              (try? fileManager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeRegular
        else {
            throw VideoRepairError.inputNotRegularFile
        }
        guard fileManager.isReadableFile(atPath: url.path) else {
            throw VideoRepairError.inputNotReadable
        }
    }

    private static func fileIdentity(
        of url: URL,
        fileManager: FileManager
    ) -> VideoFileIdentity? {
        var status = stat()
        guard stat(url.resolvingSymlinksInPath().standardizedFileURL.path, &status) == 0 else {
            return nil
        }
        return VideoFileIdentity(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
    }
}

/// Общий untrunc-бэкенд исправления видео для GUI и CLI: preflight,
/// атомарное имя результата, запуск через `tool-launcher`, потоковая очистка
/// лога и отмена всей группы процессов. Запрос отмены запоминается и не
/// теряется даже в окне между регистрацией Process и `run()`.
public final class VideoRepairExecutor: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancellationRequested = false
    private var verifiedResultURL: URL?

    public init() {}

    /// Путь результата, который untrunc уже создал и Core проверил. Читается
    /// CLI для события `cancelled`, если Ctrl-C пришёл в момент доставки
    /// готового результата; до успешной проверки остаётся `nil`.
    public var completedResultURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return verifiedResultURL
    }

    /// `onValidated` вызывается после успешного preflight и резервирования
    /// имени результата, но до запуска инструмента — CLI посылает в этот
    /// момент потоковое событие `started`. GUI не использует этот callback.
    public func run(
        request: VideoRepairRequest,
        onOutput: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        onValidated: @escaping @MainActor @Sendable (URL) -> Void = { _ in }
    ) async throws -> URL {
        try request.validate()
        let toolURL = try Self.toolURL()
        let launcherURL = try Self.launcherURL()

        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { [self] in
                try runBlocking(
                    launcherURL: launcherURL,
                    toolURL: toolURL,
                    request: request,
                    onOutput: onOutput,
                    onValidated: onValidated
                )
            }.value
        } onCancel: { [self] in
            cancel()
        }
    }

    /// Отмена: запрос запоминается (не теряется до запуска процесса), вся
    /// группа `tool-launcher`/`untrunc` останавливается сигналами. Частично
    /// записанный результат текущей операции удаляется, чужие файлы не
    /// затрагиваются.
    public func cancel() {
        lock.lock()
        cancellationRequested = true
        let runningProcess = process
        lock.unlock()
        guard let runningProcess, runningProcess.isRunning else { return }

        let pid = runningProcess.processIdentifier
        if kill(-pid, SIGTERM) != 0 {
            kill(pid, SIGTERM)
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) {
            if kill(-pid, 0) == 0 {
                kill(-pid, SIGKILL)
            } else if kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
        }
    }

    private func runBlocking(
        launcherURL: URL,
        toolURL: URL,
        request: VideoRepairRequest,
        onOutput: @escaping @MainActor @Sendable (String) -> Void,
        onValidated: @escaping @MainActor @Sendable (URL) -> Void
    ) throws -> URL {
        let (outputURL, placeholderDescriptor) = request.reserveResultURL()
        close(placeholderDescriptor)
        notify(outputURL, onValidated)

        let launchedProcess = Process()
        let outputPipe = Pipe()
        launchedProcess.executableURL = launcherURL
        launchedProcess.arguments = [
            toolURL.path,
            "-n", "-dst", outputURL.path,
            request.referenceURL.path,
            request.damagedURL.path
        ]
        launchedProcess.standardOutput = outputPipe
        launchedProcess.standardError = outputPipe
        launchedProcess.standardInput = FileHandle.nullDevice
        var transcript = ""

        lock.lock()
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
            Self.removeReservedResult(at: outputURL)
            throw VideoRepairError.cancelled
        }

        do {
            try launchedProcess.run()
        } catch {
            Self.removeReservedResult(at: outputURL)
            throw VideoRepairError.launchFailed(error.localizedDescription)
        }
        // Окно между регистрацией Process и run(): отмена могла прийти, когда
        // отменять ещё было нечего. Гасим только что запущенный процесс.
        lock.lock()
        let cancellationArrivedDuringLaunch = cancellationRequested
        lock.unlock()
        if cancellationArrivedDuringLaunch {
            cancel()
        }

        while true {
            let data = outputPipe.fileHandleForReading.availableData
            if data.isEmpty { break }
            let text = LogSanitizer.clean(String(decoding: data, as: UTF8.self))
            transcript.append(text)
            transcript.append("\n")
            notify(text + "\n", onOutput)
        }
        launchedProcess.waitUntilExit()

        if launchedProcess.terminationReason == .uncaughtSignal {
            Self.removeReservedResult(at: outputURL)
            throw VideoRepairError.cancelled
        }
        guard launchedProcess.terminationStatus == 0 else {
            Self.removeReservedResult(at: outputURL)
            if Self.indicatesNoSpace(transcript) {
                throw VideoRepairError.outputSpaceExhausted
            }
            try request.validate()
            throw VideoRepairError.toolFailed(launchedProcess.terminationStatus)
        }
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw VideoRepairError.resultMissing
        }
        lock.lock()
        verifiedResultURL = outputURL
        lock.unlock()
        return outputURL
    }

    /// Убирает только плейсхолдер/недописанный файл именно этой операции;
    /// чужие файлы и прежние результаты не затрагиваются.
    private static func removeReservedResult(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func notify(
        _ value: String,
        _ callback: @escaping @MainActor @Sendable (String) -> Void
    ) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await callback(value)
            semaphore.signal()
        }
        semaphore.wait()
    }

    private func notify(
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

    private static func indicatesNoSpace(_ output: String) -> Bool {
        let value = output.lowercased()
        return value.contains("no space left") || value.contains("enospc") ||
            value.contains("недостаточно места")
    }

    private static func toolURL() throws -> URL {
        do {
            return try RecoveryToolLocator.toolURL(named: "untrunc", environmentKey: "RECOVERYAPP_UNTRUNC_PATH")
        } catch {
            throw VideoRepairError.toolMissing
        }
    }

    private static func launcherURL() throws -> URL {
        do {
            return try RecoveryToolLocator.launcherURL()
        } catch {
            throw VideoRepairError.toolMissing
        }
    }
}
