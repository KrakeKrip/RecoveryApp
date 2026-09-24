import Foundation
import RecoveryCore

// Счётчик позволяет печатать фактическое число проверок вместо ручной константы.
nonisolated(unsafe) private var checkCount = 0

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checkCount += 1
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

check(RecoveryFeature.videoRepair.title == "Повреждённые видео", "название раздела видео")
check(RecoveryFeature.deletedFiles.title == "Удалённые файлы", "название раздела файлов")

let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("RecoveryAppTests-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }

let reference = root.appendingPathComponent("reference.mp4")
let damaged = root.appendingPathComponent("clip.mp4")
let existing = root.appendingPathComponent("clip_recovered.mp4")
_ = FileManager.default.createFile(atPath: reference.path, contents: Data("reference".utf8))
_ = FileManager.default.createFile(atPath: damaged.path, contents: Data("damaged".utf8))
_ = FileManager.default.createFile(atPath: existing.path, contents: Data())

let request = VideoRepairRequest(
    referenceURL: reference,
    damagedURL: damaged,
    outputFolderURL: root
)
// Политика физического носителя: результат и исходники на одном носителе
// теперь отклоняются, поэтому валидация здесь использует внедряемого
// поставщика с разными носителями (в production всегда применяется
// системный resolver).
try request.validate(medium: { url in
    var isDirectory: ObjCBool = false
    let isOutputFolder = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        && isDirectory.boolValue
    return VideoPhysicalMedium(identifiers: isOutputFolder ? ["out-medium"] : ["src-medium"])
})
check(request.resultURL().lastPathComponent == "clip_recovered_2.mp4", "результат не перезаписывается")

do {
    try VideoRepairRequest(
        referenceURL: reference,
        damagedURL: reference,
        outputFolderURL: root
    ).validate()
    check(false, "одинаковые входные файлы должны отклоняться")
} catch VideoRepairError.sameInputFiles {
    // Ожидаемая безопасная ошибка.
}

let flsOutput = """
r/r * 37:\tDOCS/_ECOVERY.TXT
d/d * 52:\tDELETED_FOLDER
r/r * 69:\tMEDIA/_ESTCARD.PNG
"""
let parsedFiles = SleuthKitOutputParser.deletedFiles(from: flsOutput, partitionOffset: 2048)
check(parsedFiles.count == 2, "fls parser пропускает каталоги")
check(parsedFiles[0].inode == "37", "fls parser извлекает inode")
check(parsedFiles[0].partitionOffset == 2048, "fls parser сохраняет смещение")
let physicalFiles = SleuthKitOutputParser.deletedFiles(
    from: flsOutput,
    partitionOffset: 2048,
    filesystemType: "exfat"
)
check(physicalFiles[0].filesystemType == "exfat", "fls parser сохраняет тип файловой системы")
check(physicalFiles[0].expectedSize == nil, "короткий fls не даёт ожидаемого размера")
let spacedNameParsed = SleuthKitOutputParser.deletedFiles(
    from: "r/r * 11:\tSPACE NAME.TXT",
    partitionOffset: 0
)
check(spacedNameParsed.count == 1 && spacedNameParsed[0].path == "SPACE NAME.TXT",
      "пробелы в имени не разделяют колонки")
check(spacedNameParsed[0].expectedSize == nil, "короткий fls с пробелами в имени без размера")

// Длинный формат `fls -l`: имя, четыре времени, размер, gid, uid.
let longFlsOutput = """
r/r * 4:\t_.TXT\t2026-09-22 23:32:08 (MSK)\t2026-09-22 00:00:00 (MSK)\t0000-00-00 00:00:00 (UTC)\t2026-09-22 23:32:08 (MSK)\t0\t0\t0
r/r * 419:\tTESTCARD.PNG\t2026-09-12 15:13:52 (MSK)\t2026-09-12 00:00:00 (MSK)\t0000-00-00 00:00:00 (UTC)\t2026-09-12 15:13:52 (MSK)\t26672\t0\t0
d/d * 8:\tDELETED_DIR\t2026-09-12 15:13:52 (MSK)\t2026-09-12 00:00:00 (MSK)\t0000-00-00 00:00:00 (UTC)\t2026-09-12 15:13:52 (MSK)\t4096\t0\t0
"""
let longParsed = SleuthKitOutputParser.deletedFiles(
    from: longFlsOutput,
    partitionOffset: 0,
    filesystemType: "exfat"
)
check(longParsed.count == 2, "длинный fls отфильтровывает каталоги")
check(longParsed[0].path == "_.TXT", "длинный fls сохраняет путь")
check(longParsed[0].expectedSize == nil,
      "ноль в колонке размера fls -l трактуется как неизвестный размер")
check(longParsed[0].displayName == "_.TXT", "длинный fls сохраняет имя")
check(longParsed[1].expectedSize == 26672, "положительный ожидаемый размер извлекается")
check(longParsed[1].inode == "419", "длинный fls сохраняет inode")
let tabbedNameOutput = "r/r * 9:\tMY FILE\tWITH\tTAB\t2026-09-12 15:13:52 (MSK)\t2026-09-12 00:00:00 (MSK)\t0000-00-00 00:00:00 (UTC)\t2026-09-12 15:13:52 (MSK)\t512\t0\t0"
let tabbedParsed = SleuthKitOutputParser.deletedFiles(from: tabbedNameOutput, partitionOffset: 0)
check(tabbedParsed.count == 1, "имя с табуляциями не создаёт лишних записей")
check(tabbedParsed[0].path == "MY FILE\tWITH\tTAB", "табуляции внутри имени сохраняются")
check(tabbedParsed[0].expectedSize == 512, "размер находится при табуляциях в имени")
check(tabbedParsed[0].displayName == "MY FILE\tWITH\tTAB", "displayName сохраняет имя с табуляциями целиком")

// Классификатор размерных статусов: пять состояний из архитектуры.
check(RecoveredFileSizeClassifier.status(expectedSize: 0, actualSize: 0) == .expectedEmpty,
      "нулевой источник и результат — expectedEmpty")
check(RecoveredFileSizeClassifier.status(expectedSize: 229, actualSize: 229) == .sizeMatches,
      "равные размеры — sizeMatches")
check(RecoveredFileSizeClassifier.status(expectedSize: 4246, actualSize: 4096) == .incomplete,
      "короткий результат — incomplete")
check(RecoveredFileSizeClassifier.status(expectedSize: 100, actualSize: 200) == .sizeMismatch,
      "результат больше ожидаемого — sizeMismatch")
check(RecoveredFileSizeClassifier.status(expectedSize: nil, actualSize: 4096) == .sizeUnknown,
      "неизвестный ожидаемый размер — sizeUnknown")
check(RecoveredFileSizeClassifier.status(expectedSize: 0, actualSize: 4096) == .sizeMismatch,
      "нулевой источник с непустым результатом — sizeMismatch")
check(RecoveredFileSizeClassifier.status(expectedSize: 229, actualSize: nil) == .sizeUnknown,
      "неизвестный фактический размер не маркируется как сверенный")
check(RecoveredFileSizeClassifier.status(expectedSize: 0, actualSize: nil) == .sizeUnknown,
      "неизвестный фактический размер при нулевом ожидании — sizeUnknown")

let mmlsOutput = """
004:  000       0000002048   0000249855   0000247808
005:  -------   0000249856   0000249999   0000000144   Unallocated
"""
check(SleuthKitOutputParser.partitionOffsets(from: mmlsOutput) == [2048], "mmls parser")

let existingDocument = root.appendingPathComponent("document.txt")
_ = FileManager.default.createFile(atPath: existingDocument.path, contents: Data())
check(
    ImageQuickRecovery.uniqueResultURL(suggestedName: "document.txt", folder: root)
        .lastPathComponent == "document_2.txt",
    "восстановление не перезаписывает найденный файл"
)

// Опасные имена из fls не должны выходить за пределы папки результата.
check(ImageQuickRecovery.safeResultName("..") == "recovered_file", "имя .. заменяется безопасным")
check(ImageQuickRecovery.safeResultName(".") == "recovered_file", "имя . заменяется безопасным")
check(ImageQuickRecovery.safeResultName("") == "recovered_file", "пустое имя заменяется безопасным")
check(ImageQuickRecovery.safeResultName("/etc/passwd") == "_etc_passwd", "абсолютный путь теряет разделители")
check(ImageQuickRecovery.safeResultName("dir/..\\evil") == "dir_.._evil", "разделители / и \\ заменяются")
let resultFolder = root.appendingPathComponent("results", isDirectory: true)
try FileManager.default.createDirectory(at: resultFolder, withIntermediateDirectories: false)
let escapeCandidate = ImageQuickRecovery.uniqueResultURL(suggestedName: "..", folder: resultFolder)
check(escapeCandidate.deletingLastPathComponent().standardizedFileURL == resultFolder.standardizedFileURL,
      "результат для имени .. остаётся внутри папки результата")
check(escapeCandidate.lastPathComponent != "..", "имя .. не попадает в результат")
let traversal = ImageQuickRecovery.uniqueResultURL(suggestedName: "RECOVERY.TXT", folder: resultFolder)
_ = FileManager.default.createFile(atPath: traversal.path, contents: Data("first".utf8))
check(
    ImageQuickRecovery.uniqueResultURL(suggestedName: "RECOVERY.TXT", folder: resultFolder)
        .lastPathComponent == "RECOVERY_2.TXT",
    "повторный запуск выбирает новое имя без перезаписи"
)

let photoRecBase = root.appendingPathComponent("PhotoRec-Recovery")
let photoRecFirst = root.appendingPathComponent("PhotoRec-Recovery.1", isDirectory: true)
let photoRecSecond = root.appendingPathComponent("PhotoRec-Recovery.2", isDirectory: true)
try FileManager.default.createDirectory(at: photoRecFirst, withIntermediateDirectories: false)
try FileManager.default.createDirectory(at: photoRecSecond, withIntermediateDirectories: false)
_ = FileManager.default.createFile(
    atPath: photoRecSecond.appendingPathComponent("f000001.jpg").path,
    contents: Data("jpeg".utf8)
)
let latestPhotoRecDirectory = try PhotoRecDeepRecovery.photoRecOutputDirectory(
    baseURL: photoRecBase
)
check(
    latestPhotoRecDirectory.lastPathComponent == photoRecSecond.lastPathComponent,
    "выбирается последний каталог результата PhotoRec"
)
check(
    PhotoRecDeepRecovery.regularFilesRecursively(in: photoRecSecond).count == 1,
    "подсчитываются восстановленные PhotoRec файлы"
)

let drivePlist: [String: Any] = [
    "AllDisksAndPartitions": [[
        "DeviceIdentifier": "disk7",
        "Size": 128_000_000_000 as NSNumber,
        "BusProtocol": "USB",
        "Partitions": [[
            "DeviceIdentifier": "disk7s1",
            "VolumeName": "TEST USB",
            "MountPoint": "/Volumes/TEST USB"
        ]]
    ]]
]
let driveData = try PropertyListSerialization.data(
    fromPropertyList: drivePlist,
    format: .xml,
    options: 0
)
let drives = try ExternalDriveParser.drives(from: driveData)
check(drives.count == 1, "diskutil parser находит внешний диск")
check(drives[0].displayName.contains("TEST USB"), "показывается имя тома")
check(drives[0].rawDevicePath == "/dev/rdisk7", "формируется raw read-only путь")
check(
    drives[0].contains(URL(fileURLWithPath: "/Volumes/TEST USB/results")),
    "запрещается результат на исходном накопителе"
)

// Физический источник: выбор и сверка диска по снимку без diskutil и авторизации.
let matchedDrive = try PhysicalDriveSelector.selectDrive(
    identifier: "disk7",
    expectedName: "TEST USB",
    expectedSize: 128_000_000_000,
    from: drives
)
check(matchedDrive.id == "disk7", "селектор находит сверенный диск")

private func expectDriveError(
    _ identifier: String,
    _ name: String,
    _ size: Int64,
    _ expected: DeletedFilesError,
    _ message: String
) {
    do {
        _ = try PhysicalDriveSelector.selectDrive(
            identifier: identifier,
            expectedName: name,
            expectedSize: size,
            from: drives
        )
        check(false, message)
    } catch let error as DeletedFilesError {
        check(error == expected, message)
    } catch {
        check(false, message)
    }
}

private func expectInvalidDriveSource(
    _ identifier: String,
    _ name: String,
    _ size: Int64,
    _ message: String
) {
    do {
        _ = try PhysicalDriveSelector.selectDrive(
            identifier: identifier,
            expectedName: name,
            expectedSize: size,
            from: drives
        )
        check(false, message)
    } catch let error as DeletedFilesError {
        guard case .invalidDriveSource = error else {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    } catch {
        check(false, message)
    }
}

expectDriveError("disk9", "TEST USB", 128_000_000_000, .sourceUnavailable, "отсутствующий диск даёт sourceUnavailable")
expectDriveError("disk7", "ДРУГОЕ ИМЯ", 128_000_000_000, .sourceChanged, "изменившееся имя даёт sourceChanged")
expectDriveError("disk7", "TEST USB", 127_000_000_000, .sourceChanged, "изменившийся размер даёт sourceChanged")
expectInvalidDriveSource("/dev/rdisk7", "TEST USB", 128_000_000_000, "raw-путь вместо diskN отклоняется")
expectInvalidDriveSource("disk7", "TEST USB", 0, "нулевой ожидаемый размер отклоняется")
expectInvalidDriveSource("disk7", "TEST USB", -5, "отрицательный ожидаемый размер отклоняется")

// JSON-кодирование физического отчёта скана.
let physicalScanData = try JSONEncoder().encode(PhysicalQuickScanReport(
    schemaVersion: 1,
    drive: DriveIdentityReport(drives[0]),
    candidates: []
))
let physicalScanJSON = String(decoding: physicalScanData, as: UTF8.self)
check(physicalScanJSON.contains("\"schemaVersion\":1"), "физический JSON содержит schemaVersion")
check(physicalScanJSON.contains("\"id\":\"disk7\""), "физический JSON содержит id")
check(physicalScanJSON.contains("\"rawDevicePath\"") && physicalScanJSON.contains("rdisk7"),
      "физический JSON содержит rawDevicePath")
check(physicalScanJSON.contains("\"candidates\":[]"), "физический JSON допускает пустой список кандидатов")

// Preflight выхода физического восстановления выполняется до Authorization
// Services: только файловая система и точки монтирования снимка диска.
// Синтетический снимок с реальным каталогом монтирования внутри temp.
let mntRoot = root.appendingPathComponent("mnt", isDirectory: true)
let mntInner = mntRoot.appendingPathComponent("inner", isDirectory: true)
try FileManager.default.createDirectory(at: mntInner, withIntermediateDirectories: true)
let mountedPlist: [String: Any] = [
    "AllDisksAndPartitions": [[
        "DeviceIdentifier": "disk8",
        "Size": 64_000_000_000 as NSNumber,
        "MountPoint": mntRoot.path
    ]]
]
let mountedData = try PropertyListSerialization.data(
    fromPropertyList: mountedPlist,
    format: .xml,
    options: 0
)
let mountedDrive = try ExternalDriveParser.drives(from: mountedData)[0]
do {
    try PhysicalQuickRecovery.preflightRecoveryOutput(outputFolderURL: mntInner, drive: mountedDrive)
    check(false, "output внутри точки монтирования отклоняется")
} catch let error as DeletedFilesError {
    check(error == .outputOnSource, "output внутри точки монтирования даёт outputOnSource")
} catch {
    check(false, "output внутри точки монтирования даёт outputOnSource")
}
do {
    try PhysicalQuickRecovery.preflightRecoveryOutput(
        outputFolderURL: root.appendingPathComponent("absent-output", isDirectory: true),
        drive: mountedDrive
    )
    check(false, "несуществующий output отклоняется")
} catch let error as DeletedFilesError {
    check(error == .outputFolderMissing, "несуществующий output даёт outputFolderMissing")
} catch {
    check(false, "несуществующий output даёт outputFolderMissing")
}
do {
    try PhysicalQuickRecovery.preflightRecoveryOutput(outputFolderURL: root, drive: mountedDrive)
    check(true, "корректный output вне источника проходит preflight")
} catch {
    check(false, "корректный output вне источника проходит preflight")
}

let dirtyLog = "\u{001B}[31mОшибка\u{001B}[0m\r\n\n\n  Следующий этап  \u{0007}"
let cleanLog = LogSanitizer.clean(dirtyLog)
check(!cleanLog.contains("\u{001B}"), "из лога удаляются ANSI-команды")
check(!cleanLog.contains("\u{0007}"), "из лога удаляются управляющие символы")
check(cleanLog == "Ошибка\n\nСледующий этап", "лог получает читаемые строки")

let photoRecTerminal = """
\u{001B}[2JPhotoRec 7.2, Data Recovery Utility\r
123456789\r
\u{001B}[5;1HDisk /dev/fd/4 - 2055 MB (RO)\r
Pass 0 - Reading sector 37674/4014080\r
Elapsed time 0h00m01s\r
PhotoRec 7.2, Data Recovery Utility\r
PhotoRec exited normally.\r
"""
let photoRecLog = LogSanitizer.photoRecSummary(photoRecTerminal)
check(!photoRecLog.contains("123456789"), "PhotoRec-лог скрывает служебные числа терминала")
check(photoRecLog.components(separatedBy: "PhotoRec 7.2").count == 2, "заголовок PhotoRec не дублируется")
check(photoRecLog.contains("Disk /dev/fd/4") && photoRecLog.contains("Pass 0"), "PhotoRec-лог сохраняет этапы сканирования")

check(
    UserFacingFailure.make(from: DeletedFilesError.outputSpaceExhausted).title == "Недостаточно места",
    "ENOSPC получает понятное сообщение"
)
check(
    UserFacingFailure.make(from: DeletedFilesError.authorizationDenied).title == "Доступ macOS не предоставлен",
    "отказ системного разрешения объясняется"
)
check(
    UserFacingFailure.make(from: DeletedFilesError.sourceUnavailable).title == "Накопитель отключён",
    "отключение накопителя объясняется"
)
check(
    DeletedFilesError.cancelled.localizedDescription == "Операция остановлена.",
    "остановка поиска не обещает сохранённые файлы"
)
check(
    UserFacingFailure.make(from: VideoRepairError.inputMissing).title == "Исходный файл исчез",
    "исчезнувший видеофайл объясняется"
)
let hiddenTechnicalFailure = UserFacingFailure.make(from: DeletedFilesError.toolFailed("icat", 73))
check(
    !hiddenTechnicalFailure.message.contains("73") && !hiddenTechnicalFailure.message.contains("icat"),
    "технический код скрыт из основной ошибки"
)

do {
    let emptyCommand = try CommandLineParser.parse([])
    let helpCommand = try CommandLineParser.parse(["help"])
    let versionText = try CommandLineParser.parse(["version"])
    let versionJSON = try CommandLineParser.parse(["version", "--json"])
    let drivesText = try CommandLineParser.parse(["drives", "list"])
    let drivesJSON = try CommandLineParser.parse(["drives", "list", "--json"])
    let quickScan = try CommandLineParser.parse(["quick", "scan", "--image", "a.img"])
    let quickScanJSON = try CommandLineParser.parse(["quick", "scan", "--json", "--image", "a.img"])
    let quickDriveScan = try CommandLineParser.parse([
        "quick", "scan", "--drive", "disk4", "--expected-name", "Flashka", "--expected-size", "125829120000"
    ])
    let quickDriveRecover = try CommandLineParser.parse([
        "quick", "recover", "--drive", "disk4", "--expected-name", "Flashka",
        "--expected-size", "125829120000", "--output", "res", "--all"
    ])
    let quickRecover = try CommandLineParser.parse([
        "quick", "recover", "--image", "i.img", "--output", "result", "--all"
    ])
    let quickRecoverJSON = try CommandLineParser.parse([
        "quick", "recover", "--image", "i.img", "--output", "result", "--all", "--json"
    ])
    check(emptyCommand == .help, "пустой вызов CLI показывает справку")
    check(helpCommand == .help, "help разбирается")
    check(versionText == .version(json: false), "version разбирается")
    check(versionJSON == .version(json: true), "version --json разбирается")
    check(drivesText == .drivesList(json: false), "drives list разбирается")
    check(drivesJSON == .drivesList(json: true), "drives list --json разбирается")
    check(quickScan == .quickScan(source: .image("a.img"), json: false), "quick scan разбирается")
    check(quickScanJSON == .quickScan(source: .image("a.img"), json: true), "quick scan --json разбирается")
    check(
        quickDriveScan == .quickScan(
            source: .drive(identifier: "disk4", expectedName: "Flashka", expectedSize: 125829120000),
            json: false
        ),
        "quick scan --drive разбирается"
    )
    check(
        quickDriveRecover == .quickRecover(
            source: .drive(identifier: "disk4", expectedName: "Flashka", expectedSize: 125829120000),
            output: "res",
            json: false
        ),
        "quick recover --drive разбирается"
    )
    check(
        quickRecover == .quickRecover(source: .image("i.img"), output: "result", json: false),
        "quick recover разбирается"
    )
    check(
        quickRecoverJSON == .quickRecover(source: .image("i.img"), output: "result", json: true),
        "quick recover --json разбирается"
    )
} catch {
    check(false, "валидные аргументы CLI не должны отклоняться")
}

private func expectUsageError(_ arguments: [String], _ message: String) {
    do {
        _ = try CommandLineParser.parse(arguments)
        check(false, message)
    } catch {
        check(error is CLIUsageError, message)
    }
}
expectUsageError(["заведомо-неизвестная"], "неизвестная команда CLI отклоняется")
expectUsageError(["drives"], "drives без подкоманды отклоняется")
expectUsageError(["drives", "show"], "неизвестная подкоманда drives отклоняется")
expectUsageError(["version", "--yaml"], "неизвестный параметр CLI отклоняется")
expectUsageError(["version", "лишний"], "лишний аргумент CLI отклоняется")
expectUsageError(["quick"], "quick без подкоманды отклоняется")
expectUsageError(["quick", "show"], "неизвестная подкоманда quick отклоняется")
expectUsageError(["quick", "scan"], "quick scan без --image отклоняется")
expectUsageError(["quick", "scan", "--image"], "--image без значения отклоняется")
expectUsageError(["quick", "scan", "--image", "a.img", "--output", "d"], "--output в scan отклоняется")
expectUsageError(["quick", "scan", "--image", "a.img", "--all"], "--all в scan отклоняется")
expectUsageError(["quick", "recover", "--image", "a.img", "--all"], "recover без --output отклоняется")
expectUsageError(["quick", "recover", "--image", "a.img", "--output", "d"], "recover без --all отклоняется")
expectUsageError([
    "quick", "scan", "--image", "a.img", "--image", "b.img"
], "повторный --image отклоняется")
expectUsageError(["quick", "scan", "--image", "a.img", "--json", "--yaml"], "неизвестный параметр в quick отклоняется")
expectUsageError(["quick", "scan", "--image", "--json"], "--image не принимает --json как значение")
expectUsageError(["quick", "scan", "--image", "--all"], "--image не принимает --all как значение")
expectUsageError([
    "quick", "recover", "--image", "i.img", "--output", "--all"
], "--output не принимает --all как значение")
expectUsageError(["quick", "scan", "--output", "--image"], "--output не принимает --image как значение")
expectUsageError(["quick", "scan", "--image", "a.img", "--drive", "disk4"], "конфликт --image и --drive отклоняется")
expectUsageError([
    "quick", "recover", "--image", "a.img", "--drive", "disk4", "--output", "d", "--all"
], "конфликт --image и --drive в recover отклоняется")
expectUsageError(["quick", "scan", "--drive", "disk4"], "drive без expected-имени и размера отклоняется")
expectUsageError(["quick", "scan", "--drive", "disk4", "--expected-name", "N"], "drive без expected-size отклоняется")
expectUsageError([
    "quick", "scan", "--drive", "/dev/rdisk4", "--expected-name", "N", "--expected-size", "5"
], "raw-путь в --drive отклоняется")
expectUsageError([
    "quick", "scan", "--drive", "disk4", "--expected-name", "N", "--expected-size", "abc"
], "не-число в expected-size отклоняется")
expectUsageError([
    "quick", "scan", "--drive", "disk4", "--expected-name", "N", "--expected-size", "0"
], "нулевой expected-size отклоняется")
expectUsageError([
    "quick", "scan", "--drive", "disk4", "--expected-name", "N", "--expected-size", "-5"
], "отрицательный expected-size отклоняется")
expectUsageError(["quick", "scan", "--image", "a.img", "--expected-name", "N"], "expected-name с --image запрещён")
expectUsageError(["quick", "scan"], "источник не указан")
expectUsageError(["quick", "scan", "--drive"], "--drive без значения отклоняется")
expectUsageError([
    "quick", "recover", "--drive", "disk4", "--expected-name", "N", "--expected-size", "5", "--output", "d"
], "recover --drive без --all отклоняется")

// Deep-команды CLI: парсинг и отклонение неверных аргументов.
do {
    let deepImage = try CommandLineParser.parse(["deep", "recover", "--image", "i.img", "--output", "res"])
    let deepImageJSONL = try CommandLineParser.parse([
        "deep", "recover", "--image", "i.img", "--output", "res", "--jsonl"
    ])
    let deepDrive = try CommandLineParser.parse([
        "deep", "recover", "--drive", "disk4", "--expected-name", "Flashka",
        "--expected-size", "125829120000", "--output", "res", "--jsonl"
    ])
    check(
        deepImage == .deepRecover(source: .image("i.img"), output: "res", jsonl: false),
        "deep recover --image разбирается"
    )
    check(
        deepImageJSONL == .deepRecover(source: .image("i.img"), output: "res", jsonl: true),
        "deep recover --jsonl разбирается"
    )
    check(
        deepDrive == .deepRecover(
            source: .drive(identifier: "disk4", expectedName: "Flashka", expectedSize: 125829120000),
            output: "res",
            jsonl: true
        ),
        "deep recover --drive --jsonl разбирается"
    )
} catch {
    check(false, "валидные deep-аргументы CLI не должны отклоняться")
}
expectUsageError(["deep"], "deep без подкоманды отклоняется")
expectUsageError(["deep", "scan", "--image", "a.img"], "deep scan не существует — только recover")
expectUsageError(["deep", "recover"], "deep recover без источника отклоняется")
expectUsageError(["deep", "recover", "--image", "a.img"], "deep recover без --output отклоняется")
expectUsageError(["deep", "recover", "--image", "a.img", "--output", "d", "--json"], "--json в deep отклоняется")
expectUsageError(["deep", "recover", "--image", "a.img", "--output", "d", "--all"], "--all в deep отклоняется")
expectUsageError(["quick", "scan", "--image", "a.img", "--jsonl"], "--jsonl в quick отклоняется")
expectUsageError(["version", "--jsonl"], "--jsonl в version отклоняется")
expectUsageError([
    "deep", "recover", "--image", "a.img", "--drive", "disk4", "--output", "d"
], "конфликт --image и --drive в deep отклоняется")
expectUsageError([
    "deep", "recover", "--drive", "/dev/rdisk4", "--expected-name", "N", "--expected-size", "5", "--output", "d"
], "raw-путь в deep --drive отклоняется")
expectUsageError([
    "deep", "recover", "--drive", "disk4", "--expected-size", "5", "--output", "d"
], "deep --drive без expected-name отклоняется")
expectUsageError([
    "deep", "recover", "--image", "a.img", "--expected-name", "N", "--output", "d"
], "expected-name с --image в deep отклоняется")

// Снимки прогресса PhotoRec: только измеренные значения, nil вместо подмен.
let progressSession = root.appendingPathComponent("progress-session", isDirectory: true)
let progressRecup = progressSession.appendingPathComponent("Recovered.1", isDirectory: true)
try FileManager.default.createDirectory(at: progressRecup, withIntermediateDirectories: true)
_ = FileManager.default.createFile(
    atPath: progressRecup.appendingPathComponent("f000001.jpg").path,
    contents: Data(count: 100)
)
_ = FileManager.default.createFile(
    atPath: progressRecup.appendingPathComponent("f000002.png").path,
    contents: Data(count: 250)
)
_ = FileManager.default.createFile(
    atPath: progressRecup.appendingPathComponent("f000003.txt").path,
    contents: Data(count: 4096)
)
_ = FileManager.default.createFile(
    atPath: progressSession.appendingPathComponent("photorec.log").path,
    contents: Data(count: 64)
)
let sesText = """
blocksize,512
0-1000
2000-3000
"""
_ = FileManager.default.createFile(
    atPath: progressSession.appendingPathComponent("photorec.ses").path,
    contents: Data(sesText.utf8)
)
let progressFileText = """
version=1
processed=512000
total=1024000
"""
_ = FileManager.default.createFile(
    atPath: progressSession.appendingPathComponent(".recoveryapp-progress").path,
    contents: Data(progressFileText.utf8)
)
let snapshot = PhotoRecDeepRecovery.progressSnapshot(at: progressSession)
check(snapshot.fileCount == 2, "снимок считает только файлы сигнатур jpg/png/mov/mp4")
check(snapshot.resultBytes == 350, "снимок суммирует объём результата")
check(snapshot.logSize == 64, "снимок читает размер журнала PhotoRec")
check(snapshot.processedBytes == 1024000,
      "снимок берёт максимум из файла прогресса и photorec.ses (2000 * 512)")
check(snapshot.totalBytes == 1024000, "снимок читает общий объём из файла прогресса")
check(PhotoRecDeepRecovery.photoRecSessionProcessedBytes(
    at: progressSession.appendingPathComponent("photorec.ses"),
    totalBytes: 1024000
) == 1024000, "photorec.ses: начало последнего диапазона умножается на blocksize")
check(PhotoRecDeepRecovery.photoRecSessionProcessedBytes(
    at: root.appendingPathComponent("absent.ses"),
    totalBytes: 1024000
) == nil, "отсутствующий photorec.ses даёт nil, а не ноль")
let sesNoBlocksize = progressSession.appendingPathComponent("ses-no-blocksize")
_ = FileManager.default.createFile(atPath: sesNoBlocksize.path, contents: Data("0-1000\n".utf8))
check(PhotoRecDeepRecovery.photoRecSessionProcessedBytes(at: sesNoBlocksize, totalBytes: 1024) == nil,
      "photorec.ses без blocksize не даёт обработанный объём")
let badProgress = root.appendingPathComponent("bad-progress")
_ = FileManager.default.createFile(
    atPath: badProgress.path,
    contents: Data("version=2\nprocessed=5\ntotal=10\n".utf8)
)
check(PhotoRecDeepRecovery.progressFileValues(at: badProgress) == nil,
      "файл прогресса с неверной версией игнорируется")
let overProgress = root.appendingPathComponent("over-progress")
_ = FileManager.default.createFile(
    atPath: overProgress.path,
    contents: Data("version=1\nprocessed=20\ntotal=10\n".utf8)
)
check(PhotoRecDeepRecovery.progressFileValues(at: overProgress) == nil,
      "файл прогресса с processed больше total игнорируется")
let emptySession = root.appendingPathComponent("empty-deep-session", isDirectory: true)
try FileManager.default.createDirectory(at: emptySession, withIntermediateDirectories: false)
let emptySnapshot = PhotoRecDeepRecovery.progressSnapshot(at: emptySession)
check(emptySnapshot == .empty, "сессия без находок даёт пустой снимок с nil-счётчиками чтения")

// JSONL-события deep recover: ключи опускаются, когда значения недоступны.
func encodeJSON<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try! encoder.encode(value), as: UTF8.self)
}
func parseJSONObject(_ string: String) -> [String: Any] {
    try! JSONSerialization.jsonObject(with: Data(string.utf8)) as! [String: Any]
}
func parseJSONArray(_ string: String) -> [[String: Any]] {
    try! JSONSerialization.jsonObject(with: Data(string.utf8)) as! [[String: Any]]
}
let startedParsed = parseJSONObject(encodeJSON(DeepStartedEvent(
    source: .image(path: "/abs/image.img"),
    sessionDirectory: "/abs/out/PhotoRec-Recovery"
)))
check(startedParsed["event"] as? String == "started", "started содержит событие")
check(startedParsed["schemaVersion"] as? Int == 1, "started содержит версию схемы")
check(startedParsed["sessionDirectory"] as? String == "/abs/out/PhotoRec-Recovery",
      "started содержит папку сессии")
