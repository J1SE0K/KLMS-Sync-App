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
    case files
    case missingFiles
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
        case .files:
            "파일 목록"
        case .missingFiles:
            "누락 파일"
        case .newFiles:
            "새 파일"
        case .quarantine:
            "격리"
        case .pruned:
            "삭제된 파일"
        case .calendar:
            "캘린더"
        case .hidden:
            "보관함"
        }
    }
}

struct DashboardDetailPanelView: View {
    var kind: DashboardDetailKind
    @ObservedObject var model: KLMSMacModel
    @State private var searchText = ""
    @State private var selectedCourse = DashboardCourseFilter.all
    @State private var selectedYear = DashboardTermFilter.allYears
    @State private var selectedSemester = DashboardTermFilter.allSemesters
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
                    Text("보관 \(hiddenCount)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            DashboardFilterBarView(
                searchText: $searchText,
                selectedCourse: $selectedCourse,
                selectedYear: $selectedYear,
                selectedSemester: $selectedSemester,
                showHidden: $showHidden,
                newOnly: $newOnly,
                recentOnly: $recentOnly,
                courses: courseOptions,
                years: yearOptions,
                semesters: semesterOptions,
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
            case .files:
                FileManifestListView(filters: filters, model: model)
            case .missingFiles:
                MissingFilesListView(filters: filters, model: model)
            case .newFiles:
                NewFilesListView(filters: filters, model: model)
            case .quarantine:
                QuarantineListView(filters: filters, model: model)
            case .pruned:
                PrunedListView(filters: filters, snapshot: model.snapshot)
            case .calendar:
                CalendarDetailView(snapshot: model.snapshot, filters: filters, model: model)
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
            selectedYear: selectedYear,
            selectedSemester: selectedSemester,
            showHidden: showHidden || kind == .hidden,
            hiddenOnly: kind == .hidden,
            newOnly: newOnly,
            recentOnly: recentOnly
        )
    }

    private var courseOptions: [String] {
        DashboardCourseFilter.options(for: kind, snapshot: model.snapshot)
    }

    private var yearOptions: [String] {
        DashboardTermFilter.yearOptions(for: kind, snapshot: model.snapshot)
    }

    private var semesterOptions: [String] {
        DashboardTermFilter.semesterOptions(for: kind, snapshot: model.snapshot)
    }

    private var hiddenCount: Int {
        model.snapshot.hiddenSummary.total
    }
}

private struct DashboardDetailFilters {
    var searchText: String
    var selectedCourse: String
    var selectedYear: String
    var selectedSemester: String
    var showHidden: Bool
    var hiddenOnly: Bool
    var newOnly: Bool
    var recentOnly: Bool

    var hasActiveFilter: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || selectedCourse != DashboardCourseFilter.all
            || selectedYear != DashboardTermFilter.allYears
            || selectedSemester != DashboardTermFilter.allSemesters
            || showHidden
            || hiddenOnly
            || newOnly
            || recentOnly
    }
}

private enum DashboardLargeList {
    static let initialVisibleLimit = 80
    static let increment = 80
}

private struct DashboardShowMoreButton: View {
    var remainingCount: Int
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("더 보기 \(remainingCount)개 남음", systemImage: "chevron.down")
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.bordered)
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
        case .files, .newFiles:
            courses = snapshot.courseFileManifest.map(\.course)
        case .missingFiles:
            courses = snapshot.filePreview?.localMissingEntries.map(\.course) ?? []
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
        let content = snapshot.rawLegacyState?.content ?? snapshot.legacyState?.content
        let overrides = snapshot.manualOverrides
        courses += (
            (content?.assignments ?? [])
                + (content?.assignmentCandidates ?? [])
                + (content?.completedAssignments ?? [])
                + (content?.assignmentRecords ?? [])
                + (content?.helpDeskItems ?? [])
        )
            .filter { overrides?.isAssignmentHidden($0) == true }
            .map(\.course)
        courses += (content?.examItems ?? []).filter { overrides?.isExamHidden($0) == true }.map(\.course)
        courses += (content?.examCandidates ?? []).filter { overrides?.isExamHidden($0) == true }.map(\.course)
        courses += (snapshot.noticeDigest?.notices ?? []).filter {
            snapshot.noticeUserState?.notices[$0.noticeIdentifier]?.hidden == true
        }.map(\.course)
        courses += snapshot.appUserState?.files.values.filter(\.isHiddenLike).map(\.course) ?? []
        courses += snapshot.appUserState?.quarantine.values.filter(\.isHiddenLike).map(\.course) ?? []
        return courses
    }
}

private enum DashboardTermFilter {
    static let allYears = "전체 년도"
    static let allSemesters = "전체 학기"
    static let unknown = "학기 미확인"

    static func label(_ term: AcademicTerm?) -> String {
        term?.displayName ?? unknown
    }

    static func matches(_ term: AcademicTerm?, selectedYear: String, selectedSemester: String) -> Bool {
        if selectedYear != allYears {
            guard let term, "\(term.year)" == selectedYear else {
                return false
            }
        }
        if selectedSemester == unknown {
            return term == nil
        }
        if selectedSemester != allSemesters {
            guard let term, term.semester.displayName == selectedSemester else {
                return false
            }
        }
        return true
    }

    static func yearOptions(for kind: DashboardDetailKind, snapshot: EngineSnapshot) -> [String] {
        let years = Set(terms(for: kind, snapshot: snapshot).compactMap { $0?.year })
        return [allYears] + years.sorted(by: >).map(String.init)
    }

    static func semesterOptions(for kind: DashboardDetailKind, snapshot: EngineSnapshot) -> [String] {
        let terms = terms(for: kind, snapshot: snapshot)
        let known = Set(terms.compactMap { $0?.semester })
            .sorted(by: <)
            .map(\.displayName)
        let unknowns = terms.contains(where: { $0 == nil }) ? [unknown] : []
        return [allSemesters] + known + unknowns
    }

