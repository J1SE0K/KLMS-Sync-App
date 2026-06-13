import ApplicationServices
import AppKit
import Foundation

struct NoticeDigest: Decodable {
    let generatedAt: String
    let noticeCount: Int
    let newCount: Int
    let updatedCount: Int
    let courses: [CourseDigest]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case noticeCount = "notice_count"
        case newCount = "new_count"
        case updatedCount = "updated_count"
        case courses
    }
}

struct CourseDigest: Decodable {
    let course: String
    let notices: [NoticeDigestEntry]
}

struct NoticeAttachmentItem: Decodable {
    let name: String?
    let relativePath: String?
    let absolutePath: String?

    enum CodingKeys: String, CodingKey {
        case name
        case relativePath = "relative_path"
        case absolutePath = "absolute_path"
    }
}

struct NoticeDigestEntry: Decodable {
    let url: String?
    let articleId: String?
    let title: String
    let postedAt: String?
    let attachments: [String]?
    let attachmentItems: [NoticeAttachmentItem]?
    let summary: String?
    let bodyText: String?
    let fingerprint: String?
    let changeState: NoticeChangeState?

    enum CodingKeys: String, CodingKey {
        case url
        case articleId = "article_id"
        case title
        case postedAt = "posted_at"
        case attachments
        case attachmentItems = "attachment_items"
        case summary
        case bodyText = "body_text"
        case fingerprint
        case changeState = "change_state"
    }
}

enum NoticeChangeState: String, Decodable {
    case new
    case updated
    case stable
}

struct LineRange: Codable {
    let location: Int
    let length: Int
}

struct NoticeInteractionState: Codable {
    var title: String?
    var course: String?
    var url: String?
    var fingerprint: String?
    var readFingerprint: String?
    var readAt: String?
    var important: Bool?
    var importantAt: String?
    var hidden: Bool?
    var hiddenAt: String?
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case title
        case course
        case url
        case fingerprint
        case readFingerprint = "read_fingerprint"
        case readAt = "read_at"
        case important
        case importantAt = "important_at"
        case hidden
        case hiddenAt = "hidden_at"
        case updatedAt = "updated_at"
    }
}

struct NoticeUserStateFile: Codable {
    var version: Int
    var updatedAt: String
    var notices: [String: NoticeInteractionState]

    enum CodingKeys: String, CodingKey {
        case version
        case updatedAt = "updated_at"
        case notices
    }
}

struct RenderedNoticeState: Codable {
    let noticeId: String
    let course: String
    let title: String
    let renderedTitle: String?
    let fingerprint: String
    let shouldCheckRead: Bool?
    let shouldCheckImportant: Bool?
    let sectionRange: LineRange
    let readChecklistRange: LineRange
    let importantChecklistRange: LineRange

    enum CodingKeys: String, CodingKey {
        case noticeId = "notice_id"
        case course
        case title
        case renderedTitle = "rendered_title"
        case fingerprint
        case shouldCheckRead = "should_check_read"
        case shouldCheckImportant = "should_check_important"
        case sectionRange = "section_range"
        case readChecklistRange = "read_checklist_range"
        case importantChecklistRange = "important_checklist_range"
    }
}

struct NoticeRenderStateFile: Codable {
    let version: Int
    let styleVersion: String?
    let updatedAt: String
    let noteTitle: String
    let noteID: String?
    let renderedNotices: [RenderedNoticeState]
    let contentHash: String?
    let plaintextHash: String?
    let renderSignature: String?

    enum CodingKeys: String, CodingKey {
        case version
        case styleVersion = "style_version"
        case updatedAt = "updated_at"
        case noteTitle = "note_title"
        case noteID = "note_id"
        case renderedNotices = "rendered_notices"
        case contentHash = "content_hash"
        case plaintextHash = "plaintext_hash"
        case renderSignature = "render_signature"
    }
}

enum NoticeDisplayMode: Equatable {
    case primary
    case archive
}

struct DisplayNotice {
    let noticeId: String
    let course: String
    let title: String
    let displayTitle: String
    let postedAt: String?
    let attachments: [String]
    let attachmentItems: [NoticeAttachmentItem]
    let summary: String?
    let bodyText: String?
    let fingerprint: String
    let changeState: NoticeChangeState
    let shouldCheckRead: Bool
    let shouldCheckImportant: Bool
}

struct DisplayCourse {
    let title: String
    let notices: [DisplayNotice]
}

struct RenderLine {
    let text: String
    let isChecklist: Bool
    let isBold: Bool
    let fontSize: CGFloat
}

struct RenderChunk {
    let text: String
    let isChecklist: Bool
}

struct RenderedNoticePlan {
    let noticeId: String
    let course: String
    let title: String
    let renderedTitle: String
    let fingerprint: String
    let sectionLineIndex: Int
    let readLineIndex: Int
    let importantLineIndex: Int
    let sectionRange: LineRange
    let readChecklistRange: LineRange
    let importantChecklistRange: LineRange
    let shouldCheckRead: Bool
    let shouldCheckImportant: Bool
}

