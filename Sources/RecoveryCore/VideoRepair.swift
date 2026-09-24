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
    /// Результат оказался на том же физическом носителе, где лежит исходное
    /// видео (том образа на том же диске тоже считается этим носителем).
    case resultOnSourceVolume
    /// Физический носитель результата или источника не удалось надёжно
    /// определить: операция отказывает ради безопасности вместо записи в
    /// неизвестное место.
    case volumeIdentityUnknown
    case toolMissing
    case launchFailed(String)
    case toolFailed(Int32)
    case outputSpaceExhausted
    case cancelled
    case resultMissing
    /// Резервирование имени результата не удалось (ошибка файловой системы,
    /// а не занятое имя).
    case resultNamingFailed(String)
    /// Все 10 000 кандидатов имени результата заняты.
    case resultNamingExhausted

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
        case .volumeIdentityUnknown: "Не удалось надёжно определить физический носитель результата. Для безопасности выберите папку на другом диске и повторите попытку."
        case .toolMissing: "Встроенный инструмент untrunc отсутствует или повреждён."
        case .launchFailed(let message): "Не удалось запустить untrunc: \(message)"
        case .toolFailed(let code): "untrunc завершился с кодом \(code). Откройте подробный лог."
        case .outputSpaceExhausted: "В папке результата закончилось свободное место."
        case .cancelled: "Операция остановлена. Доступные результаты сохранены."
        case .resultMissing: "untrunc завершился без ошибки, но файл результата не найден или пуст."
        case .resultNamingFailed(let detail): "Не удалось зарезервировать имя результата: \(detail)."
        case .resultNamingExhausted: "В папке результата не нашлось свободного имени: проверено 10 000 вариантов."
        }
    }
}

/// Идентичность физического носителя: множество терминальных физических
/// устройств (например, `disk0` для встроенного накопителя), к которым в
/// итоге сводится хранение данных. Носитель файла-образа — это носитель
/// самого файла, RAM-диск (`ram://`) — отдельный носитель «память».
public struct VideoPhysicalMedium: Sendable, Equatable {
    public let identifiers: Set<String>

    public init(identifiers: Set<String>) {
        self.identifiers = identifiers
    }

    /// Носители считаются общими, если хотя бы один терминальный физический
    /// идентификатор совпадает.
    public func overlaps(_ other: VideoPhysicalMedium) -> Bool {
        !identifiers.isDisjoint(with: other.identifiers)
    }
}

/// Поставщик физического носителя для пути. Возвращает `nil`, когда носитель
/// надёжно определить нельзя — валидация в этом случае отказывает операцию.
/// Переопределяется только в доменных тестах; производственные CLI и GUI
/// всегда используют системную реализацию (`systemMediumResolver`).
public typealias VideoMediumProvider = @Sendable (URL) -> VideoPhysicalMedium?

/// Фактическая идентичность файла: физический том и инод. Совпадение
/// означает, что входы — один и тот же файл даже через разные имена.
private struct VideoFileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
}

