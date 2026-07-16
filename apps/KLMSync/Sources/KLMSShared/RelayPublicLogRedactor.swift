import Foundation

public enum RelayPublicLogRedactor {
    private static let credentialMarker = "[credential]"
    private static let encodedDataMarker = "[encoded-data]"
    private static let redactedLineMarker = "[redacted-log-line]"
    private static let sensitiveKeyFragments = [
        "authorization",
        "credential",
        "bearer",
        "token",
        "secret",
        "password",
        "passwd",
        "passphrase",
        "cookie",
        "session",
        "apikey",
        "accesskey",
        "privatekey",
        "ticket",
        "deviceid",
        "deviceidentifier",
        "deviceuuid",
        "udid",
        "identifierforvendor",
        "vendoridentifier",
        "installationid",
        "installid",
        "advertisingid",
        "idfa",
    ]

    public static func redact(
        _ value: String,
        maximumLines: Int = 40,
        maximumUTF8Bytes: Int = 6_000
    ) -> String {
        var text = normalizedPublicLogText(value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        text = redactPEMBlocks(text)
        text = redactSensitiveJSONMembers(text)
        text = redactAuthorizationCredentials(text)
        text = redactSensitiveAssignments(text)
        text = redactDeviceIdentifiers(text)
        text = redactURLsAndPaths(text)
        text = replacingRegex(
            in: text,
            pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
            with: "[email]"
        )
        text = replacingRegex(
            in: text,
            pattern: #"KAIST 인증 번호:\s*\d{1,3}"#,
            with: "KAIST 인증 번호: --"
        )
        text = replacingRegex(
            in: text,
            pattern: #"digits=\d{1,3}"#,
            with: "digits=--"
        )

        let lines = text.components(separatedBy: "\n").map { line in
            let trimmed = trimmingTrailingWhitespace(line)
            if looksLikeEncodedData(trimmed) { return encodedDataMarker }
            if containsResidualPrivateMaterial(trimmed) { return redactedLineMarker }
            return trimmed
        }
        let boundedLineCount = max(0, maximumLines)
        let joined = boundedLineCount == 0
            ? ""
            : lines.suffix(boundedLineCount).joined(separator: "\n")
        return utf8Suffix(joined, maximumBytes: max(0, maximumUTF8Bytes))
    }

    private static func normalizedPublicLogText(_ value: String) -> String {
        var text = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        text = replacingRegex(
            in: text,
            pattern: #"\x1B\[[0-?]*[ -/]*[@-~]"#,
            with: ""
        )
        text = replacingRegex(in: text, pattern: #"\x1B[@-_]"#, with: "")

        var output = String.UnicodeScalarView()
        let space = Unicode.Scalar(32)!
        for scalar in text.unicodeScalars {
            if scalar.value == 10 {
                output.append(scalar)
            } else if scalar.value == 9 {
                output.append(space)
            } else if !isForbiddenScalar(scalar.value) {
                output.append(scalar)
            }
        }
        return String(output)
    }

    private static func isForbiddenScalar(_ value: UInt32) -> Bool {
        value <= 0x1f
            || (0x7f...0x9f).contains(value)
            || (0x200b...0x200f).contains(value)
            || (0x202a...0x202e).contains(value)
            || (0x2060...0x206f).contains(value)
            || value == 0xfeff
    }

    private static func redactPEMBlocks(_ text: String) -> String {
        var output = ""
        var cursor = text.startIndex
        while cursor < text.endIndex {
            guard let marker = text.range(of: "-----", range: cursor..<text.endIndex) else {
                output += String(text[cursor...])
                break
            }
            let markerToEnd = marker.lowerBound..<text.endIndex
            if let end = text.range(
                of: "-----END ",
                options: [.anchored, .caseInsensitive],
                range: markerToEnd
            ) {
                let close = text.range(of: "-----", range: end.upperBound..<text.endIndex)
                output += credentialMarker
                cursor = close?.upperBound ?? text.endIndex
                continue
            }
            if let begin = text.range(
                of: "-----BEGIN ",
                options: [.anchored, .caseInsensitive],
                range: markerToEnd
            ) {
                output += String(text[cursor..<marker.lowerBound]) + credentialMarker
                guard let beginClose = text.range(
                    of: "-----",
                    range: begin.upperBound..<text.endIndex
                ) else {
                    return output
                }
                let label = String(text[begin.upperBound..<beginClose.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty else { return output }
                let endMarker = "-----END \(label)-----"
                guard let matchingEnd = text.range(
                    of: endMarker,
                    options: .caseInsensitive,
                    range: beginClose.upperBound..<text.endIndex
                ) else {
                    return output
                }
                cursor = matchingEnd.upperBound
                continue
            }
            output += String(text[cursor..<marker.upperBound])
            cursor = marker.upperBound
        }
        return output
    }

    private static func redactSensitiveJSONMembers(_ text: String) -> String {
        let characters = Array(text)
        var output = ""
        var copiedThrough = 0
        var index = 0
        while index < characters.count {
            guard characters[index] == "\"" else {
                index += 1
                continue
            }
            let keyEnd = quotedValueEnd(characters, start: index, quote: "\"")
            guard keyEnd > index + 1 else {
                index += 1
                continue
            }
            var separator = keyEnd
            while separator < characters.count, characters[separator].isWhitespace {
                separator += 1
            }
            guard separator < characters.count, characters[separator] == ":" else {
                index = keyEnd
                continue
            }
            let rawKey = String(characters[index..<keyEnd])
            guard let decodedKey = decodedJSONString(rawKey), isSensitiveKey(decodedKey) else {
                index = keyEnd
                continue
            }
            var valueStart = separator + 1
            while valueStart < characters.count, characters[valueStart].isWhitespace {
                valueStart += 1
            }
            let valueEnd = structuredValueEnd(characters, start: valueStart)
            output += String(characters[copiedThrough..<valueStart]) + "\"\(credentialMarker)\""
            copiedThrough = valueEnd
            index = valueEnd
        }
        output += String(characters[copiedThrough..<characters.count])
        return output
    }

    private static func decodedJSONString(_ value: String) -> String? {
        guard let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(String.self, from: data)
    }

    private static func quotedValueEnd(
        _ characters: [Character],
        start: Int,
        quote: Character
    ) -> Int {
        var index = start + 1
        while index < characters.count {
            if characters[index] == "\\" {
                index = min(characters.count, index + 2)
            } else if characters[index] == quote {
                return index + 1
            } else {
                index += 1
            }
        }
        return characters.count
    }

    private static func structuredValueEnd(_ characters: [Character], start: Int) -> Int {
        guard start < characters.count else { return start }
        let first = characters[start]
        if first == "\"" || first == "'" {
            return quotedValueEnd(characters, start: start, quote: first)
        }
        if first == "{" || first == "[" {
            var stack = [first]
            var index = start + 1
            while index < characters.count, !stack.isEmpty {
                let character = characters[index]
                if character == "\"" || character == "'" {
                    index = quotedValueEnd(characters, start: index, quote: character)
                } else {
                    if character == "{" || character == "[" { stack.append(character) }
                    if character == "}", stack.last == "{" { stack.removeLast() }
                    if character == "]", stack.last == "[" { stack.removeLast() }
                    index += 1
                }
            }
            return index
        }
        var index = start
        while index < characters.count, !isValueDelimiter(characters[index]) {
            index += 1
        }
        return index
    }

    private static func redactAuthorizationCredentials(_ text: String) -> String {
        var output = replacingRegex(
            in: text,
            pattern: #"\bauthorization\s*:\s*[^\n]*"#,
            with: credentialMarker,
            caseInsensitive: true
        )
        output = replacingRegex(
            in: output,
            pattern: #"\b(?:bearer|basic|digest)\s+(?:\\?\"(?:\\.|[^\"\\])*\\?\"|\\?'(?:\\.|[^'\\])*\\?'|[^\s,;&\"'<>]+)"#,
            with: credentialMarker,
            caseInsensitive: true
        )
        return output
    }

    private static func redactSensitiveAssignments(_ text: String) -> String {
        let characters = Array(text)
        var output = ""
        var copiedThrough = 0
        var index = 0
        while index < characters.count {
            if index > 0, isAssignmentKeyCharacter(characters[index - 1]) {
                index += 1
                continue
            }
            let start = index
            var key = ""
            var keyEnd = index
            let keyQuote: Character? = characters[index] == "'" || characters[index] == "\""
                ? characters[index]
                : nil
            if let keyQuote {
                keyEnd = quotedValueEnd(characters, start: index, quote: keyQuote)
                guard keyEnd > index + 1,
                      keyEnd <= characters.count,
                      characters[keyEnd - 1] == keyQuote else {
                    index += 1
                    continue
                }
                let rawKey = String(characters[index..<keyEnd])
                key = keyQuote == "\""
                    ? decodedJSONString(rawKey) ?? ""
                    : String(characters[(index + 1)..<(keyEnd - 1)])
            } else if isAssignmentKeyCharacter(characters[index]) {
                while keyEnd < characters.count, isAssignmentKeyCharacter(characters[keyEnd]) {
                    keyEnd += 1
                }
                key = String(characters[index..<keyEnd])
            } else {
                index += 1
                continue
            }
            var separator = keyEnd
            while separator < characters.count, isInlineWhitespace(characters[separator]) {
                separator += 1
            }
            let separatorCharacter = separator < characters.count ? characters[separator] : nil
            guard isSensitiveKey(key),
                  separatorCharacter == ":" || separatorCharacter == "=",
                  !(keyQuote == "\"" && separatorCharacter != "=") else {
                index = max(index + 1, keyEnd)
                continue
            }
            var valueStart = separator + 1
            while valueStart < characters.count, characters[valueStart].isWhitespace {
                valueStart += 1
            }
            let valueEnd = assignmentValueEnd(characters, start: valueStart)
            output += String(characters[copiedThrough..<start]) + credentialMarker
            copiedThrough = valueEnd
            index = max(valueEnd, start + 1)
        }
        output += String(characters[copiedThrough..<characters.count])
        return output
    }

    private static func assignmentValueEnd(_ characters: [Character], start: Int) -> Int {
        guard start < characters.count else { return start }
        if String(characters[start...]).hasPrefix(credentialMarker) {
            return min(characters.count, start + credentialMarker.count)
        }
        let first = characters[start]
        if first == "\"" || first == "'" {
            return quotedValueEnd(characters, start: start, quote: first)
        }
        if first == "{" || first == "[" {
            return structuredValueEnd(characters, start: start)
        }
        var index = start
        while index < characters.count {
            let character = characters[index]
            if character == "\n" || [",", ";", "&", "}", "]", "\"", "'", "<", ">"].contains(character) {
                break
            }
            if isInlineWhitespace(character) {
                var next = index
                while next < characters.count, isInlineWhitespace(characters[next]) {
                    next += 1
                }
                if startsAssignmentAt(characters, start: next) { break }
                index = next
                continue
            }
            index += 1
        }
        return index
    }

    private static func startsAssignmentAt(_ characters: [Character], start: Int) -> Bool {
        guard start < characters.count else { return false }
        var keyEnd = start
        let quote: Character? = characters[start] == "'" || characters[start] == "\""
            ? characters[start]
            : nil
        if let quote {
            keyEnd = quotedValueEnd(characters, start: start, quote: quote)
            guard keyEnd > start + 1,
                  keyEnd <= characters.count,
                  characters[keyEnd - 1] == quote else {
                return false
            }
        } else {
            while keyEnd < characters.count, isAssignmentKeyCharacter(characters[keyEnd]) {
                keyEnd += 1
            }
            guard keyEnd > start else { return false }
        }
        while keyEnd < characters.count, isInlineWhitespace(characters[keyEnd]) {
            keyEnd += 1
        }
        guard keyEnd < characters.count else { return false }
        return characters[keyEnd] == ":" || characters[keyEnd] == "="
    }

    private static func isValueDelimiter(_ character: Character) -> Bool {
        character.isWhitespace || [",", ";", "&", "}", "]", "\"", "'", "<", ">"].contains(character)
    }

    private static func isAssignmentKeyCharacter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let value = character.unicodeScalars.first?.value else {
            return false
        }
        return (48...57).contains(value)
            || (65...90).contains(value)
            || (97...122).contains(value)
            || [37, 45, 46, 95].contains(value)
    }

    private static func isInlineWhitespace(_ character: Character) -> Bool {
        character == " " || character == "\t"
    }

    private static func isSensitiveKey(_ value: String) -> Bool {
        var decoded = value.replacingOccurrences(of: "+", with: " ")
        for _ in 0..<2 {
            guard let next = decoded.removingPercentEncoding, next != decoded else { break }
            decoded = next
        }
        let normalized = decoded
            .precomposedStringWithCompatibilityMapping
            .lowercased()
            .unicodeScalars
            .filter {
                (48...57).contains($0.value)
                    || (97...122).contains($0.value)
            }
            .map(String.init)
            .joined()
        return sensitiveKeyFragments.contains { normalized.contains($0) }
    }

    private static func redactDeviceIdentifiers(_ text: String) -> String {
        replacingRegex(
            in: text,
            pattern: #"\b(?:udid|device[\s_.-]*(?:id|identifier|uuid)|identifier[\s_.-]*for[\s_.-]*vendor|vendor[\s_.-]*identifier|installation[\s_.-]*id|install[\s_.-]*id|advertising[\s_.-]*id|idfa)\b(?:\s*(?::|=)\s*|\s+)(?:\"(?:\\.|[^\"\\])+\"|'(?:\\.|[^'\\])+'|[A-Za-z0-9][A-Za-z0-9._:-]{7,})"#,
            with: credentialMarker,
            caseInsensitive: true
        )
    }

    private static func redactURLsAndPaths(_ text: String) -> String {
        var output = replacingRegex(
            in: text,
            pattern: #"file:/{2,3}(?:[A-Za-z]:)?[^\s\"'<>}\]]+"#,
            with: "[local-path]",
            caseInsensitive: true
        )
        output = replacingRegex(
            in: output,
            pattern: #"https?://[^\s\"'<>]+"#,
            with: "[URL]",
            caseInsensitive: true
        )
        output = replacingRegex(
            in: output,
            pattern: #"[A-Za-z]:[\\/]+[^\r\n\"'<>}\]]*"#,
            with: "[local-path]"
        )
        output = replacingRegex(
            in: output,
            pattern: #"\\{2,}[^\r\n\"'<>}\]]+"#,
            with: "[local-path]"
        )
        return replacingRegex(
            in: output,
            pattern: #"(^|[^A-Za-z0-9])(?:~/|/)[^\r\n\"'<>}\]]*"#,
            with: "$1[local-path]",
            anchorsMatchLines: true
        )
    }

    private static func looksLikeEncodedData(_ line: String) -> Bool {
        let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.count >= 48 else { return false }
        return candidate.range(
            of: #"^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$"#,
            options: .regularExpression
        ) != nil
    }

    private static func containsResidualPrivateMaterial(_ line: String) -> Bool {
        let patterns: [(String, Bool)] = [
            (#"-----\s*(?:BEGIN|END)\b"#, true),
            (#"\b(?:bearer|basic|digest)\s+"#, true),
            (#"\bauthorization\s*:"#, true),
            (#"(?:^|[^A-Za-z0-9])(?:~/|/|[A-Za-z]:[\\/]|\\{2,})"#, false),
            (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, false),
            (#"(주소|address)"#, true),
            (#"[가-힣A-Za-z0-9_.-]+(로|길)\s*\d{1,4}(\s*-\s*\d{1,4})?"#, false),
        ]
        return patterns.contains { pattern, caseInsensitive in
            line.range(
                of: pattern,
                options: caseInsensitive
                    ? [.regularExpression, .caseInsensitive]
                    : .regularExpression
            ) != nil
        }
    }

    private static func trimmingTrailingWhitespace(_ value: String) -> String {
        var result = value
        while let last = result.last, last.isWhitespace {
            result.removeLast()
        }
        return result
    }

    private static func utf8Suffix(_ value: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0 else { return "" }
        guard value.utf8.count > maximumBytes else { return value }
        let prefix = "...\n"
        let prefixBytes = prefix.utf8.count
        guard maximumBytes > prefixBytes else {
            return String(repeating: ".", count: maximumBytes)
        }
        var reversedScalars: [Unicode.Scalar] = []
        var used = 0
        for scalar in value.unicodeScalars.reversed() {
            let bytes = String(scalar).utf8.count
            guard used + bytes <= maximumBytes - prefixBytes else { break }
            reversedScalars.append(scalar)
            used += bytes
        }
        var suffix = String.UnicodeScalarView()
        for scalar in reversedScalars.reversed() {
            suffix.append(scalar)
        }
        return prefix + String(suffix)
    }

    private static func replacingRegex(
        in value: String,
        pattern: String,
        with replacement: String,
        caseInsensitive: Bool = false,
        anchorsMatchLines: Bool = false
    ) -> String {
        var options: String.CompareOptions = .regularExpression
        if caseInsensitive { options.insert(.caseInsensitive) }
        if anchorsMatchLines {
            let expression = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines)
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            return expression?.stringByReplacingMatches(
                in: value,
                range: range,
                withTemplate: replacement
            ) ?? value
        }
        return value.replacingOccurrences(of: pattern, with: replacement, options: options)
    }
}