let startedSource = startedParsed["source"] as? [String: Any]
check(startedSource?["type"] as? String == "image" && startedSource?["path"] as? String == "/abs/image.img",
      "started для образа содержит абсолютный путь и тип")
let startedDriveParsed = parseJSONObject(encodeJSON(DeepStartedEvent(
    source: .drive(id: "disk4", name: "Flashka", size: 125_829_120_000, rawDevicePath: "/dev/rdisk4"),
    sessionDirectory: "/abs/out/RecoveryApp-восстановление"
)))
let startedDriveSource = startedDriveParsed["source"] as? [String: Any]
check(startedDriveSource?["type"] as? String == "drive"
      && startedDriveSource?["id"] as? String == "disk4"
      && startedDriveSource?["rawDevicePath"] as? String == "/dev/rdisk4"
      && startedDriveSource?["size"] as? Int == 125_829_120_000,
      "started для накопителя содержит сверенные id, размер и raw-путь")
let progressParsed = parseJSONObject(encodeJSON(DeepProgressEvent(
    elapsedSeconds: 2.5,
    foundFiles: 3,
    resultBytes: 350,
    processedBytes: nil,
    totalBytes: nil,
    readBytesPerSecond: nil
)))
check(progressParsed["event"] as? String == "progress" && progressParsed["elapsedSeconds"] as? Double == 2.5,
      "progress содержит прошедшее время")