struct RenderPlan {
    let mode: NoticeDisplayMode
    let primaryFallbackAllNotices: Bool
    let bodyLines: [RenderLine]
    let titleLineIndex: Int
    let summaryLineIndex: Int
    let sectionDividerLineIndexes: [Int]
    let importantHeadingLineIndexes: [Int]
    let freshHeadingLineIndexes: [Int]
    let unreadHeadingLineIndexes: [Int]
    let courseHeadingLineIndexes: [Int]
    let noticeMetaLineIndexes: [Int]
    let attachmentHeadingLineIndexes: [Int]
    let titleRange: LineRange
    let summaryRange: LineRange
    let sectionDividerRanges: [LineRange]
    let importantHeadingRanges: [LineRange]
    let freshHeadingRanges: [LineRange]
    let unreadHeadingRanges: [LineRange]
    let courseHeadingRanges: [LineRange]
    let noticeMetaRanges: [LineRange]
    let attachmentHeadingRanges: [LineRange]
    let renderedNotices: [RenderedNoticePlan]
    let visibleUnreadCount: Int
    let visibleImportantCount: Int
}

struct PlanBuildResult {
    let plan: RenderPlan
    let currentNoticeIds: Set<String>
}

enum RenderStrategy {
    case chunked
    case conservative
}

struct NotesEditorContext {
    let app: AXUIElement
    let window: AXUIElement
    let textArea: AXUIElement
    let checklistButton: AXUIElement?
    let noteID: String?
    let anchorTexts: [String]
}

struct NoteSnapshot: Decodable {
    let id: String
    let name: String
    let plaintext: String
}

struct ChecklistInfo {
    let isChecked: Bool
    let attachment: AXUIElement?
}

struct CapturedChecklistLine {
    let label: String
    let isChecked: Bool
    let range: LineRange
}

struct StyleValidationTarget {
    let label: String
    let range: LineRange
}

struct ResolvedRenderedNotice {
    let notice: RenderedNoticePlan
    let readRange: LineRange
    let importantRange: LineRange
}

let defaultNoteTitle = "KLMS 공지"
let defaultArchiveNoteTitle = "KLMS 확인한 공지"
let nativeNoticeRenderStateVersion = 2
let nativeNoticeRenderStyleVersion = "2026-06-13-functional-notes-v19-plain-text-color"
let readChecklistLabel = "읽음"
let importantChecklistLabel = "중요"
let noticeReadGuidanceLine = "\"읽음\"만 체크한 공지는 다음 동기화 때 KLMS 확인한 공지에 표시됩니다."
let noticeImportantGuidanceLine =
    "\"중요\"를 체크한 공지는 다음 동기화 때 KLMS 공지 상단의 중요 공지에 표시됩니다."
let noticeFreshGuidanceLine =
    "새 글/수정 글은 새로운 공지에, 그 외 미확인 공지는 읽지 않은 공지에 표시됩니다."
let noticePrimaryEmptyGuidanceLine =
    "표시할 공지가 생기면 상태에 따라 중요 공지, 새로운 공지, 읽지 않은 공지에 표시됩니다."
let noticeArchiveEmptyGuidanceLine =
    "\"읽음\"만 체크한 공지는 다음 동기화 때 이 메모에 표시됩니다."
let noticeTitleStyleMenuItems = ["제목", "Title"]
let noticeHeadingStyleMenuItems = ["머리말", "Heading"]
let noticeSubheadingStyleMenuItems = ["부머리말", "부제목", "소제목", "Subheading"]
let checklistMenuTitles = ["체크리스트", "Checklist"]
let noticeDebugEnabled = ProcessInfo.processInfo.environment["NOTICE_DEBUG_CAPTURE"] == "1"
let automationDebugEnabled = ProcessInfo.processInfo.environment["NOTICE_DEBUG_AUTOMATION"] == "1"
let noticeTimingEnabled = ProcessInfo.processInfo.environment["NOTICE_TIMING"] == "1"
let collapseNoticeSectionsEnabled = ProcessInfo.processInfo.environment["NOTICE_COLLAPSE_SECTIONS"] == "1"
let collapseNoticeCoursesEnabled = ProcessInfo.processInfo.environment["NOTICE_COLLAPSE_COURSES"] == "1"
let collapseNoticeItemsEnabled = ProcessInfo.processInfo.environment["NOTICE_COLLAPSE_NOTICE_ITEMS"] == "1"
let initialNoticeCollapseEnabled =
    ProcessInfo.processInfo.environment["NOTICE_NATIVE_INITIAL_COLLAPSE_ENABLED"] != "0"
let styleNoticeItemsAsHeadingsEnabled =
    ProcessInfo.processInfo.environment["NOTICE_STYLE_NOTICE_ITEMS_AS_HEADINGS"] == "1"
