import Foundation

public struct LegacySyncState: Decodable, Sendable, Equatable {
    public var status: String
    public var generatedAt: String
    public var content: Content

    enum CodingKeys: String, CodingKey {
        case status
        case generatedAt = "generated_at"
        case content
    }

    public init(status: String = "missing", generatedAt: String = "", content: Content = Content()) {
        self.status = status
        self.generatedAt = generatedAt
        self.content = content
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = container.decodeIfPresentDefault(String.self, forKey: .status, default: "missing")
        generatedAt = container.decodeIfPresentDefault(String.self, forKey: .generatedAt, default: "")
        content = container.decodeIfPresentDefault(Content.self, forKey: .content, default: Content())
    }

    public struct Content: Decodable, Sendable, Equatable {
        public var kind: String
        public var assignments: [StateItem]
        public var assignmentCandidates: [StateItem]
        public var examItems: [StateItem]
        public var examCandidates: [StateItem]
        public var helpDeskItems: [StateItem]

        enum CodingKeys: String, CodingKey {
            case kind
            case assignments
            case assignmentCandidates = "assignment_candidates"
            case examItems = "exam_items"
            case examCandidates = "exam_candidates"
            case helpDeskItems = "help_desk_items"
        }

        public init(
            kind: String = "",
            assignments: [StateItem] = [],
            assignmentCandidates: [StateItem] = [],
            examItems: [StateItem] = [],
            examCandidates: [StateItem] = [],
            helpDeskItems: [StateItem] = []
        ) {
            self.kind = kind
            self.assignments = assignments
            self.assignmentCandidates = assignmentCandidates
            self.examItems = examItems
            self.examCandidates = examCandidates
            self.helpDeskItems = helpDeskItems
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = container.decodeIfPresentDefault(String.self, forKey: .kind, default: "")
            assignments = container.decodeIfPresentDefault([StateItem].self, forKey: .assignments, default: [])
            assignmentCandidates = container.decodeIfPresentDefault([StateItem].self, forKey: .assignmentCandidates, default: [])
            examItems = container.decodeIfPresentDefault([StateItem].self, forKey: .examItems, default: [])
            examCandidates = container.decodeIfPresentDefault([StateItem].self, forKey: .examCandidates, default: [])
            helpDeskItems = container.decodeIfPresentDefault([StateItem].self, forKey: .helpDeskItems, default: [])
        }
    }
}

public struct StateItem: Decodable, Sendable, Equatable, Identifiable {
    public var url: String
    public var type: String
    public var category: String
    public var course: String
    public var title: String
    public var due: String
    public var syncDue: String
    public var syncStart: String
    public var location: String
    public var coverageSummary: String

    public var id: String { url.isEmpty ? "\(course)-\(title)-\(syncDue)" : url }

    enum CodingKeys: String, CodingKey {
        case url
        case type
        case category
        case course
        case title
        case due
        case syncDue = "sync_due"
        case syncStart = "sync_start"
        case location
        case coverageSummary = "coverage_summary"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = container.decodeIfPresentDefault(String.self, forKey: .url, default: "")
        type = container.decodeIfPresentDefault(String.self, forKey: .type, default: "")
        category = container.decodeIfPresentDefault(String.self, forKey: .category, default: "")
        course = container.decodeIfPresentDefault(String.self, forKey: .course, default: "")
        title = container.decodeIfPresentDefault(String.self, forKey: .title, default: "")
        due = container.decodeIfPresentDefault(String.self, forKey: .due, default: "")
        syncDue = container.decodeIfPresentDefault(String.self, forKey: .syncDue, default: "")
        syncStart = container.decodeIfPresentDefault(String.self, forKey: .syncStart, default: "")
        location = container.decodeIfPresentDefault(String.self, forKey: .location, default: "")
        coverageSummary = container.decodeIfPresentDefault(String.self, forKey: .coverageSummary, default: "")
    }
}