check(progressParsed["foundFiles"] as? Int == 3 && progressParsed["resultBytes"] as? Int == 350,
      "progress содержит найденные файлы и объём результата")
check(progressParsed["processedBytes"] == nil && progressParsed["totalBytes"] == nil
      && progressParsed["readBytesPerSecond"] == nil,
      "недоступные счётчики опускаются из progress, а не кодируются нулём")
let progressMeasuredParsed = parseJSONObject(encodeJSON(DeepProgressEvent(
    elapsedSeconds: 4,
    foundFiles: 3,
    resultBytes: 350,
    processedBytes: 1024000,
    totalBytes: 1024000,
    readBytesPerSecond: 512000
)))
check(progressMeasuredParsed["processedBytes"] as? Int == 1024000
      && progressMeasuredParsed["readBytesPerSecond"] as? Int == 512000,
      "измеренные счётчики присутствуют в progress")
let completedParsed = parseJSONObject(encodeJSON(DeepCompletedEvent(
    sessionDirectory: "/abs/session",
    recoveredCount: 2,
    files: ["/abs/session/Recovered.1/a.jpg", "/abs/session/Recovered.1/b.png"]
)))
check(completedParsed["event"] as? String == "completed" && completedParsed["recoveredCount"] as? Int == 2,
      "completed содержит папку сессии и число файлов")
