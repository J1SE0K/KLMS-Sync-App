import Foundation
import Darwin

public struct KLMSCommandResult: Sendable, Equatable {
    public var invocation: KLMSCommandInvocation
    public var startedAt: Date
    public var finishedAt: Date
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String
    public var authDigits: String?
    public var wasCancelled: Bool

    public init(
        invocation: KLMSCommandInvocation,
        startedAt: Date,
        finishedAt: Date,
        exitCode: Int32,
        standardOutput: String,
        standardError: String,
        authDigits: String?,
        wasCancelled: Bool = false
    ) {
        self.invocation = invocation
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.authDigits = authDigits
        self.wasCancelled = wasCancelled
    }

    public var combinedOutput: String {
        [standardOutput, standardError].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    public var succeeded: Bool {
        exitCode == 0
    }

    public var loginAuthenticated: Bool {
        KLMSCommandRunner.outputIndicatesAuthenticatedAfterLatestAuthDigits(combinedOutput)
    }

    public var sawAuthDigits: Bool {
        KLMSCommandRunner.extractLatestAuthDigits(from: combinedOutput) != nil
    }

    public var requiresLoginApproval: Bool {
        authDigits != nil && !loginAuthenticated
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
    private var currentProcess: Process?
    private var cancellationRequested = false

    public init() {}

    @discardableResult
    public func cancelCurrentCommand() -> Bool {
        guard let currentProcess, currentProcess.isRunning else {
            return false
        }
        cancellationRequested = true
        let rootPID = currentProcess.processIdentifier
        Self.sendSignalToProcessTree(rootPID: rootPID, signal: SIGTERM)
        currentProcess.terminate()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await self?.forceKillIfStillRunning(rootPID: rootPID)
        }
        return true
    }

    public func run(
        _ command: KLMSEngineCommand,
        paths: KLMSPaths,
        dryRun: Bool = false,
        environment: [String: String] = [:],
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> KLMSCommandResult {
        if let currentCommand {
            throw KLMSCommandRunnerError.alreadyRunning(currentCommand)
        }
        currentCommand = command
        cancellationRequested = false
        defer {
            currentCommand = nil
            currentProcess = nil
            cancellationRequested = false
        }

        let invocation = command.invocation(dryRun: dryRun)
        let started = Date()
        let process = Process()
        process.currentDirectoryURL = paths.engineRoot
        process.executableURL = URL(fileURLWithPath: invocation.executablePath)
        process.arguments = invocation.arguments

        process.environment = Self.processEnvironmentForLaunch(
            base: ProcessInfo.processInfo.environment,
            overrides: environment
        )

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdoutCollector = CommandOutputCollector(onOutput: onOutput)
        let stderrCollector = CommandOutputCollector(onOutput: onOutput)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            stdoutCollector.readAvailableData(from: handle)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            stderrCollector.readAvailableData(from: handle)
        }

        do {
            try process.run()
            currentProcess = process
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw KLMSCommandRunnerError.launchFailed(error.localizedDescription)
        }

        let terminationWaiter = ProcessTerminationWaiter()
        process.terminationHandler = { _ in
            terminationWaiter.finish()
        }
        if !process.isRunning {
            terminationWaiter.finish()
        }
        await terminationWaiter.wait()
        process.terminationHandler = nil
        let wasCancelled = cancellationRequested
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        stdoutCollector.readAvailableData(from: stdout.fileHandleForReading)
        stderrCollector.readAvailableData(from: stderr.fileHandleForReading)

        let stdoutText = stdoutCollector.text
        let stderrText = stderrCollector.text
        let combined = [stdoutText, stderrText].joined(separator: "\n")
        return KLMSCommandResult(
            invocation: invocation,
            startedAt: started,
            finishedAt: Date(),
            exitCode: process.terminationStatus,
            standardOutput: stdoutText,
            standardError: stderrText,
            authDigits: Self.extractAuthDigits(from: combined),
            wasCancelled: wasCancelled
        )
    }

    private func forceKillIfStillRunning(rootPID: Int32) {
        guard cancellationRequested,
              let currentProcess,
              currentProcess.processIdentifier == rootPID,
              currentProcess.isRunning else {
            return
        }
        Self.sendSignalToProcessTree(rootPID: rootPID, signal: SIGKILL)
    }

    public static func extractAuthDigits(from text: String) -> String? {
        guard let latestMatch = latestAuthDigitsMatch(in: text) else {
            return nil
        }
        if let authenticatedLocation = latestAuthenticatedLocation(in: text),
           authenticatedLocation > latestMatch.location {
            return nil
        }
        return latestMatch.digits
    }

    public static func extractLatestAuthDigits(from text: String) -> String? {
        latestAuthDigitsMatch(in: text)?.digits
    }

    private static func latestAuthDigitsMatch(in text: String) -> (location: Int, digits: String)? {
        let patterns = [
            #"KAIST 인증 번호:\s*([0-9][0-9])"#,
            #"digits=([0-9][0-9])"#,
        ]
        var latestMatch: (location: Int, digits: String)?
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            regex.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match, match.numberOfRanges > 1 else {
                    return
                }
                guard let digitsRange = Range(match.range(at: 1), in: text) else {
                    return
                }
                let digits = String(text[digitsRange])
                if latestMatch == nil || match.range.location > latestMatch!.location {
                    latestMatch = (match.range.location, digits)
                }
            }
        }
        return latestMatch
    }

    public static func outputIndicatesAuthenticated(_ text: String) -> Bool {
        latestAuthenticatedLocation(in: text) != nil
    }

    public static func outputIndicatesAuthenticatedAfterLatestAuthDigits(_ text: String) -> Bool {
        guard let authenticatedLocation = latestAuthenticatedLocation(in: text) else {
            return false
        }
        guard let authDigitsLocation = latestAuthDigitsMatch(in: text)?.location else {
            return true
        }
        return authenticatedLocation > authDigitsLocation
    }

    public static func latestAuthenticatedLocation(in text: String) -> Int? {
        let markers = [
            "status=ok stage=authenticated",
            "status=authenticated",
            "KLMS 로그인 보조 완료",
        ]
        let nsText = text as NSString
        var latestLocation: Int?
        for marker in markers {
            let range = nsText.range(
                of: marker,
                options: [.caseInsensitive, .backwards]
            )
            guard range.location != NSNotFound else {
                continue
            }
            if latestLocation == nil || range.location > latestLocation! {
                latestLocation = range.location
            }
        }
        return latestLocation
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

    public static func processEnvironmentForLaunch(
        base: [String: String],
        overrides: [String: String] = [:]
    ) -> [String: String] {
        var environment = base
        environment["PATH"] = pathWithDeveloperToolLocations(environment["PATH"])
        environment["LANG"] = "ko_KR.UTF-8"
        environment["LC_ALL"] = "ko_KR.UTF-8"
        environment["LC_CTYPE"] = "ko_KR.UTF-8"
        environment["PYTHONIOENCODING"] = "utf-8"
        environment["PYTHONUTF8"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        environment["NODE_DISABLE_COLORS"] = "1"
        for (key, value) in overrides {
            environment[key] = value
        }
        return environment
    }

    private static func sendSignalToProcessTree(rootPID: Int32, signal: Int32) {
        guard rootPID > 1 else {
            return
        }
        let childrenByParent = processChildrenByParent()
        let descendants = processTree(rootPID: rootPID, childrenByParent: childrenByParent)
        for pid in descendants.reversed() where pid > 1 {
            Darwin.kill(pid_t(pid), signal)
        }
        Darwin.kill(pid_t(rootPID), signal)
    }

    private static func processTree(rootPID: Int32, childrenByParent: [Int32: [Int32]]) -> [Int32] {
        var result: [Int32] = []
        var stack = childrenByParent[rootPID] ?? []
        while let pid = stack.popLast() {
            result.append(pid)
            stack.append(contentsOf: childrenByParent[pid] ?? [])
        }
        return result
    }

    private static func processChildrenByParent() -> [Int32: [Int32]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return [:]
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        var children: [Int32: [Int32]] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let values = line
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .compactMap { Int32($0) }
            guard values.count >= 2 else {
                continue
            }
            let pid = values[0]
            let parent = values[1]
            children[parent, default: []].append(pid)
        }
        return children
    }
}

private final class ProcessTerminationWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if finished {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func finish() {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume()
            return
        }
        finished = true
        lock.unlock()
    }
}

private final class CommandOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    private var emittedCharacterCount = 0
    private let onOutput: (@Sendable (String) -> Void)?

    init(onOutput: (@Sendable (String) -> Void)?) {
        self.onOutput = onOutput
    }

    var text: String {
        lock.lock()
        defer {
            lock.unlock()
        }
        return Self.decode(storage)
    }

    func readAvailableData(from handle: FileHandle) {
        let data = handle.availableData
        guard !data.isEmpty else {
            return
        }
        lock.lock()
        storage.append(data)
        let decoded = Self.decode(storage)
        let text: String
        if emittedCharacterCount <= decoded.count {
            text = String(decoded.dropFirst(emittedCharacterCount))
        } else {
            text = decoded
        }
        emittedCharacterCount = decoded.count
        lock.unlock()
        if !text.isEmpty {
            onOutput?(text)
        }
    }

    private static func decode(_ data: Data) -> String {
        data.klmsDecodedDisplayText
    }
}