    private static func terms(for kind: DashboardDetailKind, snapshot: EngineSnapshot) -> [AcademicTerm?] {
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
        case .files:
            terms = snapshot.courseFileManifest.map(\.academicTerm)
        case .missingFiles:
            terms = missingFileTerms(snapshot: snapshot)
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
        return terms
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

    private static func missingFileTerms(snapshot: EngineSnapshot) -> [AcademicTerm?] {
        (snapshot.filePreview?.localMissingEntries ?? []).map { entry in
            AcademicTerm.infer(
                title: entry.effectiveRelativePath,
                dateTexts: [entry.effectiveRelativePath, entry.expectedPath ?? ""]
            )
        }
    }

    private static func hiddenTerms(snapshot: EngineSnapshot) -> [AcademicTerm?] {
        var terms: [AcademicTerm?] = []
        let content = snapshot.rawLegacyState?.content ?? snapshot.legacyState?.content
        let overrides = snapshot.manualOverrides
        terms += (
            (content?.assignments ?? [])
                + (content?.assignmentCandidates ?? [])
                + (content?.completedAssignments ?? [])
                + (content?.assignmentRecords ?? [])
                + (content?.helpDeskItems ?? [])
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
        case .notices, .files, .missingFiles, .newFiles:
            true
        default:
            false
        }
    }

    var supportsRecentOnly: Bool {
        switch self {
        case .notices, .files, .missingFiles, .newFiles, .quarantine:
            true
        default:
            false
        }
    }
}

private struct DashboardFilterBarView: View {
    @Binding var searchText: String
    @Binding var selectedCourse: String
    @Binding var selectedYear: String
    @Binding var selectedSemester: String
    @Binding var showHidden: Bool
    @Binding var newOnly: Bool
    @Binding var recentOnly: Bool
    var courses: [String]
    var years: [String]
    var semesters: [String]
    var supportsNewOnly: Bool
    var supportsRecentOnly: Bool
    var supportsHiddenToggle: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    searchControl
                    rangeControl
                }
                VStack(alignment: .leading, spacing: 8) {
                    searchControl
                    rangeControl
                }
            }
            displayControl
        }
    }

    private var searchControl: some View {
        DashboardControlBox(title: "검색", systemImage: "magnifyingglass") {
            HStack(spacing: 8) {
                TextField("검색", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180)
            }
        }
    }

    private var rangeControl: some View {
        DashboardControlBox(title: "범위", systemImage: "line.3.horizontal.decrease.circle") {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    coursePickerField
                    yearPickerField
                    semesterPickerField
                }
                VStack(alignment: .leading, spacing: 8) {
                    coursePickerField
                    HStack(spacing: 8) {
                        yearPickerField
                        semesterPickerField
                    }
                }
            }
        }
    }

    private var coursePickerField: some View {
        DashboardRangeField(title: "과목", systemImage: "book.closed", minWidth: 150) {
            Picker("과목", selection: normalizedCourseBinding) {
                ForEach(courses, id: \.self) { course in
                    Text(course).tag(course)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
    }

    private var yearPickerField: some View {
        DashboardRangeField(title: "년도", systemImage: "calendar", minWidth: 86, disabled: years.count <= 1) {
            Picker("년도", selection: normalizedYearBinding) {
                ForEach(years, id: \.self) { year in
                    Text(year).tag(year)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .disabled(years.count <= 1)
        }
    }

    private var semesterPickerField: some View {
        DashboardRangeField(title: "학기", systemImage: "calendar.badge.clock", minWidth: 98, disabled: semesters.count <= 1) {
            Picker("학기", selection: normalizedTermBinding) {
                ForEach(semesters, id: \.self) { semester in
                    Text(semester).tag(semester)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .disabled(semesters.count <= 1)
        }
    }

    private var displayControl: some View {
        DashboardControlBox(title: "표시", systemImage: "slider.horizontal.3") {
            HStack(spacing: 10) {
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
            || selectedYear != DashboardTermFilter.allYears
            || selectedSemester != DashboardTermFilter.allSemesters
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

    private var normalizedYearBinding: Binding<String> {
        Binding(
            get: {
                years.contains(selectedYear) ? selectedYear : DashboardTermFilter.allYears
            },
            set: { selectedYear = $0 }
        )
    }

    private var normalizedTermBinding: Binding<String> {
        Binding(
            get: {
                semesters.contains(selectedSemester)
                    ? selectedSemester
                    : DashboardTermFilter.allSemesters
            },
            set: { selectedSemester = $0 }
        )
    }

    private func resetFilters() {
        searchText = ""
        selectedCourse = DashboardCourseFilter.all
        selectedYear = DashboardTermFilter.allYears
        selectedSemester = DashboardTermFilter.allSemesters
        showHidden = false
        newOnly = false
        recentOnly = false
    }
}

private struct DashboardControlBox<Content: View>: View {
    var title: String
    var systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
        }
    }
}

private struct DashboardRangeField<Content: View>: View {
    var title: String
    var systemImage: String
    var minWidth: CGFloat
    var disabled = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(minWidth: minWidth, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(disabled ? 0.20 : 0.52), lineWidth: 1)
        }
        .opacity(disabled ? 0.58 : 1)
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
    @State private var visibleLimit = DashboardLargeList.initialVisibleLimit

    var body: some View {
        let visibleItems = filteredItems
        let renderedItems = Array(visibleItems.prefix(visibleLimit))
        if visibleItems.isEmpty {
            EmptyDetailText(text: filters.hasActiveFilter ? "검색/필터 조건에 맞는 항목이 없습니다. 필터 초기화를 눌러 전체 목록을 보세요." : emptyText)
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(renderedItems) { item in
                    StateItemRowView(item: item, editor: editor, model: model)
                }
                if visibleItems.count > renderedItems.count {
                    DashboardShowMoreButton(remainingCount: visibleItems.count - renderedItems.count) {
                        visibleLimit += DashboardLargeList.increment
                    }
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
            guard DashboardTermFilter.matches(
                item.academicTerm,
                selectedYear: filters.selectedYear,
                selectedSemester: filters.selectedSemester
            ) else {
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
    @State private var didRequestSync = false

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

            DashboardActionCaption("수정")
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

            if didRequestSync {
                MacInlinePendingActionView(message: "과제/시험 동기화 반영을 시작했습니다.")
            } else {
                HStack(spacing: 8) {
                if editor == .exam {
                    Button {
                        approveExam()
                    } label: {
                        Label("시험 반영", systemImage: "checkmark.seal")
                    }
                    .disabled(isHidden)
                }
                Button {
                    didRequestSync = true
                    Task { await model.run(.coreSync) }
                } label: {
                    Label("동기화 반영", systemImage: KLMSEngineCommand.coreSync.systemImage)
                }
                .disabled(model.runningCommand != nil)
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
                        Label(editor == .exam ? "삭제/시험 아님" : "삭제/숨김", systemImage: "eye.slash")
                    }
                }
                Spacer()
                }
                .font(.caption)
                .buttonStyle(.bordered)
            }
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

    private func approveExam() {
        var override = model.snapshot.manualOverrides?.examOverride(for: item) ?? ExamOverride()
        override.status = "approved"
        model.setExamOverride(override, for: item)
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

private struct DashboardActionCaption: View {
    var text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }
}

private struct MacInlinePendingActionView: View {
    var message: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
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
    @State private var category: NoticeListCategory
    @State private var visibleLimit = DashboardLargeList.initialVisibleLimit

    init(
        filters: DashboardDetailFilters,
        defaultCategory: NoticeListCategory = .all,
        model: KLMSMacModel
    ) {
        self.filters = filters
        self.model = model
        _category = State(initialValue: defaultCategory)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NoticeCategoryPickerView(
                category: $category,
                snapshot: model.snapshot,
                hiddenOnly: filters.hiddenOnly
            )
            noticeRows
        }
    }

    @ViewBuilder
    private var noticeRows: some View {
        let notices = filteredNotices
        let renderedNotices = Array(notices.prefix(visibleLimit))
        if notices.isEmpty {
            EmptyDetailText(text: filters.hasActiveFilter ? "검색/필터 조건에 맞는 공지가 없습니다. 필터 초기화를 눌러 전체 목록을 보세요." : "공지 목록이 없습니다.")
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(renderedNotices) { notice in
                    NoticeRowView(notice: notice, model: model)
                }
                if notices.count > renderedNotices.count {
                    DashboardShowMoreButton(remainingCount: notices.count - renderedNotices.count) {
                        visibleLimit += DashboardLargeList.increment
                    }
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
            let read = noticeReadStateMatches(interaction, fingerprint: notice.fingerprint)
            let fresh = notice.changeState == "new" || notice.changeState == "updated"
            let term = notice.academicTerm(generatedAt: generatedAt)
            guard filters.showHidden || !hidden else { return false }
            guard !filters.hiddenOnly || hidden else { return false }
            guard !filters.newOnly || fresh else { return false }
            guard !filters.recentOnly || fresh else { return false }
            guard DashboardTermFilter.matches(
                term,
                selectedYear: filters.selectedYear,
                selectedSemester: filters.selectedSemester
            ) else {
                return false
            }
            guard filters.selectedCourse == DashboardCourseFilter.all || notice.course == filters.selectedCourse else {
                return false
            }
            guard category.matches(
                hidden: hidden,
                important: important,
                read: read,
                fresh: fresh,
                hiddenOnly: filters.hiddenOnly
            ) else {
                return false
            }
            let query = filters.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return true }
            var searchableFields = [term?.displayName ?? "", notice.title, notice.course, notice.postedAt, notice.summary, notice.url]
            if query.count >= 3 {
                searchableFields.append(notice.bodyText)
            }
            return searchableFields
                .joined(separator: " ")
                .localizedCaseInsensitiveContains(query)
        }
    }
}

private func noticeReadStateMatches(_ state: NoticeInteractionState?, fingerprint: String) -> Bool {
    guard let state else {
        return false
    }
    if state.readAt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
        return true
    }
    return !fingerprint.isEmpty && state.readFingerprint == fingerprint
}

enum NoticeListCategory: String, CaseIterable, Identifiable {
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

    func matches(hidden: Bool, important: Bool, read: Bool, fresh: Bool, hiddenOnly: Bool = false) -> Bool {
        if hiddenOnly {
            switch self {
            case .all, .hidden:
                hidden
            case .important:
                important && hidden
            case .fresh:
                fresh && !read && hidden
            case .unread:
                !read && hidden
            case .archived:
                read && !important && hidden
            }
        } else {
            switch self {
            case .all:
                !hidden
            case .important:
                important && !hidden
            case .fresh:
                fresh && !read && !hidden
            case .unread:
                !read && !hidden
            case .archived:
                read && !important && !hidden
            case .hidden:
                hidden
            }
        }
    }
}

private struct NoticeCategoryPickerView: View {
    @Binding var category: NoticeListCategory
    var snapshot: EngineSnapshot
    var hiddenOnly: Bool

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
            let read = noticeReadStateMatches(interaction, fingerprint: notice.fingerprint)
            let fresh = notice.changeState == "new" || notice.changeState == "updated"
            return category.matches(
                hidden: hidden,
                important: important,
                read: read,
                fresh: fresh,
                hiddenOnly: hiddenOnly
            )
        }.count
    }
}

private struct NoticeRowView: View {
    var notice: NoticeDigestEntry
    @ObservedObject var model: KLMSMacModel
    @State private var didRequestSync = false

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

            let attachments = attachmentDisplays
            if !attachments.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("첨부 파일")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(attachments) { attachment in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: attachment.path.isEmpty ? "paperclip" : "doc")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(attachment.name.klmsDisplayText)
                                    .font(.caption2)
                                    .lineLimit(2)
                                if !attachment.path.isEmpty {
                                    Text(attachment.path.klmsDisplayText)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .textSelection(.enabled)
                                }
                            }
                            Spacer(minLength: 6)
                            if !attachment.path.isEmpty {
                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: attachment.path)])
                                } label: {
                                    Image(systemName: "folder")
                                }
                                .buttonStyle(.borderless)
                                .help("Finder에서 보기")
                            }
                        }
                    }
                }
            }

            DashboardActionCaption("수정")
            HStack {
                Toggle("읽음", isOn: readBinding)
                Toggle("중요", isOn: importantBinding)
                Toggle("숨김", isOn: hiddenBinding)
                Spacer()
            }
            .toggleStyle(.checkbox)

            if didRequestSync {
                MacInlinePendingActionView(message: "공지 메모 반영을 시작했습니다.")
            } else {
                HStack(spacing: 8) {
                Button {
                    didRequestSync = true
                    Task { await model.run(.noticeSync) }
                } label: {
                    Label("메모 반영", systemImage: KLMSEngineCommand.noticeSync.systemImage)
                }
                .disabled(model.runningCommand != nil)
                Button {
                    model.setNoticeHidden(!hidden, for: notice)
                } label: {
                    Label(hidden ? "복구" : "삭제/숨김", systemImage: hidden ? "arrow.uturn.backward" : "eye.slash")
                }
                .buttonStyle(.bordered)
                Spacer()
                }
                .font(.caption)
            }
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
                return noticeReadStateMatches(state, fingerprint: notice.fingerprint)
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

    private var attachmentDisplays: [NoticeAttachmentDisplay] {
        if !notice.attachmentItems.isEmpty {
            return notice.attachmentItems.map { item in
                let path = item.absolutePath.trimmingCharacters(in: .whitespacesAndNewlines)
                let relativePath = item.relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
                let fallbackName = path.isEmpty ? relativePath : URL(fileURLWithPath: path).lastPathComponent
                let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return NoticeAttachmentDisplay(
                    name: name.isEmpty ? (fallbackName.isEmpty ? "(이름 없음)" : fallbackName) : name,
                    path: path,
                    fallbackKey: relativePath
                )
            }
        }

        var seen = Set<String>()
        return notice.attachments.compactMap { rawName in
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let key = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(key).inserted else { return nil }
            return NoticeAttachmentDisplay(name: name, path: "", fallbackKey: key)
        }
    }
}

