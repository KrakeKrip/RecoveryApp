@preconcurrency import Foundation
import Darwin

struct VideoRepairRequest: Sendable {
    let referenceURL: URL
    let damagedURL: URL
    let outputFolderURL: URL

    func validate(fileManager: FileManager = .default) throws {
        guard referenceURL.standardizedFileURL != damagedURL.standardizedFileURL else {
            throw VideoRepairError.sameInputFiles
        }
        guard fileManager.fileExists(atPath: referenceURL.path),
              fileManager.fileExists(atPath: damagedURL.path) else {
            throw VideoRepairError.inputMissing
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: outputFolderURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw VideoRepairError.outputFolderMissing
        }
        guard fileManager.isWritableFile(atPath: outputFolderURL.path) else {
            throw VideoRepairError.outputFolderNotWritable
        }
    }

    func resultURL(fileManager: FileManager = .default) -> URL {
        let base = damagedURL.deletingPathExtension().lastPathComponent
        let ext = damagedURL.pathExtension.isEmpty ? "mp4" : damagedURL.pathExtension
        var candidate = outputFolderURL
            .appendingPathComponent("\(base)_recovered")
            .appendingPathExtension(ext)
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = outputFolderURL
                .appendingPathComponent("\(base)_recovered_\(index)")
                .appendingPathExtension(ext)
            index += 1
        }
        return candidate
    }
}

enum VideoRepairError: LocalizedError {
    case sameInputFiles
    case inputMissing
    case outputFolderMissing
    case outputFolderNotWritable
    case toolMissing
    case launchFailed(String)
    case toolFailed(Int32)
    case outputSpaceExhausted
    case cancelled
    case resultMissing

    var errorDescription: String? {
        switch self {
        case .sameInputFiles: "Исправный пример и повреждённое видео должны быть разными файлами."
        case .inputMissing: "Один из выбранных файлов больше недоступен."
        case .outputFolderMissing: "Папка результата больше недоступна."
        case .outputFolderNotWritable: "Нет доступа для записи в папку результата."
        case .toolMissing: "Встроенный инструмент untrunc отсутствует или повреждён."
        case .launchFailed(let message): "Не удалось запустить untrunc: \(message)"
        case .toolFailed(let code): "untrunc завершился с кодом \(code). Откройте подробный лог."
        case .outputSpaceExhausted: "В папке результата закончилось свободное место."
        case .cancelled: "Операция остановлена. Доступные результаты сохранены."
        case .resultMissing: "untrunc завершился без ошибки, но файл результата не найден."
        }
    }
}

final class VideoRepairExecutor: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func run(
        request: VideoRepairRequest,
        onOutput: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> URL {
        try request.validate()
        let outputURL = request.resultURL()
        let toolURL = try Self.toolURL()
        let launcherURL = try Self.launcherURL()

        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { [self] in
                try runBlocking(
                    launcherURL: launcherURL,
                    toolURL: toolURL,
                    request: request,
                    outputURL: outputURL,
                    onOutput: onOutput
                )
            }.value
        } onCancel: { [self] in
            cancel()
        }
    }

    func cancel() {
        lock.lock()
        let runningProcess = process
        lock.unlock()
        guard let runningProcess, runningProcess.isRunning else { return }

        let pid = runningProcess.processIdentifier
        if kill(-pid, SIGTERM) != 0 {
            kill(pid, SIGTERM)
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) {
            if kill(-pid, 0) == 0 {
                kill(-pid, SIGKILL)
            } else if kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
        }
    }

    private func runBlocking(
        launcherURL: URL,
        toolURL: URL,
        request: VideoRepairRequest,
        outputURL: URL,
        onOutput: @escaping @MainActor @Sendable (String) -> Void
    ) throws -> URL {
        if Task.isCancelled { throw VideoRepairError.cancelled }
        let launchedProcess = Process()
        let outputPipe = Pipe()
        launchedProcess.executableURL = launcherURL
        launchedProcess.arguments = [
            toolURL.path,
            "-n", "-dst", outputURL.path,
            request.referenceURL.path,
            request.damagedURL.path
        ]
        launchedProcess.standardOutput = outputPipe
        launchedProcess.standardError = outputPipe
        launchedProcess.standardInput = FileHandle.nullDevice
        var transcript = ""

        lock.lock()
        process = launchedProcess
        lock.unlock()

        defer {
            lock.lock()
            process = nil
            lock.unlock()
        }

        do {
            try launchedProcess.run()
        } catch {
            throw VideoRepairError.launchFailed(error.localizedDescription)
        }

        while true {
            let data = outputPipe.fileHandleForReading.availableData
            if data.isEmpty { break }
            let text = LogSanitizer.clean(String(decoding: data, as: UTF8.self))
            transcript.append(text)
            transcript.append("\n")
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                if !text.isEmpty { await onOutput(text + "\n") }
                semaphore.signal()
            }
            semaphore.wait()
        }
        launchedProcess.waitUntilExit()

        if launchedProcess.terminationReason == .uncaughtSignal {
            throw VideoRepairError.cancelled
        }
        guard launchedProcess.terminationStatus == 0 else {
            if Self.indicatesNoSpace(transcript) {
                throw VideoRepairError.outputSpaceExhausted
            }
            try request.validate()
            throw VideoRepairError.toolFailed(launchedProcess.terminationStatus)
        }
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw VideoRepairError.resultMissing
        }
        return outputURL
    }

    private static func indicatesNoSpace(_ output: String) -> Bool {
        let value = output.lowercased()
        return value.contains("no space left") || value.contains("enospc") ||
            value.contains("недостаточно места")
    }

    private static func toolURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["RECOVERYAPP_UNTRUNC_PATH"] {
            let url = URL(fileURLWithPath: override)
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw VideoRepairError.toolMissing
            }
            return url
        }
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Tools/untrunc"),
              FileManager.default.isExecutableFile(atPath: url.path) else {
            throw VideoRepairError.toolMissing
        }
        return url
    }

    private static func launcherURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["RECOVERYAPP_TOOL_LAUNCHER_PATH"] {
            let url = URL(fileURLWithPath: override)
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw VideoRepairError.toolMissing
            }
            return url
        }
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Tools/tool-launcher"),
              FileManager.default.isExecutableFile(atPath: url.path) else {
            throw VideoRepairError.toolMissing
        }
        return url
    }
}