check((completedParsed["files"] as? [String])?.count == 2, "completed содержит пути файлов")
let cancelledParsed = parseJSONObject(encodeJSON(DeepCancelledEvent(
    sessionDirectory: "/abs/session",
    foundFiles: 1,
    files: ["/abs/session/Recovered.1/a.jpg"]
)))
check(cancelledParsed["event"] as? String == "cancelled" && cancelledParsed["foundFiles"] as? Int == 1,
      "cancelled содержит папку сессии и уже найденные файлы")
let cancelledEarlyParsed = parseJSONObject(encodeJSON(DeepCancelledEvent(
    sessionDirectory: nil,
    foundFiles: 0,
    files: []
)))
check(cancelledEarlyParsed["sessionDirectory"] == nil,
      "cancelled до создания сессии опускает sessionDirectory")
check(parseJSONObject(encodeJSON(DeepErrorEvent(code: "imageMissing", message: "текст")))["code"]
      as? String == "imageMissing",
      "error содержит стабильный код")

// Атомарность JSONL: параллельные события не склеивают и не рвут строки.
let emitterFile = root.appendingPathComponent("emitter-events.jsonl")
_ = FileManager.default.createFile(atPath: emitterFile.path, contents: nil)
let emitterHandle = try FileHandle(forWritingTo: emitterFile)
let emitter = DeepEventEmitter(jsonl: true, output: emitterHandle)
let emitterWorkers = 8
let emitterPerWorker = 25
await withTaskGroup(of: Void.self) { group in
    for worker in 0..<emitterWorkers {
        group.addTask { @Sendable in
            for index in 0..<emitterPerWorker {
                emitter.jsonLine(DeepErrorEvent(
                    code: "worker\(worker)-event\(index)",
                    message: "тест атомарности"
                ))
            }
        }
    }
}
try? emitterHandle.close()
let emitterLines = try String(contentsOf: emitterFile, encoding: .utf8)
    .split(separator: "\n", omittingEmptySubsequences: true)
