import Foundation

enum CLICommand: Equatable {
    case help
    case version(json: Bool)
    case drivesList(json: Bool)
}

enum CLIUsageError: Error, Equatable {
    case unknownCommand(String)
    case unknownOption(String)
    case missingDrivesCommand
    case unknownDrivesCommand(String)
    case unexpectedArgument(String)
}

enum CommandLineParser {
    static func parse(_ arguments: [String]) throws -> CLICommand {
        var positional: [String] = []
        var json = false
        for token in arguments {
            if token == "--json" {
                json = true
            } else if token.hasPrefix("-"), token.count > 1 {
                throw CLIUsageError.unknownOption(token)
            } else {
                positional.append(token)
            }
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
        case let other:
            throw CLIUsageError.unknownCommand(other)
        }
    }
}