private struct NoticeAttachmentDisplay: Identifiable {
    var name: String
    var path: String
    var fallbackKey: String

    var id: String {
        if !path.isEmpty {
            return path
        }
        return fallbackKey.isEmpty ? name : fallbackKey
    }
}

private struct NewFilesListView: View {
    var filters: DashboardDetailFilters
    @ObservedObject var model: KLMSMacModel
    @State private var sortOption = DashboardFileSortOption.recent
    @State private var visibleLimit = DashboardLargeList.initialVisibleLimit

    var body: some View {
        let files = filteredItems
        let sortedFiles = files.sorted(by: sortOption)
        let visibleFiles = Array(sortedFiles.prefix(visibleLimit))
        if files.isEmpty {
            EmptyDetailText(text: filters.hasActiveFilter ? "검색/필터 조건에 맞는 새 파일이 없습니다. 필터 초기화를 눌러 전체 목록을 보세요." : "새 파일이 없습니다.")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                FileSortPickerView(selection: $sortOption)
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(visibleFiles) { item in
                        FileRowView(item: item, kind: .file, model: model)
                    }
                    if sortedFiles.count > visibleFiles.count {
                        DashboardShowMoreButton(remainingCount: sortedFiles.count - visibleFiles.count) {
                            visibleLimit += DashboardLargeList.increment
                        }
                    }
                }
                .id(sortOption.rawValue)
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
                sortPath: item.relativePath,
                bucket: manifest?.bucket ?? fileBucket(from: item.relativePath),
                url: item.url,
                isRecent: true,
                recencyText: manifest?.localDownloadedAt ?? "",
                klmsTimestampEpoch: manifest?.klmsTimestampEpoch,
                interaction: interaction(for: item.url, path: manifest?.absolutePath ?? "", fallback: item.relativePath)
            )
            return file.matches(filters: filters) ? file : nil
        }
    }

    private func interaction(for url: String, path: String, fallback: String) -> FileInteractionState? {
        model.snapshot.appUserState?.files[fileKey(url: url, path: path, fallback: fallback)]
    }
}