check(emitterLines.count == emitterWorkers * emitterPerWorker,
      "параллельные события дают \(emitterWorkers * emitterPerWorker) строк (получено \(emitterLines.count))")
var seenEmitterCodes = Set<String>()
for line in emitterLines {
    guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          let code = object["code"] as? String else {
        check(false, "строка JSONL не является отдельным валидным JSON: \(line)")
        continue
    }
    seenEmitterCodes.insert(code)
}
check(seenEmitterCodes.count == emitterWorkers * emitterPerWorker,
      "каждая строка — целый отдельный JSON-объект без склейки")

// Ранний Ctrl-C в Core (регрессия гонки до запуска дочернего процесса):
// запрос отмены до recover запоминается и запрещает запуск PhotoRec.
private func writeExecutableShim(_ url: URL, _ script: String) throws {
    try script.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

private func noProcess(named pattern: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-f", pattern]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return true }
    process.waitUntilExit()
    return process.terminationStatus != 0
}

let deepCancelRoot = root.appendingPathComponent("deep-cancel", isDirectory: true)
let deepCancelOut = deepCancelRoot.appendingPathComponent("out", isDirectory: true)
try FileManager.default.createDirectory(at: deepCancelOut, withIntermediateDirectories: true)
let earlyMarker = deepCancelRoot.appendingPathComponent("shim-started.txt")
let cancelImage = deepCancelRoot.appendingPathComponent("shim-source.img")
_ = FileManager.default.createFile(atPath: cancelImage.path, contents: Data("synthetic\n".utf8))
let earlyShim = deepCancelRoot.appendingPathComponent("deep-cancel-shim-early.py")
try writeExecutableShim(earlyShim, """
#!/usr/bin/env python3
import time

open("\(earlyMarker.path)", "w").write("started\\n")
time.sleep(60)
""")

let earlyBackend = PhotoRecDeepRecovery(photorec: earlyShim, launcher: nil)
earlyBackend.cancel()
do {
    _ = try await earlyBackend.recover(imageURL: cancelImage, outputFolderURL: deepCancelOut)
    check(false, "ранний cancel должен приводить к .cancelled")
} catch let error as DeletedFilesError {
    check(error == .cancelled, "ранний cancel даёт .cancelled (получено \(error))")
} catch {
    check(false, "ранний cancel даёт .cancelled")
}
check(!FileManager.default.fileExists(atPath: earlyMarker.path),
      "после раннего cancel PhotoRec-shim не запускался")

// Отмена во время работы: запомненный запрос останавливает дочерний процесс,
// найденное сохраняется; живых процессов после отмены нет.
let midMarker = deepCancelRoot.appendingPathComponent("shim-running.txt")
let midOut = deepCancelRoot.appendingPathComponent("out-mid", isDirectory: true)
try FileManager.default.createDirectory(at: midOut, withIntermediateDirectories: true)
let midFile = midOut
    .appendingPathComponent("PhotoRec-Recovery", isDirectory: true)
    .appendingPathComponent("Recovered.1", isDirectory: true)
    .appendingPathComponent("f000001.jpg")
let midShim = deepCancelRoot.appendingPathComponent("deep-cancel-shim-running.py")
try writeExecutableShim(midShim, """
#!/usr/bin/env python3
import os, sys, time

args = sys.argv[1:]
i = 0
base = None
while i < len(args):
    if args[i] == "/d":
        i += 1
        base = args[i]
    i += 1

directory = base + ".1"
os.makedirs(directory, exist_ok=True)
open("\(midMarker.path)", "w").write("running\\n")
open(directory + "/f000001.jpg", "wb").write(b"RECOVERYAPP-HARNESS-CANCEL\\n")
time.sleep(60)
""")

let midBackend = PhotoRecDeepRecovery(photorec: midShim, launcher: nil)
// Detached: главный поток занят опросом, унаследованный Task не стартовал бы.
let midTask = Task.detached {
    try await midBackend.recover(imageURL: cancelImage, outputFolderURL: midOut)
}
var midWaited = 0
while !FileManager.default.fileExists(atPath: midFile.path), midWaited < 250 {
    // Асинхронный сон: колбэки Core (@MainActor) должны успевать выполняться,
    // блокировка главного потока здесь приводит к взаимной ожидании.
    try await Task.sleep(for: .milliseconds(20))
    midWaited += 1
}
if !FileManager.default.fileExists(atPath: midFile.path) {
    // Диагностика: показать реальную причину, почему находка не появилась.
    do {
        _ = try await midTask.value
        check(false, "shim успел создать находку до отмены (recover завершился успешно)")
    } catch {
        check(false, "shim успел создать находку до отмены (recover упал: \(type(of: error)): \(error))")
    }
}
check(FileManager.default.fileExists(atPath: midFile.path),
      "shim успел создать находку до отмены")
midBackend.cancel()
do {
    _ = try await midTask.value
    check(false, "отмена во время работы даёт .cancelled")
} catch let error as DeletedFilesError {
    check(error == .cancelled, "отмена во время работы даёт .cancelled (получено \(error))")
} catch {
    check(false, "отмена во время работы даёт .cancelled")
}
check(FileManager.default.fileExists(atPath: midFile.path),
      "найденные до отмены файлы сохраняются")
var goneWaited = 0
while goneWaited < 150, !noProcess(named: "deep-cancel-shim-running") {
    try await Task.sleep(for: .milliseconds(20))
    goneWaited += 1
}
check(noProcess(named: "deep-cancel-shim-running"),
      "после отмены нет живого дочернего процесса")

// TASK-006: видео — preflight, физический носитель, конкуренция имён, JSONL.
private func expectVideoError(
    _ request: VideoRepairRequest,
    _ expectedCase: VideoRepairError,
    _ message: String,
    medium: VideoMediumProvider? = nil
) {
    do {
        try request.validate(medium: medium)
        check(false, message)
    } catch let error as VideoRepairError {
        // Сравнение по варианту случая: ассоциированные значения не важны.
        switch (error, expectedCase) {
        case (.sameInputFiles, .sameInputFiles),
             (.inputMissing, .inputMissing),
             (.inputNotRegularFile, .inputNotRegularFile),
             (.inputNotReadable, .inputNotReadable),
             (.outputFolderMissing, .outputFolderMissing),
             (.outputFolderNotWritable, .outputFolderNotWritable),
             (.outputFolderIsFile, .outputFolderIsFile),
             (.resultOnSourceVolume, .resultOnSourceVolume),
             (.volumeIdentityUnknown, .volumeIdentityUnknown),
             (.resultNamingFailed, .resultNamingFailed),
             (.resultNamingExhausted, .resultNamingExhausted),
             (.toolMissing, .toolMissing),
             (.launchFailed, .launchFailed),
             (.toolFailed, .toolFailed),
             (.outputSpaceExhausted, .outputSpaceExhausted),
             (.cancelled, .cancelled),
             (.resultMissing, .resultMissing):
            check(true, message)
        default:
            check(false, "\(message): получено \(error)")
        }
    } catch {
        check(false, message)
    }
}

let videoRoot = root.appendingPathComponent("video-repair", isDirectory: true)
let videoOutput = videoRoot.appendingPathComponent("out", isDirectory: true)
try FileManager.default.createDirectory(at: videoOutput, withIntermediateDirectories: true)
let referenceFile = videoRoot.appendingPathComponent("reference.mp4")
let damagedFile = videoRoot.appendingPathComponent("damaged.mp4")
_ = FileManager.default.createFile(atPath: referenceFile.path, contents: Data("reference-video".utf8))
_ = FileManager.default.createFile(atPath: damagedFile.path, contents: Data("damaged-video".utf8))
let healthyVideoRequest = VideoRepairRequest(
    referenceURL: referenceFile,
    damagedURL: damagedFile,
    outputFolderURL: videoOutput
)

// Один и тот же файл через symlink отклоняется.
let damagedSymlink = videoRoot.appendingPathComponent("damaged-alias.mp4")
try FileManager.default.createSymbolicLink(at: damagedSymlink, withDestinationURL: referenceFile)
expectVideoError(
    VideoRepairRequest(referenceURL: referenceFile, damagedURL: damagedSymlink, outputFolderURL: videoOutput),
    .sameInputFiles,
    "совпадение входов через symlink отклоняется"
)
// Жёсткая ссылка — тот же файл по паре «том + инод».
let damagedHardlink = videoRoot.appendingPathComponent("damaged-hard.mp4")
link(referenceFile.path, damagedHardlink.path)
expectVideoError(
    VideoRepairRequest(referenceURL: referenceFile, damagedURL: damagedHardlink, outputFolderURL: videoOutput),
    .sameInputFiles,
    "совпадение входов через жёсткую ссылку отклоняется"
)
// Отсутствующий вход, каталог вместо видео, нечитаемый файл.
expectVideoError(
    VideoRepairRequest(
        referenceURL: videoRoot.appendingPathComponent("absent.mp4"),
        damagedURL: damagedFile,
        outputFolderURL: videoOutput
    ),
    .inputMissing,
    "отсутствующий вход отклоняется"
)
expectVideoError(
    VideoRepairRequest(referenceURL: videoRoot, damagedURL: damagedFile, outputFolderURL: videoOutput),
    .inputNotRegularFile,
    "каталог на входе отклоняется"
)
let lockedVideoFile = videoRoot.appendingPathComponent("locked.mp4")
_ = FileManager.default.createFile(atPath: lockedVideoFile.path, contents: Data("x".utf8))
try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedVideoFile.path)
expectVideoError(
    VideoRepairRequest(referenceURL: lockedVideoFile, damagedURL: damagedFile, outputFolderURL: videoOutput),
    .inputNotReadable,
    "нечитаемый вход отклоняется"
)
try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lockedVideoFile.path)

