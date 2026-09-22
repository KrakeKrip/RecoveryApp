import Foundation
import RecoveryCore

// Значения должны совпадать с CFBundleShortVersionString и CFBundleVersion
// в Packaging/Info.plist; менять их можно только отдельным пунктом задания.
enum ProductInfo {
    static let appVersion = "0.8.1"
    static let build = "13"
}

struct VersionReport: Encodable {
    let schemaVersion: Int
    let appVersion: String
    let build: String
}

struct DrivesReport: Encodable {
    let schemaVersion: Int
    let drives: [DriveReport]
}

struct DriveReport: Encodable {
    let id: String
    let name: String
    let size: Int64
    let rawDevicePath: String
    let mountPoints: [String]

    init(_ drive: ExternalDrive) {
        id = drive.identifier
        name = drive.name
        size = drive.size
        rawDevicePath = drive.rawDevicePath
        mountPoints = drive.mountPoints.map { $0.path(percentEncoded: false) }
    }
}

struct QuickScanReport: Encodable {
    let schemaVersion: Int
    let source: String
    let candidates: [QuickCandidateReport]
}

struct DriveIdentityReport: Encodable {
    let id: String
    let name: String
    let size: Int64
    let rawDevicePath: String

    init(_ drive: ExternalDrive) {
        id = drive.identifier
        name = drive.name
        size = drive.size
        rawDevicePath = drive.rawDevicePath
    }
}

struct PhysicalQuickScanReport: Encodable {
    let schemaVersion: Int
    let drive: DriveIdentityReport
    let candidates: [QuickCandidateReport]
}

struct QuickCandidateReport: Encodable {
    let inode: String
    let path: String
    let displayName: String
    let partitionOffset: Int64
    let filesystemType: String
    let expectedSize: Int64?

    init(_ candidate: DeletedFileCandidate) {
        inode = candidate.inode
        path = candidate.path
        displayName = candidate.displayName
        partitionOffset = candidate.partitionOffset
        filesystemType = candidate.filesystemType
        expectedSize = candidate.expectedSize
    }
}

struct RecoveredFileItemReport: Encodable {
    let path: String
    let expectedSize: Int64?
    let actualSize: Int64
    let status: String

    init(_ result: RecoveredFileResult) {
        path = result.url.path
        expectedSize = result.expectedSize
        actualSize = result.actualSize
        status = result.status.rawValue
    }
}

/// Агрегированные счётчики по опубликованным файлам; сумма равна
/// recoveredCount.
struct StatusCountsReport: Encodable {
    let expectedEmpty: Int
    let sizeMatches: Int
    let incomplete: Int
    let sizeMismatch: Int
    let sizeUnknown: Int

    init(results: [RecoveredFileResult]) {
        var counts = [
            RecoveredFileSizeStatus.expectedEmpty: 0,
            .sizeMatches: 0,
            .incomplete: 0,
            .sizeMismatch: 0,
            .sizeUnknown: 0
        ]
        for result in results {
            counts[result.status, default: 0] += 1
        }
        expectedEmpty = counts[.expectedEmpty] ?? 0
        sizeMatches = counts[.sizeMatches] ?? 0
        incomplete = counts[.incomplete] ?? 0
        sizeMismatch = counts[.sizeMismatch] ?? 0
        sizeUnknown = counts[.sizeUnknown] ?? 0
    }
}

struct QuickRecoverReport: Encodable {
    let schemaVersion: Int
    let outputDirectory: String
    let recoveredCount: Int
    let files: [String]
    let items: [RecoveredFileItemReport]
    let statusCounts: StatusCountsReport

    init(outputDirectory: String, results: [RecoveredFileResult]) {
        schemaVersion = 1
        self.outputDirectory = outputDirectory
        recoveredCount = results.count
        files = results.map(\.url.path)
        items = results.map { RecoveredFileItemReport($0) }
        statusCounts = StatusCountsReport(results: results)
    }
}