private struct FileManifestListView: View {
    var filters: DashboardDetailFilters
    @ObservedObject var model: KLMSMacModel
    @State private var sortOption = DashboardFileSortOption.course
    @State private var visibleLimit = DashboardLargeList.initialVisibleLimit

    var body: some View {
        let files = filteredItems
        let sortedFiles = files.sorted(by: sortOption)
        let visibleFiles = Array(sortedFiles.prefix(visibleLimit))
        if files.isEmpty {
            EmptyDetailText(text: filters.hasActiveFilter ? "검색/필터 조건에 맞는 파일이 없습니다. 필터 초기화를 눌러 전체 목록을 보세요." : "파일 목록이 없습니다. 파일 동기화를 한 번 실행하면 KLMS 파일 목록이 여기에 표시됩니다.")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                FileSortPickerView(selection: $sortOption)
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(visibleFiles) { item in
                        FileRowView(item: item, kind: .file, model: model)
                    }
                    if sortedFiles.count > visibleFiles.count {
                        DashboardShowMoreButton(remainingCount: sortedFiles.count - visibleFiles.count) {
                            visibleLimit += DashboardLargeList.increment
                        }
                    }
                }
                .id(sortOption.rawValue)
            }
        }
    }

    private var filteredItems: [DashboardFileItem] {
        model.snapshot.courseFileManifest.compactMap { entry in
            let key = fileKey(url: entry.url, path: entry.absolutePath, fallback: entry.relativePath)
            let item = DashboardFileItem(
                key: key,
                title: fileDisplayTitle(filename: entry.filename, relativePath: entry.relativePath),
                course: entry.course,
                academicTerm: entry.academicTerm,
                path: entry.absolutePath,
                sortPath: entry.relativePath,
                bucket: entry.bucket,
                url: entry.url,
                isRecent: isRecent(entry),
                recencyText: entry.localDownloadedAt,
                klmsTimestampEpoch: entry.klmsTimestampEpoch,
                interaction: model.snapshot.appUserState?.files[key]
            )
            return item.matches(filters: filters) ? item : nil
        }
    }

    private func isRecent(_ entry: CourseFileManifestEntry) -> Bool {
        (model.snapshot.downloadResult?.results ?? []).contains { result in
            let sameFile = (!result.url.isEmpty && result.url == entry.url)
                || (!result.relativePath.isEmpty && result.relativePath == entry.relativePath)
            guard sameFile else {
                return false
            }
            return result.copiedToNewFilesInbox
                || (!result.skippedExisting
                    && !result.restoredFromArchive
                    && !result.reusedLoggedFile
                    && !result.failed
                    && !result.quarantined)
        }
    }
}