/// Системное определение физического носителя: по `statfs` получает устройство
/// тома, затем через `diskutil info` поднимается по цепочке бэкенда
/// (APFS-контейнер → физический store → целое устройство), а для
/// подключённых образов рекурсивно определяет носитель файла-образа через
/// `hdiutil info`. RAM-диск (`ram://`) — отдельный носитель «память».
/// Неопределимый носитель даёт `nil` — валидация отказывает операцию.
public final class SystemPhysicalMediumResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var deviceCache: [String: Set<String>?] = [:]
    private var volumeCache: [String: VideoPhysicalMedium?] = [:]
    private var imageMap: [String: String]?

    public init() {}

    /// Единый resolver для одной валидации: кэширует ответы diskutil/hdiutil.
    public static func makeProvider() -> VideoMediumProvider {
        let resolver = SystemPhysicalMediumResolver()
        return { url in resolver.medium(for: url) }
    }

    public func medium(for path: URL) -> VideoPhysicalMedium? {
        lock.lock()
        let resolved = path.resolvingSymlinksInPath().standardizedFileURL
        if let cached = volumeCache[resolved.path] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let medium = mountSourceDevice(of: resolved).flatMap { mountFrom in
            SystemPhysicalMediumResolver.baseDiskName(of: mountFrom).flatMap { base in
                resolveDevice(base, depth: 0, visited: [])
            }.map { VideoPhysicalMedium(identifiers: $0) }
        }

        lock.lock()
        volumeCache[resolved.path] = medium
        lock.unlock()
        return medium
    }

    /// Разрешает целое устройство в множество терминальных физических
    /// идентификаторов; `nil` — носитель надёжно определить не удалось.
    private func resolveDevice(
        _ baseDisk: String,
        depth: Int,
        visited: Set<String>
    ) -> Set<String>? {
        guard depth < 5, !visited.contains(baseDisk) else { return nil }
        lock.lock()
        if let cached = deviceCache[baseDisk] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved: Set<String>? = resolveUncachedDevice(baseDisk, depth: depth, visited: visited)

        lock.lock()
        deviceCache[baseDisk] = resolved
        lock.unlock()
        return resolved
    }

    private func resolveUncachedDevice(
        _ baseDisk: String,
        depth: Int,
        visited: Set<String>
    ) -> Set<String>? {
        guard let info = SystemPhysicalMediumResolver.diskutilInfoPlist(baseDisk) else { return nil }
        let storeNames = ((info["APFSPhysicalStores"] as? [[String: Any]]) ?? [])
            .compactMap { ($0["APFSPhysicalStore"] as? String).flatMap(SystemPhysicalMediumResolver.baseDiskName) }
        if !storeNames.isEmpty {
            var terminals: Set<String> = []
            var nextVisited = visited
            nextVisited.insert(baseDisk)
            for store in storeNames {
                guard let terminal = resolveDevice(store, depth: depth + 1, visited: nextVisited) else {
                    return nil
                }
                terminals.formUnion(terminal)
            }
            return terminals
        }
        switch info["VirtualOrPhysical"] as? String {
        case "Physical", "Unknown":
            // Терминальное физическое устройство (встроенный NVMe сообщает
            // Unknown); ссылок на другой бэкенд у него нет.
            return [baseDisk]
        case "Virtual":
            // Подключённый образ: носитель — носитель файла образа; RAM-диск
            // (ram://) — память. Без записи в hdiutil info носитель неизвестен.
            switch attachedImagePath(forDisk: baseDisk) {
            case "ram":
                return ["ram"]
            case .some(let imagePath):
                return medium(for: URL(fileURLWithPath: imagePath))?.identifiers
            case nil:
                return nil
            }
        default:
            return nil
        }
    }

    private func mountSourceDevice(of url: URL) -> String? {
        var stats = statfs()
        guard statfs(url.path, &stats) == 0 else { return nil }
        return withUnsafePointer(to: &stats.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
    }

    /// `disk5s1` → `disk5`; устройства без слайса возвращаются как есть.
    private static func baseDiskName(of device: String) -> String? {
        let name = (device as NSString).lastPathComponent
        guard name.hasPrefix("disk") else { return nil }
        var digitsEnd = name.index(name.startIndex, offsetBy: 4)
        while digitsEnd < name.endIndex, name[digitsEnd].isNumber {
            digitsEnd = name.index(after: digitsEnd)
        }
        guard digitsEnd > name.index(name.startIndex, offsetBy: 4) else { return nil }
        let remainder = name[digitsEnd...]
        if remainder.isEmpty { return name }
        guard remainder.hasPrefix("s"), remainder.dropFirst().allSatisfy(\.isNumber) else {
            return nil
        }
        return String(name[..<digitsEnd])
    }

    private static func diskutilInfoPlist(_ device: String) -> [String: Any]? {
        plistOutput(executable: "/usr/sbin/diskutil", arguments: ["info", "-plist", device])
    }

    /// Карта «целое устройство → путь файла образа» из `hdiutil info`.
    /// `"ram"` — специальное значение для RAM-дисков (`ram://`).
    private func attachedImagePath(forDisk baseDisk: String) -> String? {
        lock.lock()
        if let imageMap {
            lock.unlock()
            return imageMap[baseDisk]
        }
        lock.unlock()

        var map: [String: String] = [:]
        if let plist = SystemPhysicalMediumResolver.plistOutput(executable: "/usr/bin/hdiutil", arguments: ["info", "-plist"]),
           let images = plist["images"] as? [[String: Any]] {
            for image in images {
                guard let imagePath = image["image-path"] as? String else { continue }
                let entities = image["system-entities"] as? [[String: Any]] ?? []
                for entity in entities {
                    guard let devEntry = entity["dev-entry"] as? String,
                          let base = SystemPhysicalMediumResolver.baseDiskName(of: devEntry) else { continue }
                    map[base] = imagePath.hasPrefix("ram://") ? "ram" : imagePath
                }
            }
        }

        lock.lock()
        if imageMap == nil {
            imageMap = map
        }
        let cached = imageMap?[baseDisk]
        lock.unlock()
        return cached
    }

    private static func plistOutput(executable: String, arguments: [String]) -> [String: Any]? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else {
            return nil
        }
        return plist as? [String: Any]
    }
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
    /// записи, не является файлом и находится на другом ФИЗИЧЕСКОМ носителе,
    /// чем исходные видео (том образа на том же диске — тот же носитель).
    /// Неопределимый носитель — безопасный отказ.
    public func validate(
        fileManager: FileManager = .default,
        medium: VideoMediumProvider? = nil
    ) throws {
        let mediumProvider = medium ?? SystemPhysicalMediumResolver.makeProvider()
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

        guard let referenceMedium = mediumProvider(referenceURL),
              let damagedMedium = mediumProvider(damagedURL),
              let outputMedium = mediumProvider(outputFolderURL) else {
            throw VideoRepairError.volumeIdentityUnknown
        }
        guard !outputMedium.overlaps(referenceMedium),
              !outputMedium.overlaps(damagedMedium) else {
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
    /// Занятое имя пропускается; любая другая ошибка `open` и исчерпание
    /// 10 000 кандидатов завершаются отказом — небезопасного запасного
    /// пути без `O_EXCL` здесь нет.
    public func reserveResultURL(fileManager: FileManager = .default) throws -> (url: URL, descriptor: Int32) {
        let stem = Self.resultStem(of: damagedURL)
        let ext = Self.resultExtension(of: damagedURL)
        var candidateNames = ["\(stem)_recovered.\(ext)"]
        var index = 2
        while candidateNames.count < Self.resultNameCandidateLimit {
            candidateNames.append("\(stem)_recovered_\(index).\(ext)")
            index += 1
        }
        for name in candidateNames {
            let candidate = outputFolderURL.appendingPathComponent(name)
            let descriptor = open(candidate.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if descriptor >= 0 {
                return (candidate, descriptor)
            }
            if errno == EEXIST {
                // Имя занято другим файлом или параллельным запуском.
                continue
            }
            let openErrno = errno
            throw VideoRepairError.resultNamingFailed(String(cString: strerror(openErrno)))
        }
        throw VideoRepairError.resultNamingExhausted
    }

    /// Число кандидатов имени результата: `_recovered` плюс `_2`…`_10000`.
    /// Исчерпание всех кандидатов — отказ операции, а не запись поверх чужого
    /// файла.
    public static let resultNameCandidateLimit = 10_000

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
        let (outputURL, placeholderDescriptor) = try request.reserveResultURL()
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
        // Инструмент мог завершиться успешно, ни разу не записав данные:
        // пустой плейсхолдер — не восстановленное видео, публиковать его
        // нельзя.
        let resultSize = ((try? FileManager.default.attributesOfItem(atPath: outputURL.path))?[.size] as? NSNumber)?.int64Value ?? 0
        guard resultSize > 0 else {
            Self.removeReservedResult(at: outputURL)
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
