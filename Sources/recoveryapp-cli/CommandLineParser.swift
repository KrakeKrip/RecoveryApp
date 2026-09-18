import Foundation
import RecoveryCore

enum QuickSource: Equatable {
    case image(String)
    case drive(identifier: String, expectedName: String, expectedSize: Int64)
}

enum CLICommand: Equatable {
    case help
    case version(json: Bool)
    case drivesList(json: Bool)
    case quickScan(source: QuickSource, json: Bool)
    case quickRecover(source: QuickSource, output: String, json: Bool)
}

enum CLIUsageError: Error, Equatable {
    case unknownCommand(String)
    case unknownOption(String)
    case missingDrivesCommand
    case unknownDrivesCommand(String)
    case unexpectedArgument(String)
    case missingQuickCommand
    case unknownQuickCommand(String)
    case missingOptionValue(String)
    case missingRequiredOption(String)
    case duplicateOption(String)
    case optionNotAllowed(String, String)
    case conflictingOptions(String, String)
    case missingSourceOption
    case invalidDriveIdentifier(String)
    case invalidExpectedSize(String)
}

enum CommandLineParser {
    /// Опции quick, принимающие значение.
    private static let valueOptionTokens: Set<String> = [
        "--image", "--output", "--drive", "--expected-name", "--expected-size"
    ]
    private static let knownOptionTokens: Set<String> =
        valueOptionTokens.union(["--json", "--all"])

    static func parse(_ arguments: [String]) throws -> CLICommand {
        var positional: [String] = []
        var json = false
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            if token == "--json" {
                json = true
            } else if token == "--all" {
                positional.append(token)
            } else if valueOptionTokens.contains(token) {
                // Значением не может быть другой известный параметр CLI:
                // "quick scan --image --json" — это ошибка, а не образ "--json".
                guard index + 1 < arguments.count,
                      !knownOptionTokens.contains(arguments[index + 1]) else {
                    throw CLIUsageError.missingOptionValue(token)
                }
                positional.append(token)
                index += 1
                positional.append(arguments[index])
            } else if token.hasPrefix("-"), token.count > 1 {
                throw CLIUsageError.unknownOption(token)
            } else {
                positional.append(token)
            }
            index += 1
        }
        guard let command = positional.first else { return .help }
        switch command {
        case "help":
            guard positional.count == 1 else { throw CLIUsageError.unexpectedArgument(positional[1]) }
            return .help
        case "version":
            guard positional.count == 1 else { throw CLIUsageError.unexpectedArgument(positional[1]) }
            return .version(json: json)
        case "drives":
            guard positional.count >= 2 else { throw CLIUsageError.missingDrivesCommand }
            guard positional[1] == "list" else { throw CLIUsageError.unknownDrivesCommand(positional[1]) }
            guard positional.count == 2 else { throw CLIUsageError.unexpectedArgument(positional[2]) }
            return .drivesList(json: json)
        case "quick":
            return try parseQuick(positional: positional, json: json)
        case let other:
            throw CLIUsageError.unknownCommand(other)
        }
    }

    private static func parseQuick(positional: [String], json: Bool) throws -> CLICommand {
        guard positional.count >= 2 else { throw CLIUsageError.missingQuickCommand }
        let subcommand = positional[1]
        guard ["scan", "recover"].contains(subcommand) else {
            throw CLIUsageError.unknownQuickCommand(subcommand)
        }

        var image: String?
        var drive: String?
        var expectedName: String?
        var expectedSize: Int64?
        var output: String?
        var all = false
        var index = 2
        while index < positional.count {
            let token = positional[index]
            if token == "--all" {
                guard !all else { throw CLIUsageError.duplicateOption(token) }
                all = true
                index += 1
                continue
            }
            // Pre-scan гарантирует пары «опция — значение» и то, что значением
            // не является другой известный параметр.
            guard valueOptionTokens.contains(token), index + 1 < positional.count else {
                throw CLIUsageError.unexpectedArgument(token)
            }
            let value = positional[index + 1]
            switch token {
            case "--image":
                guard image == nil else { throw CLIUsageError.duplicateOption(token) }
                image = value
            case "--drive":
                guard drive == nil else { throw CLIUsageError.duplicateOption(token) }
                drive = value
            case "--expected-name":
                guard expectedName == nil else { throw CLIUsageError.duplicateOption(token) }
                expectedName = value
            case "--expected-size":
                guard expectedSize == nil else { throw CLIUsageError.duplicateOption(token) }
                guard let parsed = Int64(value), parsed > 0 else {
                    throw CLIUsageError.invalidExpectedSize(value)
                }
                expectedSize = parsed
            default:
                guard output == nil else { throw CLIUsageError.duplicateOption(token) }
                output = value
            }
            index += 2
        }

        if image != nil, drive != nil {
            throw CLIUsageError.conflictingOptions("--image", "--drive")
        }
        if image != nil, expectedName != nil {
            throw CLIUsageError.optionNotAllowed("--expected-name", "quick scan --image")
        }
        if image != nil, expectedSize != nil {
            throw CLIUsageError.optionNotAllowed("--expected-size", "quick scan --image")
        }

        let source: QuickSource
        if let drive {
            guard PhysicalDriveSelector.isValidDriveIdentifier(drive) else {
                throw CLIUsageError.invalidDriveIdentifier(drive)
            }
            guard let expectedName else { throw CLIUsageError.missingRequiredOption("--expected-name") }
            guard let expectedSize else { throw CLIUsageError.missingRequiredOption("--expected-size") }
            source = .drive(identifier: drive, expectedName: expectedName, expectedSize: expectedSize)
        } else if let image {
            source = .image(image)
        } else {
            throw CLIUsageError.missingSourceOption
        }

        switch subcommand {
        case "scan":
            if output != nil {
                throw CLIUsageError.optionNotAllowed("--output", "quick scan")
            }
            if all {
                throw CLIUsageError.optionNotAllowed("--all", "quick scan")
            }
            return .quickScan(source: source, json: json)
        case "recover":
            guard let output else { throw CLIUsageError.missingRequiredOption("--output") }
            guard all else { throw CLIUsageError.missingRequiredOption("--all") }
            return .quickRecover(source: source, output: output, json: json)
        case let other:
            throw CLIUsageError.unknownQuickCommand(other)
        }
    }
}
