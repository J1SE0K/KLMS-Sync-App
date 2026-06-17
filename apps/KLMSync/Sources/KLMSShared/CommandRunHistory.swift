import Foundation

public struct CommandRunHistory: Codable, Sendable, Equatable {
    public var version: Int
    public var records: [CommandRunRecord]

    public init(version: Int = 2, records: [CommandRunRecord] = []) {
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
    public var stageDurations: [KLMSStageDuration]

    private enum CodingKeys: String, CodingKey {
        case id
        case command
        case dryRun
        case startedAt
        case finishedAt
        case exitCode
        case wasCancelled
        case authDigits
        case outputTail
        case stageDurations
    }

    public init(
        id: String = UUID().uuidString,
        command: KLMSEngineCommand,
        dryRun: Bool,
        startedAt: Date,
        finishedAt: Date,
        exitCode: Int32,
        wasCancelled: Bool,
        authDigits: String?,
        outputTail: String,
        stageDurations: [KLMSStageDuration] = []
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
        self.stageDurations = stageDurations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        command = try container.decode(KLMSEngineCommand.self, forKey: .command)
        dryRun = try container.decode(Bool.self, forKey: .dryRun)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        finishedAt = try container.decode(Date.self, forKey: .finishedAt)
        exitCode = try container.decode(Int32.self, forKey: .exitCode)
        wasCancelled = try container.decode(Bool.self, forKey: .wasCancelled)
        authDigits = try container.decodeIfPresent(String.self, forKey: .authDigits)
        outputTail = try container.decode(String.self, forKey: .outputTail)
        stageDurations = try container.decodeIfPresent([KLMSStageDuration].self, forKey: .stageDurations) ?? []
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

    public var stageDurationSummaryText: String {
        Self.stageDurationSummaryText(stageDurations)
    }

    public static func stageDurationSummaryText(_ durations: [KLMSStageDuration]) -> String {
        durations
            .map { "\($0.displayName) \($0.secondsText)" }
            .joined(separator: " · ")
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
            if normalized.stageDurations.isEmpty {
                normalized.stageDurations = KLMSStageDurationParser.parse(from: normalized.outputTail)
            }
            if normalized.wasCancelled {
                normalized.authDigits = nil
            }
            return normalized
        }
        return history
    }

    public func append(_ result: KLMSCommandResult) throws -> CommandRunHistory {
        var history = load()
        let displayOutput = Self.displayOutput(result.combinedOutput, wasCancelled: result.wasCancelled)
        let stageDurations = KLMSStageDurationParser.parse(from: displayOutput)
        let outputTail = Self.outputTailWithStageSummary(
            Self.tail(displayOutput, maxLines: 120),
            stageDurations: stageDurations
        )
        history.records.insert(
            CommandRunRecord(
                command: result.invocation.command,
                dryRun: result.invocation.dryRun,
                startedAt: result.startedAt,
                finishedAt: result.finishedAt,
                exitCode: result.exitCode,
                wasCancelled: result.wasCancelled,
                authDigits: result.wasCancelled ? nil : result.authDigits,
                outputTail: outputTail,
                stageDurations: stageDurations
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

    @discardableResult
    public func removeRecord(id: String) throws -> CommandRunHistory {
        var history = load()
        history.records.removeAll { $0.id == id }
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

    private static func outputTailWithStageSummary(_ outputTail: String, stageDurations: [KLMSStageDuration]) -> String {
        guard !stageDurations.isEmpty else {
            return outputTail
        }
        let summaryLine = stageDurationSummaryLine(stageDurations)
        guard !outputTail.contains(summaryLine) else {
            return outputTail
        }
        let trimmed = outputTail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return summaryLine
        }
        return "\(trimmed)\n\(summaryLine)"
    }

    private static func stageDurationSummaryLine(_ durations: [KLMSStageDuration]) -> String {
        let raw = durations.map { "\($0.stage)=\($0.seconds)s" }.joined(separator: " ")
        let readable = CommandRunRecord.stageDurationSummaryText(durations)
        return "== 단계별 실행시간 \(raw) (\(readable)) =="
    }
}
