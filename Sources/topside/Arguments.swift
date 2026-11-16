import Foundation

struct CLIError: Error, CustomStringConvertible {
    var description: String
    init(_ d: String) { description = d }
}

/// Minimal argument parsing: `--name value`, `--flag`, and positionals. No dependencies.
struct Arguments {
    static let valueOptions: Set<String> = ["repo", "agent", "model", "budget", "copy", "clone", "prep", "verify"]
    static let flagOptions: Set<String> = ["in-place", "wait", "all", "follow", "clear", "help"]

    var positional: [String] = []
    var values: [String: [String]] = [:]
    var flags: Set<String> = []

    init(_ argv: [String]) throws {
        var i = 0
        var onlyPositional = false
        while i < argv.count {
            let a = argv[i]
            if onlyPositional || !a.hasPrefix("--") || a == "-" {
                positional.append(a)
            } else if a == "--" {
                onlyPositional = true
            } else {
                let name = String(a.dropFirst(2))
                if Self.flagOptions.contains(name) {
                    flags.insert(name)
                } else if Self.valueOptions.contains(name) {
                    guard i + 1 < argv.count else { throw CLIError("--\(name) needs a value.") }
                    values[name, default: []].append(argv[i + 1])
                    i += 1
                } else {
                    throw CLIError("Unknown option --\(name). See `topside help`.")
                }
            }
            i += 1
        }
    }

    func value(_ name: String) -> String? { values[name]?.last }
    func all(_ name: String) -> [String] { values[name] ?? [] }
    func has(_ name: String) -> Bool { flags.contains(name) }
}
