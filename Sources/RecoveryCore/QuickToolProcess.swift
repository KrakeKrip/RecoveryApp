@preconcurrency import Foundation
import Darwin

public typealias QuickCandidatesHandler = @MainActor @Sendable ([DeletedFileCandidate]) -> Void
public typealias QuickRecoveredHandler = @MainActor @Sendable (DeletedFileCandidate, RecoveredFileResult) -> Void

enum QuickCallbacks {
    static func deliver(_ body: @escaping @MainActor @Sendable () -> Void) {
        let ready = DispatchSemaphore(value: 0)
        Task { @MainActor in
            body()
            ready.signal()
        }
        ready.wait()
    }
}

/// Byte-oriented framing: UTF-8 may be split at ANY byte, including within a
/// filename. Only complete records are published; duplicate IDs are suppressed.
public struct QuickCandidateStream: Sendable {
    private var pending = Data()
    private var seen: Set<DeletedFileCandidate.ID> = []
    public private(set) var candidates: [DeletedFileCandidate] = []
    private let offset: Int64
    private let filesystem: String

    public init(partitionOffset: Int64, filesystemType: String) {
        offset = partitionOffset
        filesystem = filesystemType
    }

    public mutating func consume(_ data: Data, isFinal: Bool = false) -> [DeletedFileCandidate] {
        pending.append(data)
        var records: [DeletedFileCandidate] = []
        while let newline = pending.firstIndex(of: 10) {
            records.append(contentsOf: parse(Data(pending[..<newline])))
            pending.removeSubrange(...newline)
        }
        if isFinal, !pending.isEmpty {
            records.append(contentsOf: parse(pending))
            pending.removeAll(keepingCapacity: false)
        }
        candidates.append(contentsOf: records)
        return records
    }

    private mutating func parse(_ line: Data) -> [DeletedFileCandidate] {
        SleuthKitOutputParser.deletedFiles(
            from: String(decoding: line, as: UTF8.self),
            partitionOffset: offset,
            filesystemType: filesystem
        ).filter { seen.insert($0.id).inserted }
    }
}

/// One runner per operation. A saving worker MUST NOT share this runner with
/// the search worker: each has independent process cancellation and raw FD.
final class QuickToolProcess: @unchecked Sendable {
    struct Result {
        let status: Int32
        let terminationReason: Process.TerminationReason
        let output: String
    }

    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func checkCancelled() throws {
        lock.lock()
        let stopped = cancelled
        lock.unlock()
        if stopped || Task.isCancelled { throw DeletedFilesError.cancelled }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        guard let running, running.isRunning else { return }
        let pid = running.processIdentifier
        if kill(-pid, SIGTERM) != 0 { kill(pid, SIGTERM) }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) {
            // Don't send a delayed signal to a PID after this Process exited.
            guard running.isRunning else { return }
            if kill(-pid, SIGKILL) != 0 { kill(pid, SIGKILL) }
        }
    }

    func run(
        _ tool: URL,
        launcher: URL?,
        arguments: [String],
        standardOutput: FileHandle? = nil,
        standardInput: Data? = nil,
        onStdout: ((Data) -> Void)? = nil
    ) throws -> Result {
        let child = Process()
        child.executableURL = launcher ?? tool
        child.arguments = launcher == nil ? arguments : [tool.path] + arguments
        let combined = Pipe()
        let errors = Pipe()
        let input = standardInput == nil ? nil : Pipe()
        child.standardInput = input ?? FileHandle.nullDevice

        // fls uses block buffering with a pipe. Give ONLY stdout a PTY so libc
        // line-buffers its output, without patching TSK or exposing auth bytes
        // on a terminal. stdin stays a pipe (helper replaces it with raw FD).
        var master: FileHandle?
        var slave: FileHandle?
        if onStdout != nil {
            var readFD: Int32 = -1
            var writeFD: Int32 = -1
            guard openpty(&readFD, &writeFD, nil, nil, nil) == 0 else {
                throw DeletedFilesError.launchFailed("Не удалось открыть поток результатов поиска.")
            }
            master = FileHandle(fileDescriptor: readFD, closeOnDealloc: true)
            slave = FileHandle(fileDescriptor: writeFD, closeOnDealloc: true)
            _ = fcntl(readFD, F_SETFD, FD_CLOEXEC)
            _ = fcntl(writeFD, F_SETFD, FD_CLOEXEC)
            var options = termios()
            if tcgetattr(writeFD, &options) == 0 {
                options.c_oflag &= ~tcflag_t(OPOST)
                _ = tcsetattr(writeFD, TCSANOW, &options)
            }
            child.standardOutput = slave
            child.standardError = errors
        } else if let standardOutput {
            child.standardOutput = standardOutput
            child.standardError = errors
        } else {
            child.standardOutput = combined
            child.standardError = combined
        }
        defer { try? master?.close(); try? slave?.close() }

        // Registration and launch are atomic with cancel(): a cancellation
        // before child.run must never be lost.
        lock.lock()
        if cancelled {
            lock.unlock()
            throw DeletedFilesError.cancelled
        }
        if process != nil {
            lock.unlock()
            throw DeletedFilesError.launchFailed("Для одновременного сохранения нужен отдельный процесс восстановления.")
        }
        process = child
        do { try child.run() } catch {
            process = nil
            lock.unlock()
            throw DeletedFilesError.launchFailed(error.localizedDescription)
        }
        lock.unlock()
        defer {
            lock.lock()
            process = nil
            lock.unlock()
        }
        try? slave?.close()
        if let standardInput, let input {
            input.fileHandleForWriting.write(standardInput)
            try? input.fileHandleForWriting.close()
        }

        var output = Data()
        if let master, let onStdout {
            let diagnostics = QuickDiagnosticBuffer()
            let drained = DispatchGroup()
            drained.enter()
            DispatchQueue.global(qos: .utility).async {
                // Concurrent drain prevents stderr filling and blocking fls.
                while let data = try? errors.fileHandleForReading.read(upToCount: 16384), !data.isEmpty {
                    diagnostics.append(data)
                }
                drained.leave()
            }
            var buffer = [UInt8](repeating: 0, count: 65536)
            var readFailure = false
            while true {
                let count = Darwin.read(master.fileDescriptor, &buffer, buffer.count)
                if count > 0 {
                    let data = Data(buffer.prefix(count))
                    onStdout(data)
                } else if count == 0 || errno == EIO {
                    // Darwin PTY masters report EIO after the last slave closes.
                    break
                } else if errno != EINTR {
                    readFailure = true
                    cancel()
                    break
                }
            }
            child.waitUntilExit()
            drained.wait()
            output = diagnostics.data
            if readFailure { throw DeletedFilesError.sourceReadFailed }
            try checkCancelled()
        } else {
            output = (standardOutput == nil ? combined : errors).fileHandleForReading.readDataToEndOfFile()
            child.waitUntilExit()
            try checkCancelled()
        }
        return Result(status: child.terminationStatus, terminationReason: child.terminationReason,
                      output: String(decoding: output, as: UTF8.self))
    }
}

private final class QuickDiagnosticBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ bytes: Data) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(bytes)
        if storage.count > 65536 { storage.removeFirst(storage.count - 65536) }
    }
}
