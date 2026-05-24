import Foundation

public enum AcademicSemester: String, Sendable, Codable, Hashable, Comparable {
    case spring
    case fall

    public var displayName: String {
        switch self {
        case .spring:
            "봄학기"
        case .fall:
            "가을학기"
        }
    }

    private var sortOrder: Int {
        switch self {
        case .spring:
            0
        case .fall:
            1
        }
    }

    public static func < (lhs: AcademicSemester, rhs: AcademicSemester) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

public struct AcademicTerm: Sendable, Codable, Hashable, Comparable, Identifiable {
    public var year: Int
    public var semester: AcademicSemester

    public init(year: Int, semester: AcademicSemester) {
        self.year = year
        self.semester = semester
    }

    public var id: String {
        "\(year)-\(semester.rawValue)"
    }

    public var displayName: String {
        "\(year)년 \(semester.displayName)"
    }

    public static func < (lhs: AcademicTerm, rhs: AcademicTerm) -> Bool {
        if lhs.year != rhs.year {
            return lhs.year < rhs.year
        }
        return lhs.semester < rhs.semester
    }

    public static func infer(
        course: String = "",
        title: String = "",
        dateTexts: [String] = [],
        generatedAt: String = ""
    ) -> AcademicTerm? {
        let texts = ([course, title] + dateTexts + [generatedAt])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for text in texts {
            if let explicit = explicitTerm(in: text) {
                return explicit
            }
        }

        let generatedYear = firstYearMonth(in: generatedAt)?.year
        for text in texts {
            if let yearMonth = firstYearMonth(in: text) {
                return term(year: yearMonth.year, month: yearMonth.month)
            }
            if let month = firstMonthWithoutYear(in: text), let generatedYear {
                return term(year: generatedYear, month: month)
            }
        }
        return nil
    }

    public static func term(year: Int, month: Int) -> AcademicTerm? {
        guard (1...12).contains(month), (2000...2099).contains(year) else {
            return nil
        }
        if (3...8).contains(month) {
            return AcademicTerm(year: year, semester: .spring)
        }
        if month >= 9 {
            return AcademicTerm(year: year, semester: .fall)
        }
        return AcademicTerm(year: year - 1, semester: .fall)
    }

    private static func explicitTerm(in text: String) -> AcademicTerm? {
        let normalized = text.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "/", with: " ")

        let yearFirstPatterns: [(String, AcademicSemester)] = [
            (#"(20\d{2}).{0,18}(?:spring|spr|봄|1\s*학기|1st\s*semester|first\s*semester)"#, .spring),
            (#"(20\d{2}).{0,18}(?:fall|autumn|가을|2\s*학기|2nd\s*semester|second\s*semester)"#, .fall),
            (#"(20\d{2})\s*[sS]\b"#, .spring),
            (#"(20\d{2})\s*[fF]\b"#, .fall),
        ]
        for (pattern, semester) in yearFirstPatterns {
            if let year = firstCapturedYear(pattern: pattern, in: normalized) {
                return AcademicTerm(year: year, semester: semester)
            }
        }

        let semesterFirstPatterns: [(String, AcademicSemester)] = [
            (#"(?:spring|spr|봄|1\s*학기|1st\s*semester|first\s*semester).{0,18}(20\d{2})"#, .spring),
            (#"(?:fall|autumn|가을|2\s*학기|2nd\s*semester|second\s*semester).{0,18}(20\d{2})"#, .fall),
        ]
        for (pattern, semester) in semesterFirstPatterns {
            if let year = firstCapturedYear(pattern: pattern, in: normalized) {
                return AcademicTerm(year: year, semester: semester)
            }
        }

        return nil
    }

    private static func firstCapturedYear(pattern: String, in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return Int(text[range])
    }

    private static func firstYearMonth(in text: String) -> (year: Int, month: Int)? {
        let patterns = [
            #"(20\d{2})\s*년\s*(1[0-2]|0?[1-9])\s*월"#,
            #"(20\d{2})[-./_](1[0-2]|0[1-9])[-./_]\d{1,2}"#,
            #"(20\d{2})[-./_](1[0-2]|0[1-9])\b"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: nsRange),
                  match.numberOfRanges > 2,
                  let yearRange = Range(match.range(at: 1), in: text),
                  let monthRange = Range(match.range(at: 2), in: text),
                  let year = Int(text[yearRange]),
                  let month = Int(text[monthRange])
            else {
                continue
            }
            return (year, month)
        }
        return nil
    }

    private static func firstMonthWithoutYear(in text: String) -> Int? {
        let patterns = [
            #"\b(1[0-2]|0?[1-9])\s*월"#,
            #"\b(1[0-2]|0?[1-9])[-./]\d{1,2}\b"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: nsRange),
                  match.numberOfRanges > 1,
                  let monthRange = Range(match.range(at: 1), in: text)
            else {
                continue
            }
            return Int(text[monthRange])
        }
        return nil
    }
}

public extension StateItem {
    var academicTerm: AcademicTerm? {
        AcademicTerm.infer(
            course: course,
            title: title,
            dateTexts: [syncStart, syncDue, due, submission]
        )
    }
}

public extension NoticeDigestEntry {
    func academicTerm(generatedAt: String = "") -> AcademicTerm? {
        AcademicTerm.infer(
            course: course,
            title: title,
            dateTexts: [postedAt, summary, excerpt],
            generatedAt: generatedAt
        )
    }
}

public extension CourseFileManifestEntry {
    var academicTerm: AcademicTerm? {
        AcademicTerm.infer(
            course: course,
            title: filename,
            dateTexts: [relativePath, localDownloadedAt]
        )
    }
}

public extension FileInteractionState {
    var academicTerm: AcademicTerm? {
        AcademicTerm.infer(
            course: course,
            title: title,
            dateTexts: [path, updatedAt, hiddenAt ?? "", ignoredAt ?? "", trashedAt ?? ""]
        )
    }
}

public extension CalendarChange {
    var academicTerm: AcademicTerm? {
        AcademicTerm.infer(
            course: course,
            title: title,
            dateTexts: [startAt, dueAt, raw]
        )
    }
}
