import Foundation

public struct KLMSCommandResult: Sendable, Equatable {
    public var invocation: KLMSCommandInvocation
    public var startedAt: Date
    public var finishedAt: Date
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String
    public var authDigits: String?

    public init(
        invocation: KLMSCommandInvocation,
        startedAt: Date,
        finishedAt: Date,
        exitCode: Int32,
        standardOutput: String,
        standardError: String,
        authDigits: String?
    ) {
        self.invocation = invocation
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.authDigits = authDigits
    }

    public var combinedOutput: String {
        [standardOutput, standardError].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    public var succeeded: Bool {
        exitCode == 0
    }
}

public enum KLMSCommandRunnerError: Error, Sendable, LocalizedError, Equatable {
    case alreadyRunning(KLMSEngineCommand)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .alreadyRunning(command):
            "이미 실행 중: \(command.displayName)"
        case let .launchFailed(message):
            message
        }
    }
}

public actor KLMSCommandRunner {
    private var currentCommand: KLMSEngineCommand?

    public init() {}

    public func run(
        _ command: KLMSEngineCommand,
        paths: KLMSPaths,
        dryRun: Bool = false,
        environment: [String: String] = [:]
    ) async throws -> KLMSCommandResult {
        if let currentCommand {
            throw KLMSCommandRunnerError.alreadyRunning(currentCommand)
        }
        currentCommand = command
        defer {
            currentCommand = nil
        }

        let invocation = command.invocation(dryRun: dryRun)
        let started = Date()
        let process = Process()
        process.currentDirectoryURL = paths.engineRoot
        process.executableURL = URL(fileURLWithPath: invocation.executablePath)
        process.arguments = invocation.arguments

        var processEnvironment = ProcessInfo.processInfo.environment
        processEnvironment["PATH"] = Self.pathWithDeveloperToolLocations(processEnvironment["PATH"])
        for (key, value) in environment {
            processEnvironment[key] = value
        }
        process.environment = processEnvironment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw KLMSCommandRunnerError.launchFailed(error.localizedDescription)
        }

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
        let combined = [stdoutText, stderrText].joined(separator: "\n")
        return KLMSCommandResult(
            invocation: invocation,
            startedAt: started,
            finishedAt: Date(),
            exitCode: process.terminationStatus,
            standardOutput: stdoutText,
            standardError: stderrText,
            authDigits: Self.extractAuthDigits(from: combined)
        )
    }

    public static func extractAuthDigits(from text: String) -> String? {
        let patterns = [
            #"KAIST 인증 번호:\s*([0-9][0-9])"#,
            #"digits=([0-9][0-9])"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else {
                continue
            }
            guard let digitsRange = Range(match.range(at: 1), in: text) else {
                continue
            }
            return String(text[digitsRange])
        }
        return nil
    }

    public static func pathWithDeveloperToolLocations(_ path: String?) -> String {
        let defaults = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/local/bin", "/opt/homebrew/bin"]
        var parts = (path ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }
        for item in defaults where !parts.contains(item) {
            parts.append(item)
        }
        return parts.joined(separator: ":")
    }
}
