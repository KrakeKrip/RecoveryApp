import Foundation

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
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
try request.validate()
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

let mmlsOutput = """
004:  000       0000002048   0000249855   0000247808
005:  -------   0000249856   0000249999   0000000144   Unallocated
"""
check(SleuthKitOutputParser.partitionOffsets(from: mmlsOutput) == [2048], "mmls parser")

let existingDocument = root.appendingPathComponent("document.txt")
_ = FileManager.default.createFile(atPath: existingDocument.path, contents: Data())
check(
    DeletedFilesExecutor.uniqueResultURL(suggestedName: "document.txt", folder: root)
        .lastPathComponent == "document_2.txt",
    "восстановление не перезаписывает найденный файл"
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
let latestPhotoRecDirectory = try DeletedFilesExecutor.photoRecOutputDirectory(
    baseURL: photoRecBase
)
check(
    latestPhotoRecDirectory.lastPathComponent == photoRecSecond.lastPathComponent,
    "выбирается последний каталог результата PhotoRec"
)
check(
    DeletedFilesExecutor.regularFilesRecursively(in: photoRecSecond).count == 1,
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
    UserFacingFailure.make(from: VideoRepairError.inputMissing).title == "Исходный файл исчез",
    "исчезнувший видеофайл объясняется"
)
let hiddenTechnicalFailure = UserFacingFailure.make(from: DeletedFilesError.toolFailed("icat", 73))
check(
    !hiddenTechnicalFailure.message.contains("73") && !hiddenTechnicalFailure.message.contains("icat"),
    "технический код скрыт из основной ошибки"
)

print("PASS: 28 domain checks")
