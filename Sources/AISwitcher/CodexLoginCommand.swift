import Foundation

struct CodexLoginCommand: Equatable {
    let executablePath: String
    let arguments: [String]

    static func shellWrapped(codexPath: String) -> CodexLoginCommand {
        shellWrapped(executablePath: codexPath, shellCommand: "login")
    }

    static func shellWrapped(executablePath: String, shellCommand: String) -> CodexLoginCommand {
        let escapedPath = executablePath.replacingOccurrences(of: "'", with: "'\"'\"'")
        let escapedCommand = shellCommand.replacingOccurrences(of: "'", with: "'\"'\"'")
        return CodexLoginCommand(
            executablePath: "/bin/zsh",
            arguments: ["-l", "-c", "exec '\(escapedPath)' \(escapedCommand)"]
        )
    }
}
