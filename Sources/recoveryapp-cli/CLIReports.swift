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
        RecoveryApp CLI — безопасная диагностика накопителей через RecoveryCore.

        Использование:
          recoveryapp-cli help                     Показать эту справку
          recoveryapp-cli version [--json]         Версия приложения и сборки
          recoveryapp-cli drives list [--json]     Внешние физические накопители

        --json — машинночитаемый результат одной JSON-строкой в stdout.
        Команда «drives list» только перечисляет накопители: ни чтение содержимого,
        ни запись не выполняются, пароль не запрашивается.

        Коды выхода: 0 — успех; 1 — ошибка выполнения; 2 — неверные аргументы.
        Диагностика и подсказки выводятся в stderr.
        """

    static func description(for error: CLIUsageError) -> String {
        switch error {
        case .unknownCommand(let name):
            "Неизвестная команда «\(name)»."
        case .unknownOption(let option):
            "Неизвестный параметр «\(option)». Поддерживается только --json."
        case .missingDrivesCommand:
            "После «drives» укажите подкоманду «list»."
        case .unknownDrivesCommand(let name):
            "Неизвестная подкоманда «\(name)» для drives. Доступно: drives list."
        case .unexpectedArgument(let token):
            "Лишний аргумент «\(token)»."
        }
    }
}
