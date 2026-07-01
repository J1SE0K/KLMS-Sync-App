import Foundation

public enum AcademicSemester: String, Sendable, Codable, Hashable, Comparable {
    case spring
    case summer
    case fall
    case winter

    public var displayName: String {
        switch self {
        case .spring:
            "봄학기"
        case .summer:
            "여름학기"
        case .fall:
            "가을학기"
        case .winter:
            "겨울학기"
        }
    }

    private var sortOrder: Int {
        switch self {
        case .spring:
            0
        case .summer:
            1
        case .fall:
            2
        case .winter:
            3
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
        if (3...6).contains(month) {
            return AcademicTerm(year: year, semester: .spring)
        }
        if (7...8).contains(month) {
            return AcademicTerm(year: year, semester: .summer)
        }
        if month >= 9 {
            return AcademicTerm(year: year, semester: .fall)
        }
        return AcademicTerm(year: year - 1, semester: .winter)
    }

    private static func explicitTerm(in text: String) -> AcademicTerm? {
        let normalized = text.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "/", with: " ")

        let yearFirstPatterns: [(String, AcademicSemester)] = [
            (#"(20\d{2}).{0,18}(?:spring|spr|봄|1\s*학기|1st\s*semester|first\s*semester)"#, .spring),
            (#"(20\d{2}).{0,18}(?:summer|sum|여름|하계|summer\s*semester)"#, .summer),
            (#"(20\d{2}).{0,18}(?:fall|autumn|가을|2\s*학기|2nd\s*semester|second\s*semester)"#, .fall),
            (#"(20\d{2}).{0,18}(?:winter|win|겨울|동계|winter\s*semester)"#, .winter),
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
            (#"(?:summer|sum|여름|하계|summer\s*semester).{0,18}(20\d{2})"#, .summer),
            (#"(?:fall|autumn|가을|2\s*학기|2nd\s*semester|second\s*semester).{0,18}(20\d{2})"#, .fall),
            (#"(?:winter|win|겨울|동계|winter\s*semester).{0,18}(20\d{2})"#, .winter),
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

public struct AcademicTermCatalog: Codable, Sendable, Equatable {
    public var version: Int
    public var generatedAt: String
    public var selectedYear: Int?
    public var selectedSemesterCode: String
    public var selectedSemester: String
    public var years: [AcademicYearCatalogOption]
    public var semesters: [AcademicSemesterCatalogOption]
    public var terms: [AcademicTermCatalogOption]
    public var courses: [AcademicCourseCatalogOption]

    enum CodingKeys: String, CodingKey {
        case version
        case generatedAt = "generated_at"
        case selectedYear = "selected_year"
        case selectedSemesterCode = "selected_semester_code"
        case selectedSemester = "selected_semester"
        case years
        case semesters
        case terms
        case courses
    }

    public var selectedAcademicTerm: AcademicTerm? {
        guard let selectedYear,
              let semester = AcademicSemester(displayName: selectedSemester)
        else {
            return nil
        }
        return AcademicTerm(year: selectedYear, semester: semester)
    }

    public var academicTerms: [AcademicTerm] {
        terms.compactMap { item in
            guard let semester = AcademicSemester(displayName: item.semester) else {
                return nil
            }
            return AcademicTerm(year: item.year, semester: semester)
        }
    }

    public func selectedTermApplies(to course: String) -> Bool {
        let needle = course.klmsCourseKey
        guard !needle.isEmpty else {
            return false
        }
        return courses.contains { item in
            Self.courseKey(needle, matches: item.title.klmsCourseKey)
                || Self.courseKey(needle, matches: item.code.klmsCourseKey)
        }
    }

    private static func courseKey(_ lhs: String, matches rhs: String) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else {
            return false
        }
        if lhs == rhs {
            return true
        }
        guard min(lhs.count, rhs.count) >= 4 else {
            return false
        }
        return lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs)
    }
}

public struct AcademicYearCatalogOption: Codable, Sendable, Equatable, Identifiable {
    public var year: Int
    public var label: String
    public var selected: Bool

    public var id: Int { year }
}

public struct AcademicSemesterCatalogOption: Codable, Sendable, Equatable, Identifiable {
    public var code: String
    public var label: String
    public var displayName: String
    public var selected: Bool

    enum CodingKeys: String, CodingKey {
        case code
        case label
        case displayName = "display_name"
        case selected
    }

    public var id: String { code.isEmpty ? displayName : code }
}

public struct AcademicTermCatalogOption: Codable, Sendable, Equatable, Identifiable {
    public var year: Int
    public var semesterCode: String
    public var semester: String
    public var displayName: String
    public var selected: Bool

    enum CodingKeys: String, CodingKey {
        case year
        case semesterCode = "semester_code"
        case semester
        case displayName = "display_name"
        case selected
    }

    public var id: String { "\(year)-\(semesterCode)-\(semester)" }
}

public struct AcademicCourseCatalogOption: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var code: String
    public var title: String
    public var url: String
    public var year: Int?
    public var semesterCode: String
    public var semester: String
    public var term: String

    enum CodingKeys: String, CodingKey {
        case id
        case code
        case title
        case url
        case year
        case semesterCode = "semester_code"
        case semester
        case term
    }
}

public extension AcademicSemester {
    init?(displayName: String) {
        let normalized = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("봄") || normalized.contains("spring") {
            self = .spring
        } else if normalized.contains("여름") || normalized.contains("summer") {
            self = .summer
        } else if normalized.contains("가을") || normalized.contains("fall") || normalized.contains("autumn") {
            self = .fall
        } else if normalized.contains("겨울") || normalized.contains("winter") {
            self = .winter
        } else {
            return nil
        }
    }
}

private extension String {
    var klmsCourseKey: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
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