// Папка результата: отсутствует, файл вместо папки, без права записи.
expectVideoError(
    VideoRepairRequest(
        referenceURL: referenceFile,
        damagedURL: damagedFile,
        outputFolderURL: videoRoot.appendingPathComponent("absent-dir")
    ),
    .outputFolderMissing,
    "несуществующая папка результата отклоняется"
)
let videoOutputFile = videoRoot.appendingPathComponent("plain.txt")
_ = FileManager.default.createFile(atPath: videoOutputFile.path, contents: Data("f".utf8))
expectVideoError(
    VideoRepairRequest(referenceURL: referenceFile, damagedURL: damagedFile, outputFolderURL: videoOutputFile),
    .outputFolderIsFile,
    "файл вместо папки результата отклоняется"
)
let readOnlyVideoDir = videoRoot.appendingPathComponent("ro-dir", isDirectory: true)
try FileManager.default.createDirectory(at: readOnlyVideoDir, withIntermediateDirectories: true)
try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnlyVideoDir.path)
expectVideoError(
    VideoRepairRequest(referenceURL: referenceFile, damagedURL: damagedFile, outputFolderURL: readOnlyVideoDir),
    .outputFolderNotWritable,
    "папка без права записи отклоняется"
)
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnlyVideoDir.path)

// Политика физического носителя: seam внедряется только в доменных тестах,
// production использует системный resolver (цепочка diskutil/hdiutil);
// отключить защиту он не позволяет.
expectVideoError(
    healthyVideoRequest,
    .volumeIdentityUnknown,
    "неопределимый носитель результата даёт безопасный отказ",
    medium: { _ in nil }
)
expectVideoError(
    healthyVideoRequest,
    .resultOnSourceVolume,
    "результат на носителе исходного видео отклоняется",
    medium: { _ in VideoPhysicalMedium(identifiers: ["shared-medium"]) }
)
do {
    try healthyVideoRequest.validate(medium: { url in
        var isDirectory: ObjCBool = false
        let isOutputFolder = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
        return VideoPhysicalMedium(
            identifiers: isOutputFolder ? ["out-medium"] : ["src-medium"]
        )
    })
    check(true, "результат на другом носителе проходит валидацию")
} catch {
    check(false, "результат на другом носителе проходит валидацию: \(error)")
}