extension ExternalDrive {
    var cliSummaryLine: String {
        let mounts = mountPoints.isEmpty
            ? "не смонтирован"
            : mountPoints.map { $0.path(percentEncoded: false) }.joined(separator: ", ")
        return "\(id) · \(displayName) — \(rawDevicePath) · \(mounts)"
    }
}

enum CommandLineHelp {
    static let usage = """
        RecoveryApp CLI — безопасная диагностика и восстановление через RecoveryCore.

        Использование:
          recoveryapp-cli help                          Показать эту справку
          recoveryapp-cli version [--json]              Версия приложения и сборки
          recoveryapp-cli drives list [--json]          Внешние физические накопители
          recoveryapp-cli quick scan --image ФАЙЛ [--json]
              Найти удалённые записи FAT32/exFAT в файле-образе, ничего не записывая
          recoveryapp-cli quick recover --image ФАЙЛ --output ПАПКА --all [--json]
              Повторно найти удалённые записи и восстановить их все в папку
          recoveryapp-cli quick scan --drive diskN --expected-name ИМЯ --expected-size БАЙТЫ [--json]
              Найти удалённые записи на внешнем накопителе только для чтения
          recoveryapp-cli quick recover --drive diskN --expected-name ИМЯ --expected-size БАЙТЫ --output ПАПКА --all [--json]
              Найти и восстановить все записи с накопителя в папку

        --image и --drive взаимоисключающие. Для --drive система заново
        обнаруживает накопитель и сверяет точные имя и размер до запроса
        разрешения; одна команда создаёт не более одного системного запроса.
        macOS может показать запрос пароля для read-only доступа.
        Пароль CLI не принимает ни в каком виде.

        --json — машинночитаемый результат одной JSON-строкой в stdout.
        Пути встроенных инструментов mmls, fls и icat берутся из переменных
        окружения RECOVERYAPP_MMLS_PATH, RECOVERYAPP_FLS_PATH, RECOVERYAPP_ICAT_PATH.

        Коды выхода: 0 — успех; 1 — ошибка выполнения; 2 — неверные аргументы.
        Диагностика и подсказки выводятся в stderr.
        """

    static func description(for error: CLIUsageError) -> String {
        switch error {
        case .unknownCommand(let name):
            "Неизвестная команда «\(name)»."
        case .unknownOption(let option):
            "Неизвестный параметр «\(option)». Поддерживаются --json, --image, --output, --all."
        case .missingDrivesCommand:
            "После «drives» укажите подкоманду «list»."
        case .unknownDrivesCommand(let name):
            "Неизвестная подкоманда «\(name)» для drives. Доступно: drives list."
        case .unexpectedArgument(let token):
            "Лишний аргумент «\(token)»."
        case .missingQuickCommand:
            "После «quick» укажите подкоманду: quick scan или quick recover."
        case .unknownQuickCommand(let name):
            "Неизвестная подкоманда «\(name)» для quick. Доступно: quick scan, quick recover."
        case .missingOptionValue(let option):
            "После «\(option)» укажите значение."
        case .missingRequiredOption(let option):
            "Не указан обязательный параметр \(option)."
        case .duplicateOption(let option):
            "Параметр «\(option)» указан более одного раза."
        case .optionNotAllowed(let option, let command):
            "Параметр «\(option)» не применяется к команде «\(command)»."
        case .conflictingOptions(let first, let second):
            "Параметры «\(first)» и «\(second)» взаимоисключающие."
        case .missingSourceOption:
            "Укажите источник: --image ФАЙЛ или --drive diskN с ожидаемыми именем и размером."
        case .invalidDriveIdentifier(let value):
            "Идентификатор накопителя указывается как diskN без /dev/, получено «\(value)»."
        case .invalidExpectedSize(let value):
            "Ожидаемый размер должен быть положительным числом байтов, получено «\(value)»."
        }
    }
}
