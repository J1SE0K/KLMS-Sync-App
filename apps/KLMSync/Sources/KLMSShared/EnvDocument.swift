import Foundation

public enum EnvKnownKey: String, CaseIterable, Sendable, Identifiable {
    case ssoLoginID = "KLMS_SSO_LOGIN_ID"
    case loginAssistEnabled = "KLMS_LOGIN_ASSIST_ENABLED"
    case loginAssistMode = "KLMS_LOGIN_ASSIST_MODE"
    case loginAssistAllowNoninteractive = "KLMS_LOGIN_ASSIST_ALLOW_NONINTERACTIVE"
    case autoSyncEnabled = "KLMS_AUTO_SYNC_ENABLED"
    case syncIntervalSeconds = "SYNC_INTERVAL_SECONDS"
    case minIdleSeconds = "MIN_IDLE_SECONDS"
    case syncAbortOnUserActivity = "SYNC_ABORT_ON_USER_ACTIVITY"
    case syncActiveAbortIdleSeconds = "SYNC_ACTIVE_ABORT_IDLE_SECONDS"
    case safariBackgroundWindowEnabled = "KLMS_SAFARI_BACKGROUND_WINDOW_ENABLED"
    case safariBackgroundWindowMode = "KLMS_SAFARI_BACKGROUND_WINDOW_MODE"
    case safariReuseExistingWindowEnabled = "KLMS_SAFARI_REUSE_EXISTING_WINDOW_ENABLED"
    case calendarSkipUnchangedDesired = "CALENDAR_SKIP_UNCHANGED_DESIRED"
    case syncMode = "SYNC_MODE"
    case fileRefreshMode = "FILE_REFRESH_MODE"
    case fileSkipDownloadWhenPreviewEmpty = "FILE_SKIP_DOWNLOAD_WHEN_PREVIEW_EMPTY"
    case fileKeepFreshDownloads = "FILE_KEEP_FRESH_DOWNLOADS"
    case fileWeeklyFoldersEnabled = "FILE_WEEKLY_FOLDERS_ENABLED"
    case fileForceDownload = "FILE_FORCE_DOWNLOAD"
    case filePreserveDownloadArchive = "FILE_PRESERVE_DOWNLOAD_ARCHIVE"
    case fileNewFilesRoot = "FILE_NEW_FILES_ROOT"
    case fileQuarantineRoot = "FILE_QUARANTINE_ROOT"
    case noticeNoteName = "NOTICE_NOTE_NAME"
    case noticeArchiveNoteName = "NOTICE_ARCHIVE_NOTE_NAME"
    case noticeCollapseSections = "NOTICE_COLLAPSE_SECTIONS"
    case noticeCollapseCourses = "NOTICE_COLLAPSE_COURSES"
    case noticeCollapseItems = "NOTICE_COLLAPSE_NOTICE_ITEMS"
    case noticeStyleItemsAsHeadings = "NOTICE_STYLE_NOTICE_ITEMS_AS_HEADINGS"
    case noticeHideHiddenItems = "NOTICE_HIDE_HIDDEN_ITEMS"
    case noticeStableNoopSkip = "NOTICE_NATIVE_STABLE_NOOP_SKIP"
    case noticeAlwaysCaptureState = "NOTICE_NATIVE_ALWAYS_CAPTURE_STATE"
    case noticeVerifyStableSkipFormat = "NOTICE_NATIVE_VERIFY_STABLE_SKIP_FORMAT"
    case noticePreformattedPasteOnly = "NOTICE_NATIVE_PREFORMATTED_PASTE_ONLY"
    case noticePlainTextPaste = "NOTICE_NATIVE_PLAIN_TEXT_PASTE"

    public var id: String { rawValue }
}

public struct EnvDocument: Sendable, Equatable {
    public struct Line: Sendable, Equatable {
        public var raw: String
        public var key: String?
        public var exportPrefix: Bool

        public init(raw: String, key: String? = nil, exportPrefix: Bool = false) {
            self.raw = raw
            self.key = key
            self.exportPrefix = exportPrefix
        }
    }

