import KLMSShared
import AppKit
import SwiftUI

enum DashboardDetailKind: String, CaseIterable, Identifiable {
    case assignments
    case assignmentRecords
    case assignmentCandidates
    case exams
    case examCandidates
    case helpDesk
    case notices
    case newFiles
    case quarantine
    case pruned
    case calendar
    case hidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .assignments:
            "과제"
        case .assignmentRecords:
            "완료 기록"
        case .assignmentCandidates:
            "과제 후보"
        case .exams:
            "시험"
        case .examCandidates:
            "시험 후보"
        case .helpDesk:
            "헬프데스크"
        case .notices:
            "공지"
        case .newFiles:
            "새 파일"
        case .quarantine:
            "격리"
        case .pruned:
            "삭제된 파일"
        case .calendar:
            "캘린더"
        case .hidden:
            "숨긴 항목"
        }
    }
}

struct DashboardDetailPanelView: View {
    var kind: DashboardDetailKind
    @ObservedObject var model: KLMSMacModel
    @State private var searchText = ""
    @State private var selectedCourse = DashboardCourseFilter.all
    @State private var selectedTerm = DashboardTermFilter.all
    @State private var showHidden = false
    @State private var newOnly = false
    @State private var recentOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(kind.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if hiddenCount > 0, kind != .hidden {
                    Text("숨김 \(hiddenCount)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            DashboardFilterBarView(
                searchText: $searchText,
                selectedCourse: $selectedCourse,
                selectedTerm: $selectedTerm,
                showHidden: $showHidden,
                newOnly: $newOnly,
                recentOnly: $recentOnly,
                courses: courseOptions,
                terms: termOptions,
                supportsNewOnly: kind.supportsNewOnly,
                supportsRecentOnly: kind.supportsRecentOnly,
                supportsHiddenToggle: kind != .calendar && kind != .hidden && hiddenCount > 0
            )

            switch kind {
            case .assignments:
                StateItemListView(
                    items: model.snapshot.legacyState?.content.assignments ?? [],
                    emptyText: "과제가 없습니다.",
                    editor: .assignment,
                    filters: filters,
                    model: model
                )
            case .assignmentRecords:
                StateItemListView(
                    items: model.snapshot.legacyState?.content.completedAssignments ?? [],
                    emptyText: "완료 기록이 없습니다.",
                    editor: .assignmentRecord,
                    filters: filters,
                    model: model
                )
            case .assignmentCandidates:
                StateItemListView(
                    items: model.snapshot.legacyState?.content.assignmentCandidates ?? [],
                    emptyText: "과제 후보가 없습니다.",
                    editor: .assignment,
                    filters: filters,
                    model: model
                )
            case .exams:
                StateItemListView(
                    items: model.snapshot.legacyState?.content.examItems ?? [],
                    emptyText: "시험 항목이 없습니다.",
                    editor: .exam,
                    filters: filters,
                    model: model
                )
            case .examCandidates:
                StateItemListView(
                    items: model.snapshot.legacyState?.content.examCandidates ?? [],
                    emptyText: "시험 후보가 없습니다.",
                    editor: .exam,
                    filters: filters,
                    model: model
                )
            case .helpDesk:
                StateItemListView(
                    items: model.snapshot.legacyState?.content.helpDeskItems ?? [],
                    emptyText: "헬프데스크 항목이 없습니다.",
                    editor: .assignment,
                    filters: filters,
                    model: model
                )
            case .notices:
                NoticeListView(filters: filters, model: model)
            case .newFiles:
                NewFilesListView(filters: filters, model: model)
            case .quarantine:
                QuarantineListView(filters: filters, model: model)
            case .pruned:
                PrunedListView(filters: filters, snapshot: model.snapshot)
            case .calendar:
                CalendarDetailView(snapshot: model.snapshot, filters: filters)
            case .hidden:
                HiddenItemsListView(filters: filters, model: model)
            }
        }
        .padding(10)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private var filters: DashboardDetailFilters {
        DashboardDetailFilters(
            searchText: searchText,
            selectedCourse: selectedCourse,
            selectedTerm: selectedTerm,
            showHidden: showHidden || kind == .hidden,
            hiddenOnly: kind == .hidden,
            newOnly: newOnly,
            recentOnly: recentOnly
        )
    }

    private var courseOptions: [String] {
        DashboardCourseFilter.options(for: kind, snapshot: model.snapshot)
    }

    private var termOptions: [String] {
        DashboardTermFilter.options(for: kind, snapshot: model.snapshot)
    }

    private var hiddenCount: Int {
        DashboardHiddenSummary(snapshot: model.snapshot).total
    }
}

private struct DashboardDetailFilters {
    var searchText: String
    var selectedCourse: String
    var selectedTerm: String
    var showHidden: Bool
    var hiddenOnly: Bool
    var newOnly: Bool
    var recentOnly: Bool

    var hasActiveFilter: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || selectedCourse != DashboardCourseFilter.all
            || selectedTerm != DashboardTermFilter.all
            || showHidden
            || hiddenOnly
            || newOnly
            || recentOnly
    }
}

private enum DashboardCourseFilter {
    static let all = "전체"

