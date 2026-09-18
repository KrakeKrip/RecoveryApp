@preconcurrency import Foundation

public struct ExternalDrive: Identifiable, Hashable, Sendable {
    public let identifier: String
    public let name: String
    public let size: Int64
    public let connection: String
    public let mountPoints: [URL]

    public var id: String { identifier }
    public var rawDevicePath: String { "/dev/r\(identifier)" }

    public var displayName: String {
        let details = [name, Self.humanSize(size), connection]
            .filter { !$0.isEmpty }
        return details.joined(separator: " · ")
    }

    public static func humanSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        formatter.allowedUnits = [.useGB, .useTB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: max(0, bytes))
    }

    public func contains(_ destination: URL) -> Bool {
        let destinationPath = destination.resolvingSymlinksInPath().standardizedFileURL.path
        return mountPoints.contains { mountPoint in
            let mountPath = mountPoint.resolvingSymlinksInPath().standardizedFileURL.path
            return destinationPath == mountPath || destinationPath.hasPrefix(mountPath + "/")
        }
    }
}

public enum ExternalDriveError: LocalizedError {
    case unavailable(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail):
            "Не удалось получить список накопителей. \(detail)"
        case .invalidResponse:
            "macOS вернула непонятный список накопителей."
        }
    }
}

public enum ExternalDriveParser {
    public static func drives(from data: Data) throws -> [ExternalDrive] {
        let propertyList = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        guard let root = propertyList as? [String: Any],
              let diskNodes = root["AllDisksAndPartitions"] as? [[String: Any]]
        else { throw ExternalDriveError.invalidResponse }

        return diskNodes.compactMap { node in
            guard let identifier = node["DeviceIdentifier"] as? String,
                  isValidDiskIdentifier(identifier)
            else { return nil }
            let names = collectStrings(key: "VolumeName", node: node)
            let mediaName = (node["MediaName"] as? String)?.trimmingCharacters(in: .whitespaces)
            let name = names.first ?? mediaName.flatMap { $0.isEmpty ? nil : $0 } ?? identifier
            let size = (node["Size"] as? NSNumber)?.int64Value
                ?? (node["TotalSize"] as? NSNumber)?.int64Value
                ?? 0
            let connection = (node["BusProtocol"] as? String)?.trimmingCharacters(in: .whitespaces)
                ?? "Внешний накопитель"
            let mounts = collectStrings(key: "MountPoint", node: node).map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
            return ExternalDrive(
                identifier: identifier,
                name: name,
                size: size,
                connection: connection,
                mountPoints: mounts
            )
        }
    }

    private static func collectStrings(key: String, node: [String: Any]) -> [String] {
        var values: [String] = []
        if let value = node[key] as? String, !value.isEmpty {
            values.append(value)
        }
        for childKey in ["Partitions", "APFSVolumes"] {
            for child in node[childKey] as? [[String: Any]] ?? [] {
                values.append(contentsOf: collectStrings(key: key, node: child))
            }
        }
        return Array(NSOrderedSet(array: values)) as? [String] ?? values
    }

    private static func isValidDiskIdentifier(_ value: String) -> Bool {
        guard value.hasPrefix("disk") else { return false }
        let suffix = value.dropFirst(4)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }
}

public final class ExternalDriveDiscovery: Sendable {
    public init() {}

    public func load() async throws -> [ExternalDrive] {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            let error = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            process.arguments = ["list", "-plist", "external", "physical"]
            process.standardOutput = output
            process.standardError = error
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                throw ExternalDriveError.unavailable(error.localizedDescription)
            }
            let outputData = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = error.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let detail = String(decoding: errorData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw ExternalDriveError.unavailable(detail)
            }
            return try ExternalDriveParser.drives(from: outputData)
        }.value
    }
}
