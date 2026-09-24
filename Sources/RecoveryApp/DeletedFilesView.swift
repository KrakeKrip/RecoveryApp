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
