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

struct QuickCandidateReport: Encodable {
    let inode: String
    let path: String
    let displayName: String
    let partitionOffset: Int64
    let filesystemType: String

    init(_ candidate: DeletedFileCandidate) {
        inode = candidate.inode
        path = candidate.path
        displayName = candidate.displayName
        partitionOffset = candidate.partitionOffset
        filesystemType = candidate.filesystemType
    }
}

struct QuickRecoverReport: Encodable {
    let schemaVersion: Int
    let outputDirectory: String
    let recoveredCount: Int
    let files: [String]
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

        --json — машинночитаемый результат одной JSON-строкой в stdout.
        Пути встроенных инструментов mmls, fls и icat берутся из переменных
        окружения RECOVERYAPP_MMLS_PATH, RECOVERYAPP_FLS_PATH, RECOVERYAPP_ICAT_PATH.
        Команды для образов читают только обычные файлы-образы и не обращаются
        к физическим накопителям; пароль не запрашивается.

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
        }
    }
}