private struct MissingFilesListView: View {
    var filters: DashboardDetailFilters
    @ObservedObject var model: KLMSMacModel
    @State private var sortOption = DashboardFileSortOption.course
    @State private var visibleLimit = DashboardLargeList.initialVisibleLimit

    var body: some View {
        let files = filteredItems
        let sortedFiles = files.sorted(by: sortOption)
        let visibleFiles = Array(sortedFiles.prefix(visibleLimit))
        if files.isEmpty {
            EmptyDetailText(text: filters.hasActiveFilter ? "검색/필터 조건에 맞는 누락 파일이 없습니다. 필터 초기화를 눌러 전체 목록을 보세요." : "로컬에서 누락된 파일이 없습니다.")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("파일 목록에는 있지만 현재 로컬 저장 위치에 없는 항목입니다. 파일 동기화를 실행하면 archive/log에서 복구하거나, 없으면 KLMS에서 다시 받습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                FileSortPickerView(selection: $sortOption)
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(visibleFiles) { item in
                        FileRowView(item: item, kind: .file, model: model)
                    }
                    if sortedFiles.count > visibleFiles.count {
                        DashboardShowMoreButton(remainingCount: sortedFiles.count - visibleFiles.count) {
                            visibleLimit += DashboardLargeList.increment
                        }
                    }
                }
                .id(sortOption.rawValue)
            }
        }
    }

    private var filteredItems: [DashboardFileItem] {
        (model.snapshot.verifyResult?.files?.missingFiles ?? []).compactMap { path in
            let relativePath = normalizedMissingFilePath(path)
            let key = fileKey(url: "", path: path, fallback: relativePath)
            let title = fileDisplayTitle(filename: URL(fileURLWithPath: relativePath).lastPathComponent, relativePath: relativePath)
            let course = relativePath.split(separator: "/", omittingEmptySubsequences: true).first.map(String.init) ?? ""
            let item = DashboardFileItem(
                key: key,
                title: title,
                course: course,
                academicTerm: AcademicTerm.infer(
                    title: relativePath,
                    dateTexts: [relativePath, path]
                ),
                path: path,
                sortPath: relativePath,
                bucket: fileBucket(from: relativePath),
                url: "",
                isRecent: true,
                recencyText: "",
                interaction: model.snapshot.appUserState?.files[key]
            )
            return item.matches(filters: filters) ? item : nil
        }
    }

    private func normalizedMissingFilePath(_ path: String) -> String {
        let marker = "/KLMSNotesSync/course_files/"
        if let range = path.range(of: marker) {
            return String(path[range.upperBound...])
        }
        return path
    }
}

private struct DashboardFileItem: Identifiable {
    var key: String
    var title: String
    var course: String
    var academicTerm: AcademicTerm?
    var path: String
    var sortPath: String
    var bucket: String
    var url: String
    var isRecent: Bool
    var recencyText: String
    var klmsTimestampEpoch: Int? = nil
    var interaction: FileInteractionState?

    var id: String { key }

    var isHidden: Bool {
        interaction?.isHiddenLike == true
    }

    func matches(filters: DashboardDetailFilters) -> Bool {
        guard filters.showHidden || !isHidden else { return false }
        guard !filters.hiddenOnly || isHidden else { return false }
        guard !filters.newOnly || isRecent else { return false }
        guard !filters.recentOnly || isRecent else { return false }
        guard DashboardTermFilter.matches(
            academicTerm,
            selectedYear: filters.selectedYear,
            selectedSemester: filters.selectedSemester
        ) else {
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

private enum DashboardFileSortOption: String, CaseIterable, Identifiable {
    case course
    case kind
    case name
    case path
    case recent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .course:
            "과목"
        case .kind:
            "종류"
        case .name:
            "파일명"
        case .path:
            "경로"
        case .recent:
            "최근"
        }
    }
}

private struct FileSortPickerView: View {
    @Binding var selection: DashboardFileSortOption

