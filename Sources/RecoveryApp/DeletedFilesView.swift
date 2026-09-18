import AppKit
import RecoveryCore
import SwiftUI
import UniformTypeIdentifiers

private let recoveryDiskImageType = UTType(importedAs: "org.recoveryapp.disk-image")

@MainActor
final class DeletedFilesViewModel: ObservableObject {
    enum State: Equatable {
        case ready
        case scanning
        case scanFinished
        case recovering
        case deepRecovering
        case succeeded(Int, URL)
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

    private let executor = DeletedFilesExecutor()
    private let driveDiscovery = ExternalDriveDiscovery()
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

    private struct ProgressSnapshot: Equatable, Sendable {
        let fileCount: Int
        let resultBytes: Int64
        let logSize: Int64
        let processedBytes: Int64?
        let totalBytes: Int64?

        static let empty = ProgressSnapshot(
            fileCount: 0,
            resultBytes: 0,
            logSize: 0,
            processedBytes: nil,
            totalBytes: nil
        )
    }

    init(
        initialDriveID: ExternalDrive.ID? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        selectedDriveID = initialDriveID
        if let path = environment["RECOVERYAPP_TEST_DISK_IMAGE"] {
            imageURL = URL(fileURLWithPath: path)
        }
        if let path = environment["RECOVERYAPP_TEST_DELETED_OUTPUT"] {
            outputFolderURL = URL(fileURLWithPath: path)
        }
        let testCount = Int(environment["RECOVERYAPP_TEST_RESULT_COUNT"] ?? "") ?? 12
        if let path = environment["RECOVERYAPP_TEST_DELETED_SUCCESS"] {
            state = .succeeded(testCount, URL(fileURLWithPath: path, isDirectory: true))
        } else if let path = environment["RECOVERYAPP_TEST_DEEP_SUCCESS"] {
            state = .deepSucceeded(testCount, URL(fileURLWithPath: path, isDirectory: true))
        } else if let path = environment["RECOVERYAPP_TEST_DELETED_CANCELLED"] {
            state = .cancelled(URL(fileURLWithPath: path, isDirectory: true))
        } else if environment["RECOVERYAPP_TEST_DELETED_FAILURE"] == "no-space" {
            state = .failed(UserFacingFailure.make(from: DeletedFilesError.outputSpaceExhausted))
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
    }

    func selectDrive(id: ExternalDrive.ID?) {
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
            let found = try await driveDiscovery.load()
            drives = found
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
                    let currentDrives = try await driveDiscovery.load()
                    guard let currentDrive = currentDrives.first(where: { $0.id == drive.id }) else {
                        throw DeletedFilesError.sourceUnavailable
                    }
                    guard currentDrive.size == drive.size, currentDrive.name == drive.name else {
                        throw DeletedFilesError.sourceChanged
                    }
                    found = try await executor.scan(drive: currentDrive) { [weak self] text in
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
                let urls: [URL]
                if let drive {
                    let currentDrives = try await driveDiscovery.load()
                    guard let currentDrive = currentDrives.first(where: { $0.id == drive.id }) else {
                        throw DeletedFilesError.sourceUnavailable
                    }
                    guard currentDrive.size == drive.size, currentDrive.name == drive.name else {
                        throw DeletedFilesError.sourceChanged
                    }
                    urls = try await executor.recover(
                        drive: currentDrive,
                        outputFolderURL: outputFolderURL,
                        candidates: chosen
                    ) { [weak self] text in self?.log.append(text) }
                } else if let imageURL {
                    urls = try await executor.recover(
                        imageURL: imageURL,
                        outputFolderURL: outputFolderURL,
                        candidates: chosen
                    ) { [weak self] text in self?.log.append(text) }
                } else { return }
                finishTimer()
                state = .succeeded(urls.count, outputFolderURL)
                log.append("Готово. Создано файлов: \(urls.count).\n")
            } catch let error as DeletedFilesError {
                handle(error)
            } catch {
                finishTimer()
                state = .failed(UserFacingFailure.make(from: error))
                log.append("\(error.localizedDescription)\n")
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
                    let currentDrives = try await driveDiscovery.load()
                    guard let currentDrive = currentDrives.first(where: { $0.id == drive.id }) else {
                        throw DeletedFilesError.sourceUnavailable
                    }
                    guard currentDrive.size == drive.size,
                          currentDrive.name == drive.name else {
                        throw DeletedFilesError.sourceChanged
                    }
                    result = try await executor.deepRecover(
                        drive: currentDrive,
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

    func cancel() {
        executor.cancel()
        task?.cancel()
    }

    private func handle(_ error: DeletedFilesError) {
        let stoppedSessionURL = activeSessionURL
        finishTimer()
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
                    Self.progressSnapshot(at: sessionURL)
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

    nonisolated private static func progressSnapshot(at sessionURL: URL) -> ProgressSnapshot {
        let fileManager = FileManager.default
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
        return ProgressSnapshot(
            fileCount: fileCount,
            resultBytes: resultBytes,
            logSize: logSize,
            processedBytes: processedBytes,
            totalBytes: progressValues?.total
        )
    }

    nonisolated private static func photoRecSessionProcessedBytes(at url: URL, totalBytes: Int64) -> Int64? {
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

    nonisolated private static func minimumMeaningfulProgress(total: Int64) -> Int64 {
        min(1_048_576, max(1, total / 100))
    }

    nonisolated private static func progressFileValues(at url: URL) -> (processed: Int64, total: Int64)? {
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

    nonisolated private static func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func resetResults() {
        candidates = []
        selection = []
        state = .ready
        log = ""
    }
}

struct DeletedFilesView: View {
    @StateObject private var model: DeletedFilesViewModel

    init(initialDriveID: ExternalDrive.ID? = nil) {
        _model = StateObject(wrappedValue: DeletedFilesViewModel(initialDriveID: initialDriveID))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            drivePicker
            FileChoiceRow(title: "Папка результата", url: model.outputFolderURL) {
                model.selectingOutput = true
            }
            .disabled(model.isBusy)

            DisclosureGroup("Для специалистов: открыть образ накопителя", isExpanded: $model.showingAdvancedSource) {
                FileChoiceRow(title: "Файл IMG, RAW, DD или DMG", url: model.imageURL) {
                    chooseDiskImage()
                }
                Text("Выбор образа отключит выбранный физический накопитель. Этот режим нужен для экспертизы и повторяемых тестов.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if model.usesPhysicalDrive {
                    Button("Быстрый поиск по именам") { model.scan() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canScan)
                } else {
                    Button("Найти удалённые файлы") { model.scan() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canScan)
                }
                if model.isBusy {
                    Spacer()
                    Button("Остановить", role: .destructive) { model.cancel() }
                } else {
                    statusView
                    Spacer()
                    Button("Глубокий поиск PhotoRec") {
                        model.confirmingDeepRecovery = true
                    }
                    .disabled(!model.canDeepRecover)
                }
            }

            if model.isBusy {
                activityPanel
            }

            resultCard

            if model.hasTerminalResult {
                Spacer(minLength: 0)
            } else if model.candidates.isEmpty {
                ContentUnavailableView {
                    Label("Список находок пуст", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text(emptyStateDescription)
                }
                .frame(maxHeight: .infinity)
            } else {
                findingsTable
                HStack {
                    Text("Выбрано: \(model.selection.count) из \(model.candidates.count)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Восстановить выбранные") { model.recoverSelected() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canRecover)
                }
            }

            LogPanel(isExpanded: $model.showingLog, text: model.log)
        }
        .padding(26)
        .navigationTitle("Удалённые файлы")
        .task { await model.refreshDrives() }
        .fileImporter(isPresented: $model.selectingOutput, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.selectOutputFolder(url) }
        }
        .confirmationDialog(
            "Запустить глубокий поиск?",
            isPresented: $model.confirmingDeepRecovery,
            titleVisibility: .visible
        ) {
            Button("Запустить PhotoRec") { model.deepRecover() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }

    private var drivePicker: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Picker(
                    "Накопитель",
                    selection: Binding(
                        get: { model.selectedDriveID ?? "" },
                        set: { model.selectDrive(id: $0.isEmpty ? nil : $0) }
                    )
                ) {
                    Text("Не выбрано").tag("")
                    ForEach(model.drives) { drive in
                        Text(drive.displayName).tag(drive.id)
                    }
                }
                .pickerStyle(.menu)
                .disabled(model.drivesLoading || model.isBusy)

                Button {
                    Task { await model.refreshDrives() }
                } label: {
                    Label("Обновить", systemImage: "arrow.clockwise")
                }
                .disabled(model.drivesLoading || model.isBusy)

                if model.drivesLoading { ProgressView().controlSize(.small) }
            }
            Text(model.driveMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let drive = model.selectedDrive {
                Label("Источник открывается только для чтения: \(drive.rawDevicePath)", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }

    private var activityPanel: some View {
        HStack(spacing: 12) {
            if let fraction = processedFraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(model.activityTitle)
                    .font(.subheadline.weight(.semibold))
                Text(model.activityDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(formattedElapsed)
                    .monospacedDigit()
                    .font(.subheadline.weight(.medium))
                Text("Точное время окончания неизвестно")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private var processedFraction: Double? {
        guard let processed = model.processedBytes,
              let total = model.totalBytes,
              total > 0,
              processed >= min(1_048_576, max(1, total / 100)) else { return nil }
        return min(1, max(0, Double(processed) / Double(total)))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Восстановление удалённых файлов")
                .font(.largeTitle.bold())
            Text("Выберите подключённую флешку или карту памяти и отдельную папку для результата. Исходный накопитель открывается только для чтения.")
                .foregroundStyle(.secondary)
            Label(
                "Быстрый поиск сохраняет имена, когда метаданные уцелели; PhotoRec ищет фото и видео без имён.",
                systemImage: "checkmark.shield"
            )
            .font(.callout)
            .foregroundStyle(.orange)
        }
    }

    private var findingsTable: some View {
        Table(model.candidates, selection: $model.selection) {
            TableColumn("Имя") { item in
                Text(item.displayName).lineLimit(1)
            }
            TableColumn("Исходная папка") { item in
                Text(item.folder).lineLimit(1)
            }
            TableColumn("Тип") { item in
                Text(item.typeDescription)
            }
            .width(70)
            TableColumn("Запись") { item in
                Text(item.inode).font(.system(.caption, design: .monospaced))
            }
            .width(90)
        }
        .frame(minHeight: 220)
    }

    @ViewBuilder
    private var statusView: some View {
        switch model.state {
        case .ready:
            Text("Готово к поиску").foregroundStyle(.secondary)
        case .scanning, .recovering, .deepRecovering:
            EmptyView()
        case .scanFinished:
            Label("Поиск завершён", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .succeeded, .deepSucceeded, .failed, .cancelled:
            EmptyView()
        }
    }

    @ViewBuilder
    private var resultCard: some View {
        switch model.state {
        case .succeeded(let count, let folder):
            OperationResultCard(
                tone: .success,
                title: "Восстановление завершено",
                message: "Сохранено файлов: \(count).",
                path: folder.path,
                actionTitle: "Открыть папку"
            ) {
                NSWorkspace.shared.open(folder)
            }
        case .deepSucceeded(let count, let session):
            OperationResultCard(
                tone: .success,
                title: "Глубокий поиск завершён",
                message: "Найдено и сохранено файлов: \(count).",
                path: session.path,
                actionTitle: "Открыть папку"
            ) {
                NSWorkspace.shared.open(session)
            }
        case .cancelled(let session):
            OperationResultCard(
                tone: .warning,
                title: "Операция остановлена",
                message: session == nil
                    ? "Операция остановлена пользователем. Уже завершённые действия сохранены."
                    : "Уже найденные файлы сохранены в папке текущей сессии.",
                path: session?.path,
                actionTitle: session == nil ? nil : "Открыть папку",
                action: session.map { url in { NSWorkspace.shared.open(url) } }
            )
        case .failed(let failure):
            OperationResultCard(tone: .failure, title: failure.title, message: failure.message)
        case .ready, .scanning, .scanFinished, .recovering, .deepRecovering:
            EmptyView()
        }
    }

    private var formattedElapsed: String {
        let seconds = Int(model.elapsed)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var emptyStateDescription: String {
        if model.usesPhysicalDrive {
            return "Выберите папку результата на другом диске и нажмите «Начать восстановление»."
        }
        return "Выберите накопитель выше или откройте raw/IMG/DMG-образ в режиме для специалистов."
    }

    private var confirmationMessage: String {
        let capacityWarning = outputCapacityWarning.map { "\n\n⚠️ \($0)" } ?? ""
        if model.usesPhysicalDrive {
            return "macOS запросит разрешение на чтение выбранного накопителя. PhotoRec найдёт JPEG, PNG и MOV/MP4 и сохранит их только в указанную папку. Исходные имена и папки восстановить нельзя; могут попасться неудалённые файлы.\(capacityWarning)"
        }
        return "PhotoRec прочитает весь образ и сразу сохранит найденные JPEG, PNG и MOV/MP4 в отдельную папку. Исходные имена и структура каталогов будут потеряны; могут попасться и неудалённые файлы.\(capacityWarning)"
    }

    private var outputCapacityWarning: String? {
        guard let output = model.outputFolderURL,
              let values = try? output.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else { return nil }
        let sourceSize: Int64?
        if let drive = model.selectedDrive {
            sourceSize = drive.size
        } else if let image = model.imageURL {
            sourceSize = (try? image.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        } else {
            sourceSize = nil
        }
        guard let sourceSize, sourceSize > 0, available < sourceSize else { return nil }
        return "В папке результата свободно \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)), а размер источника — \(ByteCountFormatter.string(fromByteCount: sourceSize, countStyle: .file)). В худшем случае места может не хватить."
    }

    private func chooseDiskImage() {
        let panel = NSOpenPanel()
        panel.title = "Выберите образ накопителя"
        panel.prompt = "Выбрать"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [recoveryDiskImageType]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.selectImage(url)
    }
}
