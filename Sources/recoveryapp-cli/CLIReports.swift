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
    let actualSize: Int64?
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

// MARK: - JSONL-события `deep recover --jsonl`
//
// Контракт stdout в режиме --jsonl: не более одного валидного JSON-объекта на
// строку; сообщения и техническая диагностика идут в stderr. Значения, которые
// пока нельзя достоверно определить, ключом не кодируются (никаких нулевых
// подмен). ETA не выдаётся никогда.

/// Источник запуска deep recover. Для образа — абсолютный путь файла, для
/// накопителя — повторно сверенные идентификатор, имя, размер и raw-путь.
enum DeepSourceReport: Encodable {
    case image(path: String)
    case drive(id: String, name: String, size: Int64, rawDevicePath: String)

    private enum CodingKeys: String, CodingKey {
        case type, path, id, name, size, rawDevicePath
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .image(let path):
            try container.encode("image", forKey: .type)
            try container.encode(path, forKey: .path)
        case .drive(let id, let name, let size, let rawDevicePath):
            try container.encode("drive", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(size, forKey: .size)
            try container.encode(rawDevicePath, forKey: .rawDevicePath)
        }
    }
}

struct DeepStartedEvent: Encodable {
    let event = "started"
    let schemaVersion = 1
    let source: DeepSourceReport
    let sessionDirectory: String
}

/// progress: прошедшее время, найденные файлы и доступные фактические
/// счётчики чтения/объёма результата. processedBytes/totalBytes присутствуют
/// только когда есть источник метрик (файл прогресса helper, photorec.ses);
/// readBytesPerSecond — только при реальных измерениях на двух снимках.
struct DeepProgressEvent: Encodable {
    let event = "progress"
    let schemaVersion = 1
    let elapsedSeconds: Double
    let foundFiles: Int
    let resultBytes: Int64
    let processedBytes: Int64?
    let totalBytes: Int64?
    let readBytesPerSecond: Double?

    private enum CodingKeys: String, CodingKey {
        case event, schemaVersion, elapsedSeconds, foundFiles, resultBytes
        case processedBytes, totalBytes, readBytesPerSecond
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(event, forKey: .event)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(elapsedSeconds, forKey: .elapsedSeconds)
        try container.encode(foundFiles, forKey: .foundFiles)
        try container.encode(resultBytes, forKey: .resultBytes)
        try container.encodeIfPresent(processedBytes, forKey: .processedBytes)
        try container.encodeIfPresent(totalBytes, forKey: .totalBytes)
        try container.encodeIfPresent(readBytesPerSecond, forKey: .readBytesPerSecond)
    }
}

struct DeepCompletedEvent: Encodable {
    let event = "completed"
    let schemaVersion = 1
    let sessionDirectory: String
    let recoveredCount: Int
    let files: [String]
}

/// Итог после Ctrl-C: папка сессии сохраняется, files — уже найденные файлы.
/// sessionDirectory отсутствует, только если отмена случилась до создания
/// папки сессии.
struct DeepCancelledEvent: Encodable {
    let event = "cancelled"
    let schemaVersion = 1
    let sessionDirectory: String?
    let foundFiles: Int
    let files: [String]

    private enum CodingKeys: String, CodingKey {
        case event, schemaVersion, sessionDirectory, foundFiles, files
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(event, forKey: .event)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(sessionDirectory, forKey: .sessionDirectory)
        try container.encode(foundFiles, forKey: .foundFiles)
        try container.encode(files, forKey: .files)
    }
}

struct DeepErrorEvent: Encodable {
    let event = "error"
    let schemaVersion = 1
    let code: String
    let message: String
}

/// Стабильные коды ошибки для события error; строка сообщения понятна
/// пользователю и может уточняться без смены кода.
func deepErrorCode(for error: Error) -> String {
    guard let deletedError = error as? DeletedFilesError else { return "internal" }
    return switch deletedError {
    case .imageMissing: "imageMissing"
    case .imageNotRegularFile: "imageNotRegularFile"
    case .invalidDriveSource: "invalidDriveSource"
    case .outputFolderMissing: "outputFolderMissing"
    case .outputFolderNotWritable: "outputFolderNotWritable"
    case .outputOnSource: "outputOnSource"
    case .sourceUnavailable: "sourceUnavailable"
    case .sourceChanged: "sourceChanged"
    case .authorizationDenied: "authorizationDenied"
    case .toolMissing: "toolMissing"
    case .unsupportedImage: "unsupportedImage"
    case .launchFailed: "launchFailed"
    case .toolFailed: "toolFailed"
    case .outputSpaceExhausted: "outputSpaceExhausted"
    case .sourceReadFailed: "sourceReadFailed"
    case .cancelled: "cancelled"
    case .nothingSelected: "nothingSelected"
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
          recoveryapp-cli deep recover --image ФАЙЛ --output ПАПКА [--jsonl]
              Глубокий сигнатурный поиск PhotoRec по всему образу: JPEG, PNG, MOV/MP4
          recoveryapp-cli deep recover --drive diskN --expected-name ИМЯ --expected-size БАЙТЫ --output ПАПКА [--jsonl]
              Глубокий сигнатурный поиск по внешнему накопителю только для чтения

        --image и --drive взаимоисключающие. Для --drive система заново
        обнаруживает накопитель и сверяет точные имя и размер до запроса
        разрешения; одна команда создаёт не более одного системного запроса.
        macOS может показать запрос пароля для read-only доступа.
        Пароль CLI не принимает ни в каком виде.

        Глубокий режим сразу запускает PhotoRec без предварительного скана и
        создаёт уникальную папку сессии внутри --output: результаты, журнал и
        photorec.ses находятся только в ней. Исходные имена и папки не
        восстанавливаются. Точный ETA не показывается — достоверного источника
        для него нет. Остановка (Ctrl-C) завершает всю группу PhotoRec/helper,
        уже найденные файлы остаются в папке сессии.

        --json — машинночитаемый результат одной JSON-строкой (quick, drives,
        version). --jsonl — построчные JSON-события deep recover в stdout:
        started (источник и папка сессии), progress (прошедшее время, найдено
        файлов, доступные счётчики чтения), completed (папка сессии, число и
        пути файлов), cancelled (папка сессии и уже найденные файлы), error
        (стабильный код и понятное сообщение). Диагностика всегда идёт в stderr.

        Пути встроенных инструментов берутся из переменных окружения
        RECOVERYAPP_MMLS_PATH, RECOVERYAPP_FLS_PATH, RECOVERYAPP_ICAT_PATH,
        RECOVERYAPP_PHOTOREC_PATH, RECOVERYAPP_READONLY_HELPER_PATH.

        Коды выхода: 0 — успех (включая пустой результат); 1 — ошибка
        выполнения; 2 — неверные аргументы; 130 — операция остановлена
        (Ctrl-C), найденные файлы сохранены.
        """

    static func description(for error: CLIUsageError) -> String {
        switch error {
        case .unknownCommand(let name):
            "Неизвестная команда «\(name)»."
        case .unknownOption(let option):
            "Неизвестный параметр «\(option)». Поддерживаются --json, --jsonl, --image, --output, --all."
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
        case .missingDeepCommand:
            "После «deep» укажите подкоманду «recover»."
        case .unknownDeepCommand(let name):
            "Неизвестная подкоманда «\(name)» для deep. Доступно: deep recover."
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