    var body: some View {
        DashboardControlBox(title: "정렬", systemImage: "arrow.up.arrow.down") {
            HStack(spacing: 4) {
                ForEach(DashboardFileSortOption.allCases) { option in
                    DashboardControlChip(
                        title: option.title,
                        isSelected: selection == option,
                        help: option.helpText
                    ) {
                        selection = option
                    }
                }
            }
        }
    }
}

private struct DashboardControlChip: View {
    var title: String
    var isSelected: Bool
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .frame(minWidth: 42)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(isSelected ? Color.accentColor.opacity(0.16) : Color(nsColor: .textBackgroundColor), in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(isSelected ? Color.accentColor.opacity(0.45) : Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private extension Array where Element == DashboardFileItem {
    func sorted(by option: DashboardFileSortOption) -> [DashboardFileItem] {
        sorted { lhs, rhs in
            if option == .recent {
                let leftKLMSTimestamp = lhs.klmsTimestampEpoch ?? Int.min
                let rightKLMSTimestamp = rhs.klmsTimestampEpoch ?? Int.min
                if leftKLMSTimestamp != rightKLMSTimestamp {
                    return leftKLMSTimestamp > rightKLMSTimestamp
                }
                if lhs.isRecent != rhs.isRecent {
                    return lhs.isRecent && !rhs.isRecent
                }
                let leftRecency = lhs.recencySortText
                let rightRecency = rhs.recencySortText
                if leftRecency != rightRecency {
                    return leftRecency.localizedStandardCompare(rightRecency) == .orderedDescending
                }
            }
            let leftKeys = lhs.sortKeys(for: option)
            let rightKeys = rhs.sortKeys(for: option)
            for (left, right) in zip(leftKeys, rightKeys) {
                let comparison = left.localizedStandardCompare(right)
                if comparison != .orderedSame {
                    return comparison == .orderedAscending
                }
            }
            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }
}

private extension DashboardFileItem {
    func sortKeys(for option: DashboardFileSortOption) -> [String] {
        switch option {
        case .course:
            [course.normalizedFileSortKey, title.normalizedFileSortKey, sortPath.normalizedFileSortKey, url]
        case .kind:
            [fileKindLabel.normalizedFileSortKey, course.normalizedFileSortKey, title.normalizedFileSortKey, sortPath.normalizedFileSortKey, url]
        case .name:
            [title.normalizedFileSortKey, course.normalizedFileSortKey, sortPath.normalizedFileSortKey, url]
        case .path:
            [(sortPath.isEmpty ? title : sortPath).normalizedFileSortKey, title.normalizedFileSortKey, course.normalizedFileSortKey, url]
        case .recent:
            [course.normalizedFileSortKey, title.normalizedFileSortKey, sortPath.normalizedFileSortKey, url]
        }
    }

    var recencySortText: String {
        if !recencyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return recencyText
        }
        return isRecent ? "9999-12-31 23:59 KST" : "0000-00-00 00:00 KST"
    }
}

private extension DashboardFileSortOption {
    var helpText: String {
        switch self {
        case .course:
            "과목명, 파일명 순서로 정렬"
        case .kind:
            "공지 첨부, 과제 첨부, 강의 자료 같은 파일 종류별로 정렬"
        case .name:
            "파일명 순서로 정렬"
        case .path:
            "KLMS 상대 경로 순서로 정렬"
        case .recent:
            "KLMS 등록 시각이 최신인 파일을 먼저 정렬"
        }
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

private func fileSortPath(from path: String) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    if let range = trimmed.range(of: "/course_files/") {
        return String(trimmed[range.upperBound...])
    }
    if let range = trimmed.range(of: "course_files/") {
        return String(trimmed[range.upperBound...])
    }
    return trimmed
}

private func fileBucket(from path: String) -> String {
    let components = fileSortPath(from: path)
        .split(separator: "/", omittingEmptySubsequences: true)
        .map(String.init)
    return components.count >= 2 ? components[1] : ""
}

private extension String {
    var normalizedFileSortKey: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ko_KR"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private func fileDisplayTitle(filename: String, relativePath: String) -> String {
    let trimmedFilename = filename.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedFilename.isEmpty {
        return trimmedFilename
    }
    let trimmedRelativePath = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedRelativePath.isEmpty else {
        return ""
    }
    let basename = URL(fileURLWithPath: trimmedRelativePath).lastPathComponent
    return basename.isEmpty ? trimmedRelativePath : basename
}

private enum DashboardFileRowKind {
    case file
    case quarantine
    case pruned
}

private struct HiddenItemsListView: View {
    var filters: DashboardDetailFilters
    @ObservedObject var model: KLMSMacModel
    @State private var visibleLimit = DashboardLargeList.initialVisibleLimit

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
            NoticeListView(filters: filters, defaultCategory: .hidden, model: model)
            hiddenFileRows
        }
    }

    @ViewBuilder
    private var hiddenFileRows: some View {
        let hiddenFileItems = hiddenFiles + hiddenQuarantine
        let visibleItems = Array(hiddenFileItems.prefix(visibleLimit))
        if hiddenFileItems.isEmpty {
            EmptyDetailText(text: "숨긴 파일이 없습니다.")
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(visibleItems) { item in
                    FileRowView(item: item, kind: item.bucket == "quarantine" ? .quarantine : .file, model: model)
                }
                if hiddenFileItems.count > visibleItems.count {
                    DashboardShowMoreButton(remainingCount: hiddenFileItems.count - visibleItems.count) {
                        visibleLimit += DashboardLargeList.increment
                    }
                }
            }
        }
    }

    private var hiddenAssignments: [StateItem] {
        let content = model.snapshot.rawLegacyState?.content ?? model.snapshot.legacyState?.content
        return (
            (content?.assignments ?? [])
                + (content?.assignmentCandidates ?? [])
                + (content?.completedAssignments ?? [])
                + (content?.assignmentRecords ?? [])
                + (content?.helpDeskItems ?? [])
        )
            .filter { model.snapshot.manualOverrides?.isAssignmentHidden($0) == true }
            .dedupedDashboardItems()
    }

    private var hiddenExams: [StateItem] {
        let content = model.snapshot.rawLegacyState?.content ?? model.snapshot.legacyState?.content
        return ((content?.examItems ?? []) + (content?.examCandidates ?? []))
            .filter { model.snapshot.manualOverrides?.isExamHidden($0) == true }
            .filter { !$0.isPastDashboardExamForApp }
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
                sortPath: fileSortPath(from: item.path),
                bucket: fileBucket(from: item.path),
                url: item.url,
                isRecent: item.trashedAt != nil,
                recencyText: item.updatedAt,
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
                sortPath: fileSortPath(from: item.path),
                bucket: "quarantine",
                url: item.url,
                isRecent: item.trashedAt != nil,
                recencyText: item.updatedAt,
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

private extension StateItem {
    var isPastDashboardExamForApp: Bool {
        let normalizedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedCategory == "exam" || normalizedCategory == "exam_candidate" else {
            return false
        }
        let rawDue = syncDue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawDue.isEmpty, let due = ISO8601DateFormatter().date(from: rawDue) else {
            return false
        }
        return due < Date()
    }
}

private struct QuarantineListView: View {
    var filters: DashboardDetailFilters
    @ObservedObject var model: KLMSMacModel
    @State private var sortOption = DashboardFileSortOption.name
    @State private var visibleLimit = DashboardLargeList.initialVisibleLimit

    var body: some View {
        let records = filteredItems
        let sortedRecords = records.sorted(by: sortOption)
        let visibleRecords = Array(sortedRecords.prefix(visibleLimit))
        if records.isEmpty {
            EmptyDetailText(text: filters.hasActiveFilter ? "검색/필터 조건에 맞는 격리 파일이 없습니다. 필터 초기화를 눌러 전체 목록을 보세요." : "격리 파일이 없습니다.")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                FileSortPickerView(selection: $sortOption)
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(visibleRecords) { item in
                        FileRowView(
                            item: item,
                            kind: .quarantine,
                            model: model
                        )
                    }
                    if sortedRecords.count > visibleRecords.count {
                        DashboardShowMoreButton(remainingCount: sortedRecords.count - visibleRecords.count) {
                            visibleLimit += DashboardLargeList.increment
                        }
                    }
                }
                .id(sortOption.rawValue)
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
                sortPath: record.quarantineRelativePath,
                bucket: "quarantine",
                url: record.url,
                isRecent: true,
                recencyText: "",
                interaction: model.snapshot.appUserState?.quarantine[key]
            )
            return item.matches(filters: filters) ? item : nil
        }
    }
}

private struct PrunedListView: View {
    var filters: DashboardDetailFilters
    var snapshot: EngineSnapshot
    @State private var sortOption = DashboardFileSortOption.path
    @State private var visibleLimit = DashboardLargeList.initialVisibleLimit