    static func options(for kind: DashboardDetailKind, snapshot: EngineSnapshot) -> [String] {
        let courses: [String]
        switch kind {
        case .assignments:
            courses = snapshot.legacyState?.content.assignments.map(\.course) ?? []
        case .assignmentRecords:
            courses = snapshot.legacyState?.content.completedAssignments.map(\.course) ?? []
        case .assignmentCandidates:
            courses = snapshot.legacyState?.content.assignmentCandidates.map(\.course) ?? []
        case .exams:
            courses = snapshot.legacyState?.content.examItems.map(\.course) ?? []
        case .examCandidates:
            courses = snapshot.legacyState?.content.examCandidates.map(\.course) ?? []
        case .helpDesk:
            courses = snapshot.legacyState?.content.helpDeskItems.map(\.course) ?? []
        case .notices:
            courses = snapshot.noticeDigest?.notices.map(\.course) ?? []
        case .newFiles:
            courses = snapshot.courseFileManifest.map(\.course)
        case .calendar:
            courses = snapshot.calendarSyncResult?.changes.map(\.course) ?? []
        case .hidden:
            courses = hiddenCourseOptions(snapshot: snapshot)
        default:
            courses = []
        }
        let unique = Set(courses.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        return [all] + unique.sorted()
    }

    private static func hiddenCourseOptions(snapshot: EngineSnapshot) -> [String] {
        var courses: [String] = []
        let content = snapshot.legacyState?.content
        let overrides = snapshot.manualOverrides
        courses += (
            (content?.assignments ?? [])
                + (content?.assignmentCandidates ?? [])
                + (content?.completedAssignments ?? [])
                + (content?.assignmentRecords ?? [])
        )
            .filter { overrides?.isAssignmentHidden($0) == true }
            .map(\.course)
        courses += (content?.examItems ?? []).filter { overrides?.isExamHidden($0) == true }.map(\.course)
        courses += (content?.examCandidates ?? []).filter { overrides?.isExamHidden($0) == true }.map(\.course)
        courses += (snapshot.noticeDigest?.notices ?? []).filter {
            snapshot.noticeUserState?.notices[$0.noticeIdentifier]?.hidden == true
        }.map(\.course)
        courses += snapshot.appUserState?.files.values.filter(\.isHiddenLike).map(\.course) ?? []
        return courses
    }
}

private enum DashboardTermFilter {
    static let all = "전체 학기"
    static let unknown = "학기 미확인"

    static func label(_ term: AcademicTerm?) -> String {
        term?.displayName ?? unknown
    }

    static func matches(_ term: AcademicTerm?, selected: String) -> Bool {
        selected == all || label(term) == selected
    }

    static func options(for kind: DashboardDetailKind, snapshot: EngineSnapshot) -> [String] {
        let terms: [AcademicTerm?]
        switch kind {
        case .assignments:
            terms = snapshot.legacyState?.content.assignments.map(\.academicTerm) ?? []
        case .assignmentRecords:
            terms = snapshot.legacyState?.content.completedAssignments.map(\.academicTerm) ?? []
        case .assignmentCandidates:
            terms = snapshot.legacyState?.content.assignmentCandidates.map(\.academicTerm) ?? []
        case .exams:
            terms = snapshot.legacyState?.content.examItems.map(\.academicTerm) ?? []
        case .examCandidates:
            terms = snapshot.legacyState?.content.examCandidates.map(\.academicTerm) ?? []
        case .helpDesk:
            terms = snapshot.legacyState?.content.helpDeskItems.map(\.academicTerm) ?? []
        case .notices:
            let generatedAt = snapshot.noticeDigest?.generatedAt ?? ""
            terms = (snapshot.noticeDigest?.notices ?? []).map { $0.academicTerm(generatedAt: generatedAt) }
        case .newFiles:
            terms = newFileTerms(snapshot: snapshot)
        case .quarantine:
            terms = (snapshot.quarantineReport?.records ?? []).map(quarantineTerm)
        case .pruned:
            terms = (snapshot.cleanupResult?.actions ?? []).map(cleanupTerm)
        case .calendar:
            terms = snapshot.calendarSyncResult?.changes.map(\.academicTerm) ?? []
        case .hidden:
            terms = hiddenTerms(snapshot: snapshot)
        }
        return labels(from: terms)
    }

    private static func labels(from terms: [AcademicTerm?]) -> [String] {
        guard !terms.isEmpty else {
            return [all]
        }
        let known = Array(Set(terms.compactMap { $0 }))
            .sorted(by: >)
            .map(\.displayName)
        let unknowns = terms.contains(where: { $0 == nil }) ? [unknown] : []
        return [all] + known + unknowns
    }

    private static func newFileTerms(snapshot: EngineSnapshot) -> [AcademicTerm?] {
        let downloadItems = snapshot.downloadResult?.results.filter(\.copiedToNewFilesInbox) ?? []
        return downloadItems.map { item in
            let manifest = snapshot.courseFileManifest.first { entry in
                (!item.url.isEmpty && entry.url == item.url) || entry.relativePath == item.relativePath
            }
            return manifest?.academicTerm ?? AcademicTerm.infer(title: item.relativePath, dateTexts: [item.relativePath])
        }
    }

    private static func hiddenTerms(snapshot: EngineSnapshot) -> [AcademicTerm?] {
        var terms: [AcademicTerm?] = []
        let content = snapshot.legacyState?.content
        let overrides = snapshot.manualOverrides
        terms += (
            (content?.assignments ?? [])
                + (content?.assignmentCandidates ?? [])
                + (content?.completedAssignments ?? [])
                + (content?.assignmentRecords ?? [])
        )
            .filter { overrides?.isAssignmentHidden($0) == true }
            .map(\.academicTerm)
        terms += ((content?.examItems ?? []) + (content?.examCandidates ?? []))
            .filter { overrides?.isExamHidden($0) == true }
            .map(\.academicTerm)
        let generatedAt = snapshot.noticeDigest?.generatedAt ?? ""
        terms += (snapshot.noticeDigest?.notices ?? [])
            .filter { snapshot.noticeUserState?.notices[$0.noticeIdentifier]?.hidden == true }
            .map { $0.academicTerm(generatedAt: generatedAt) }
        terms += snapshot.appUserState?.files.values.filter(\.isHiddenLike).map(\.academicTerm) ?? []
        terms += snapshot.appUserState?.quarantine.values.filter(\.isHiddenLike).map(\.academicTerm) ?? []
        return terms
    }

    private static func quarantineTerm(_ record: QuarantineRecord) -> AcademicTerm? {
        AcademicTerm.infer(
            title: record.quarantineRelativePath,
            dateTexts: [record.quarantinePath, record.quarantineRelativePath]
        )
    }

    private static func cleanupTerm(_ action: CleanupAction) -> AcademicTerm? {
        AcademicTerm.infer(title: action.path, dateTexts: [action.path])
    }
}

private extension DashboardDetailKind {
    var supportsNewOnly: Bool {
        switch self {
        case .notices, .newFiles:
            true
        default:
            false
        }
    }

    var supportsRecentOnly: Bool {
        switch self {
        case .notices, .newFiles, .quarantine:
            true
        default:
            false
        }
    }
}

private struct DashboardHiddenSummary {
    var assignments: Int
    var exams: Int
    var notices: Int
    var files: Int
    var quarantine: Int

