import Combine
import Foundation
import RecoveryCore


@MainActor
final class DeletedFilesViewModel: ObservableObject {
    enum State: Equatable {
        case ready
        case scanning
        case scanFinished
        case recovering
        case deepRecovering
        case succeeded(QuickRecoverySummary)
        case deepSucceeded(Int, URL)
        case failed(UserFacingFailure)
        case cancelled(URL?)
    }

    @Published var imageURL: URL?
    @Published var outputFolderURL: URL?
    @Published var drives: [ExternalDrive] = []
    @Published var selectedDriveID: ExternalDrive.ID?
    @Published var drivesLoading = false
    @Published var driveMessage = "Подключите флешку или карту памяти."
    @Published var candidates: [DeletedFileCandidate] = []
    @Published var selection: Set<DeletedFileCandidate.ID> = []
    @Published var state: State = .ready
    @Published var log = ""
    @Published var elapsed: TimeInterval = 0
    @Published var selectingOutput = false
    @Published var confirmingDeepRecovery = false
    @Published var showingAdvancedSource = false
    @Published var showingLog = false
    @Published private(set) var activityTitle = "Получаем доступ к накопителю…"
    @Published private(set) var activityDetail = "macOS может показать системное подтверждение."
    @Published private(set) var processedBytes: Int64?
    @Published private(set) var totalBytes: Int64?
    @Published private(set) var readBytesPerSecond: Double?
    /// Идентичность источника последнего успешного физического скана:
    /// находки актуальны, пока диск с этим `diskN` сохраняет имя и размер.
    private(set) var scannedSourceIdentity: PhysicalSourceIdentity?

    private let executor: DeletedFilesExecutor
    /// Снимок списка накопителей. Production — реальный `ExternalDriveDiscovery`;
    /// подмена внедряется только в доменных тестах (не через переменную
    /// окружения) и не позволяет обходить политику.
    private let driveSnapshot: @Sendable () async throws -> [ExternalDrive]

    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var processActivity: NSObjectProtocol?
    private var progressTask: Task<Void, Never>?
    private var activeSessionURL: URL?
    private var lastProgressSignature = ProgressSnapshot.empty
    private var lastProgressChange = Date()
    private var lastMeasuredBytes: Int64?
    private var lastMeasurementDate: Date?
    private var lastSpeedUpdateDate: Date?

    // Снимок прогресса и его расчёт живут в RecoveryCore
    // (`PhotoRecDeepRecovery.progressSnapshot`) и общие с CLI.
    private typealias ProgressSnapshot = PhotoRecProgressSnapshot

    init(
        initialDriveID: ExternalDrive.ID? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        driveSnapshot: @escaping @Sendable () async throws -> [ExternalDrive] = {
            try await ExternalDriveDiscovery().load()
        },
        executor: DeletedFilesExecutor = DeletedFilesExecutor()
    ) {
        self.executor = executor
        self.driveSnapshot = driveSnapshot
        selectedDriveID = initialDriveID
        if let path = environment["RECOVERYAPP_TEST_DISK_IMAGE"] {
            imageURL = URL(fileURLWithPath: path)
        }
        if let path = environment["RECOVERYAPP_TEST_DELETED_OUTPUT"] {
            outputFolderURL = URL(fileURLWithPath: path)
        }
        let testCount = Int(environment["RECOVERYAPP_TEST_RESULT_COUNT"] ?? "") ?? 12
        if let path = environment["RECOVERYAPP_TEST_DELETED_SUCCESS"] {
            state = .succeeded(QuickRecoverySummary.make(
                folder: URL(fileURLWithPath: path, isDirectory: true),
                results: Array(repeating: RecoveredFileResult(
                    url: URL(fileURLWithPath: path),
                    expectedSize: 1,
                    actualSize: 1,
                    status: .sizeMatches
                ), count: testCount)
            ))
        } else if let path = environment["RECOVERYAPP_TEST_DEEP_SUCCESS"] {
            state = .deepSucceeded(testCount, URL(fileURLWithPath: path, isDirectory: true))
        } else if let path = environment["RECOVERYAPP_TEST_DELETED_CANCELLED"] {
            state = .cancelled(URL(fileURLWithPath: path, isDirectory: true))
        } else if environment["RECOVERYAPP_TEST_DELETED_FAILURE"] == "no-space" {
            state = .failed(UserFacingFailure.make(from: DeletedFilesError.outputSpaceExhausted))
        } else if environment["RECOVERYAPP_TEST_DELETED_FAILURE"] == "source-changed" {
            state = .failed(UserFacingFailure.make(from: DeletedFilesError.sourceChanged))
        } else if environment["RECOVERYAPP_TEST_DELETED_FAILURE"] == "output-on-source" {
            state = .failed(UserFacingFailure.make(from: DeletedFilesError.outputOnSource))
        }
    }