// Системный resolver: реальный путь внутри Data-тома сводится к физическому
// диску (идентификатор вида diskN), а не к st_dev тома.
let systemMediumResolver = SystemPhysicalMediumResolver.makeProvider()
let resolvedMedium = systemMediumResolver(damagedFile)
check(resolvedMedium != nil, "системный resolver определяет носитель реального пути")
check(resolvedMedium?.identifiers.contains(where: { $0.hasPrefix("disk") }) == true,
      "системный resolver возвращает идентификатор физического диска: \(resolvedMedium?.identifiers ?? [])")

// Исчерпание имён результата: все 10 000 кандидатов заняты — отказ, а не
// запись поверх чужого файла.
let exhaustedDir = videoRoot.appendingPathComponent("exhausted", isDirectory: true)
try FileManager.default.createDirectory(at: exhaustedDir, withIntermediateDirectories: true)
let exhaustedRequest = VideoRepairRequest(
    referenceURL: referenceFile,
    damagedURL: damagedFile,
    outputFolderURL: exhaustedDir
)
_ = FileManager.default.createFile(
    atPath: exhaustedDir.appendingPathComponent("damaged_recovered.mp4").path,
    contents: nil
)
var exhaustedIndex = 2
while exhaustedIndex <= VideoRepairRequest.resultNameCandidateLimit {
    _ = FileManager.default.createFile(
        atPath: exhaustedDir.appendingPathComponent("damaged_recovered_\(exhaustedIndex).mp4").path,
        contents: nil
    )
    exhaustedIndex += 1
}
do {
    _ = try exhaustedRequest.reserveResultURL()
    check(false, "исчерпание имён результата даёт отказ")
} catch let error as VideoRepairError {
    var isExhausted = false
    if case .resultNamingExhausted = error {
        isExhausted = true
    }
    check(isExhausted, "исчерпание имён даёт resultNamingExhausted, получено \(error)")
} catch {
    check(false, "исчерпание имён результата даёт отказ")
}

// Конкурентное резервирование имён: параллельные запуски получают разные
// имена, существующие файлы не перезаписываются, плейсхолдеры остаются.
let namingRequest = VideoRepairRequest(
    referenceURL: referenceFile,
    damagedURL: damagedFile,
    outputFolderURL: videoOutput
)
let reservedNames = try await withThrowingTaskGroup(of: String.self) { group in
    for _ in 0..<2 {
        group.addTask { @Sendable in
            let (url, descriptor) = try namingRequest.reserveResultURL()
            close(descriptor)
            return url.lastPathComponent
        }
    }
    var names: [String] = []
    for try await name in group {
        names.append(name)
    }
    return names
}
check(reservedNames.count == 2 && Set(reservedNames).count == 2,      "параллельное резервирование даёт разные имена: \(reservedNames)")
let thirdReserved = try namingRequest.reserveResultURL()
close(thirdReserved.descriptor)
check(!reservedNames.contains(thirdReserved.url.lastPathComponent),
      "третье резервирование снова выбирает уникальное имя")
for name in reservedNames {
    check(FileManager.default.fileExists(atPath: videoOutput.appendingPathComponent(name).path),
          "зарезервированный плейсхолдер \(name) существует")
}

// JSONL-события video repair.
let videoStartedParsed = parseJSONObject(encodeJSON(VideoStartedEvent(
    reference: "/abs/ref.mp4",
    damaged: "/abs/dmg.mp4",
    outputDirectory: "/abs/out"
)))
check(videoStartedParsed["event"] as? String == "started"
      && videoStartedParsed["schemaVersion"] as? Int == 1
      && videoStartedParsed["reference"] as? String == "/abs/ref.mp4"
      && videoStartedParsed["damaged"] as? String == "/abs/dmg.mp4"
      && videoStartedParsed["outputDirectory"] as? String == "/abs/out",
      "video started содержит абсолютные пути и версию схемы")
let videoCompletedParsed = parseJSONObject(encodeJSON(VideoCompletedEvent(result: "/abs/out/x_recovered.mp4")))
check(videoCompletedParsed["event"] as? String == "completed"
      && videoCompletedParsed["result"] as? String == "/abs/out/x_recovered.mp4",
      "video completed содержит абсолютный путь результата")
let videoCancelledNoResult = parseJSONObject(encodeJSON(VideoCancelledEvent(result: nil)))
check(videoCancelledNoResult["event"] as? String == "cancelled"
      && videoCancelledNoResult["result"] == nil,
      "video cancelled без готового файла опускает result")
let videoCancelledReady = parseJSONObject(encodeJSON(VideoCancelledEvent(result: "/abs/out/x_recovered.mp4")))
check(videoCancelledReady["result"] as? String == "/abs/out/x_recovered.mp4",
      "video cancelled с готовым файлом указывает result")
check(parseJSONObject(encodeJSON(VideoErrorEvent(code: "resultOnSourceVolume", message: "текст")))["code"]
      as? String == "resultOnSourceVolume",
      "video error содержит стабильный код")
check(videoErrorCode(for: VideoRepairError.volumeIdentityUnknown) == "volumeIdentityUnknown",
      "videoErrorCode отображает случай неизвестного тома")
check(videoErrorCode(for: VideoRepairError.resultNamingFailed("нет места")) == "resultNamingFailed"
      && videoErrorCode(for: VideoRepairError.resultNamingExhausted) == "resultNamingExhausted",
      "videoErrorCode отображает новые случаи резервирования")

// TASK-007: порядок физической quick-операции GUI — повторная сверка
// источника по свежему снимку, preflight папки до авторизации, сессия
// создаётся только после успеха обеих проверок.
nonisolated(unsafe) private var physicalFactoryCalls = 0