    init(snapshot: EngineSnapshot) {
        let content = snapshot.legacyState?.content
        let overrides = snapshot.manualOverrides
        assignments = (
            (content?.assignments ?? [])
                + (content?.assignmentCandidates ?? [])
                + (content?.completedAssignments ?? [])
                + (content?.assignmentRecords ?? [])
        )
            .filter { overrides?.isAssignmentHidden($0) == true }
            .reduce(into: Set<String>()) { keys, item in
                keys.insert(item.id)
            }
            .count
        exams = ((content?.examItems ?? []) + (content?.examCandidates ?? []))
            .filter { overrides?.isExamHidden($0) == true }
            .count
        notices = (snapshot.noticeDigest?.notices ?? [])
            .filter { snapshot.noticeUserState?.notices[$0.noticeIdentifier]?.hidden == true }
            .count
        files = snapshot.appUserState?.files.values.filter(\.isHiddenLike).count ?? 0
        quarantine = snapshot.appUserState?.quarantine.values.filter(\.isHiddenLike).count ?? 0
    }

    var total: Int {
        assignments + exams + notices + files + quarantine
    }
}

private struct DashboardFilterBarView: View {
    @Binding var searchText: String
    @Binding var selectedCourse: String
    @Binding var selectedTerm: String
    @Binding var showHidden: Bool
    @Binding var newOnly: Bool
    @Binding var recentOnly: Bool
    var courses: [String]
    var terms: [String]
    var supportsNewOnly: Bool
    var supportsRecentOnly: Bool
    var supportsHiddenToggle: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("검색", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Picker("과목", selection: normalizedCourseBinding) {
                    ForEach(courses, id: \.self) { course in
                        Text(course).tag(course)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 170)
                if terms.count > 1 {
                    Picker("학기", selection: normalizedTermBinding) {
                        ForEach(terms, id: \.self) { term in
                            Text(term).tag(term)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 150)
                }
            }
            HStack(spacing: 12) {
                if supportsNewOnly {
                    Toggle("새 항목만", isOn: $newOnly)
                }
                if supportsRecentOnly {
                    Toggle("최근 변경만", isOn: $recentOnly)
                }
                if supportsHiddenToggle {
                    Toggle("숨김 포함", isOn: $showHidden)
                }
                Spacer()
                if hasActiveFilter {
                    Button {
                        resetFilters()
                    } label: {
                        Label("필터 초기화", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .font(.caption)
            .toggleStyle(.checkbox)
        }
    }

    private var hasActiveFilter: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || selectedCourse != DashboardCourseFilter.all
            || selectedTerm != DashboardTermFilter.all
            || showHidden
            || newOnly
            || recentOnly
    }

    private var normalizedCourseBinding: Binding<String> {
        Binding(
            get: {
                courses.contains(selectedCourse) ? selectedCourse : DashboardCourseFilter.all
            },
            set: { selectedCourse = $0 }
        )
    }

    private var normalizedTermBinding: Binding<String> {
        Binding(
            get: {
                terms.contains(selectedTerm) ? selectedTerm : DashboardTermFilter.all
            },
            set: { selectedTerm = $0 }
        )
    }

    private func resetFilters() {
        searchText = ""
        selectedCourse = DashboardCourseFilter.all
        selectedTerm = DashboardTermFilter.all
        showHidden = false
        newOnly = false
        recentOnly = false
    }
}

private enum StateItemEditorKind {
    case assignment
    case assignmentRecord
    case exam
}

private struct StateItemListView: View {
    var items: [StateItem]
    var emptyText: String
    var editor: StateItemEditorKind
    var filters: DashboardDetailFilters
    @ObservedObject var model: KLMSMacModel

    var body: some View {
        let visibleItems = filteredItems
        if visibleItems.isEmpty {
            EmptyDetailText(text: filters.hasActiveFilter ? "검색/필터 조건에 맞는 항목이 없습니다. 필터 초기화를 눌러 전체 목록을 보세요." : emptyText)
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(visibleItems) { item in
                    StateItemRowView(item: item, editor: editor, model: model)
                }
            }
        }
    }

    private var filteredItems: [StateItem] {
        items.filter { item in
            let hidden = isHidden(item)
            guard filters.showHidden || !hidden else { return false }
            guard !filters.hiddenOnly || hidden else { return false }
            guard courseMatches(item.course) else { return false }
            guard DashboardTermFilter.matches(item.academicTerm, selected: filters.selectedTerm) else {
                return false
            }
            guard searchMatches([
                item.academicTerm?.displayName ?? "",
                item.title,
                item.course,
                item.due,
                item.location,
                item.coverageSummary,
                item.url,
            ]) else {
                return false
            }
            return true
        }
    }

    private func isHidden(_ item: StateItem) -> Bool {
        switch editor {
        case .assignment, .assignmentRecord:
            model.snapshot.manualOverrides?.isAssignmentHidden(item) == true
        case .exam:
            model.snapshot.manualOverrides?.isExamHidden(item) == true
        }
    }

    private func courseMatches(_ course: String) -> Bool {
        filters.selectedCourse == DashboardCourseFilter.all || course == filters.selectedCourse
    }

    private func searchMatches(_ fields: [String]) -> Bool {
        let query = filters.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return fields.joined(separator: " ").localizedCaseInsensitiveContains(query)
    }
}

private struct StateItemRowView: View {
    var item: StateItem
    var editor: StateItemEditorKind
    @ObservedObject var model: KLMSMacModel

    var body: some View {
        let hidden = isHidden
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.title.isEmpty ? "(제목 없음)" : item.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(2)
                        if hidden {
                            Label("숨김", systemImage: "eye.slash")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if editor == .assignmentRecord, !item.recordDisplayStatus.isEmpty {
                            Text(item.recordDisplayStatus)
                                .font(.caption2)
                                .foregroundStyle(item.recordStatus == "completed" ? .green : .secondary)
                        }
                    }
                    Text([item.academicTerm?.displayName ?? "", item.course, item.due].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if !item.location.isEmpty || !item.coverageSummary.isEmpty {
                        Text([item.location, item.coverageSummary].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                if !item.url.isEmpty {
                    Button {
                        openExternalURL(item.url)
                    } label: {
                        Image(systemName: "safari")
                    }
                    .help("KLMS 열기")
                    .buttonStyle(.borderless)
                }
            }

            switch editor {
            case .assignment:
                AssignmentOverridePicker(item: item, model: model)
            case .assignmentRecord:
                RecordStatusView(item: item)
            case .exam:
                ExamOverrideEditor(
                    item: item,
                    override: model.snapshot.manualOverrides?.examOverride(for: item) ?? ExamOverride(),
                    model: model
                )
            }

            HStack(spacing: 8) {
                if editor == .assignmentRecord, isManualCompleted {
                    Button {
                        clearCompletion()
                    } label: {
                        Label("완료 해제", systemImage: "arrow.uturn.backward")
                    }
                }
                if hidden {
                    Button {
                        restoreHidden()
                    } label: {
                        Label("복구", systemImage: "arrow.uturn.backward")
                    }
                } else if editor != .assignmentRecord || isManualCompleted {
                    Button {
                        hide()
                    } label: {
                        Label(editor == .exam ? "시험 아님" : "숨김", systemImage: "eye.slash")
                    }
                }
                Spacer()
            }
            .font(.caption)
            .buttonStyle(.bordered)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hidden ? Color.orange.opacity(0.10) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var isHidden: Bool {
        switch editor {
        case .assignment, .assignmentRecord:
            model.snapshot.manualOverrides?.isAssignmentHidden(item) == true
        case .exam:
            model.snapshot.manualOverrides?.isExamHidden(item) == true
        }
    }

    private var isManualCompleted: Bool {
        let overrideStatus = model.snapshot.manualOverrides?.assignmentStatus(for: item) ?? ""
        return overrideStatus == "completed" || item.completionReason == "manual_completed"
    }

    private func hide() {
        switch editor {
        case .assignment, .assignmentRecord:
            model.setAssignmentHidden(true, for: item)
        case .exam:
            model.setExamHidden(true, for: item)
        }
    }

    private func clearCompletion() {
        model.setAssignmentOverride("", for: item)
    }

    private func restore() {
        restoreHidden()
    }

    private func restoreHidden() {
        switch editor {
        case .assignment, .assignmentRecord:
            model.setAssignmentHidden(false, for: item)
        case .exam:
            model.setExamHidden(false, for: item)
        }
    }
}

private struct RecordStatusView: View {
    var item: StateItem

    var body: some View {
        HStack(spacing: 8) {
            Label(item.recordDisplayStatus.isEmpty ? "기록" : item.recordDisplayStatus, systemImage: "clock.arrow.circlepath")
                .font(.caption)
                .foregroundStyle(item.recordStatus == "completed" ? .green : .secondary)
            if !item.submission.isEmpty {
                Text(item.submission)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private extension StateItem {
    var recordDisplayStatus: String {
        if recordStatus == "completed" {
            switch completionReason {
            case "manual_completed":
                return "완료 처리"
            case "submitted":
                return "제출 완료"
            case "past_due":
                return "마감 지남"
            case "auto_completed":
                return "자동 완료"
            case "submitted_match":
                return "제출 완료와 일치"
            default:
                return "완료"
            }
        }
        if recordStatus == "active" {
            return "진행 중"
        }
        if recordStatus == "ignored" || recordStatus == "hidden" || recordStatus == "skip" {
            return "제외됨"
        }
        if recordStatus == "converted_to_exam" {
            return "시험으로 분류"
        }
        return ""
    }
}

private struct AssignmentOverridePicker: View {
    var item: StateItem
    @ObservedObject var model: KLMSMacModel

    var body: some View {
        Picker("처리", selection: binding) {
            Text("동기화").tag("")
            Text("완료").tag("completed")
            Text("무시").tag("ignored")
        }
        .pickerStyle(.segmented)
        .disabled(item.url.isEmpty)
        .help(item.url.isEmpty ? "KLMS URL이 없는 항목은 다음 동기화에 반영할 키가 없어 완료 처리할 수 없습니다." : "완료는 앱 화면에 즉시 반영되고 다음 과제/시험 동기화 때 미리 알림에도 반영됩니다.")
    }

    private var binding: Binding<String> {
        Binding(
            get: {
                model.snapshot.manualOverrides?.assignmentStatus(for: item) ?? ""
            },
            set: { value in
                model.setAssignmentOverride(value, for: item)
            }
        )
    }
}

private struct ExamOverrideEditor: View {
    var item: StateItem
    var override: ExamOverride
    @ObservedObject var model: KLMSMacModel
    @State private var draft: ExamOverride

    init(item: StateItem, override: ExamOverride, model: KLMSMacModel) {
        self.item = item
        self.override = override
        self.model = model
        _draft = State(initialValue: override)
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Picker("상태", selection: $draft.status) {
                    Text("후보 유지").tag("")
                    Text("승인").tag("approved")
                    Text("무시").tag("ignored")
                }
                .pickerStyle(.segmented)

                TextField("표시 일정", text: $draft.due)
                TextField("시작 시각 ISO", text: $draft.syncStart)
                TextField("종료 시각 ISO", text: $draft.syncDue)
                TextField("장소", text: $draft.location)
                TextField("범위 요약", text: $draft.coverageSummary)
                TextField("범위 원문", text: $draft.coverage)
                TextField("추가 지시", text: $draft.instructionsAppend)

                HStack {
                    Button("저장") {
                        model.setExamOverride(draft, for: item)
                    }
                    Button("비우기") {
                        draft = ExamOverride()
                        model.setExamOverride(draft, for: item)
                    }
                    Spacer()
                    Text(overrideStatusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding(.top, 6)
        } label: {
            Text("시험 수동 수정")
                .font(.caption.weight(.semibold))
        }
        .onChange(of: override) { _, next in
            draft = next
        }
    }

    private var overrideStatusText: String {
        override.isEmpty ? "저장된 override 없음" : "저장됨"
    }
}

private struct NoticeListView: View {
    var filters: DashboardDetailFilters
    @ObservedObject var model: KLMSMacModel
    @State private var category = NoticeListCategory.all

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NoticeCategoryPickerView(category: $category, snapshot: model.snapshot)
            noticeRows
        }
    }

    @ViewBuilder
    private var noticeRows: some View {
        let notices = filteredNotices
        if notices.isEmpty {
            EmptyDetailText(text: filters.hasActiveFilter ? "검색/필터 조건에 맞는 공지가 없습니다. 필터 초기화를 눌러 전체 목록을 보세요." : "공지 목록이 없습니다.")
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(notices.prefix(80)) { notice in
                    NoticeRowView(notice: notice, model: model)
                }
            }
        }
    }

    private var filteredNotices: [NoticeDigestEntry] {
        let state = model.snapshot.noticeUserState?.notices ?? [:]
        let generatedAt = model.snapshot.noticeDigest?.generatedAt ?? ""
        return (model.snapshot.noticeDigest?.notices ?? []).filter { notice in
            let interaction = state[notice.noticeIdentifier]
            let hidden = interaction?.hidden == true
            let important = interaction?.important == true
            let read = notice.fingerprint.isEmpty
                ? interaction?.readAt != nil
                : interaction?.readFingerprint == notice.fingerprint
            let fresh = notice.changeState == "new" || notice.changeState == "updated"
            let term = notice.academicTerm(generatedAt: generatedAt)
            guard filters.showHidden || !hidden else { return false }
            guard !filters.hiddenOnly || hidden else { return false }
            guard !filters.newOnly || fresh else { return false }
            guard !filters.recentOnly || fresh else { return false }
            guard DashboardTermFilter.matches(term, selected: filters.selectedTerm) else {
                return false
            }
            guard filters.selectedCourse == DashboardCourseFilter.all || notice.course == filters.selectedCourse else {
                return false
            }
            guard category.matches(hidden: hidden, important: important, read: read, fresh: fresh) else {
                return false
            }
            let query = filters.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return true }
            return [term?.displayName ?? "", notice.title, notice.course, notice.postedAt, notice.summary, notice.bodyText, notice.url]
                .joined(separator: " ")
                .localizedCaseInsensitiveContains(query)
        }
    }
}

private enum NoticeListCategory: String, CaseIterable, Identifiable {
    case all
    case important
    case fresh
    case unread
    case archived
    case hidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            "전체"
        case .important:
            "중요"
        case .fresh:
            "새 공지"
        case .unread:
            "읽지 않음"
        case .archived:
            "확인함"
        case .hidden:
            "숨김"
        }
    }

    func matches(hidden: Bool, important: Bool, read: Bool, fresh: Bool) -> Bool {
        switch self {
        case .all:
            true
        case .important:
            important
        case .fresh:
            fresh
        case .unread:
            !read && !hidden
        case .archived:
            read && !important
        case .hidden:
            hidden
        }
    }
}

private struct NoticeCategoryPickerView: View {
    @Binding var category: NoticeListCategory
    var snapshot: EngineSnapshot

    var body: some View {
        Picker("공지 분류", selection: $category) {
            ForEach(NoticeListCategory.allCases) { item in
                Text("\(item.title) \(count(for: item))").tag(item)
            }
        }
        .pickerStyle(.segmented)
    }

    private func count(for category: NoticeListCategory) -> Int {
        let state = snapshot.noticeUserState?.notices ?? [:]
        return (snapshot.noticeDigest?.notices ?? []).filter { notice in
            let interaction = state[notice.noticeIdentifier]
            let hidden = interaction?.hidden == true
            let important = interaction?.important == true
            let read = notice.fingerprint.isEmpty
                ? interaction?.readAt != nil
                : interaction?.readFingerprint == notice.fingerprint
            let fresh = notice.changeState == "new" || notice.changeState == "updated"
            return category.matches(hidden: hidden, important: important, read: read, fresh: fresh)
        }.count
    }
}

private struct NoticeRowView: View {
    var notice: NoticeDigestEntry
    @ObservedObject var model: KLMSMacModel

    var body: some View {
        let hidden = model.snapshot.noticeUserState?.notices[notice.noticeIdentifier]?.hidden == true
        let fresh = notice.changeState == "new" || notice.changeState == "updated"
        let term = notice.academicTerm(generatedAt: model.snapshot.noticeDigest?.generatedAt ?? "")
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text((notice.title.isEmpty ? "(제목 없음)" : notice.title).klmsDisplayText)
                            .font(.caption.weight(.semibold))
                            .lineLimit(2)
                        if fresh {
                            Label("최근", systemImage: "sparkle")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                        }
                        if hidden {
                            Label("숨김", systemImage: "eye.slash")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text([term?.displayName ?? "", notice.course, notice.postedAt, notice.changeState].filter { !$0.isEmpty }.joined(separator: " · ").klmsDisplayText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if !notice.url.isEmpty {
                    Button {
                        openExternalURL(notice.url)
                    } label: {
                        Image(systemName: "safari")
                    }
                    .help("공지 열기")
                    .buttonStyle(.borderless)
                }
            }

            if !notice.summary.isEmpty {
                Text(notice.summary.klmsDisplayText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }

            HStack {
                Toggle("읽음", isOn: readBinding)
                Toggle("중요", isOn: importantBinding)
                Toggle("숨김", isOn: hiddenBinding)
                Spacer()
            }
            .toggleStyle(.checkbox)

            HStack(spacing: 8) {
                Button {
                    model.setNoticeHidden(!hidden, for: notice)
                } label: {
                    Label(hidden ? "복구" : "목록에서 숨김", systemImage: hidden ? "arrow.uturn.backward" : "eye.slash")
                }
                .buttonStyle(.bordered)
                Spacer()
            }
            .font(.caption)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(hidden: hidden, fresh: fresh), in: RoundedRectangle(cornerRadius: 8))
    }

    private var readBinding: Binding<Bool> {
        Binding(
            get: {
                guard let state = model.snapshot.noticeUserState?.notices[notice.noticeIdentifier] else {
                    return false
                }
                if notice.fingerprint.isEmpty {
                    return state.readAt != nil
                }
                return state.readFingerprint == notice.fingerprint
            },
            set: { value in
                model.setNoticeRead(value, for: notice)
            }
        )
    }

    private var importantBinding: Binding<Bool> {
        Binding(
            get: {
                model.snapshot.noticeUserState?.notices[notice.noticeIdentifier]?.important == true
            },
            set: { value in
                model.setNoticeImportant(value, for: notice)
            }
        )
    }

    private var hiddenBinding: Binding<Bool> {
        Binding(
            get: {
                model.snapshot.noticeUserState?.notices[notice.noticeIdentifier]?.hidden == true
            },
            set: { value in
                model.setNoticeHidden(value, for: notice)
            }
        )
    }

    private func rowBackground(hidden: Bool, fresh: Bool) -> Color {
        if hidden {
            return Color.orange.opacity(0.10)
        }
        if fresh {
            return Color.blue.opacity(0.08)
        }
        return Color(nsColor: .controlBackgroundColor)
    }
}

private struct NewFilesListView: View {
    var filters: DashboardDetailFilters
    @ObservedObject var model: KLMSMacModel

    var body: some View {
        let items = filteredItems
        if items.isEmpty {
            EmptyDetailText(text: filters.hasActiveFilter ? "검색/필터 조건에 맞는 파일이 없습니다. 필터 초기화를 눌러 전체 목록을 보세요." : "새 파일이 없습니다.")
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(items) { item in
                    FileRowView(
                        item: item,
                        kind: .file,
                        model: model
                    )
                }
            }
        }
    }

    private var filteredItems: [DashboardFileItem] {
        let downloadItems = model.snapshot.downloadResult?.results.filter(\.copiedToNewFilesInbox) ?? []
        return downloadItems.compactMap { item in
            let manifest = model.snapshot.courseFileManifest.first { entry in
                (!item.url.isEmpty && entry.url == item.url) || entry.relativePath == item.relativePath
            }
            let file = DashboardFileItem(
                key: fileKey(url: item.url, path: manifest?.absolutePath ?? "", fallback: item.relativePath),
                title: item.relativePath,
                course: manifest?.course ?? "",
                academicTerm: manifest?.academicTerm ?? AcademicTerm.infer(title: item.relativePath, dateTexts: [item.relativePath]),
                path: manifest?.absolutePath ?? "",
                url: item.url,
                isRecent: true,
                interaction: interaction(for: item.url, path: manifest?.absolutePath ?? "", fallback: item.relativePath)
            )
            return file.matches(filters: filters) ? file : nil
        }
    }

    private func interaction(for url: String, path: String, fallback: String) -> FileInteractionState? {
        model.snapshot.appUserState?.files[fileKey(url: url, path: path, fallback: fallback)]
    }
}

private struct DashboardFileItem: Identifiable {
    var key: String
    var title: String
    var course: String
    var academicTerm: AcademicTerm?
    var path: String
    var url: String
    var isRecent: Bool
    var interaction: FileInteractionState?

    var id: String { key }

    var isHidden: Bool {
        interaction?.isHiddenLike == true
    }

    func matches(filters: DashboardDetailFilters) -> Bool {
        guard filters.showHidden || !isHidden else { return false }
        guard !filters.hiddenOnly || isHidden else { return false }
        guard !filters.recentOnly || isRecent else { return false }
        guard DashboardTermFilter.matches(academicTerm, selected: filters.selectedTerm) else {
            return false
        }
        guard filters.selectedCourse == DashboardCourseFilter.all || course == filters.selectedCourse else {
            return false
        }
        let query = filters.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return [academicTerm?.displayName ?? "", title, course, path, url]
            .joined(separator: " ")
            .localizedCaseInsensitiveContains(query)
    }
}

private func fileKey(url: String, path: String, fallback: String) -> String {
    if !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return url
    }
    if !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return path
    }
    return fallback
}

private enum DashboardFileRowKind {
    case file
    case quarantine
    case pruned
}

private struct HiddenItemsListView: View {
    var filters: DashboardDetailFilters
    @ObservedObject var model: KLMSMacModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StateItemListView(
                items: hiddenAssignments,
                emptyText: "숨긴 과제가 없습니다.",
                editor: .assignment,
                filters: filters,
                model: model
            )
            StateItemListView(
                items: hiddenExams,
                emptyText: "숨긴 시험이 없습니다.",
                editor: .exam,
                filters: filters,
                model: model
            )
            NoticeListView(filters: filters, model: model)
            hiddenFileRows
        }
    }

