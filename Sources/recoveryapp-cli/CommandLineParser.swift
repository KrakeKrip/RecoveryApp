import Foundation

enum CLICommand: Equatable {
    case help
    case version(json: Bool)
    case drivesList(json: Bool)
    case quickScan(image: String, json: Bool)
    case quickRecover(image: String, output: String, json: Bool)
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
}

enum CommandLineParser {
    private static let quickOptionTokens: Set<String> = ["--image", "--output", "--all"]
    private static let knownOptionTokens: Set<String> = ["--json", "--image", "--output", "--all"]

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
            } else if token == "--image" || token == "--output" {
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
            guard quickOptionTokens.contains(token) else {
                throw CLIUsageError.unexpectedArgument(token)
            }
            guard index + 1 < positional.count else {
                throw CLIUsageError.missingOptionValue(token)
            }
            let value = positional[index + 1]
            if token == "--image" {
                guard image == nil else { throw CLIUsageError.duplicateOption(token) }
                image = value
            } else {
                guard output == nil else { throw CLIUsageError.duplicateOption(token) }
                output = value
            }
            index += 2
        }

        switch subcommand {
        case "scan":
            guard let image else { throw CLIUsageError.missingRequiredOption("--image") }
            if output != nil {
                throw CLIUsageError.optionNotAllowed("--output", "quick scan")
            }
            if all {
                throw CLIUsageError.optionNotAllowed("--all", "quick scan")
            }
            return .quickScan(image: image, json: json)
        case "recover":
            guard let image else { throw CLIUsageError.missingRequiredOption("--image") }
            guard let output else { throw CLIUsageError.missingRequiredOption("--output") }
            guard all else { throw CLIUsageError.missingRequiredOption("--all") }
            return .quickRecover(image: image, output: output, json: json)
        case let other:
            throw CLIUsageError.unknownQuickCommand(other)
        }
    }
}
