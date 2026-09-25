import SwiftUI
import AppKit
import RecoveryCore
import UniformTypeIdentifiers

@MainActor
final class VideoRepairViewModel: ObservableObject {
    enum State: Equatable {
        case ready
        case running
        case succeeded(URL)
        case failed(UserFacingFailure)
        case cancelled
    }

    @Published var referenceURL: URL?
    @Published var damagedURL: URL?
    @Published var outputFolderURL: URL?
    @Published var state: State = .ready
    @Published var log = ""
    @Published var elapsed: TimeInterval = 0
    @Published var selectingReference = false
    @Published var selectingDamaged = false
    @Published var selectingOutput = false
    @Published var showingLog = false

    private let executor = VideoRepairExecutor()
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var processActivity: NSObjectProtocol?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let path = environment["RECOVERYAPP_TEST_REFERENCE"] {
            referenceURL = URL(fileURLWithPath: path)
        }
        if let path = environment["RECOVERYAPP_TEST_DAMAGED"] {
            damagedURL = URL(fileURLWithPath: path)
        }
        if let path = environment["RECOVERYAPP_TEST_OUTPUT"] {
            outputFolderURL = URL(fileURLWithPath: path)
        }
        if let path = environment["RECOVERYAPP_TEST_VIDEO_SUCCESS"] {
            state = .succeeded(URL(fileURLWithPath: path))
        } else if environment["RECOVERYAPP_TEST_VIDEO_FAILURE"] == "missing-source" {
            state = .failed(UserFacingFailure.make(from: VideoRepairError.inputMissing))
        } else if environment["RECOVERYAPP_TEST_VIDEO_CANCELLED"] == "1" {
            state = .cancelled
        }
    }

    var canStart: Bool {
        referenceURL != nil && damagedURL != nil && outputFolderURL != nil && state != .running
    }

    func start() {
        guard let referenceURL, let damagedURL, let outputFolderURL else { return }
        let request = VideoRepairRequest(
            referenceURL: referenceURL,
            damagedURL: damagedURL,
            outputFolderURL: outputFolderURL
        )
        state = .running
        log = "Запуск встроенного untrunc…\n"
        elapsed = 0
        if processActivity == nil {
            processActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "RecoveryApp восстанавливает видео"
            )
        }
        let startDate = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.elapsed = Date().timeIntervalSince(startDate) }
        }

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.executor.run(request: request) { [weak self] text in
                    self?.log.append(text)
                }
                self.finishTimer()
                self.state = .succeeded(result)
                self.log.append("\nГотово: \(result.path)\n")
            } catch let error as VideoRepairError {
                self.finishTimer()
                if case .cancelled = error {
                    self.state = .cancelled
                } else {
                    self.state = .failed(UserFacingFailure.make(from: error))
                }
                self.log.append("\n\(error.localizedDescription)\n")
            } catch {
                self.finishTimer()
                self.state = .failed(UserFacingFailure.make(from: error))
                self.log.append("\n\(error.localizedDescription)\n")
            }
        }
    }

    func cancel() {
        executor.cancel()
        task?.cancel()
    }

    private func finishTimer() {
        timer?.invalidate()
        timer = nil
        if let processActivity {
            ProcessInfo.processInfo.endActivity(processActivity)
            self.processActivity = nil
        }
    }
}

struct VideoRepairView: View {
    @StateObject private var model = VideoRepairViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                RecoveryPageHeader(
                    symbol: "video.badge.ellipsis",
                    title: "Восстановление видео",
                    subtitle: "Нужен исправный пример с того же устройства. Исходное видео не изменится."
                )

                FileChoiceRow(title: "Исправный пример", url: model.referenceURL, step: 1, symbol: "film") {
                    model.selectingReference = true
                }
                FileChoiceRow(title: "Повреждённое видео", url: model.damagedURL, step: 2, symbol: "video") {
                    model.selectingDamaged = true
                }
                FileChoiceRow(title: "Куда сохранить результат", url: model.outputFolderURL, step: 3, symbol: "folder") {
                    model.selectingOutput = true
                }

                HStack(spacing: 12) {
                    Image(systemName: model.state == .running ? "arrow.triangle.2.circlepath" : "sparkles")
                        .font(.title3)
                        .foregroundStyle(RecoveryPalette.lavender)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.state == .running ? "Исправляем видео · \(formattedElapsed)" : "Готовы исправить видео?")
                            .font(.headline)
                        Text(model.state == .running
                             ? "Точное время окончания неизвестно"
                             : "Готовый файл появится в выбранной папке отдельно от оригинала.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    if model.state == .running {
                        ProgressView().controlSize(.small)
                        Button("Остановить", role: .destructive) { model.cancel() }
                    } else if model.canStart {
                        Button("Начать восстановление") { model.start() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    } else {
                        Text("Выберите три пункта выше")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .recoveryPanel()

                resultCard
                LogPanel(isExpanded: $model.showingLog, text: model.log)
            }
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.vertical, 30)
        }
        .navigationTitle("Повреждённые видео")
        .fileImporter(isPresented: $model.selectingReference, allowedContentTypes: [.movie]) { result in
            if case .success(let url) = result { model.referenceURL = url }
        }
        .fileImporter(isPresented: $model.selectingDamaged, allowedContentTypes: [.movie]) { result in
            if case .success(let url) = result { model.damagedURL = url }
        }
        .fileImporter(isPresented: $model.selectingOutput, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.outputFolderURL = url }
        }
    }

    @ViewBuilder
    private var resultCard: some View {
        switch model.state {
        case .succeeded(let url):
            OperationResultCard(
                tone: .success,
                title: "Видео восстановлено",
                message: "Готовый файл сохранён отдельно. Исходное повреждённое видео не изменялось.",
                path: url.path,
                actionTitle: "Показать файл"
            ) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case .failed(let failure):
            OperationResultCard(tone: .failure, title: failure.title, message: failure.message)
        case .cancelled:
            OperationResultCard(
                tone: .warning,
                title: "Операция остановлена",
                message: "Обработка остановлена пользователем. Исходные видео не изменялись."
            )
        case .ready, .running:
            EmptyView()
        }
    }

    private var formattedElapsed: String {
        let seconds = Int(model.elapsed)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct FileChoiceRow: View {
    let title: String
    let url: URL?
    let step: Int?
    let symbol: String
    let action: () -> Void

    init(title: String, url: URL?, step: Int? = nil, symbol: String = "doc", action: @escaping () -> Void) {
        self.title = title
        self.url = url
        self.step = step
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let step {
                RecoveryStepHeading(number: step, title: title, symbol: symbol)
            } else {
                Text(title).font(.headline)
            }
            HStack(spacing: 14) {
                Text(url?.path ?? "Пока не выбрано")
                    .font(.subheadline)
                    .foregroundStyle(url == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(url == nil ? "Выбрать…" : "Изменить…", action: action)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .recoveryPanel()
    }
}
