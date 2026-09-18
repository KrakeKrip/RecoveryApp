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
    }
} catch let error as CLIUsageError {
    writeErrorLine(CommandLineHelp.description(for: error))
    writeErrorLine(CommandLineHelp.usage)
    exit(2)
} catch {
    writeErrorLine("Ошибка: \(error.localizedDescription)")
    exit(1)
}
