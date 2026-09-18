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
    case .quickScan(let image, let json):
        let imageURL = absoluteFileURL(image)
        let candidates = try await makeImageRecovery().scan(imageURL: imageURL)
        if json {
            try printJSON(QuickScanReport(
                schemaVersion: 1,
                source: imageURL.path,
                candidates: candidates.map { QuickCandidateReport($0) }
            ))
        } else if candidates.isEmpty {
            print("Удалённые файлы не найдены.")
        } else {
            print("Найдено удалённых файлов: \(candidates.count).")
            for candidate in candidates {
                let offset = candidate.partitionOffset > 0
                    ? "смещение \(candidate.partitionOffset)"
                    : "без таблицы разделов"
                print("  [\(candidate.filesystemType), \(offset)] \(candidate.path)")
            }
        }
    case .quickRecover(let image, let output, let json):
        let imageURL = absoluteFileURL(image)
        let outputURL = absoluteFileURL(output)
        let recovery = try makeImageRecovery()
        let candidates = try await recovery.scan(imageURL: imageURL)
        let recovered: [URL] = candidates.isEmpty
            ? []
            : try await recovery.recover(
                imageURL: imageURL,
                outputFolderURL: outputURL,
                candidates: candidates
            )
        if json {
            try printJSON(QuickRecoverReport(
                schemaVersion: 1,
                outputDirectory: outputURL.path,
                recoveredCount: recovered.count,
                files: recovered.map(\.path)
            ))
        } else if recovered.isEmpty {
            print("Удалённые файлы не найдены — восстанавливать нечего.")
        } else {
            print("Восстановлено файлов: \(recovered.count).")
            for file in recovered {
                print("  \(file.path)")
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