/// Синтетический диск через публичный plist-парсер Core (прямые конструкторы
/// ExternalDrive недоступны за пределами модуля).
private func makeSyntheticDrive(
    identifier: String,
    name: String,
    size: Int64,
    mountPoint: String? = nil
) throws -> ExternalDrive {
    var partition: [String: Any] = [
        "DeviceIdentifier": "\(identifier)s1",
        "VolumeName": name
    ]
    if let mountPoint {
        partition["MountPoint"] = mountPoint
    }
    let plist: [String: Any] = [
        "AllDisksAndPartitions": [[
            "DeviceIdentifier": identifier,
            "Size": size as NSNumber,
            "BusProtocol": "USB",
            "Partitions": [partition]
        ]]
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    return try ExternalDriveParser.drives(from: data)[0]
}

let guiSelectedDrive = try makeSyntheticDrive(identifier: "disk7", name: "TEST USB", size: 128_000_000_000)
let guiSessions = PhysicalQuickSessionCoordinator(makeRecovery: {
    physicalFactoryCalls += 1
    return PhysicalQuickRecovery(helper: URL(fileURLWithPath: "/nonexistent/helper"), launcher: nil)
})
let guiOutputFolder = root.appendingPathComponent("gui-out", isDirectory: true)
try FileManager.default.createDirectory(at: guiOutputFolder, withIntermediateDirectories: true)

private func expectPrepareFailure(
    _ snapshot: [ExternalDrive],
    _ drive: ExternalDrive,
    _ expected: DeletedFilesError,
    _ message: String,
    outputFolderURL: URL = guiOutputFolder
) {
    let callsBefore = physicalFactoryCalls
    do {
        _ = try PhysicalQuickOperationPreparation.prepare(
            selected: drive,
            snapshot: snapshot,
            outputFolderURL: outputFolderURL,
            sessions: guiSessions
        )
        check(false, message)
    } catch let error as DeletedFilesError {
        var matched = false
        if case expected = error { matched = true }
        check(matched, "\(message): получено \(error)")
        // Отказ сверки или preflight происходит ДО обращения к сессии:
        // авторизация не создаётся.
        check(physicalFactoryCalls == callsBefore,
              "\(message): сессия не должна создаваться")
    } catch {
        check(false, message)
    }
}

// Тот же источник в свежем снимке — операция готовится, сессия создаётся.
let guiPhysicalDrives = [guiSelectedDrive]
let callsBeforeConfirm = physicalFactoryCalls
let preparedSession = try PhysicalQuickOperationPreparation.prepare(
    selected: guiSelectedDrive,
    snapshot: guiPhysicalDrives,
    outputFolderURL: guiOutputFolder,
    sessions: guiSessions
)
check(physicalFactoryCalls == callsBeforeConfirm + 1,
      "успешная подготовка создаёт сессию (одну)")
expectPrepareFailure(
    [],
    guiSelectedDrive,
    .sourceUnavailable,
    "исчезнувший diskN отказывает до сессии"
)
expectPrepareFailure(
    [try makeSyntheticDrive(identifier: "disk7", name: "ДРУГОЕ ИМЯ", size: 128_000_000_000)],
    guiSelectedDrive,
    .sourceChanged,
    "другое имя отказывает до сессии"
)
expectPrepareFailure(
    [try makeSyntheticDrive(identifier: "disk7", name: "TEST USB", size: 64_000_000_000)],
    guiSelectedDrive,
    .sourceChanged,
    "другой размер отказывает до сессии"
)

// Preflight папки до авторизации: папка на источнике отклоняется, в том
// числе через symlink на точку монтирования источника.
let guiMountRoot = root.appendingPathComponent("gui-mnt", isDirectory: true)
let guiMountInner = guiMountRoot.appendingPathComponent("inner", isDirectory: true)
try FileManager.default.createDirectory(at: guiMountInner, withIntermediateDirectories: true)
let guiMountLink = root.appendingPathComponent("gui-mnt-link", isDirectory: true)
try FileManager.default.createSymbolicLink(at: guiMountLink, withDestinationURL: guiMountInner)
let guiMountedDrive = try makeSyntheticDrive(
    identifier: "disk8",
    name: "MOUNTED",
    size: 64_000_000_000,
    mountPoint: guiMountRoot.path
)
expectPrepareFailure(
    [guiMountedDrive],
    guiMountedDrive,
    .outputOnSource,
    "папка на источнике отказывает до сессии",
    outputFolderURL: guiMountInner
)
expectPrepareFailure(
    [guiMountedDrive],
    guiMountedDrive,
    .outputOnSource,
    "папка на источнике через symlink отказывает до сессии",
    outputFolderURL: guiMountLink
)

// Жизненный цикл одной физической quick-сессии на синтетической фабрике:
// scan и recover одного источника переиспользуют её, смена диска и сброс
// создают новую.
let lifecycleCallsBefore = physicalFactoryCalls
let firstSession = try guiSessions.recovery(for: guiSelectedDrive)
check(firstSession === preparedSession,
      "обращение после подготовки переиспользует ту же сессию")
check(physicalFactoryCalls == lifecycleCallsBefore,
      "переиспользование не создаёт новую сессию")
let otherDrive = try makeSyntheticDrive(identifier: "disk9", name: "TEST USB", size: 128_000_000_000)
let _ = try guiSessions.recovery(for: otherDrive)
check(physicalFactoryCalls == lifecycleCallsBefore + 1, "другой источник получает новую сессию")
guiSessions.reset()
let afterReset = try guiSessions.recovery(for: guiSelectedDrive)
check(afterReset !== firstSession, "после сброса создаётся новая сессия")
check(physicalFactoryCalls == lifecycleCallsBefore + 2,
      "после сброса фабрика вызывается заново")

// TASK-007: сводки quick-извлечения для карточки результата.
private func guiResult(_ status: RecoveredFileSizeStatus) -> RecoveredFileResult {
    RecoveredFileResult(url: root.appendingPathComponent("f-\(status.rawValue)"), expectedSize: 10, actualSize: 10, status: status)
}

let summaryFolder = root.appendingPathComponent("summary-out", isDirectory: true)
let emptySummary = QuickRecoverySummary.make(folder: summaryFolder, results: [])
check(emptySummary.savedCount == 0 && emptySummary.title == "Восстанавливать нечего",
      "пустой quick-результат — нормальное состояние без успеха «сохранено 0»")
check(!emptySummary.message.contains("Сохранено файлов: 0"),
      "пустой результат не сообщает успех «сохранено 0»")
check(emptySummary.hasSizeProblems == false, "пустой результат не считается проблемным")
let matchesSummary = QuickRecoverySummary.make(
    folder: summaryFolder,
    results: [guiResult(.sizeMatches), guiResult(.sizeMatches), guiResult(.expectedEmpty)]
)
check(matchesSummary.title == "Восстановление завершено" && !matchesSummary.hasSizeProblems,
      "полное совпадение размеров — спокойный успех")
check(matchesSummary.savedCount == 3 && matchesSummary.sizeMatchesCount == 3,
      "совпавшие и достоверно пустые считаются сверенными")
check(matchesSummary.message.contains("Совпадение размеров не является проверкой целостности содержимого."),
      "успех не выдаёт совпадение размеров за проверку целостности")
let incompleteSummary = QuickRecoverySummary.make(
    folder: summaryFolder,
    results: [guiResult(.sizeMatches), guiResult(.incomplete)]
)
check(incompleteSummary.hasSizeProblems && incompleteSummary.title == "Восстановление завершено с предупреждениями",
      "неполные файлы дают предупреждающий заголовок")
check(incompleteSummary.savedCount == 2,
      "число сохранённых файлов не уменьшается из-за статуса")
check(incompleteSummary.message.contains("извлечены не полностью: 1"),
      "предупреждение называет число неполных файлов")
let mismatchSummary = QuickRecoverySummary.make(folder: summaryFolder, results: [guiResult(.sizeMismatch)])
check(mismatchSummary.hasSizeProblems && mismatchSummary.sizeMismatchCount == 1,
      "несовпадение размеров считается проблемой")
check(mismatchSummary.message.contains("размер отличается от метаданных: 1"),
      "предупреждение называет число несовпадающих файлов")
let unknownSummary = QuickRecoverySummary.make(folder: summaryFolder, results: [guiResult(.sizeUnknown)])
check(!unknownSummary.hasSizeProblems && unknownSummary.title == "Восстановление завершено",
      "неизвестный размер не превращает результат в проблемный")
check(unknownSummary.message.contains("не удалось сверить"),
      "неизвестный размер объяснён, а не скрыт")
check(!unknownSummary.message.contains("полностью") || unknownSummary.message.contains("не доказывает"),
      "неизвестный размер не выдаётся за доказанную полноту")
let mixedSummary = QuickRecoverySummary.make(
    folder: summaryFolder,
    results: [
        guiResult(.sizeMatches), guiResult(.incomplete), guiResult(.sizeMismatch),
        guiResult(.sizeUnknown), guiResult(.sizeMatches)
    ]
)
check(mixedSummary.savedCount == 5 && mixedSummary.sizeMatchesCount == 2
      && mixedSummary.incompleteCount == 1 && mixedSummary.sizeMismatchCount == 1
      && mixedSummary.sizeUnknownCount == 1,
      "смешанный набор считается по каждому статусу")
check(mixedSummary.message.contains("Совпадение размеров не является проверкой целостности содержимого."),
      "смешанный результат напоминает про границы сверки размеров")

print("PASS: \(checkCount) domain checks")

print("PASS: \(checkCount) domain checks")