    var body: some View {
        let deleted = filteredItems
        let sortedDeleted = deleted.sorted(by: sortOption)
        let visibleDeleted = Array(sortedDeleted.prefix(visibleLimit))
        if deleted.isEmpty {
            EmptyDetailText(text: "삭제된 파일 기록이 없습니다.")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                FileSortPickerView(selection: $sortOption)
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(visibleDeleted) { item in
                        FileRowView(
                            item: item,
                            kind: .pruned,
                            model: nil
                        )
                    }
                    if sortedDeleted.count > visibleDeleted.count {
                        DashboardShowMoreButton(remainingCount: sortedDeleted.count - visibleDeleted.count) {
                            visibleLimit += DashboardLargeList.increment
                        }
                    }
                }
                .id(sortOption.rawValue)
            }
        }
    }

    private var filteredItems: [DashboardFileItem] {
        (snapshot.cleanupResult?.actions.filter { $0.action == "deleted" } ?? []).compactMap { action in
            let term = AcademicTerm.infer(title: action.path, dateTexts: [action.path])
            guard DashboardTermFilter.matches(
                term,
                selectedYear: filters.selectedYear,
                selectedSemester: filters.selectedSemester
            ) else {
                return nil
            }
            let query = filters.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard query.isEmpty || [term?.displayName ?? "", action.path].joined(separator: " ").localizedCaseInsensitiveContains(query) else {
                return nil
            }
            return DashboardFileItem(
                key: action.path,
                title: action.path,
                course: action.action,
                academicTerm: term,
                path: action.path,
                sortPath: fileSortPath(from: action.path),
                bucket: fileBucket(from: action.path),
                url: "",
                isRecent: false,
                recencyText: "",
                interaction: nil
            )
        }
    }
}

private struct FileRowView: View {
    var item: DashboardFileItem
    var kind: DashboardFileRowKind
    var model: KLMSMacModel?
    @State private var didRequestSync = false

