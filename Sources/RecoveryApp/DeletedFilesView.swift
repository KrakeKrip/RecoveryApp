import AppKit
import RecoveryCore
import SwiftUI
import UniformTypeIdentifiers

private let recoveryDiskImageType = UTType(importedAs: "org.recoveryapp.disk-image")


struct DeletedFilesView: View {
    @StateObject private var model: DeletedFilesViewModel

    init(initialDriveID: ExternalDrive.ID? = nil) {
        _model = StateObject(wrappedValue: DeletedFilesViewModel(initialDriveID: initialDriveID))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                HStack(alignment: .top, spacing: 12) {
                    sourceCard
                    outputCard
                }

                Label(
                    "Источник открывается только для чтения. Найденные файлы сохраняются отдельно.",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.green)

                if model.isBusy {
                    activityPanel
                    HStack {
                        Spacer()
                        Button("Остановить", role: .destructive) { model.cancel() }
                    }
                } else if model.hasTerminalResult {
                    resultCard
                    Button("Начать новый поиск") { model.scan() }
                        .disabled(!model.canScan || model.outputFolderURL == nil)
                } else if model.state == .scanFinished {
                    scanResults
                } else {
                    searchActions
                }

                advancedSource
                LogPanel(isExpanded: $model.showingLog, text: model.log)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(26)
        }
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

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("1 · Откуда восстановить")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let image = model.imageURL {
                Text(image.lastPathComponent)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Выбран образ накопителя")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !model.drives.isEmpty {
                    Menu("Переключиться на флешку") {
                        ForEach(model.drives) { drive in
                            Button(drive.displayName) { model.selectDrive(id: drive.id) }
                        }
                    }
                    .font(.caption)
                    .disabled(model.isBusy)
                }
            } else {
                Picker(
                    "Накопитель",
                    selection: Binding(
                        get: { model.selectedDriveID ?? "" },
                        set: { model.selectDrive(id: $0.isEmpty ? nil : $0) }
                    )
                ) {
                    Text("Выберите накопитель").tag("")
                    ForEach(model.drives) { drive in
                        Text(drive.displayName).tag(drive.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(model.drivesLoading || model.isBusy)

                if model.selectedDrive != nil {
                    Text("Внешний накопитель выбран")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(model.driveMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Button {
                Task { await model.refreshDrives() }
            } label: {
                Label("Обновить список", systemImage: "arrow.clockwise")
            }
            .font(.caption)
            .disabled(model.drivesLoading || model.isBusy)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("2 · Куда сохранить")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(model.outputFolderURL?.lastPathComponent ?? "Папка не выбрана")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(model.outputFolderURL?.path ?? "Выберите папку на другом диске")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            Button(model.outputFolderURL == nil ? "Выбрать папку…" : "Изменить папку…") {
                model.selectingOutput = true
            }
            .font(.caption)
            .disabled(model.isBusy)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var advancedSource: some View {
        DisclosureGroup("Для специалистов: открыть образ накопителя", isExpanded: $model.showingAdvancedSource) {
            FileChoiceRow(title: "Файл IMG, RAW, DD или DMG", url: model.imageURL) {
                chooseDiskImage()
            }
            Text("Выбор образа отключит выбранный физический накопитель. Этот режим нужен для экспертизы и повторяемых тестов.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(model.isBusy)
    }

    private var searchActions: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Начните с быстрого поиска")
                        .font(.headline)
                    Text("Покажет удалённые файлы. Имена сохранятся, если они уцелели.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button("Найти удалённые файлы") { model.scan() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.canScan || model.outputFolderURL == nil)
            }
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))

            if !model.canScan || model.outputFolderURL == nil {
                Text("Чтобы начать, выберите источник и папку результата.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            deepSearchOption
        }
    }

    private var deepSearchOption: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Не нашли нужное?")
                    .font(.subheadline.weight(.semibold))
                Text("Глубокий поиск может найти фото и видео, но без исходных имён и папок.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Глубокий поиск") { model.confirmingDeepRecovery = true }
                .disabled(!model.canDeepRecover)
        }
        .padding(.horizontal, 4)
    }

    private var scanResults: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Поиск завершён · найдено файлов: \(model.candidates.count)")
                        .font(.headline)
                    Text("Отметьте, что сохранить. Найденные файлы могут быть повреждены.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Повторить поиск") { model.scan() }
                    .disabled(!model.canScan || model.outputFolderURL == nil)
            }
            .padding(16)
            .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))

            if model.candidates.isEmpty {
                ContentUnavailableView {
                    Label("Удалённых файлов не найдено", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("Попробуйте глубокий поиск фото и видео или другой накопитель.")
                }
                .frame(minHeight: 170)
                deepSearchOption
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
            Text("Восстановление файлов")
                .font(.largeTitle.bold())
            Text("Выберите, откуда искать файлы и куда сохранить найденное.")
                .foregroundStyle(.secondary)
        }
    }

    private var findingsTable: some View {
        Table(model.candidates, selection: $model.selection) {
            TableColumn("Файл") { item in
                Text(item.displayName).lineLimit(1)
            }
            TableColumn("Исходная папка") { item in
                Text(item.folder).lineLimit(1)
            }
            TableColumn("Размер") { item in
                Text(item.expectedSize.map {
                    ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                } ?? "Неизвестен")
            }
            .width(110)
        }
        .frame(minHeight: 250)
    }

    @ViewBuilder
    private var resultCard: some View {
        switch model.state {
        case .succeeded(let summary):
            OperationResultCard(
                tone: summary.hasSizeProblems ? .warning : .success,
                title: summary.title,
                message: summary.message,
                path: summary.folder.path,
                actionTitle: "Открыть папку"
            ) {
                NSWorkspace.shared.open(summary.folder)
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
        model.showingAdvancedSource = false
    }
}