    @ViewBuilder
    private var hiddenFileRows: some View {
        let files = hiddenFiles
        let quarantine = hiddenQuarantine
        if files.isEmpty && quarantine.isEmpty {
            EmptyDetailText(text: "숨긴 파일이 없습니다.")
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(files) { item in
                    FileRowView(item: item, kind: .file, model: model)
                }
                ForEach(quarantine) { item in
                    FileRowView(item: item, kind: .quarantine, model: model)
                }
            }
        }
    }

    private var hiddenAssignments: [StateItem] {
        let content = model.snapshot.legacyState?.content
        return (
            (content?.assignments ?? [])
                + (content?.assignmentCandidates ?? [])
                + (content?.completedAssignments ?? [])
                + (content?.assignmentRecords ?? [])
        )
            .filter { model.snapshot.manualOverrides?.isAssignmentHidden($0) == true }
            .dedupedDashboardItems()
    }

    private var hiddenExams: [StateItem] {
        let content = model.snapshot.legacyState?.content
        return ((content?.examItems ?? []) + (content?.examCandidates ?? []))
            .filter { model.snapshot.manualOverrides?.isExamHidden($0) == true }
    }

    private var hiddenFiles: [DashboardFileItem] {
        (model.snapshot.appUserState?.files ?? [:]).compactMap { key, item in
            guard item.isHiddenLike else { return nil }
            let file = DashboardFileItem(
                key: key,
                title: item.title,
                course: item.course,
                academicTerm: item.academicTerm,
                path: item.path,
                url: item.url,
                isRecent: item.trashedAt != nil,
                interaction: item
            )
            return file.matches(filters: filters) ? file : nil
        }
    }

