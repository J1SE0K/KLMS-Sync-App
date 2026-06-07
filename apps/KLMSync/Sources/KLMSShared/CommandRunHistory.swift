import Foundation

public struct CommandRunHistory: Codable, Sendable, Equatable {
    public var version: Int
    public var records: [CommandRunRecord]

    public init(version: Int = 1, records: [CommandRunRecord] = []) {
        self.version = version
        self.records = records
    }
}

public struct CommandRunRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var command: KLMSEngineCommand
    public var dryRun: Bool
    public var startedAt: Date
    public var finishedAt: Date
    public var exitCode: Int32
    public var wasCancelled: Bool
    public var authDigits: String?
    public var outputTail: String

    public init(
        id: String = UUID().uuidString,
        command: KLMSEngineCommand,
        dryRun: Bool,
        startedAt: Date,
        finishedAt: Date,
        exitCode: Int32,
        wasCancelled: Bool,
        authDigits: String?,
        outputTail: String
    ) {
        self.id = id
        self.command = command
        self.dryRun = dryRun
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.exitCode = exitCode
        self.wasCancelled = wasCancelled
        self.authDigits = authDigits
        self.outputTail = outputTail
    }

    public var succeeded: Bool {
        exitCode == 0
    }

    public var needsAttention: Bool {
        !succeeded && !wasCancelled
    }

    public var elapsedSecondsText: String {
        TimeDisplay.secondsText(milliseconds: Int(finishedAt.timeIntervalSince(startedAt) * 1000))
    }

    public var statusText: String {
        if wasCancelled {
            return "중단됨"
        }
        return succeeded ? "성공" : "실패 \(exitCode)"
    }
}

public struct CommandRunHistoryStore: Sendable {
    public var url: URL
    public var maxRecords: Int

    public init(url: URL, maxRecords: Int = 80) {
        self.url = url
        self.maxRecords = maxRecords
    }

    public func load() -> CommandRunHistory {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return CommandRunHistory()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var history = (try? decoder.decode(CommandRunHistory.self, from: data)) ?? CommandRunHistory()
        history.records = history.records.map { record in
            var normalized = record
            normalized.outputTail = Self.displayOutput(record.outputTail, wasCancelled: record.wasCancelled)
            if normalized.wasCancelled {
                normalized.authDigits = nil
            }
            return normalized
        }
        return history
    }

    public func append(_ result: KLMSCommandResult) throws -> CommandRunHistory {
        var history = load()
        history.records.insert(
            CommandRunRecord(
                command: result.invocation.command,
                dryRun: result.invocation.dryRun,
                startedAt: result.startedAt,
                finishedAt: result.finishedAt,
                exitCode: result.exitCode,
                wasCancelled: result.wasCancelled,
                authDigits: result.wasCancelled ? nil : result.authDigits,
                outputTail: Self.tail(
                    Self.displayOutput(result.combinedOutput, wasCancelled: result.wasCancelled),
                    maxLines: 120
                )
            ),
            at: 0
        )
        if history.records.count > maxRecords {
            history.records = Array(history.records.prefix(maxRecords))
        }
        try save(history)
        return history
    }

    @discardableResult
    public func clear() throws -> CommandRunHistory {
        let history = CommandRunHistory()
        try save(history)
        return history
    }

    private func save(_ history: CommandRunHistory) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(history)
        try data.write(to: url, options: .atomic)
    }

    private static func tail(_ text: String, maxLines: Int) -> String {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count > maxLines else {
            return text
        }
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    private static func displayOutput(_ text: String, wasCancelled: Bool) -> String {
        let displayText = text.klmsDisplayText
        return wasCancelled ? displayText.klmsRedactingAuthDigitsForDisplay : displayText
    }
}
