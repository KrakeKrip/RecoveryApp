import Foundation
import RecoveryCore

let cliArguments = Array(CommandLine.arguments.dropFirst())

func writeErrorLine(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    print(String(decoding: data, as: UTF8.self))
}

/// Пользовательские пути приводятся к абсолютным: контракт JSON требует
/// абсолютные source/outputDirectory.
func absoluteFileURL(_ path: String) -> URL {
    let url = URL(fileURLWithPath: path)
    guard !path.hasPrefix("/") else { return url.standardizedFileURL }
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    return cwd.appendingPathComponent(path).standardizedFileURL
}

func makeImageRecovery() throws -> ImageQuickRecovery {
    ImageQuickRecovery(tools: try ImageQuickToolSet.fromEnvironment())
}

func makePhysicalRecovery() throws -> PhysicalQuickRecovery {
    let helper = try RecoveryToolLocator.toolURL(
        named: "recoveryapp-metadata-helper",
        environmentKey: "RECOVERYAPP_METADATA_HELPER_PATH"
    )
    return PhysicalQuickRecovery(helper: helper, launcher: try? RecoveryToolLocator.launcherURL())
}

/// Технический прогресс физического режима — в stderr, stdout остаётся чистым.
let progressToStderr: @MainActor @Sendable (String) -> Void = { text in
    FileHandle.standardError.write(Data(text.utf8))
}

func printCandidates(_ candidates: [DeletedFileCandidate]) {
    if candidates.isEmpty {
        print("Удалённые файлы не найдены.")
        return
    }
    print("Найдено удалённых файлов: \(candidates.count).")
    for candidate in candidates {
        let offset = candidate.partitionOffset > 0
            ? "смещение \(candidate.partitionOffset)"
            : "без таблицы разделов"
        let size = candidate.expectedSize != nil
            ? ", ожидаемый размер \(candidate.expectedSize!)"
            : ", размер неизвестен"
        print("  [\(candidate.filesystemType), \(offset)\(size)] \(candidate.path)")
    }
}

func printRecoveryOutcome(_ results: [RecoveredFileResult]) {
    print("Восстановлено файлов: \(results.count).")
    for result in results {
        print("  [\(result.status.rawValue)] \(result.url.path)")
    }
    let incomplete = results.filter { $0.status == .incomplete }
    let mismatched = results.filter { $0.status == .sizeMismatch }
    let unknown = results.filter { $0.status == .sizeUnknown }
    if !incomplete.isEmpty {
        print("Внимание: \(incomplete.count) извлечены не полностью — фактический размер меньше ожидаемого из метаданных.")
    }
    if !mismatched.isEmpty {
        print("Внимание: \(mismatched.count) файл(ов) больше ожидаемого размера из метаданных.")
    }
    if !unknown.isEmpty {
        print("Размер источника неизвестен для \(unknown.count) файл(ов) — размерная сверка невозможна.")
    }
    print("Совпадение размеров не является проверкой целостности содержимого.")
}

do {
    switch try CommandLineParser.parse(cliArguments) {
    case .help:
        print(CommandLineHelp.usage)
    case .version(let json):
        if json {
            try printJSON(
                VersionReport(
                    schemaVersion: 1,
                    appVersion: ProductInfo.appVersion,
                    build: ProductInfo.build
                )
            )
        } else {
            print("RecoveryApp \(ProductInfo.appVersion), сборка \(ProductInfo.build)")
        }
    case .drivesList(let json):
        let drives = try await ExternalDriveDiscovery().load()
        if json {
            try printJSON(DrivesReport(schemaVersion: 1, drives: drives.map { DriveReport($0) }))
        } else if drives.isEmpty {
            print("Внешние накопители не найдены.")
        } else {
            print("Внешние накопители:")
            for drive in drives {
                print("  \(drive.cliSummaryLine)")
            }
        }
    case .quickScan(let source, let json):
        switch source {
        case .image(let image):
            let imageURL = absoluteFileURL(image)
            let candidates = try await makeImageRecovery().scan(imageURL: imageURL)
            if json {
                try printJSON(QuickScanReport(
                    schemaVersion: 1,
                    source: imageURL.path,
                    candidates: candidates.map { QuickCandidateReport($0) }
                ))
            } else {
                printCandidates(candidates)
            }
        case .drive(let identifier, let expectedName, let expectedSize):
            // Повторное обнаружение и сверка id/имени/размера выполняются
            // до Authorization Services.
            let discovered = try await ExternalDriveDiscovery().load()
            let drive = try PhysicalDriveSelector.selectDrive(
                identifier: identifier,
                expectedName: expectedName,
                expectedSize: expectedSize,
                from: discovered
            )
            let candidates = try await makePhysicalRecovery().scan(
                drive: drive,
                onOutput: progressToStderr
            )
            if json {
                try printJSON(PhysicalQuickScanReport(
                    schemaVersion: 1,
                    drive: DriveIdentityReport(drive),
                    candidates: candidates.map { QuickCandidateReport($0) }
                ))
            } else {
                print("Накопитель: \(drive.id) · \(drive.name) — \(drive.rawDevicePath).")
                printCandidates(candidates)
            }
        }
    case .quickRecover(let source, let output, let json):
        let outputURL = absoluteFileURL(output)
        switch source {
        case .image(let image):
            let imageURL = absoluteFileURL(image)
            let recovery = try makeImageRecovery()
            let results = try await recovery.recoverDetailed(
                imageURL: imageURL,
                outputFolderURL: outputURL,
                candidates: try await recovery.scan(imageURL: imageURL)
            )
            if json {
                try printJSON(QuickRecoverReport(
                    outputDirectory: outputURL.path,
                    results: results
                ))
            } else if results.isEmpty {
                print("Удалённые файлы не найдены — восстанавливать нечего.")
            } else {
                printRecoveryOutcome(results)
            }
        case .drive(let identifier, let expectedName, let expectedSize):
            // Повторное обнаружение и сверка — до Authorization Services;
            // preflight папки результата — до создания сессии и скана.
            // Один экземпляр PhysicalQuickRecovery держит одну сессию
            // для scan и всех icat этой команды.
            let discovered = try await ExternalDriveDiscovery().load()
            let drive = try PhysicalDriveSelector.selectDrive(
                identifier: identifier,
                expectedName: expectedName,
                expectedSize: expectedSize,
                from: discovered
            )
            try PhysicalQuickRecovery.preflightRecoveryOutput(
                outputFolderURL: outputURL,
                drive: drive
            )
            let recovery = try makePhysicalRecovery()
            let candidates = try await recovery.scan(drive: drive, onOutput: progressToStderr)
            let results: [RecoveredFileResult] = candidates.isEmpty
                ? []
                : try await recovery.recoverDetailed(
                    drive: drive,
                    outputFolderURL: outputURL,
                    candidates: candidates,
                    onOutput: progressToStderr
                )
            if json {
                try printJSON(QuickRecoverReport(
                    outputDirectory: outputURL.path,
                    results: results
                ))
            } else if results.isEmpty {
                print("Удалённые файлы не найдены — восстанавливать нечего.")
            } else {
                printRecoveryOutcome(results)
            }
        }
    }
} catch let error as CLIUsageError {
    writeErrorLine(CommandLineHelp.description(for: error))
    writeErrorLine(CommandLineHelp.usage)
    exit(2)
} catch {
    writeErrorLine("Ошибка: \(error.localizedDescription)")
    exit(1)
}