    private var hiddenQuarantine: [DashboardFileItem] {
        (model.snapshot.appUserState?.quarantine ?? [:]).compactMap { key, item in
            guard item.isHiddenLike else { return nil }
            let file = DashboardFileItem(
                key: key,
                title: item.title,
                course: item.course,
                academicTerm: item.academicTerm,
                path: item.path,
                url: item.url,
                isRecent: item.trashedAt != nil,
                interaction: item
            )
            return file.matches(filters: filters) ? file : nil
        }
    }
}

private extension Array where Element == StateItem {
    func dedupedDashboardItems() -> [StateItem] {
        var seen = Set<String>()
        return filter { item in
            seen.insert(item.id).inserted
        }
    }
}

private struct QuarantineListView: View {
    var filters: DashboardDetailFilters
    @ObservedObject var model: KLMSMacModel

    var body: some View {
        let records = filteredItems
        if records.isEmpty {
            EmptyDetailText(text: filters.hasActiveFilter ? "검색/필터 조건에 맞는 격리 파일이 없습니다. 필터 초기화를 눌러 전체 목록을 보세요." : "격리 파일이 없습니다.")
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(records) { item in
                    FileRowView(
                        item: item,
                        kind: .quarantine,
                        model: model
                    )
                }
            }
        }
    }

    private var filteredItems: [DashboardFileItem] {
        let records = model.snapshot.quarantineReport?.records ?? []
        return records.compactMap { record in
            let key = fileKey(url: record.url, path: record.quarantinePath, fallback: record.quarantineRelativePath)
            let item = DashboardFileItem(
                key: key,
                title: record.quarantineRelativePath,
                course: "격리",
                academicTerm: AcademicTerm.infer(
                    title: record.quarantineRelativePath,
                    dateTexts: [record.quarantinePath, record.quarantineRelativePath]
                ),
                path: record.quarantinePath,
                url: record.url,
                isRecent: true,
                interaction: model.snapshot.appUserState?.quarantine[key]
            )
            return item.matches(filters: filters) ? item : nil
        }
    }
}

