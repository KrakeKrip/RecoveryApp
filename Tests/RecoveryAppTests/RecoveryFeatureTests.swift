import Testing
import RecoveryCore
@testable import RecoveryApp

@Test("У каждого направления есть корректное русское название")
func everyFeatureHasRussianTitle() {
    #expect(RecoveryFeature.videoRepair.title == "Повреждённые видео")
    #expect(RecoveryFeature.deletedFiles.title == "Удалённые файлы")
}

@Test("Результат не перезаписывает существующий файл")
func resultURLDoesNotOverwrite() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let existing = root.appendingPathComponent("clip_recovered.mp4")
    _ = FileManager.default.createFile(atPath: existing.path, contents: Data())
    let request = VideoRepairRequest(
        referenceURL: root.appendingPathComponent("reference.mp4"),
        damagedURL: root.appendingPathComponent("clip.mp4"),
        outputFolderURL: root
    )
    #expect(request.resultURL().lastPathComponent == "clip_recovered_2.mp4")
}

@Test("Парсер fls извлекает только удалённые файлы")
func flsParser() {
    let output = "r/r * 37:\tDOCS/_ECOVERY.TXT\nd/d * 52:\tFOLDER\n"
    let values = SleuthKitOutputParser.deletedFiles(from: output, partitionOffset: 0)
    #expect(values.count == 1)
    #expect(values.first?.inode == "37")
}

@Test("Парсер запоминает тип файловой системы физического диска")
func flsParserKeepsFilesystemType() {
    let output = "r/r * 37:\tRECOVERY.TXT\n"
    let values = SleuthKitOutputParser.deletedFiles(
        from: output,
        partitionOffset: 2048,
        filesystemType: "exfat"
    )
    #expect(values.first?.filesystemType == "exfat")
}