    public private(set) var lines: [Line]

    public init(text: String) {
        self.lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { rawLine in
                let raw = String(rawLine)
                let parsed = EnvDocument.parseAssignment(raw)
                return Line(raw: raw, key: parsed?.key, exportPrefix: parsed?.exportPrefix ?? false)
            }
        if text.hasSuffix("\n") {
            self.lines.removeLast()
        }
    }

    public var text: String {
        lines.map(\.raw).joined(separator: "\n") + "\n"
    }

    public func value(for key: String) -> String? {
        for line in lines.reversed() where line.key == key {
            guard let parsed = EnvDocument.parseAssignment(line.raw) else { continue }
            return parsed.value
        }
        return nil
    }

    public func value(for key: EnvKnownKey) -> String? {
        value(for: key.rawValue)
    }

    public mutating func setValue(_ value: String, for key: EnvKnownKey) {
        setValue(value, forRawKey: key.rawValue)
    }

    public mutating func setValue(_ value: String, forRawKey key: String) {
        if let index = lines.lastIndex(where: { $0.key == key }) {
            let exportPrefix = lines[index].exportPrefix
            lines[index].raw = Self.renderAssignment(key: key, value: value, exportPrefix: exportPrefix)
            return
        }
        lines.append(Line(raw: Self.renderAssignment(key: key, value: value), key: key))
    }

    public mutating func setBool(_ value: Bool, for key: EnvKnownKey) {
        setValue(value ? "1" : "0", for: key)
    }

    public func boolValue(for key: EnvKnownKey, default defaultValue: Bool = false) -> Bool {
        guard let raw = value(for: key)?.lowercased() else {
            return defaultValue
        }
        return ["1", "true", "yes", "on"].contains(raw)
    }

    public static func parseAssignment(_ line: String) -> (key: String, value: String, exportPrefix: Bool)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
            return nil
        }

        var body = trimmed
        var exportPrefix = false
        if body.hasPrefix("export ") {
            exportPrefix = true
            body.removeFirst("export ".count)
            body = body.trimmingCharacters(in: .whitespaces)
        }

        guard let equals = body.firstIndex(of: "=") else {
            return nil
        }
        let key = String(body[..<equals]).trimmingCharacters(in: .whitespaces)
        guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
            return nil
        }
        var rawValue = String(body[body.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        if let hashIndex = rawValue.firstIndex(of: "#"), !rawValue.hasPrefix("\""), !rawValue.hasPrefix("'") {
            rawValue = String(rawValue[..<hashIndex]).trimmingCharacters(in: .whitespaces)
        }
        return (key, unquote(rawValue), exportPrefix)
    }

    public static func renderAssignment(key: String, value: String, exportPrefix: Bool = false) -> String {
        let escaped = value
            .replacingOccurrences(of: #"\"#, with: #"\\"#)
            .replacingOccurrences(of: #"""#, with: #"\""#)
            .replacingOccurrences(of: #"$"#, with: #"\$"#)
            .replacingOccurrences(of: #"`"#, with: #"\`"#)
        return "\(exportPrefix ? "export " : "")\(key)=\"\(escaped)\""
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else {
            return value
        }
        if value.hasPrefix("\""), value.hasSuffix("\"") {
            let inner = String(value.dropFirst().dropLast())
            return unescapeDoubleQuoted(inner)
        }
        if value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func unescapeDoubleQuoted(_ value: String) -> String {
        var result = ""
        var escaping = false
        for character in value {
            if escaping {
                result.append(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        if escaping {
            result.append("\\")
        }
        return result
    }
}

public struct EnvStore {
    public var url: URL
    public var fileManager: FileManager

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    public func load() throws -> EnvDocument {
        let text = try String(contentsOf: url, encoding: .utf8)
        return EnvDocument(text: text)
    }

    public func save(_ document: EnvDocument) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try document.text.write(to: url, atomically: true, encoding: .utf8)
    }
}