private struct PrunedListView: View {
    var filters: DashboardDetailFilters
    var snapshot: EngineSnapshot

    var body: some View {
        let deleted = filteredActions
        if deleted.isEmpty {
            EmptyDetailText(text: "삭제된 파일 기록이 없습니다.")
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(deleted) { action in
                    FileRowView(
                        item: DashboardFileItem(
                            key: action.path,
                            title: action.path,
                            course: action.action,
                            academicTerm: AcademicTerm.infer(title: action.path, dateTexts: [action.path]),
                            path: action.path,
                            url: "",
                            isRecent: false,
                            interaction: nil
                        ),
                        kind: .pruned,
                        model: nil
                    )
                }
            }
        }
    }

    private var filteredActions: [CleanupAction] {
        (snapshot.cleanupResult?.actions.filter { $0.action == "deleted" } ?? []).filter { action in
            let term = AcademicTerm.infer(title: action.path, dateTexts: [action.path])
            guard DashboardTermFilter.matches(term, selected: filters.selectedTerm) else {
                return false
            }
            let query = filters.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            return query.isEmpty || [term?.displayName ?? "", action.path].joined(separator: " ").localizedCaseInsensitiveContains(query)
        }
    }
}

private struct FileRowView: View {
    var item: DashboardFileItem
    var kind: DashboardFileRowKind
    var model: KLMSMacModel?

