import Foundation

enum LogSanitizer {
    static func clean(_ raw: String) -> String {
        let scalars = Array(raw.unicodeScalars)
        var result = String.UnicodeScalarView()
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]
            if scalar.value == 0x1B {
                index += 1
                guard index < scalars.count else { break }
                if scalars[index] == "[" {
                    index += 1
                    while index < scalars.count {
                        let value = scalars[index].value
                        index += 1
                        if value >= 0x40 && value <= 0x7E { break }
                    }
                } else {
                    index += 1
                }
                continue
            }
            if scalar == "\r" {
                result.append("\n")
            } else if scalar == "\n" || scalar == "\t" || scalar.value >= 0x20 {
                result.append(scalar)
            }
            index += 1
        }

        var lines: [String] = []
        var previousWasEmpty = false
        for rawLine in String(result).split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(
                    of: #"[\t ]+"#,
                    with: " ",
                    options: .regularExpression
                )
            if line.isEmpty {
                if !previousWasEmpty { lines.append("") }
                previousWasEmpty = true
            } else {
                lines.append(line)
                previousWasEmpty = false
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func photoRecSummary(_ raw: String) -> String {
        let cleaned = clean(raw)
        var result: [String] = []
        var includedVersion = false

        for line in cleaned.split(whereSeparator: \.isNewline).map(String.init) {
            let lower = line.lowercased()
            let isNumberOnly = !line.isEmpty && line.allSatisfy { $0.isNumber || $0.isWhitespace }
            if isNumberOnly { continue }

            if line.hasPrefix("PhotoRec ") {
                if includedVersion { continue }
                includedVersion = true
                result.append(line)
                continue
            }

            let usefulPrefixes = [
                "Disk ", "Partition", "Pass ", "Elapsed time", "Estimated time",
                "Total:", "jpg:", "png:", "mov:", "Stop"
            ]
            let isUseful = usefulPrefixes.contains { line.hasPrefix($0) }
            let isDiagnostic = ["error", "failed", "can't", "invalid", "rejected", "exited"]
                .contains { lower.contains($0) }
            if isUseful || isDiagnostic {
                if result.last != line { result.append(line) }
            }
        }

        return result.isEmpty ? "PhotoRec завершил работу." : result.joined(separator: "\n")
    }
}