    var isBusy: Bool {
        state == .scanning || state == .recovering || state == .deepRecovering
    }

    var canScan: Bool {
        (selectedDrive != nil || imageURL != nil) && !isBusy
    }

    var canRecover: Bool {
        (selectedDrive != nil || imageURL != nil) && outputFolderURL != nil && !selection.isEmpty && !isBusy
    }

    var canDeepRecover: Bool {
        (selectedDrive != nil || imageURL != nil) && outputFolderURL != nil && !isBusy
    }

    var selectedDrive: ExternalDrive? {
        drives.first { $0.id == selectedDriveID }
    }

    var usesPhysicalDrive: Bool {
        selectedDrive != nil
    }

    var hasTerminalResult: Bool {
        switch state {
        case .succeeded, .deepSucceeded, .failed, .cancelled:
            true
        case .ready, .scanning, .scanFinished, .recovering, .deepRecovering:
            false
        }
    }

    func selectImage(_ url: URL) {
        let supportedExtensions = Set(["img", "raw", "dd", "dmg"])
        guard supportedExtensions.contains(url.pathExtension.lowercased()) else {
            state = .failed(UserFacingFailure(
                title: "Неверный формат образа",
                message: "Поддерживаются образы IMG, RAW, DD и DMG."
            ))
            return
        }
        selectedDriveID = nil
        imageURL = url
        candidates = []
        selection = []
        state = .ready
        log = ""
        executor.resetPhysicalSession()
    }

    func selectDrive(id: ExternalDrive.ID?) {
        if id != selectedDriveID {
            executor.resetPhysicalSession()
        }
        selectedDriveID = id
        if id != nil { imageURL = nil }
        resetResults()
        if let outputFolderURL, let drive = selectedDrive, drive.contains(outputFolderURL) {
            self.outputFolderURL = nil
            state = .failed(UserFacingFailure(
                title: "Нужен другой диск",
                message: "Папка результата была на выбранном накопителе. Выберите другой диск."
            ))
        }
    }

    func selectOutputFolder(_ url: URL) {
        if let drive = selectedDrive, drive.contains(url) {
            outputFolderURL = nil
            state = .failed(UserFacingFailure(
                title: "Нужен другой диск",
                message: "Нельзя сохранять восстановленные файлы на исходный накопитель."
            ))
            return
        }
        outputFolderURL = url
        if case .failed = state { state = .ready }
    }

    func refreshDrives() async {
        guard !drivesLoading else { return }
        drivesLoading = true
        driveMessage = "Ищу подключённые накопители…"
        do {
            let found = try await driveSnapshot()
            drives = found
            // Находки сканирования устаревают, если диск с тем же diskN
            // подменили (другое имя/размер) или он исчез: сбрасываем находки,
            // выбор и физическую quick-сессию в ЛЮБОМ состоянии экрана, до
            // всякой авторизации. Во время операции пропускаем — операция
            // сверяет источник сама, а открытый read-only дескриптор
            // принадлежит проверенному устройству.
            if !isBusy, let reason = ScannedSourceRefresh.outdatedReason(
                scanned: scannedSourceIdentity,
                snapshot: found
            ) {
                discardStaleFindings(reason: reason)
            }
            if let selectedDriveID, !found.contains(where: { $0.id == selectedDriveID }) {
                self.selectedDriveID = nil
            }
            driveMessage = found.isEmpty
                ? "Внешние накопители не найдены. Подключите устройство и нажмите «Обновить»."
                : "Выберите накопитель, который нужно восстановить."
        } catch {
            drives = []
            selectedDriveID = nil
            driveMessage = "Не удалось получить список накопителей. Проверьте подключение и нажмите «Обновить»."
        }
        drivesLoading = false
    }