    var body: some View {
        let hidden = item.isHidden
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.title.isEmpty ? "(파일명 없음)" : item.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(2)
                        if item.isRecent {
                            Label("최근", systemImage: "sparkle")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                        }
                        if hidden {
                            Label("숨김", systemImage: "eye.slash")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    let metadata = [item.academicTerm?.displayName ?? "", item.course].filter { !$0.isEmpty }.joined(separator: " · ")
                    if !metadata.isEmpty {
                        Text(metadata)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if !item.path.isEmpty {
                        Text(item.path)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 8)
                if !item.path.isEmpty {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Finder에서 보기")
                }
                if !item.url.isEmpty {
                    Button {
                        openExternalURL(item.url)
                    } label: {
                        Image(systemName: "safari")
                    }
                    .buttonStyle(.borderless)
                    .help("KLMS 열기")
                }
            }
            actionBar(hidden: hidden)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hidden ? Color.orange.opacity(0.10) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func actionBar(hidden: Bool) -> some View {
        if let model, kind != .pruned {
            HStack(spacing: 8) {
                if hidden {
                    Button {
                        restore(model)
                    } label: {
                        Label("복구", systemImage: "arrow.uturn.backward")
                    }
                } else {
                    Button {
                        hide(model)
                    } label: {
                        Label(kind == .quarantine ? "무시" : "목록에서 숨김", systemImage: "eye.slash")
                    }
                }
                if !item.path.isEmpty {
                    Button(role: .destructive) {
                        moveToTrash(model)
                    } label: {
                        Label("휴지통", systemImage: "trash")
                    }
                }
                Spacer()
            }
            .font(.caption)
            .buttonStyle(.bordered)
            .padding(.top, 8)
        }
    }

    private func hide(_ model: KLMSMacModel) {
        switch kind {
        case .file:
            model.setFileHidden(true, key: item.key, title: item.title, course: item.course, path: item.path, url: item.url)
        case .quarantine:
            model.setQuarantineIgnored(true, key: item.key, title: item.title, path: item.path, url: item.url)
        case .pruned:
            break
        }
    }

    private func restore(_ model: KLMSMacModel) {
        switch kind {
        case .file:
            model.setFileHidden(false, key: item.key, title: item.title, course: item.course, path: item.path, url: item.url)
        case .quarantine:
            model.setQuarantineIgnored(false, key: item.key, title: item.title, path: item.path, url: item.url)
        case .pruned:
            break
        }
    }

    private func moveToTrash(_ model: KLMSMacModel) {
        model.moveFileToTrash(
            key: item.key,
            title: item.title,
            course: item.course,
            path: item.path,
            url: item.url,
            bucket: kind == .quarantine ? .quarantine : .files
        )
    }
}

private struct CalendarDetailView: View {
    var snapshot: EngineSnapshot
    var filters: DashboardDetailFilters

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let calendar = snapshot.syncReport?.calendar {
                MetricGrid(metrics: [
                    Metric("생성", calendar.created),
                    Metric("수정", calendar.updated),
                    Metric("삭제", calendar.deleted),
                ])
            } else {
                EmptyDetailText(text: "캘린더 결과가 없습니다.")
            }

            if let coreRun = snapshot.syncReport?.runs["core"] {
                Text("과제/시험 · \(coreRun.status.klmsLocalizedStatus) · \(coreRun.elapsedSecondsText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let result = snapshot.calendarSyncResult {
                CalendarSummaryListView(result: result)
                CalendarChangeListView(
                    changes: result.changes,
                    filters: filters,
                    hasLegacyCountWithoutDetails: result.changes.isEmpty && hasReportedCalendarChanges
                )
            } else if hasReportedCalendarChanges {
                EmptyDetailText(text: "이전 캘린더 결과에는 상세 내역이 없습니다. 다음 캘린더 동기화부터 생성/수정/삭제 항목이 표시됩니다.")
            }
        }
    }

    private var hasReportedCalendarChanges: Bool {
        let counts = snapshot.syncReport?.calendar
        let reportCount = (counts?.created ?? 0) + (counts?.updated ?? 0) + (counts?.deleted ?? 0)
        let summaryCount = snapshot.calendarSyncResult?.summaries.reduce(0) {
            $0 + $1.created + $1.updated + $1.deleted
        } ?? 0
        return reportCount + summaryCount > 0
    }
}

private struct CalendarSummaryListView: View {
    var result: CalendarSyncResult