let hideHiddenNoticeItemsEnabled = ProcessInfo.processInfo.environment["NOTICE_HIDE_HIDDEN_ITEMS"] != "0"
let uiStyleMenuFormattingEnabled =
    ProcessInfo.processInfo.environment["NOTICE_NATIVE_ENABLE_UI_STYLE_FORMAT"] == "1"
    && ProcessInfo.processInfo.environment["NOTICE_NATIVE_DISABLE_UI_STYLE_FORMAT"] != "1"
let preformattedPasteOnlyEnabled =
    ProcessInfo.processInfo.environment["NOTICE_NATIVE_PREFORMATTED_PASTE_ONLY"] == "1"
let plainTextPasteEnabled =
    ProcessInfo.processInfo.environment["NOTICE_NATIVE_PLAIN_TEXT_PASTE"] == "1"
let conservativeRenderFallbackEnabled =
    ProcessInfo.processInfo.environment["NOTICE_NATIVE_CONSERVATIVE_RENDER_FALLBACK"] != "0"
let uiCollapsibleGroupStyleFormattingEnabled =
    (
        uiStyleMenuFormattingEnabled
        || (
            !preformattedPasteOnlyEnabled
            && (
                collapseNoticeSectionsEnabled
                || collapseNoticeCoursesEnabled
                || collapseNoticeItemsEnabled
                || styleNoticeItemsAsHeadingsEnabled
            )
        )
    )
    && ProcessInfo.processInfo.environment["NOTICE_NATIVE_DISABLE_UI_STYLE_FORMAT"] != "1"
let batchChecklistFormattingEnabled =
    ProcessInfo.processInfo.environment["NOTICE_NATIVE_ENABLE_BATCH_CHECKLIST_FORMAT"] == "1"
    && ProcessInfo.processInfo.environment["NOTICE_NATIVE_DISABLE_BATCH_CHECKLIST_FORMAT"] != "1"
let fastBatchChecklistFormattingEnabled =
    batchChecklistFormattingEnabled
    && ProcessInfo.processInfo.environment["NOTICE_NATIVE_DISABLE_FAST_CHECKLIST_FORMAT"] != "1"
let validateReadabilityStyleEnabled =
    ProcessInfo.processInfo.environment["NOTICE_NATIVE_VALIDATE_STYLE"] == "1"
let pasteboardSettleUsec: useconds_t = 35_000
let pasteSettleUsec: useconds_t = 70_000
let selectionSettleDelay: TimeInterval =
    max(0.012, Double(ProcessInfo.processInfo.environment["NOTICE_NATIVE_SELECTION_SETTLE_SECONDS"] ?? "") ?? 0.02)
let checklistPressSettleUsec: useconds_t =
    useconds_t(max(15_000, Int(ProcessInfo.processInfo.environment["NOTICE_NATIVE_CHECKLIST_PRESS_SETTLE_US"] ?? "") ?? 25_000))
let initialEditorClearDelay: TimeInterval = 0.12
let initialEditorFocusDelay: TimeInterval = 0.04
let finalChecklistDisableDelay: TimeInterval = 0.12
let noticeCollapseStyleSettleDelay: TimeInterval = 0.45
let noticeBodyFontSize: CGFloat = 14
let noticeMetaFontSize: CGFloat = 12
let noticeSummaryFontSize: CGFloat = 14
let noticeItemTitleFontSize: CGFloat = 16
let noticeCourseHeadingFontSize: CGFloat = 17
let noticeSectionHeadingFontSize: CGFloat = 19
let noticeDocumentTitleFontSize: CGFloat = 23

func fail(_ message: String) -> Never {
    fputs("\(message)\n", stderr)
    exit(1)
}

func debugLog(_ message: String) {
    guard noticeDebugEnabled else {
        return
    }
    fputs("[notice-debug] \(message)\n", stderr)
}

func automationDebugLog(_ message: String) {
    guard automationDebugEnabled else {
        return
    }
    fputs("[notice-automation] \(message)\n", stderr)
}

let noticeTimingFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
    return formatter
}()

func timingLog(_ message: String) {
    guard noticeTimingEnabled else {
        return
    }
    fputs("[notice-timing] \(noticeTimingFormatter.string(from: Date())) \(message)\n", stderr)
}

@discardableResult
func timed<T>(_ label: String, _ body: () -> T) -> T {
    guard noticeTimingEnabled else {
        return body()
    }
    let started = DispatchTime.now()
    timingLog("start \(label)")
    let result = body()
    let elapsed = DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds
    timingLog("finish \(label) duration_ms=\(elapsed / 1_000_000)")
    return result
}

func defaultPath(near digestPath: String, fileName: String) -> String {
    URL(fileURLWithPath: digestPath).deletingLastPathComponent().appendingPathComponent(fileName).path
}