    /// Сброс устаревших находок сканирования с понятной карточкой отказа.
    private func discardStaleFindings(reason: DeletedFilesError) {
        candidates = []
        selection = []
        scannedSourceIdentity = nil
        executor.resetPhysicalSession()
        state = .failed(UserFacingFailure.make(from: reason))
        log.append("\(reason.localizedDescription)\n")
    }

    func scan() {
        let drive = selectedDrive
        let imageURL = imageURL
        guard drive != nil || imageURL != nil else { return }
        state = .scanning
        candidates = []
        selection = []
        log = drive.map { "Накопитель будет открыт только для чтения: \($0.rawDevicePath)\n" }
            ?? "Образ открыт только для чтения: \(imageURL!.path)\n"
        startTimer()

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let found: [DeletedFileCandidate]
                if let drive {
                    // Повторное обнаружение и сверка до авторизации — правила
                    // в PhysicalDriveSelector.selectDrive, без ручной копии.
                    let confirmed = try await confirmPhysicalSource(drive)
                    recordScannedSource(confirmed)
                    found = try await executor.scan(drive: confirmed) { [weak self] text in
                        self?.log.append(text)
                    }
                } else if let imageURL {
                    found = try await executor.scan(imageURL: imageURL) { [weak self] text in
                        self?.log.append(text)
                    }
                } else { return }
                finishTimer()
                candidates = found
                selection = Set(found.map(\.id))
                state = .scanFinished
                log.append("Найдено удалённых файлов: \(found.count).\n")
            } catch let error as DeletedFilesError {
                handle(error)
            } catch {
                finishTimer()
                state = .failed(UserFacingFailure.make(from: error))
                log.append("\(error.localizedDescription)\n")
            }
        }
    }

    func recoverSelected() {
        guard let outputFolderURL else { return }
        let drive = selectedDrive
        let imageURL = imageURL
        guard drive != nil || imageURL != nil else { return }
        let chosen = candidates.filter { selection.contains($0.id) }
        state = .recovering
        log.append("Восстановление выбранных файлов: \(chosen.count).\n")
        startTimer()

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let results: [RecoveredFileResult]
                if let drive {
                    // Сверка источника и preflight папки результата — до
                    // запуска инструмента и до новой авторизации; сессия
                    // переиспользуется только при том же источнике.
                    let confirmed = try await confirmPhysicalSource(drive)
                    // Находки принадлежат источнику сканирования: если
                    // подтверждённый диск с ним не совпадает (подмена между
                    // сканом и восстановлением), отказываем до авторизации
                    // и очищаем чужие находки.
                    if let scanned = scannedSourceIdentity, !scanned.matches(confirmed) {
                        candidates = []
                        selection = []
                        scannedSourceIdentity = nil
                        executor.resetPhysicalSession()
                        throw DeletedFilesError.sourceChanged
                    }
                    try PhysicalQuickRecovery.preflightRecoveryOutput(
                        outputFolderURL: outputFolderURL,
                        drive: confirmed
                    )
                    results = try await executor.recoverDetailed(
                        drive: confirmed,
                        outputFolderURL: outputFolderURL,
                        candidates: chosen
                    ) { [weak self] text in self?.log.append(text) }
                } else if let imageURL {
                    results = try await executor.recoverDetailed(
                        imageURL: imageURL,
                        outputFolderURL: outputFolderURL,
                        candidates: chosen
                    ) { [weak self] text in self?.log.append(text) }
                } else { return }
                finishTimer()
                if results.isEmpty {
                    // Пустой quick-результат — нормальное состояние без
                    // ложного успеха «сохранено 0».
                    state = .scanFinished
                    log.append("Удалённые файлы не найдены — восстанавливать нечего.\n")
                } else {
                    let summary = QuickRecoverySummary.make(folder: outputFolderURL, results: results)
                    state = .succeeded(summary)
                    log.append("Готово. Сохранено файлов: \(summary.savedCount).\n")
                    if summary.incompleteCount > 0 {
                        log.append("Внимание: \(summary.incompleteCount) файл(ов) извлечены не полностью.\n")
                    }
                }
                // Извлечение завершено — физическая quick-сессия своё отжила.
                scannedSourceIdentity = nil
                executor.resetPhysicalSession()
            } catch let error as DeletedFilesError {
                handle(error)
            } catch {
                finishTimer()
                state = .failed(UserFacingFailure.make(from: error))
                log.append("\(error.localizedDescription)\n")
                executor.resetPhysicalSession()
            }
        }
    }

    func deepRecover() {
        guard let outputFolderURL else { return }
        let drive = selectedDrive
        let imageURL = imageURL
        guard drive != nil || imageURL != nil else { return }
        state = .deepRecovering
        log.append("Запуск глубокого сигнатурного поиска PhotoRec.\n")
        activityTitle = "Получаем доступ к накопителю…"
        activityDetail = "После подтверждения начнётся чтение в режиме только для чтения."
        activeSessionURL = nil
        lastProgressSignature = .empty
        processedBytes = nil
        totalBytes = nil
        readBytesPerSecond = nil
        lastMeasuredBytes = nil
        lastMeasurementDate = nil
        lastSpeedUpdateDate = nil
        startTimer()

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result: DeepRecoveryResult
                if let drive {
                    // Сверка источника до авторизации; preflight папки до
                    // создания авторизации выполняет общий адаптер Core.
                    let confirmed = try await confirmPhysicalSource(drive)
                    result = try await executor.deepRecover(
                        drive: confirmed,
                        outputFolderURL: outputFolderURL,
                        onSessionReady: { [weak self] url in
                            self?.beginProgressMonitoring(sessionURL: url)
                        }
                    ) { [weak self] text in
                        self?.log.append(text)
                    }
                } else if let imageURL {
                    result = try await executor.deepRecover(
                        imageURL: imageURL,
                        outputFolderURL: outputFolderURL,
                        onSessionReady: { [weak self] url in
                            self?.beginProgressMonitoring(sessionURL: url)
                        }
                    ) { [weak self] text in
                        self?.log.append(text)
                    }
                } else {
                    return
                }
                finishTimer()
                state = .deepSucceeded(result.recoveredFiles.count, result.outputDirectory)
                log.append("Готово: \(result.outputDirectory.path)\n")
            } catch let error as DeletedFilesError {
                handle(error)
            } catch {
                finishTimer()
                state = .failed(UserFacingFailure.make(from: error))
                log.append("\(error.localizedDescription)\n")
            }
        }
    }

    /// Фиксация идентичности источника после успешного сканирования
    /// подтверждённого диска; доступно доменным тестам для имитации скана.
    func recordScannedSource(_ drive: ExternalDrive) {
        scannedSourceIdentity = PhysicalSourceIdentity(drive)
    }

    func cancel() {
        executor.cancel()
        task?.cancel()
    }

    /// Повторное обнаружение и сверка выбранного физического источника по
    /// свежему снимку: правила (`diskN`, точное имя, точный размер) живут в
    /// `PhysicalDriveSelector.selectDrive`. При исчезновении/подмене диска
    /// операция отказывает до авторизации; прежняя quick-сессия сбрасывается.
    private func confirmPhysicalSource(_ drive: ExternalDrive) async throws -> ExternalDrive {
        let snapshot = try await driveSnapshot()
        do {
            return try PhysicalDriveSelector.selectDrive(
                identifier: drive.identifier,
                expectedName: drive.name,
                expectedSize: drive.size,
                from: snapshot
            )
        } catch {
            executor.resetPhysicalSession()
            throw error
        }
    }

    private func handle(_ error: DeletedFilesError) {
        let stoppedSessionURL = activeSessionURL
        finishTimer()
        // Идентичность скана сохраняется: находки остаются для повторной
        // попытки, а обновление списка при подмене носителя всё равно
        // отбросит их (см. refreshDrives).
        executor.resetPhysicalSession()
        if error == .cancelled {
            state = .cancelled(stoppedSessionURL)
        } else {
            state = .failed(UserFacingFailure.make(from: error))
        }
        log.append("\(error.localizedDescription)\n")
    }

    private func startTimer() {
        elapsed = 0
        if processActivity == nil {
            processActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "RecoveryApp восстанавливает данные"
            )
        }
        let started = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.elapsed = Date().timeIntervalSince(started) }
        }
    }

    private func finishTimer() {
        timer?.invalidate()
        timer = nil
        if let processActivity {
            ProcessInfo.processInfo.endActivity(processActivity)
            self.processActivity = nil
        }
        progressTask?.cancel()
        progressTask = nil
        activeSessionURL = nil
    }

    private func beginProgressMonitoring(sessionURL: URL) {
        activeSessionURL = sessionURL
        lastProgressSignature = .empty
        lastProgressChange = Date()
        lastMeasuredBytes = nil
        lastMeasurementDate = nil
        lastSpeedUpdateDate = nil
        activityTitle = "PhotoRec запускается…"
        activityDetail = "Подготавливаем журнал и папку найденных файлов."
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.state == .deepRecovering else { return }
                let snapshot = await Task.detached(priority: .utility) {
                    PhotoRecDeepRecovery.progressSnapshot(at: sessionURL)
                }.value
                self.updateProgress(snapshot)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func updateProgress(_ snapshot: ProgressSnapshot) {
        let now = Date()
        if snapshot != lastProgressSignature {
            lastProgressSignature = snapshot
            lastProgressChange = now
        }

        if let currentBytes = snapshot.processedBytes,
           let previousBytes = lastMeasuredBytes,
           let previousDate = lastMeasurementDate,
           currentBytes > previousBytes {
            let interval = now.timeIntervalSince(previousDate)
            if interval > 0 {
                let currentSpeed = Double(currentBytes - previousBytes) / interval
                readBytesPerSecond = readBytesPerSecond.map { $0 * 0.65 + currentSpeed * 0.35 }
                    ?? currentSpeed
                lastSpeedUpdateDate = now
            }
        }
        if let currentBytes = snapshot.processedBytes {
            if lastMeasuredBytes == nil || currentBytes != lastMeasuredBytes {
                lastMeasuredBytes = currentBytes
                lastMeasurementDate = now
            }
        }
        processedBytes = snapshot.processedBytes
        totalBytes = snapshot.totalBytes

        activityTitle = snapshot.logSize > 0
            ? "PhotoRec читает накопитель"
            : "PhotoRec запускается…"
        let idleSeconds = max(0, Int(now.timeIntervalSince(lastProgressChange)))
        if let processed = snapshot.processedBytes,
           let total = snapshot.totalBytes,
           total > 0,
           processed >= Self.minimumMeaningfulProgress(total: total) {
            var parts = [
                "Обработано \(Self.formattedBytes(processed)) из \(Self.formattedBytes(total))"
            ]
            if let readBytesPerSecond,
               readBytesPerSecond > 0,
               let lastSpeedUpdateDate,
               now.timeIntervalSince(lastSpeedUpdateDate) < 6 {
                parts.append("\(Self.formattedBytes(Int64(readBytesPerSecond)))/с")
            }
            parts.append("найдено файлов: \(snapshot.fileCount)")
            activityDetail = parts.joined(separator: " • ")
        } else if snapshot.fileCount > 0 {
            let freshness = idleSeconds < 4
                ? "результаты обновляются"
                : "глубокое чтение продолжается"
            activityDetail = "Найдено файлов: \(snapshot.fileCount) • \(freshness)."
        } else if snapshot.logSize > 0 {
            activityDetail = idleSeconds < 10
                ? "Журнал обновляется • найденных файлов пока нет."
                : "Новых находок пока нет • чтение продолжается."
        }
    }

    nonisolated private static func minimumMeaningfulProgress(total: Int64) -> Int64 {
        min(1_048_576, max(1, total / 100))
    }

    nonisolated private static func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func resetResults() {
        candidates = []
        selection = []
        scannedSourceIdentity = nil
        executor.resetPhysicalSession()
        state = .ready
        log = ""
    }
}