    var body: some View {
        if !result.summaries.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("캘린더별 요약")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(result.summaries) { summary in
                    HStack(spacing: 8) {
                        Text(summary.calendar.isEmpty ? "캘린더" : summary.calendar)
                            .font(.caption.weight(.semibold))
                        Text(bucketLabel(summary.bucket))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("생성 \(summary.created)")
                        Text("수정 \(summary.updated)")
                        Text("삭제 \(summary.deleted)")
                        Text("전체 \(summary.total)")
                    }
                    .font(.caption2)
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func bucketLabel(_ bucket: String) -> String {
        switch bucket {
        case "exam":
            "시험"
        case "helpdesk":
            "헬프데스크"
        default:
            bucket.isEmpty ? "기타" : bucket
        }
    }
}

private struct CalendarChangeListView: View {
    var changes: [CalendarChange]
    var filters: DashboardDetailFilters
    var hasLegacyCountWithoutDetails: Bool

    var body: some View {
        let visibleChanges = filteredChanges
        VStack(alignment: .leading, spacing: 6) {
            Text("상세 변경")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if visibleChanges.isEmpty {
                EmptyDetailText(text: emptyText)
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(visibleChanges.prefix(50))) { change in
                        CalendarChangeRowView(change: change)
                    }
                }
                if visibleChanges.count > 50 {
                    Text("최근 50개만 표시 중 · 전체 \(visibleChanges.count)개")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var filteredChanges: [CalendarChange] {
        changes.filter { change in
            guard filters.selectedCourse == DashboardCourseFilter.all || change.course == filters.selectedCourse else {
                return false
            }
            guard DashboardTermFilter.matches(change.academicTerm, selected: filters.selectedTerm) else {
                return false
            }
            let query = filters.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return true }
            return [
                change.academicTerm?.displayName ?? "",
                change.actionDisplayName,
                change.calendar,
                change.bucket,
                change.title,
                change.course,
                change.location,
                change.url,
                change.changes.joined(separator: " "),
            ]
            .joined(separator: " ")
            .localizedCaseInsensitiveContains(query)
        }
    }

    private var emptyText: String {
        if filters.hasActiveFilter {
            return "검색/필터 조건에 맞는 캘린더 변경이 없습니다."
        }
        if hasLegacyCountWithoutDetails {
            return "이전 캘린더 결과에는 상세 내역이 없습니다. 다음 캘린더 동기화부터 생성/수정/삭제 항목이 표시됩니다."
        }
        return "이번 캘린더 실행에서 생성/수정/삭제된 항목이 없습니다."
    }
}

private struct CalendarChangeRowView: View {
    var change: CalendarChange

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Text(change.actionDisplayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(actionColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(actionColor.opacity(0.12), in: Capsule())
                VStack(alignment: .leading, spacing: 3) {
                    Text(change.title.isEmpty ? "(제목 없음)" : change.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                    Text(metadataText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if !timeText.isEmpty {
                        Text(timeText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if !change.changes.isEmpty {
                        Text("변경 필드: \(change.changes.joined(separator: ", "))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if !change.parseError.isEmpty {
                        Text("파싱 오류: \(change.parseError)")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                if !change.url.isEmpty {
                    Button {
                        openExternalURL(change.url)
                    } label: {
                        Image(systemName: "safari")
                    }
                    .help("KLMS 열기")
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var metadataText: String {
        [
            change.academicTerm?.displayName ?? "",
            change.course,
            change.calendar,
            bucketLabel(change.bucket),
            change.location,
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " · ")
    }

    private var timeText: String {
        let start = displayCalendarDate(change.startAt)
        let due = displayCalendarDate(change.dueAt)
        if start.isEmpty {
            return due.isEmpty ? "" : "종료 \(due)"
        }
        if due.isEmpty {
            return "시작 \(start)"
        }
        return "시작 \(start) · 종료 \(due)"
    }

    private var actionColor: Color {
        switch change.action {
        case "created":
            .green
        case "updated":
            .blue
        case "deleted":
            .red
        default:
            .secondary
        }
    }

    private func bucketLabel(_ bucket: String) -> String {
        switch bucket {
        case "exam":
            "시험"
        case "helpdesk":
            "헬프데스크"
        default:
            bucket
        }
    }
}

private func displayCalendarDate(_ text: String) -> String {
    guard !text.isEmpty else { return "" }
    let date = parseCalendarDetailDate(text)
    guard let date else { return text }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ko_KR")
    formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
    formatter.dateFormat = "M/d HH:mm"
    return formatter.string(from: date)
}

private func parseCalendarDetailDate(_ text: String) -> Date? {
    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractionalFormatter.date(from: text) {
        return date
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)
}

private struct EmptyDetailText: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private func openExternalURL(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let url = URL(string: trimmed) ?? trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).flatMap(URL.init(string:))
    guard let url else {
        return
    }
    NSWorkspace.shared.open(url)
}