    var body: some View {
        let hidden = item.isHidden
        let pathExists = !item.path.isEmpty && FileManager.default.fileExists(atPath: item.path)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.title.isEmpty ? "(파일명 없음)" : item.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(2)
                        Label(item.fileKindLabel, systemImage: item.fileKindIcon)
                            .font(.caption2)
                            .foregroundStyle(item.fileKindColor)
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
                if pathExists {
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
            actionBar(hidden: hidden, pathExists: pathExists)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hidden ? Color.orange.opacity(0.10) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func actionBar(hidden: Bool, pathExists: Bool) -> some View {
        if let model, kind != .pruned {
            if didRequestSync {
                MacInlinePendingActionView(message: "파일 동기화 반영을 시작했습니다.")
            } else {
                HStack(spacing: 8) {
                if pathExists {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                    } label: {
                        Label("수정/열기", systemImage: "folder")
                    }
                }
                Button {
                    didRequestSync = true
                    Task { await model.run(.filesSync) }
                } label: {
                    Label("파일 반영", systemImage: KLMSEngineCommand.filesSync.systemImage)
                }
                .disabled(model.runningCommand != nil)
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
                        Label(kind == .quarantine ? "삭제/무시" : "삭제/숨김", systemImage: "eye.slash")
                    }
                }
                if pathExists {
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

private extension DashboardFileItem {
    var fileKindLabel: String {
        switch bucket.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "board-attachments":
            "공지 첨부"
        case "assignment-attachments":
            "과제 첨부"
        case "resources":
            "강의 자료"
        case "folders":
            "폴더 자료"
        case "page-attachments":
            "페이지 첨부"
        case "quarantine":
            "격리"
        case "deleted":
            "삭제 기록"
        case "":
            "기타 파일"
        default:
            bucket
        }
    }

    var fileKindIcon: String {
        switch bucket.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "board-attachments":
            "megaphone"
        case "assignment-attachments":
            "checklist"
        case "resources":
            "books.vertical"
        case "folders":
            "folder"
        case "quarantine":
            "exclamationmark.triangle"
        default:
            "doc"
        }
    }

    var fileKindColor: Color {
        switch bucket.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "board-attachments":
            .purple
        case "assignment-attachments":
            .green
        case "resources", "folders":
            .blue
        case "quarantine":
            .orange
        default:
            .secondary
        }
    }
}

private struct CalendarDetailView: View {
    var snapshot: EngineSnapshot
    var filters: DashboardDetailFilters
    @ObservedObject var model: KLMSMacModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CalendarActionGuideView(
                model: model,
                hasReportedCalendarChanges: hasReportedCalendarChanges
            )

            if let calendar = snapshot.syncReport?.calendar {
                MetricGrid(metrics: [
                    Metric("생성", calendar.created),
                    Metric("수정", calendar.updated),
                    Metric("정리", calendar.deleted),
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
                    model: model,
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

private struct CalendarActionGuideView: View {
    @ObservedObject var model: KLMSMacModel
    var hasReportedCalendarChanges: Bool

    private let columns = [GridItem(.adaptive(minimum: 128), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 28, height: 28)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 3) {
                    Text("캘린더 확인")
                        .font(.caption.weight(.semibold))
                    Text(helpText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            LazyVGrid(columns: columns, spacing: 8) {
                CalendarActionButton(
                    title: "캘린더 열기",
                    systemImage: "calendar",
                    tint: .orange
                ) {
                    openSystemCalendar()
                }
                CalendarActionButton(
                    title: "상태 다시 검사",
                    systemImage: KLMSEngineCommand.verify.systemImage,
                    tint: .blue,
                    disabled: model.runningCommand != nil
                ) {
                    Task { await model.run(.verify) }
                }
                CalendarActionButton(
                    title: "과제/시험 재동기화",
                    systemImage: KLMSEngineCommand.coreSync.systemImage,
                    tint: .green,
                    disabled: model.runningCommand != nil
                ) {
                    Task { await model.run(.coreSync) }
                }
                CalendarActionButton(
                    title: "권한 점검",
                    systemImage: KLMSEngineCommand.doctor.systemImage,
                    tint: .secondary,
                    disabled: model.runningCommand != nil
                ) {
                    Task { await model.run(.doctor) }
                }
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.18), lineWidth: 1)
        }
    }

    private var helpText: String {
        if model.runningCommand != nil {
            return "현재 동기화가 실행 중입니다. 끝난 뒤 캘린더를 다시 검사할 수 있습니다."
        }
        if hasReportedCalendarChanges {
            return "방금 생성, 수정, 정리된 일정을 확인하려면 캘린더를 열어 보세요. 숫자가 맞지 않으면 상태 검사 또는 과제/시험 재동기화를 실행하세요."
        }
        return "캘린더가 비어 있거나 권한 문제가 의심되면 상태 검사와 권한 점검을 먼저 실행하세요."
    }

    private func openSystemCalendar() {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.open(appURL)
        }
    }
}

private struct CalendarActionButton: View {
    var title: String
    var systemImage: String
    var tint: Color
    var disabled = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 30)
        }
        .buttonStyle(.bordered)
        .tint(tint)
        .disabled(disabled)
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
                        Text("정리 \(summary.deleted)")
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
    @ObservedObject var model: KLMSMacModel
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
                        CalendarChangeRowView(change: change, model: model)
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
            guard DashboardTermFilter.matches(
                change.academicTerm,
                selectedYear: filters.selectedYear,
                selectedSemester: filters.selectedSemester
            ) else {
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
    @ObservedObject var model: KLMSMacModel
    @State private var editStatusText: String?
    @State private var isShowingEditSheet = false

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
                    CalendarChangeExplanationView(change: change)
                }
                Spacer(minLength: 8)
            }
            if let editStatusText {
                MacInlinePendingActionView(message: editStatusText)
            } else {
                HStack(spacing: 8) {
                    Button {
                        isShowingEditSheet = true
                    } label: {
                        Label("내용 수정", systemImage: "pencil")
                    }
                    .help("Apple Calendar에 저장된 이 일정의 제목, 시간, 장소를 직접 수정합니다.")
                    Button {
                        openSystemCalendar()
                    } label: {
                        Label("캘린더에서 열기", systemImage: "calendar")
                    }
                    .help("Calendar 앱을 열어 직접 확인, 수정, 삭제합니다.")
                    Spacer()
                }
                .font(.caption)
                .buttonStyle(.bordered)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .sheet(isPresented: $isShowingEditSheet) {
            CalendarEventEditSheet(change: change) { edit in
                editStatusText = "캘린더 내용을 저장하는 중입니다."
                Task {
                    await model.editCalendarEvent(change: change, edit: edit)
                    editStatusText = "캘린더 내용 수정 요청을 처리했습니다."
                }
            }
        }
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

    private func openSystemCalendar() {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.open(appURL)
        }
    }
}

private struct CalendarEventEditSheet: View {
    var change: CalendarChange
    var onSave: (CalendarEventEdit) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var startAt: String
    @State private var dueAt: String
    @State private var location: String

    init(change: CalendarChange, onSave: @escaping (CalendarEventEdit) -> Void) {
        self.change = change
        self.onSave = onSave
        _title = State(initialValue: change.title)
        _startAt = State(initialValue: calendarEditInputDate(change.startAt))
        _dueAt = State(initialValue: calendarEditInputDate(change.dueAt))
        _location = State(initialValue: change.location)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("캘린더 내용 수정")
                .font(.headline)
            Text("Apple Calendar에 저장된 이벤트를 직접 수정합니다. 비워 둔 시간/장소는 변경하지 않습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("제목")
                        .foregroundStyle(.secondary)
                    TextField("일정 제목", text: $title)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("시작")
                        .foregroundStyle(.secondary)
                    TextField("2026-06-17 13:00", text: $startAt)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("종료")
                        .foregroundStyle(.secondary)
                    TextField("2026-06-17 16:00", text: $dueAt)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("장소")
                        .foregroundStyle(.secondary)
                    TextField("장소", text: $location)
                        .textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Spacer()
                Button("취소") {
                    dismiss()
                }
                Button("저장") {
                    onSave(CalendarEventEdit(title: title, startAt: startAt, dueAt: dueAt, location: location))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 520)
    }
}

private struct CalendarChangeExplanationView: View {
    var change: CalendarChange

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(change.explanationText, systemImage: "info.circle")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(change.nextActionText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(change.actionButtonHelpText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.orange.opacity(0.14), lineWidth: 1)
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

private func calendarEditInputDate(_ text: String) -> String {
    guard let date = parseCalendarDetailDate(text) else { return text }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ko_KR")
    formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
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
