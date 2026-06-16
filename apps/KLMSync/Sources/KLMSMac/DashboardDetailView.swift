import KLMSShared
import AppKit
import SwiftUI

private let dashboardDetailExpansionDelayNanoseconds: UInt64 = 45_000_000

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
            "정리된 파일"
        case .calendar:
            "캘린더"
        case .hidden:
            "보관함"
        }
    }
}

struct DashboardRenderSignature: Equatable {
    private var value: Int

    init(snapshot: EngineSnapshot, summary: KLMSMacDashboardSummaryCache) {
        var hasher = Hasher()
        hasher.combine(summary.visibleCounts.assignments)
        hasher.combine(summary.visibleCounts.exams)
        hasher.combine(summary.visibleCounts.helpDesk)
        hasher.combine(summary.visibleCounts.notices)
        hasher.combine(summary.visibleCounts.newFiles)
        hasher.combine(summary.visibleCounts.quarantine)
        hasher.combine(summary.hiddenSummary.total)
        hasher.combine(summary.assignmentCandidateCount)
        hasher.combine(summary.examCandidateCount)
        hasher.combine(summary.localMissingFileCount)
        hasher.combine(summary.prunedFileCount)
        hasher.combine(summary.calendarAttentionCount)
        hasher.combine(summary.mailAssignmentCount)
        hasher.combine(summary.mailExamCount)
        Self.combineStateItems(snapshot.legacyState?.content.assignments, into: &hasher)
        Self.combineStateItems(snapshot.legacyState?.content.completedAssignments, into: &hasher)
        Self.combineStateItems(snapshot.legacyState?.content.assignmentCandidates, into: &hasher)
        Self.combineStateItems(snapshot.legacyState?.content.examItems, into: &hasher)
        Self.combineStateItems(snapshot.legacyState?.content.examCandidates, into: &hasher)
        Self.combineStateItems(snapshot.legacyState?.content.helpDeskItems, into: &hasher)
        Self.combineNotices(snapshot.noticeDigest?.notices, generatedAt: snapshot.noticeDigest?.generatedAt ?? "", into: &hasher)
        Self.combineFiles(snapshot.courseFileManifest, into: &hasher)
        Self.combineCalendar(snapshot.calendarSyncResult?.changes, into: &hasher)
        Self.combineNoticeInteractions(snapshot.noticeUserState?.notices ?? [:], into: &hasher)
        Self.combineFileInteractions(snapshot.appUserState?.files ?? [:], into: &hasher)
        Self.combineFileInteractions(snapshot.appUserState?.quarantine ?? [:], into: &hasher)
        hasher.combine(snapshot.verifyResult?.status ?? "")
        hasher.combine(snapshot.verifyResult?.files?.missingFileCount ?? 0)
        hasher.combine(snapshot.syncReport?.status ?? "")
        value = hasher.finalize()
    }

    private static func combineStateItems(_ items: [StateItem]?, into hasher: inout Hasher) {
        let items = items ?? []
        hasher.combine(items.count)
        for item in Array(items.prefix(3)) + Array(items.suffix(3)) {
            hasher.combine(item.id)
            hasher.combine(item.title)
            hasher.combine(item.due)
            hasher.combine(item.category)
        }
    }

    private static func combineNotices(_ notices: [NoticeDigestEntry]?, generatedAt: String, into hasher: inout Hasher) {
        let notices = notices ?? []
        hasher.combine(generatedAt)
        hasher.combine(notices.count)
        for notice in Array(notices.prefix(3)) + Array(notices.suffix(3)) {
            hasher.combine(notice.id)
            hasher.combine(notice.title)
            hasher.combine(notice.fingerprint)
            hasher.combine(notice.changeState)
        }
    }

    private static func combineFiles(_ files: [CourseFileManifestEntry], into hasher: inout Hasher) {
        hasher.combine(files.count)
        for file in Array(files.prefix(4)) + Array(files.suffix(4)) {
            hasher.combine(file.id)
            hasher.combine(file.relativePath)
            hasher.combine(file.localDownloadedAt)
            hasher.combine(file.klmsTimestampEpoch ?? -1)
        }
    }

    private static func combineCalendar(_ changes: [CalendarChange]?, into hasher: inout Hasher) {
        let changes = changes ?? []
        hasher.combine(changes.count)
        for change in Array(changes.prefix(3)) + Array(changes.suffix(3)) {
            hasher.combine(change.id)
            hasher.combine(change.action)
            hasher.combine(change.title)
        }
    }

    private static func combineNoticeInteractions(_ states: [String: NoticeInteractionState], into hasher: inout Hasher) {
        hasher.combine(states.count)
        for key in states.keys.sorted().prefix(80) {
            guard let state = states[key] else { continue }
            hasher.combine(key)
            hasher.combine(state.readFingerprint ?? "")
            hasher.combine(state.readAt ?? "")
            hasher.combine(state.important)
            hasher.combine(state.hidden)
            hasher.combine(state.updatedAt)
        }
    }

    private static func combineFileInteractions(_ states: [String: FileInteractionState], into hasher: inout Hasher) {
        hasher.combine(states.count)
        for key in states.keys.sorted().prefix(80) {
            guard let state = states[key] else { continue }
            hasher.combine(key)
            hasher.combine(state.hidden)
            hasher.combine(state.ignored)
            hasher.combine(state.trashedAt ?? "")
            hasher.combine(state.updatedAt)
        }
    }
}

struct DashboardDetailPanelView: View, @preconcurrency Equatable {
    var kind: DashboardDetailKind
    var model: KLMSMacModel
    var snapshot: EngineSnapshot
    private var renderSignature: DashboardRenderSignature
    @State private var searchText = ""
    @State private var selectedCourse = DashboardCourseFilter.all
    @State private var selectedYear = DashboardTermFilter.allYears
    @State private var selectedSemester = DashboardTermFilter.allSemesters
    @State private var showHidden = false
    @State private var newOnly = false
    @State private var recentOnly = false
    @State private var fileData: DashboardFileData?
    @State private var fileDataSignature: DashboardFileData.Signature?
    @State private var fileDataTask: Task<Void, Never>?

    init(
        kind: DashboardDetailKind,
        model: KLMSMacModel,
        snapshot: EngineSnapshot? = nil,
        renderSignature: DashboardRenderSignature? = nil
    ) {
        let resolvedSnapshot = snapshot ?? model.snapshot
        self.kind = kind
        self.model = model
        self.snapshot = resolvedSnapshot
        self.renderSignature = renderSignature
            ?? DashboardRenderSignature(snapshot: resolvedSnapshot, summary: model.dashboardSummaryCache)
        _fileData = State(initialValue: nil)
        _fileDataSignature = State(initialValue: nil)
    }

    static func == (lhs: DashboardDetailPanelView, rhs: DashboardDetailPanelView) -> Bool {
        lhs.kind == rhs.kind && lhs.renderSignature == rhs.renderSignature
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(kind.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.klmsMacSecondaryText)
                Spacer()
                if hiddenCount > 0, kind != .hidden {
                    Text("보관 \(hiddenCount)")
                        .font(.caption2)
                        .foregroundStyle(Color.klmsMacSecondaryText)
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
                    items: ((snapshot.legacyState?.content.assignments ?? []) + model.mailDashboardStateItems(kind: "assignment")).dedupedDashboardItems(),
                    emptyText: "과제가 없습니다.",
                    editor: .assignment,
                    filters: filters,
                    snapshot: snapshot,
                    model: model
                )
            case .assignmentRecords:
                StateItemListView(
                    items: snapshot.legacyState?.content.completedAssignments ?? [],
                    emptyText: "완료 기록이 없습니다.",
                    editor: .assignmentRecord,
                    filters: filters,
                    snapshot: snapshot,
                    model: model
                )
            case .assignmentCandidates:
                StateItemListView(
                    items: snapshot.legacyState?.content.assignmentCandidates ?? [],
                    emptyText: "과제 후보가 없습니다.",
                    editor: .assignment,
                    filters: filters,
                    snapshot: snapshot,
                    model: model
                )
            case .exams:
                StateItemListView(
                    items: ((snapshot.legacyState?.content.examItems ?? []) + model.mailDashboardStateItems(kind: "exam")).dedupedDashboardItems(),
                    emptyText: "시험 항목이 없습니다.",
                    editor: .exam,
                    filters: filters,
                    snapshot: snapshot,
                    model: model
                )
            case .examCandidates:
                StateItemListView(
                    items: snapshot.legacyState?.content.examCandidates ?? [],
                    emptyText: "시험 후보가 없습니다.",
                    editor: .exam,
                    filters: filters,
                    snapshot: snapshot,
                    model: model
                )
            case .helpDesk:
                StateItemListView(
                    items: snapshot.legacyState?.content.helpDeskItems ?? [],
                    emptyText: "헬프데스크 항목이 없습니다.",
                    editor: .assignment,
                    filters: filters,
                    snapshot: snapshot,
                    model: model
                )
            case .notices:
                NoticeListView(filters: filters, snapshot: snapshot, model: model)
            case .files:
                if let fileData {
                    FileManifestListView(files: fileData.manifestFiles, filters: filters, model: model)
                } else {
                    fileDataLoadingView
                }
            case .missingFiles:
                if let fileData {
                    MissingFilesListView(files: fileData.missingFiles, filters: filters, model: model)
                } else {
                    fileDataLoadingView
                }
            case .newFiles:
                if let fileData {
                    NewFilesListView(files: fileData.newFiles, filters: filters, model: model)
                } else {
                    fileDataLoadingView
                }
            case .quarantine:
                if let fileData {
                    QuarantineListView(files: fileData.quarantineFiles, filters: filters, model: model)
                } else {
                    fileDataLoadingView
                }
            case .pruned:
                PrunedListView(filters: filters, snapshot: snapshot)
            case .calendar:
                CalendarDetailView(snapshot: snapshot, filters: filters, model: model)
            case .hidden:
                if let fileData {
                    HiddenItemsListView(
                        filters: filters,
                        hiddenFileItems: fileData.hiddenFiles,
                        hiddenQuarantineItems: fileData.hiddenQuarantineFiles,
                        snapshot: snapshot,
                        model: model
                    )
                } else {
                    fileDataLoadingView
                }
            }
        }
        .padding(10)
        .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.klmsMacBorder, lineWidth: 1)
        }
        .onChange(of: currentFileDataSignature) { _, signature in
            rebuildFileDataIfNeeded(signature)
        }
        .onAppear {
            rebuildFileDataIfNeeded(currentFileDataSignature)
        }
        .onDisappear {
            fileDataTask?.cancel()
        }
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
        DashboardCourseFilter.options(for: kind, snapshot: snapshot)
    }

    private var yearOptions: [String] {
        DashboardTermFilter.yearOptions(for: kind, snapshot: snapshot)
    }

    private var semesterOptions: [String] {
        DashboardTermFilter.semesterOptions(for: kind, snapshot: snapshot)
    }

    private var hiddenCount: Int {
        snapshot.hiddenSummary.total
    }

    private var currentFileDataSignature: DashboardFileData.Signature? {
        guard kind.requiresFileData else {
            return nil
        }
        return DashboardFileData.Signature(snapshot: snapshot)
    }

    private func rebuildFileDataIfNeeded(_ signature: DashboardFileData.Signature?) {
        guard let signature else {
            fileDataTask?.cancel()
            fileData = nil
            fileDataSignature = nil
            return
        }
        guard fileDataSignature != signature || fileData == nil else {
            return
        }
        let snapshot = snapshot
        fileDataTask?.cancel()
        fileData = nil
        fileDataSignature = signature
        fileDataTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            let data = await Task.detached(priority: .userInitiated) {
                DashboardFileData(snapshot: snapshot, signature: signature)
            }.value
            guard !Task.isCancelled else { return }
            fileData = data
        }
    }

    private var fileDataLoadingView: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 3) {
                Text("파일 목록을 준비하고 있습니다.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.klmsMacPrimaryText)
                Text("파일 수가 많아도 클릭 반응이 멈추지 않도록 목록 가공을 분리했습니다.")
                    .font(.caption2)
                    .foregroundStyle(Color.klmsMacSecondaryText)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.klmsMacBorder, lineWidth: 1)
        }
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
    static let initialVisibleLimit = 6
    static let increment = 10
}

private struct DashboardFileData: Sendable {
    var signature: Signature
    var manifestFiles: [DashboardFileItem]
    var newFiles: [DashboardFileItem]
    var missingFiles: [DashboardFileItem]
    var quarantineFiles: [DashboardFileItem]
    var hiddenFiles: [DashboardFileItem]
    var hiddenQuarantineFiles: [DashboardFileItem]

    init(snapshot: EngineSnapshot, signature: Signature? = nil) {
        let resolvedSignature = signature ?? Signature(snapshot: snapshot)
        let missingPaths = dashboardMissingPathSet(from: snapshot)
        let appFileState = snapshot.appUserState?.files ?? [:]
        let appQuarantineState = snapshot.appUserState?.quarantine ?? [:]
        let recentKeys = Self.recentFileKeys(snapshot: snapshot)
        let manifestLookup = Self.manifestLookup(snapshot.courseFileManifest)

        self.signature = resolvedSignature
        manifestFiles = snapshot.courseFileManifest.map { entry in
            let key = fileKey(url: entry.url, path: entry.absolutePath, fallback: entry.relativePath)
            return DashboardFileItem(
                key: key,
                title: fileDisplayTitle(filename: entry.filename, relativePath: entry.relativePath),
                course: entry.course,
                academicTerm: entry.academicTerm,
                path: entry.absolutePath,
                sortPath: entry.relativePath,
                bucket: entry.bucket,
                url: entry.url,
                isRecent: recentKeys.contains(entry.url) || recentKeys.contains(entry.relativePath),
                recencyText: entry.localDownloadedAt,
                klmsTimestampEpoch: entry.klmsTimestampEpoch,
                pathExists: dashboardPathExists(path: entry.absolutePath, missingPaths: missingPaths),
                interaction: appFileState[key]
            )
        }

        newFiles = (snapshot.downloadResult?.results.filter(\.copiedToNewFilesInbox) ?? []).map { item in
            let manifest = (!item.url.isEmpty ? manifestLookup.byURL[item.url] : nil)
                ?? manifestLookup.byRelativePath[item.relativePath]
            let key = fileKey(url: item.url, path: manifest?.absolutePath ?? "", fallback: item.relativePath)
            return DashboardFileItem(
                key: key,
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
                pathExists: dashboardPathExists(path: manifest?.absolutePath ?? "", missingPaths: missingPaths),
                interaction: appFileState[key]
            )
        }

        missingFiles = (snapshot.verifyResult?.files?.missingFiles ?? []).map { path in
            let relativePath = Self.normalizedMissingFilePath(path)
            let key = fileKey(url: "", path: path, fallback: relativePath)
            let title = fileDisplayTitle(filename: URL(fileURLWithPath: relativePath).lastPathComponent, relativePath: relativePath)
            let course = relativePath.split(separator: "/", omittingEmptySubsequences: true).first.map(String.init) ?? ""
            return DashboardFileItem(
                key: key,
                title: title,
                course: course,
                academicTerm: AcademicTerm.infer(title: relativePath, dateTexts: [relativePath, path]),
                path: path,
                sortPath: relativePath,
                bucket: fileBucket(from: relativePath),
                url: "",
                isRecent: true,
                recencyText: "",
                pathExists: false,
                interaction: appFileState[key]
            )
        }

        quarantineFiles = (snapshot.quarantineReport?.records ?? []).map { record in
            let key = fileKey(url: record.url, path: record.quarantinePath, fallback: record.quarantineRelativePath)
            return DashboardFileItem(
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
                pathExists: !record.quarantinePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                interaction: appQuarantineState[key]
            )
        }

        hiddenFiles = appFileState.compactMap { key, item in
            guard item.isHiddenLike else { return nil }
            return DashboardFileItem(
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
                pathExists: dashboardPathExists(path: item.path, missingPaths: missingPaths),
                interaction: item
            )
        }

        hiddenQuarantineFiles = appQuarantineState.compactMap { key, item in
            guard item.isHiddenLike else { return nil }
            return DashboardFileItem(
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
                pathExists: !item.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                interaction: item
            )
        }
    }

    struct Signature: Equatable, Sendable {
        private var value: Int

        init(snapshot: EngineSnapshot) {
            var hasher = Hasher()
            for entry in snapshot.courseFileManifest {
                hasher.combine(entry.id)
                hasher.combine(entry.absolutePath)
                hasher.combine(entry.localDownloadedAt)
                hasher.combine(entry.klmsTimestampEpoch ?? -1)
                hasher.combine(entry.bucket)
            }
            for item in snapshot.downloadResult?.results ?? [] {
                hasher.combine(item.id)
                hasher.combine(item.copiedToNewFilesInbox)
                hasher.combine(item.skippedExisting)
                hasher.combine(item.restoredFromArchive)
                hasher.combine(item.reusedLoggedFile)
                hasher.combine(item.failed)
                hasher.combine(item.quarantined)
            }
            for path in snapshot.verifyResult?.files?.missingFiles ?? [] {
                hasher.combine(path)
            }
            for record in snapshot.quarantineReport?.records ?? [] {
                hasher.combine(record.id)
                hasher.combine(record.url)
                hasher.combine(record.bytes)
            }
            for (key, item) in (snapshot.appUserState?.files ?? [:]).sorted(by: { $0.key < $1.key }) {
                DashboardFileData.combineInteractionState(key: key, item: item, into: &hasher)
            }
            for (key, item) in (snapshot.appUserState?.quarantine ?? [:]).sorted(by: { $0.key < $1.key }) {
                DashboardFileData.combineInteractionState(key: key, item: item, into: &hasher)
            }
            value = hasher.finalize()
        }
    }

    private static func manifestLookup(_ manifest: [CourseFileManifestEntry]) -> (
        byURL: [String: CourseFileManifestEntry],
        byRelativePath: [String: CourseFileManifestEntry]
    ) {
        var byURL: [String: CourseFileManifestEntry] = [:]
        var byRelativePath: [String: CourseFileManifestEntry] = [:]
        for entry in manifest {
            if !entry.url.isEmpty {
                byURL[entry.url] = entry
            }
            if !entry.relativePath.isEmpty {
                byRelativePath[entry.relativePath] = entry
            }
        }
        return (byURL, byRelativePath)
    }

    private static func recentFileKeys(snapshot: EngineSnapshot) -> Set<String> {
        var keys = Set<String>()
        for result in snapshot.downloadResult?.results ?? [] {
            let isRecent = result.copiedToNewFilesInbox
                || (!result.skippedExisting
                    && !result.restoredFromArchive
                    && !result.reusedLoggedFile
                    && !result.failed
                    && !result.quarantined)
            guard isRecent else {
                continue
            }
            if !result.url.isEmpty {
                keys.insert(result.url)
            }
            if !result.relativePath.isEmpty {
                keys.insert(result.relativePath)
            }
        }
        return keys
    }

    private static func normalizedMissingFilePath(_ path: String) -> String {
        let marker = "/KLMSNotesSync/course_files/"
        if let range = path.range(of: marker) {
            return String(path[range.upperBound...])
        }
        return path
    }

    private static func combineInteractionState(key: String, item: FileInteractionState, into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(item.title)
        hasher.combine(item.course)
        hasher.combine(item.path)
        hasher.combine(item.url)
        hasher.combine(item.hidden)
        hasher.combine(item.ignored)
        hasher.combine(item.trashedAt ?? "")
        hasher.combine(item.updatedAt)
    }
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
        .buttonStyle(KLMSMacActionButtonStyle())
    }
}

private struct DeferredDashboardExpansion<Content: View>: View {
    var isExpanded: Bool
    var delayNanoseconds = dashboardDetailExpansionDelayNanoseconds
    private let content: () -> Content
    @State private var isVisible = false
    @State private var deferredTask: Task<Void, Never>?

    init(
        isExpanded: Bool,
        delayNanoseconds: UInt64 = dashboardDetailExpansionDelayNanoseconds,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.isExpanded = isExpanded
        self.delayNanoseconds = delayNanoseconds
        self.content = content
    }

    var body: some View {
        Group {
            if isVisible {
                content()
            }
        }
        .onAppear {
            updateVisibility(isExpanded)
        }
        .onChange(of: isExpanded) { _, newValue in
            updateVisibility(newValue)
        }
        .onDisappear {
            deferredTask?.cancel()
        }
    }

    private func updateVisibility(_ expanded: Bool) {
        deferredTask?.cancel()
        guard expanded else {
            isVisible = false
            return
        }
        deferredTask = Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            isVisible = true
        }
    }
}

private struct DashboardRowDisclosureButton: View {
    @Binding var isExpanded: Bool
    var collapsedTitle = "작업"
    var expandedTitle = "접기"

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            Label(isExpanded ? expandedTitle : collapsedTitle, systemImage: isExpanded ? "chevron.up" : "chevron.down")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(KLMSMacActionButtonStyle())
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
    var requiresFileData: Bool {
        switch self {
        case .files, .missingFiles, .newFiles, .quarantine, .hidden:
            true
        default:
            false
        }
    }

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
            searchControl
            rangeControl
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
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    yearPickerField
                    semesterPickerField
                }
                coursePickerField
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
                    .buttonStyle(KLMSMacActionButtonStyle())
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
                .foregroundStyle(Color.klmsMacSecondaryText)
            content
        }
        .padding(10)
        .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.klmsMacBorder, lineWidth: 1)
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
                .foregroundStyle(Color.klmsMacSecondaryText)
            content
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(minWidth: minWidth, alignment: .leading)
        .background(Color.klmsMacCardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.klmsMacBorder.opacity(disabled ? 0.45 : 1), lineWidth: 1)
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
    var snapshot: EngineSnapshot
    var model: KLMSMacModel
    @State private var visibleLimit = DashboardLargeList.initialVisibleLimit

    var body: some View {
        let visibleItems = filteredItems
        let renderedItems = visibleItems.prefix(visibleLimit)
        if visibleItems.isEmpty {
            EmptyDetailText(text: filters.hasActiveFilter ? "검색/필터 조건에 맞는 항목이 없습니다. 필터 초기화를 눌러 전체 목록을 보세요." : emptyText)
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(renderedItems) { item in
                    StateItemRowView(item: item, editor: editor, snapshot: snapshot, model: model)
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
            snapshot.manualOverrides?.isAssignmentHidden(item) == true
        case .exam:
            snapshot.manualOverrides?.isExamHidden(item) == true
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
    var snapshot: EngineSnapshot
    var model: KLMSMacModel
    @State private var didRequestSync = false
    @State private var isExpanded = false

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
                                .foregroundStyle(Color.klmsMacSecondaryText)
                        }
                        if editor == .assignmentRecord, !item.recordDisplayStatus.isEmpty {
                            Text(item.recordDisplayStatus)
                                .font(.caption2)
                                .foregroundStyle(item.recordStatus == "completed" ? Color.klmsMacSuccessBorder : Color.klmsMacSecondaryText)
                        }
                    }
                    Text([item.academicTerm?.displayName ?? "", item.course, item.due].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(Color.klmsMacSecondaryText)
                        .lineLimit(2)
                    if !item.location.isEmpty || !item.coverageSummary.isEmpty {
                        Text([item.location, item.coverageSummary].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(Color.klmsMacSecondaryText)
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
                    .buttonStyle(KLMSMacIconButtonStyle())
                }
                DashboardRowDisclosureButton(isExpanded: $isExpanded)
            }

            DeferredDashboardExpansion(isExpanded: isExpanded) {
                DashboardActionCaption("수정")
                switch editor {
                case .assignment:
                    AssignmentOverridePicker(item: item, snapshot: snapshot, model: model)
                case .assignmentRecord:
                    RecordStatusView(item: item)
                case .exam:
                    ExamOverrideEditor(
                        item: item,
                        override: snapshot.manualOverrides?.examOverride(for: item) ?? ExamOverride(),
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
                        .buttonStyle(KLMSMacActionButtonStyle(tone: .success))
                        .disabled(isHidden)
                    }
                    Button {
                        didRequestSync = true
                        Task { await model.run(.coreSync) }
                    } label: {
                        Label("동기화 반영", systemImage: KLMSEngineCommand.coreSync.systemImage)
                    }
                    .buttonStyle(KLMSMacActionButtonStyle(tone: .primary))
                    .disabled(model.runningCommand != nil)
                    if editor == .assignmentRecord, isManualCompleted {
                        Button {
                            clearCompletion()
                        } label: {
                            Label("완료 해제", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(KLMSMacActionButtonStyle())
                    }
                    if hidden {
                        Button {
                            restoreHidden()
                        } label: {
                            Label("복구", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(KLMSMacActionButtonStyle())
                    } else if editor != .assignmentRecord || isManualCompleted {
                        Button {
                            hide()
                        } label: {
                            Label(editor == .exam ? "삭제/시험 아님" : "삭제/숨김", systemImage: "eye.slash")
                        }
                        .buttonStyle(KLMSMacActionButtonStyle(tone: .destructive))
                    }
                    Spacer()
                    }
                    .font(.caption)
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hidden ? Color.klmsMacWarningBackground : Color.klmsMacCardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(hidden ? Color.klmsMacWarningBorder : Color.klmsMacBorder, lineWidth: 1)
        }
    }

    private var isHidden: Bool {
        switch editor {
        case .assignment, .assignmentRecord:
            snapshot.manualOverrides?.isAssignmentHidden(item) == true
        case .exam:
            snapshot.manualOverrides?.isExamHidden(item) == true
        }
    }

    private var isManualCompleted: Bool {
        let overrideStatus = snapshot.manualOverrides?.assignmentStatus(for: item) ?? ""
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
        var override = snapshot.manualOverrides?.examOverride(for: item) ?? ExamOverride()
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
                .foregroundStyle(item.recordStatus == "completed" ? Color.klmsMacSuccessBorder : Color.klmsMacSecondaryText)
            if !item.submission.isEmpty {
                Text(item.submission)
                    .font(.caption2)
                    .foregroundStyle(Color.klmsMacSecondaryText)
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
    var snapshot: EngineSnapshot
    var model: KLMSMacModel

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
                snapshot.manualOverrides?.assignmentStatus(for: item) ?? ""
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
            .foregroundStyle(Color.klmsMacSecondaryText)
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
                .foregroundStyle(Color.klmsMacSecondaryText)
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.klmsMacBorder, lineWidth: 1)
        }
    }
}

private struct ExamOverrideEditor: View {
    var item: StateItem
    var override: ExamOverride
    var model: KLMSMacModel
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
                        .foregroundStyle(Color.klmsMacSecondaryText)
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
    var snapshot: EngineSnapshot
    var model: KLMSMacModel
    @State private var category: NoticeListCategory
    @State private var visibleLimit = DashboardLargeList.initialVisibleLimit

    init(
        filters: DashboardDetailFilters,
        defaultCategory: NoticeListCategory = .all,
        snapshot: EngineSnapshot,
        model: KLMSMacModel
    ) {
        self.filters = filters
        self.snapshot = snapshot
        self.model = model
        _category = State(initialValue: defaultCategory)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NoticeCategoryPickerView(
                category: $category,
                snapshot: snapshot,
                hiddenOnly: filters.hiddenOnly
            )
            noticeRows
        }
    }

    @ViewBuilder
    private var noticeRows: some View {
        let notices = filteredNotices
        let renderedNotices = notices.prefix(visibleLimit)
        if notices.isEmpty {
            EmptyDetailText(text: filters.hasActiveFilter ? "검색/필터 조건에 맞는 공지가 없습니다. 필터 초기화를 눌러 전체 목록을 보세요." : "공지 목록이 없습니다.")
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(renderedNotices) { notice in
                    NoticeRowView(notice: notice, snapshot: snapshot, model: model)
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
        let state = snapshot.noticeUserState?.notices ?? [:]
        let generatedAt = snapshot.noticeDigest?.generatedAt ?? ""
        return (snapshot.noticeDigest?.notices ?? []).filter { notice in
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
    var snapshot: EngineSnapshot
    var model: KLMSMacModel
    @State private var didRequestSync = false
    @State private var isExpanded = false

    var body: some View {
        let hidden = snapshot.noticeUserState?.notices[notice.noticeIdentifier]?.hidden == true
        let fresh = notice.changeState == "new" || notice.changeState == "updated"
        let term = notice.academicTerm(generatedAt: snapshot.noticeDigest?.generatedAt ?? "")
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
                                .foregroundStyle(Color.klmsMacCommandAccent)
                        }
                        if hidden {
                            Label("숨김", systemImage: "eye.slash")
                                .font(.caption2)
                                .foregroundStyle(Color.klmsMacSecondaryText)
                        }
                    }
                    Text([term?.displayName ?? "", notice.course, notice.postedAt, notice.changeState].filter { !$0.isEmpty }.joined(separator: " · ").klmsDisplayText)
                        .font(.caption2)
                        .foregroundStyle(Color.klmsMacSecondaryText)
                }
                Spacer(minLength: 8)
                if !notice.url.isEmpty {
                    Button {
                        openExternalURL(notice.url)
                    } label: {
                        Image(systemName: "safari")
                    }
                    .help("공지 열기")
                    .buttonStyle(KLMSMacIconButtonStyle())
                }
                DashboardRowDisclosureButton(isExpanded: $isExpanded)
            }

            DeferredDashboardExpansion(isExpanded: isExpanded) {
                if !notice.summary.isEmpty {
                    Text(notice.summary.klmsDisplayText)
                        .font(.caption2)
                        .foregroundStyle(Color.klmsMacSecondaryText)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }

                let attachments = attachmentDisplays
                if !attachments.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("첨부 파일")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.klmsMacSecondaryText)
                        ForEach(attachments) { attachment in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: attachment.path.isEmpty ? "paperclip" : "doc")
                                    .font(.caption2)
                                    .foregroundStyle(Color.klmsMacSecondaryText)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(attachment.name.klmsDisplayText)
                                        .font(.caption2)
                                        .lineLimit(2)
                                    if !attachment.path.isEmpty {
                                        Text(attachment.path.klmsDisplayText)
                                            .font(.caption2)
                                            .foregroundStyle(Color.klmsMacSecondaryText)
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
                                    .buttonStyle(KLMSMacIconButtonStyle())
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
                        .buttonStyle(KLMSMacActionButtonStyle(tone: .primary))
                        .disabled(model.runningCommand != nil)
                        Button {
                            model.setNoticeHidden(!hidden, for: notice)
                        } label: {
                            Label(hidden ? "복구" : "삭제/숨김", systemImage: hidden ? "arrow.uturn.backward" : "eye.slash")
                        }
                        .buttonStyle(KLMSMacActionButtonStyle(tone: hidden ? .soft : .destructive))
                        Spacer()
                    }
                    .font(.caption)
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(hidden: hidden, fresh: fresh), in: RoundedRectangle(cornerRadius: 8))
    }

    private var readBinding: Binding<Bool> {
        Binding(
            get: {
                guard let state = snapshot.noticeUserState?.notices[notice.noticeIdentifier] else {
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
                snapshot.noticeUserState?.notices[notice.noticeIdentifier]?.important == true
            },
            set: { value in
                model.setNoticeImportant(value, for: notice)
            }
        )
    }

    private var hiddenBinding: Binding<Bool> {
        Binding(
            get: {
                snapshot.noticeUserState?.notices[notice.noticeIdentifier]?.hidden == true
            },
            set: { value in
                model.setNoticeHidden(value, for: notice)
            }
        )
    }

    private func rowBackground(hidden: Bool, fresh: Bool) -> Color {
        if hidden {
            return Color.klmsMacWarningBackground
        }
        if fresh {
            return Color.klmsMacSubtleAccentBackground
        }
        return Color.klmsMacCardBackground
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
    var files: [DashboardFileItem]
    var filters: DashboardDetailFilters
    var model: KLMSMacModel
    @State private var sortOption = DashboardFileSortOption.recent
    @State private var visibleLimit = DashboardLargeList.initialVisibleLimit

    var body: some View {
        let filteredFiles = files.filter { $0.matches(filters: filters) }
        let sortedFiles = filteredFiles.sorted(by: sortOption)
        let visibleFiles = sortedFiles.prefix(visibleLimit)
        if filteredFiles.isEmpty {
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
}

private struct FileManifestListView: View {
    var files: [DashboardFileItem]
    var filters: DashboardDetailFilters
    var model: KLMSMacModel
    @State private var sortOption = DashboardFileSortOption.recent
    @State private var visibleLimit = DashboardLargeList.initialVisibleLimit

    var body: some View {
        let filteredFiles = files.filter { $0.matches(filters: filters) }
        let sortedFiles = filteredFiles.sorted(by: sortOption)
        let visibleFiles = sortedFiles.prefix(visibleLimit)
        if filteredFiles.isEmpty {
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
}

private struct MissingFilesListView: View {
    var files: [DashboardFileItem]
    var filters: DashboardDetailFilters
    var model: KLMSMacModel
    @State private var sortOption = DashboardFileSortOption.recent
    @State private var visibleLimit = DashboardLargeList.initialVisibleLimit

    var body: some View {
        let filteredFiles = files.filter { $0.matches(filters: filters) }
        let sortedFiles = filteredFiles.sorted(by: sortOption)
        let visibleFiles = sortedFiles.prefix(visibleLimit)
        if filteredFiles.isEmpty {
            EmptyDetailText(text: filters.hasActiveFilter ? "검색/필터 조건에 맞는 누락 파일이 없습니다. 필터 초기화를 눌러 전체 목록을 보세요." : "로컬에서 누락된 파일이 없습니다.")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("파일 목록에는 있지만 현재 로컬 저장 위치에 없는 항목입니다. 파일 동기화를 실행하면 archive/log에서 복구하거나, 없으면 KLMS에서 다시 받습니다.")
                    .font(.caption)
                    .foregroundStyle(Color.klmsMacSecondaryText)
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
    var pathExists: Bool = false
    var interaction: FileInteractionState?
    private var searchBlob: String = ""
    private var courseSortKey: String = ""
    private var titleSortKey: String = ""
    private var pathSortKey: String = ""
    private var kindSortKey: String = ""
    private var recencySortKey: String = ""
    var fileKindLabel: String = ""
    var fileKindIcon: String = ""
    var fileKindColor: Color = .klmsMacSecondaryText

    init(
        key: String,
        title: String,
        course: String,
        academicTerm: AcademicTerm?,
        path: String,
        sortPath: String,
        bucket: String,
        url: String,
        isRecent: Bool,
        recencyText: String,
        klmsTimestampEpoch: Int? = nil,
        pathExists: Bool = false,
        interaction: FileInteractionState?
    ) {
        self.key = key
        self.title = title
        self.course = course
        self.academicTerm = academicTerm
        self.path = path
        self.sortPath = sortPath
        self.bucket = bucket
        self.url = url
        self.isRecent = isRecent
        self.recencyText = recencyText
        self.klmsTimestampEpoch = klmsTimestampEpoch
        self.pathExists = pathExists
        self.interaction = interaction
        searchBlob = [academicTerm?.displayName ?? "", title, course, path, url]
            .joined(separator: " ")
        courseSortKey = course.normalizedFileSortKey
        titleSortKey = title.normalizedFileSortKey
        pathSortKey = (sortPath.isEmpty ? title : sortPath).normalizedFileSortKey
        let kind = DashboardFileKindStyle(bucket: bucket)
        kindSortKey = kind.label.normalizedFileSortKey
        fileKindLabel = kind.label
        fileKindIcon = kind.icon
        fileKindColor = kind.color
        let trimmedRecency = recencyText.trimmingCharacters(in: .whitespacesAndNewlines)
        recencySortKey = trimmedRecency.isEmpty
            ? (isRecent ? "9999-12-31 23:59 KST" : "0000-00-00 00:00 KST")
            : trimmedRecency
    }

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
        return searchBlob.localizedCaseInsensitiveContains(query)
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
                .foregroundStyle(isSelected ? Color.klmsMacSelectedForeground : Color.klmsMacPrimaryText)
                .frame(minWidth: 42)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(isSelected ? Color.klmsMacSelectedBackground.opacity(0.96) : Color.klmsMacSubtleCardBackground, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(isSelected ? Color.klmsMacSelectedBorder.opacity(0.92) : Color.klmsMacCommandBorder, lineWidth: isSelected ? 1.2 : 1)
                }
        }
        .buttonStyle(KLMSMacPressFeedbackButtonStyle())
        .help(help)
    }
}

private enum KLMSMacActionButtonTone {
    case soft
    case primary
    case destructive
    case success
    case accent(Color)
}

private struct KLMSMacActionButtonStyle: ButtonStyle {
    var tone: KLMSMacActionButtonTone = .soft
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(background(isPressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(border(isPressed: configuration.isPressed), lineWidth: 1)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.96 : 1.0) : 0.46)
    }

    private var foreground: Color {
        switch tone {
        case .soft:
            return Color.klmsMacSecondaryCommandButtonForeground
        case .primary:
            return Color.klmsMacCommandButtonForeground
        case .destructive:
            return Color.klmsMacDangerBorder
        case .success:
            return Color.klmsMacSecondaryCommandButtonForeground
        case .accent(let color):
            return color
        }
    }

    private func background(isPressed: Bool) -> Color {
        switch tone {
        case .soft:
            return isPressed ? Color.klmsMacCommandButtonPressedBackground : Color.klmsMacCommandButtonBackground.opacity(0.90)
        case .primary:
            return isPressed ? Color.klmsMacPrimaryCommandButtonPressedBackground : Color.klmsMacPrimaryCommandButtonBackground
        case .destructive:
            return isPressed ? Color.klmsMacCommandButtonPressedBackground : Color.klmsMacCommandButtonBackground.opacity(0.90)
        case .success:
            return isPressed ? Color.klmsMacSuccessBorder.opacity(0.20) : Color.klmsMacSuccessBackground
        case .accent(let color):
            return color.opacity(isPressed ? 0.18 : 0.10)
        }
    }

    private func border(isPressed: Bool) -> Color {
        switch tone {
        case .soft:
            return Color.klmsMacCommandButtonBorder.opacity(0.92)
        case .primary:
            return Color.klmsMacPrimaryCommandButtonBorder.opacity(isPressed ? 0.72 : 1.0)
        case .destructive:
            return Color.klmsMacDangerBorder.opacity(isPressed ? 0.78 : 0.48)
        case .success:
            return Color.klmsMacSuccessBorder
        case .accent(let color):
            return color.opacity(0.28)
        }
    }
}

private struct KLMSMacPressFeedbackButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 10
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.klmsMacCommandButtonPressedOverlay.opacity(configuration.isPressed ? 1.0 : 0.0))
                    .allowsHitTesting(false)
            }
            .opacity(isEnabled ? 1.0 : 0.48)
    }
}

private struct KLMSMacIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.klmsMacSecondaryCommandButtonForeground)
            .frame(width: 26, height: 26)
            .background(
                configuration.isPressed
                    ? Color.klmsMacCommandButtonPressedBackground
                    : Color.klmsMacCommandButtonBackground.opacity(0.88),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        configuration.isPressed
                            ? Color.klmsMacPrimaryCommandButtonBorder.opacity(0.46)
                            : Color.klmsMacCommandButtonBorder.opacity(0.84),
                        lineWidth: 1
                    )
            }
            .opacity(isEnabled ? 1.0 : 0.48)
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
            [courseSortKey, titleSortKey, pathSortKey, url]
        case .kind:
            [kindSortKey, courseSortKey, titleSortKey, pathSortKey, url]
        case .name:
            [titleSortKey, courseSortKey, pathSortKey, url]
        case .path:
            [pathSortKey, titleSortKey, courseSortKey, url]
        case .recent:
            [courseSortKey, titleSortKey, pathSortKey, url]
        }
    }

    var recencySortText: String {
        recencySortKey
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

private func dashboardMissingPathSet(from snapshot: EngineSnapshot) -> Set<String> {
    Set((snapshot.verifyResult?.files?.missingFiles ?? []).map(dashboardNormalizedPathForExistence))
}

private func dashboardPathExists(path: String, missingPaths: Set<String>) -> Bool {
    let normalized = dashboardNormalizedPathForExistence(path)
    guard !normalized.isEmpty else { return false }
    return !missingPaths.contains(normalized)
}

private func dashboardNormalizedPathForExistence(_ path: String) -> String {
    path.trimmingCharacters(in: .whitespacesAndNewlines)
        .precomposedStringWithCanonicalMapping
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
    var hiddenFileItems: [DashboardFileItem]
    var hiddenQuarantineItems: [DashboardFileItem]
    var snapshot: EngineSnapshot
    var model: KLMSMacModel
    @State private var visibleLimit = DashboardLargeList.initialVisibleLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StateItemListView(
                items: hiddenAssignments,
                emptyText: "숨긴 과제가 없습니다.",
                editor: .assignment,
                filters: filters,
                snapshot: snapshot,
                model: model
            )
            StateItemListView(
                items: hiddenExams,
                emptyText: "숨긴 시험이 없습니다.",
                editor: .exam,
                filters: filters,
                snapshot: snapshot,
                model: model
            )
            NoticeListView(filters: filters, defaultCategory: .hidden, snapshot: snapshot, model: model)
            hiddenFileRows
        }
    }

    @ViewBuilder
    private var hiddenFileRows: some View {
        let items = (hiddenFileItems + hiddenQuarantineItems).filter { $0.matches(filters: filters) }
        let visibleItems = items.prefix(visibleLimit)
        if items.isEmpty {
            EmptyDetailText(text: "숨긴 파일이 없습니다.")
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(visibleItems) { item in
                    FileRowView(item: item, kind: item.bucket == "quarantine" ? .quarantine : .file, model: model)
                }
                if items.count > visibleItems.count {
                    DashboardShowMoreButton(remainingCount: items.count - visibleItems.count) {
                        visibleLimit += DashboardLargeList.increment
                    }
                }
            }
        }
    }

    private var hiddenAssignments: [StateItem] {
        let content = snapshot.rawLegacyState?.content ?? snapshot.legacyState?.content
        let overrides = snapshot.manualOverrides
        return (
            (content?.assignments ?? [])
                + (content?.assignmentCandidates ?? [])
                + (content?.completedAssignments ?? [])
                + (content?.assignmentRecords ?? [])
                + (content?.helpDeskItems ?? [])
        )
            .filter { overrides?.isAssignmentHidden($0) == true }
            .dedupedDashboardItems()
    }

    private var hiddenExams: [StateItem] {
        let content = snapshot.rawLegacyState?.content ?? snapshot.legacyState?.content
        let overrides = snapshot.manualOverrides
        return ((content?.examItems ?? []) + (content?.examCandidates ?? []))
            .filter { overrides?.isExamHidden($0) == true }
            .filter { !$0.isPastDashboardExamForApp }
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
    var files: [DashboardFileItem]
    var filters: DashboardDetailFilters
    var model: KLMSMacModel
    @State private var sortOption = DashboardFileSortOption.recent
    @State private var visibleLimit = DashboardLargeList.initialVisibleLimit

    var body: some View {
        let records = files.filter { $0.matches(filters: filters) }
        let sortedRecords = records.sorted(by: sortOption)
        let visibleRecords = sortedRecords.prefix(visibleLimit)
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
}

private struct PrunedListView: View {
    var filters: DashboardDetailFilters
    var snapshot: EngineSnapshot
    @State private var sortOption = DashboardFileSortOption.recent
    @State private var visibleLimit = DashboardLargeList.initialVisibleLimit

    var body: some View {
        let deleted = filteredItems
        let sortedDeleted = deleted.sorted(by: sortOption)
        let visibleDeleted = sortedDeleted.prefix(visibleLimit)
        if deleted.isEmpty {
            EmptyDetailText(text: "정리된 파일 기록이 없습니다.")
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
    @State private var isExpanded = false

    var body: some View {
        let hidden = item.isHidden
        let pathExists = item.pathExists
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
                                .foregroundStyle(Color.klmsMacCommandAccent)
                        }
                        if hidden {
                            Label("숨김", systemImage: "eye.slash")
                                .font(.caption2)
                                .foregroundStyle(Color.klmsMacSecondaryText)
                        }
                    }
                    let metadata = [item.academicTerm?.displayName ?? "", item.course].filter { !$0.isEmpty }.joined(separator: " · ")
                    if !metadata.isEmpty {
                        Text(metadata)
                            .font(.caption2)
                            .foregroundStyle(Color.klmsMacSecondaryText)
                            .lineLimit(2)
                    }
                    if isExpanded, !item.path.isEmpty {
                        Text(item.path)
                            .font(.caption2)
                            .foregroundStyle(Color.klmsMacSecondaryText)
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
                    .buttonStyle(KLMSMacIconButtonStyle())
                    .help("Finder에서 보기")
                }
                if !item.url.isEmpty {
                    Button {
                        openExternalURL(item.url)
                    } label: {
                        Image(systemName: "safari")
                    }
                    .buttonStyle(KLMSMacIconButtonStyle())
                    .help("KLMS 열기")
                }
                DashboardRowDisclosureButton(isExpanded: $isExpanded)
            }
            DeferredDashboardExpansion(isExpanded: isExpanded) {
                actionBar(hidden: hidden, pathExists: pathExists)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hidden ? Color.klmsMacWarningBackground : Color.klmsMacCardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(hidden ? Color.klmsMacWarningBorder : Color.klmsMacBorder, lineWidth: 1)
        }
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
                        .buttonStyle(KLMSMacActionButtonStyle())
                    }
                    Button {
                        didRequestSync = true
                        Task { await model.run(.filesSync) }
                    } label: {
                        Label("파일 반영", systemImage: KLMSEngineCommand.filesSync.systemImage)
                    }
                    .buttonStyle(KLMSMacActionButtonStyle(tone: .primary))
                    .disabled(model.runningCommand != nil)
                    if hidden {
                        Button {
                            restore(model)
                        } label: {
                            Label("복구", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(KLMSMacActionButtonStyle())
                    } else {
                        Button {
                            hide(model)
                        } label: {
                            Label(kind == .quarantine ? "삭제/무시" : "삭제/숨김", systemImage: "eye.slash")
                        }
                        .buttonStyle(KLMSMacActionButtonStyle(tone: .destructive))
                    }
                    if pathExists {
                        Button(role: .destructive) {
                            moveToTrash(model)
                        } label: {
                            Label("휴지통", systemImage: "trash")
                        }
                        .buttonStyle(KLMSMacActionButtonStyle(tone: .destructive))
                    }
                    Spacer()
                }
                .font(.caption)
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

private struct DashboardFileKindStyle {
    var label: String
    var icon: String
    var color: Color

    init(bucket: String) {
        switch bucket.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "board-attachments":
            label = "공지 첨부"
            icon = "megaphone"
            color = Color.klmsMacCommandAccent
        case "assignment-attachments":
            label = "과제 첨부"
            icon = "checklist"
            color = Color.klmsMacSuccessBorder
        case "resources":
            label = "강의 자료"
            icon = "books.vertical"
            color = Color.klmsMacSecondaryText
        case "folders":
            label = "폴더 자료"
            icon = "folder"
            color = Color.klmsMacSecondaryText
        case "page-attachments":
            label = "페이지 첨부"
            icon = "doc"
            color = Color.klmsMacSecondaryText
        case "quarantine":
            label = "격리"
            icon = "exclamationmark.triangle"
            color = Color.klmsMacWarningBorder
        case "deleted":
            label = "삭제 기록"
            icon = "trash"
            color = Color.klmsMacSecondaryText
        case "":
            label = "기타 파일"
            icon = "doc"
            color = Color.klmsMacSecondaryText
        default:
            label = bucket
            icon = "doc"
            color = Color.klmsMacSecondaryText
        }
    }
}

private struct CalendarDetailView: View {
    var snapshot: EngineSnapshot
    var filters: DashboardDetailFilters
    var model: KLMSMacModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CalendarActionGuideView(
                hasReportedCalendarChanges: hasReportedCalendarChanges,
                model: model
            )

            let visibleChanges = visibleCalendarChanges
            let visibleChangeCounts = calendarChangeCounts(for: visibleChanges)
            if snapshot.syncReport?.calendar != nil || !visibleChanges.isEmpty {
                MetricGrid(metrics: [
                    Metric("생성", visibleChangeCounts.created),
                    Metric("수정", visibleChangeCounts.updated),
                    Metric("정리", visibleChangeCounts.deleted),
                ])
            } else {
                EmptyDetailText(text: "캘린더 결과가 없습니다.")
            }

            if let coreRun = snapshot.syncReport?.runs["core"] {
                Text("과제/시험 · \(coreRun.status.klmsLocalizedStatus) · \(coreRun.elapsedSecondsText)")
                    .font(.caption)
                    .foregroundStyle(Color.klmsMacSecondaryText)
            }

            if let result = snapshot.calendarSyncResult {
                if !visibleChanges.isEmpty {
                    CalendarSummaryListView(result: result)
                }
                CalendarChangeListView(
                    changes: visibleChanges,
                    filters: filters,
                    model: model,
                    hasLegacyCountWithoutDetails: visibleChanges.isEmpty && hasReportedCalendarChanges
                )
            } else if hasReportedCalendarChanges {
                CalendarChangeListView(
                    changes: visibleChanges,
                    filters: filters,
                    model: model,
                    hasLegacyCountWithoutDetails: visibleChanges.isEmpty
                )
            }
        }
    }

    private var calendarChanges: [CalendarChange] {
        ((snapshot.calendarSyncResult?.changes ?? []) + model.mailCalendarChanges()).dedupedForCalendarDisplay()
    }

    private var visibleCalendarChanges: [CalendarChange] {
        calendarChanges.filter { change in
            change.isUserVisibleCalendarChange && !model.isCalendarChangeResolved(change)
        }
    }

    private var hasReportedCalendarChanges: Bool {
        if snapshot.calendarSyncResult?.changes.isEmpty == false || !model.mailCalendarChanges().isEmpty {
            return !visibleCalendarChanges.isEmpty
        }
        let counts = snapshot.syncReport?.calendar
        let reportCount = (counts?.created ?? 0) + (counts?.updated ?? 0) + (counts?.deleted ?? 0)
        let summaryCount = snapshot.calendarSyncResult?.summaries.reduce(0) {
            $0 + $1.created + $1.updated + $1.deleted
        } ?? 0
        return reportCount + summaryCount + model.mailCalendarChanges().count > 0
    }

    private func calendarChangeCounts(for changes: [CalendarChange]) -> (created: Int, updated: Int, deleted: Int) {
        var created = 0
        var updated = 0
        var deleted = 0
        for change in changes {
            switch change.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "created", "mail":
                created += 1
            case "updated":
                updated += 1
            case "deleted":
                deleted += 1
            default:
                break
            }
        }
        return (created, updated, deleted)
    }
}

private struct CalendarActionGuideView: View {
    var hasReportedCalendarChanges: Bool
    var model: KLMSMacModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.klmsMacWarningBorder)
                    .frame(width: 28, height: 28)
                    .background(Color.klmsMacWarningBackground, in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 3) {
                    Text("캘린더 일정")
                        .font(.caption.weight(.semibold))
                    Text(helpText)
                        .font(.caption2)
                        .foregroundStyle(Color.klmsMacSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                CalendarActionButton(
                    title: "KLMS 기준 반영",
                    systemImage: KLMSEngineCommand.coreSync.systemImage,
                    tint: Color.klmsMacCommandAccent,
                    disabled: model.runningCommand != nil
                ) {
                    Task {
                        await model.run(.coreSync)
                    }
                }
                CalendarActionButton(
                    title: "캘린더에서 열기",
                    systemImage: "calendar",
                    tint: Color.klmsMacWarningBorder
                ) {
                    openSystemCalendar()
                }
            }
        }
        .padding(10)
        .background(Color.klmsMacWarningBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.klmsMacWarningBorder.opacity(0.28), lineWidth: 1)
        }
    }

    private var helpText: String {
        if hasReportedCalendarChanges {
            return "방금 생성, 수정, 정리된 일정입니다. 항목별 수정·삭제는 아래 목록에서 처리하고, 전체 재반영은 KLMS 기준 반영을 누르세요."
        }
        return "캘린더 수가 맞지 않으면 KLMS 기준 반영으로 과제/시험과 Calendar를 다시 맞출 수 있습니다."
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
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(disabled ? Color.klmsMacSecondaryText.opacity(0.62) : tint)
                Text(title)
                    .foregroundStyle(disabled ? Color.klmsMacSecondaryText.opacity(0.62) : Color.klmsMacPrimaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(minHeight: 30)
                .padding(.horizontal, 9)
                .background(
                    (disabled ? Color.klmsMacSubtleCardBackground.opacity(0.58) : Color.klmsMacCommandButtonBackground.opacity(0.92)),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(disabled ? Color.klmsMacCommandBorder.opacity(0.6) : Color.klmsMacCommandButtonBorder.opacity(0.95), lineWidth: 1)
                }
        }
        .buttonStyle(KLMSMacPressFeedbackButtonStyle(cornerRadius: 8))
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
                    .foregroundStyle(Color.klmsMacSecondaryText)
                ForEach(result.summaries) { summary in
                    HStack(spacing: 8) {
                        Text(summary.calendar.isEmpty ? "캘린더" : summary.calendar)
                            .font(.caption.weight(.semibold))
                        Text(bucketLabel(summary.bucket))
                            .font(.caption2)
                            .foregroundStyle(Color.klmsMacSecondaryText)
                        Spacer()
                        Text("생성 \(summary.created)")
                        Text("수정 \(summary.updated)")
                        Text("정리 \(summary.deleted)")
                        Text("전체 \(summary.total)")
                    }
                    .font(.caption2)
                    .padding(8)
                    .background(Color.klmsMacCardBackground, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.klmsMacBorder, lineWidth: 1)
                    }
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
    var model: KLMSMacModel
    var hasLegacyCountWithoutDetails: Bool
    @State private var visibleLimit = DashboardLargeList.initialVisibleLimit

    var body: some View {
        let visibleChanges = filteredChanges
        let renderedChanges = visibleChanges.prefix(visibleLimit)
        VStack(alignment: .leading, spacing: 6) {
            Text("상세 변경")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.klmsMacSecondaryText)

            if visibleChanges.isEmpty {
                EmptyDetailText(text: emptyText)
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(renderedChanges) { change in
                        CalendarChangeRowView(change: change, model: model)
                    }
                }
                if visibleChanges.count > renderedChanges.count {
                    DashboardShowMoreButton(remainingCount: visibleChanges.count - renderedChanges.count) {
                        visibleLimit += DashboardLargeList.increment
                    }
                }
            }
        }
        .onChange(of: visibleChangesResetKey) { _, _ in
            visibleLimit = DashboardLargeList.initialVisibleLimit
        }
    }

    private var visibleChangesResetKey: String {
        let visibleChanges = filteredChanges
        return "\(visibleChanges.count):\(visibleChanges.first?.id ?? ""):\(visibleChanges.last?.id ?? "")"
    }

    private var filteredChanges: [CalendarChange] {
        changes.filter { change in
            guard change.isUserVisibleCalendarChange else {
                return false
            }
            guard !model.isCalendarChangeResolved(change) else {
                return false
            }
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
    var model: KLMSMacModel
    @State private var editStatusText: String?
    @State private var calendarSheetAction: ServerRelayItemActionKind?

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
                        .foregroundStyle(Color.klmsMacSecondaryText)
                        .lineLimit(2)
                    if !timeText.isEmpty {
                        Text(timeText)
                            .font(.caption2)
                            .foregroundStyle(Color.klmsMacSecondaryText)
                            .lineLimit(2)
                    }
                    if !change.changes.isEmpty {
                        Text("변경 필드: \(change.changes.joined(separator: ", "))")
                            .font(.caption2)
                            .foregroundStyle(Color.klmsMacSecondaryText)
                            .lineLimit(2)
                    }
                    if !change.parseError.isEmpty {
                        Text("파싱 오류: \(change.parseError)")
                            .font(.caption2)
                            .foregroundStyle(Color.klmsMacWarningBorder)
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
                        editStatusText = "캘린더 일정을 등록하는 중입니다."
                        Task {
                            let ok = await model.createCalendarEvent(change: change, edit: change.editDefaults)
                            editStatusText = ok ? "캘린더 일정 등록 완료" : "캘린더 일정 등록 실패"
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            editStatusText = nil
                        }
                    } label: {
                        Label("등록", systemImage: "calendar.badge.plus")
                    }
                    .buttonStyle(KLMSMacActionButtonStyle(tone: .success))
                    .help("Apple Calendar에 이 일정 내용을 새 이벤트로 등록합니다.")
                    Button {
                        calendarSheetAction = .calendarEdit
                    } label: {
                        Label("수정", systemImage: "pencil")
                    }
                    .buttonStyle(KLMSMacActionButtonStyle())
                    .help("Apple Calendar에 저장된 이 일정의 제목, 시간, 장소를 직접 수정합니다.")
                    Button(role: .destructive) {
                        editStatusText = "캘린더 일정을 삭제하는 중입니다."
                        Task {
                            let ok = await model.deleteCalendarEvent(change: change)
                            editStatusText = ok ? "캘린더 일정 삭제 완료" : "캘린더 일정 삭제 실패"
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            editStatusText = nil
                        }
                    } label: {
                        Label("삭제", systemImage: "calendar.badge.minus")
                    }
                    .buttonStyle(KLMSMacActionButtonStyle(tone: .destructive))
                    .help("Apple Calendar에서 이 이벤트를 삭제합니다.")
                    Button {
                        editStatusText = "캘린더에서 일정을 여는 중입니다."
                        Task {
                            let ok = await model.openCalendarEvent(change: change)
                            editStatusText = ok ? "캘린더에서 일정 선택 완료" : "캘린더 앱을 열었습니다."
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            editStatusText = nil
                        }
                    } label: {
                        Label("캘린더에서 열기", systemImage: "calendar")
                    }
                    .buttonStyle(KLMSMacActionButtonStyle())
                    .help("Calendar 앱에서 이 이벤트를 바로 선택합니다.")
                    Spacer()
                }
                .font(.caption)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsMacCardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.klmsMacBorder, lineWidth: 1)
        }
        .sheet(
            isPresented: Binding(
                get: { calendarSheetAction != nil },
                set: { if !$0 { calendarSheetAction = nil } }
            )
        ) {
            let action = calendarSheetAction ?? .calendarEdit
            CalendarEventEditSheet(change: change, action: action) { edit in
                editStatusText = "캘린더 내용을 저장하는 중입니다."
                Task {
                    let ok = await model.editCalendarEvent(change: change, edit: edit)
                    editStatusText = ok ? "캘린더 내용 수정 완료" : "캘린더 내용 수정 실패"
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    editStatusText = nil
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
            Color.klmsMacSuccessBorder
        case "updated":
            Color.klmsMacCommandAccent
        case "deleted":
            Color.klmsMacDangerBorder
        default:
            Color.klmsMacSecondaryText
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

struct MacMailPasteAnalyzerPanel: View {
    var model: KLMSMacModel
    var snapshot: EngineSnapshot
    @State private var isExpanded = false
    @State private var mailText = ""
    @State private var analysis = MacMailPasteAnalysis.empty
    @State private var isShowingCreateSheet = false
    @State private var createStatusText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isExpanded.toggle()
            } label: {
                MacMailPasteHeaderButtonContent(isExpanded: isExpanded, analysis: analysis)
            }
            .buttonStyle(KLMSMacPressFeedbackButtonStyle())

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    MacMailPasteInputBox(mailText: $mailText)

                    HStack(spacing: 8) {
                        Button {
                            pasteFromClipboard()
                        } label: {
                            Label("클립보드 붙여넣기", systemImage: "doc.on.clipboard")
                        }
                        .buttonStyle(KLMSMacActionButtonStyle())
                        Button {
                            runAnalysis()
                        } label: {
                            Label("판독하기", systemImage: "wand.and.stars")
                        }
                        .buttonStyle(KLMSMacActionButtonStyle(tone: .primary))
                        .disabled(mailText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button(role: .destructive) {
                            mailText = ""
                            analysis = .empty
                            createStatusText = nil
                        } label: {
                            Label("입력 비우기", systemImage: "trash")
                        }
                        .buttonStyle(KLMSMacActionButtonStyle(tone: .destructive))
                        .disabled(mailText.isEmpty)
                        Spacer(minLength: 0)
                        if analysis.canCreateCalendarEvent {
                            Button {
                                isShowingCreateSheet = true
                            } label: {
                                Label("캘린더에 등록", systemImage: "calendar.badge.plus")
                            }
                            .buttonStyle(KLMSMacActionButtonStyle(tone: .success))
                        }
                    }
                    .font(.caption.weight(.semibold))

                    MacMailPasteAnalysisResultView(analysis: analysis, model: model)
                    if let createStatusText {
                        MacInlinePendingActionView(message: createStatusText)
                    }
                }
                .transition(.opacity)
            }
        }
        .onChange(of: mailText) { _, _ in
            runAnalysis()
        }
        .onChange(of: snapshot.legacyState?.content.assignments.count ?? 0) { _, _ in
            runAnalysis()
        }
        .sheet(isPresented: $isShowingCreateSheet) {
            MailCalendarCreateSheet(analysis: analysis) { draft in
                createStatusText = "메일 일정을 Calendar에 등록하는 중입니다."
                Task {
                    await model.createManualCalendarEvent(
                        title: draft.title,
                        startAt: draft.startAt,
                        dueAt: draft.dueAt,
                        location: draft.location,
                        notes: draft.notes
                    )
                    createStatusText = "메일 일정 등록 요청을 처리했습니다."
                }
            }
        }
    }

    private func pasteFromClipboard() {
        if let clipboardText = NSPasteboard.general.string(forType: .string) {
            mailText = clipboardText
            isExpanded = true
            runAnalysis()
        }
    }

    private func runAnalysis() {
        analysis = MacMailPasteAnalyzer.analyze(mailText, snapshot: snapshot)
    }
}

private struct MacMailPasteHeaderButtonContent: View {
    var isExpanded: Bool
    var analysis: MacMailPasteAnalysis
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("메일·캘린더 분석")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.klmsMacPrimaryText)
                Text(isExpanded ? "메일 본문에서 과제·시험·일정을 찾습니다." : "메일 본문 붙여넣기")
                    .font(.caption2)
                    .foregroundStyle(Color.klmsMacSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !analysis.isEmpty {
                Text(analysis.kind.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(analysis.kind.tint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(analysis.kind.tint.opacity(0.12), in: Capsule())
            }
            Image(systemName: isExpanded ? "chevron.down" : "arrow.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.klmsMacSecondaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsMacCommandButtonBackground.opacity(colorScheme == .dark ? 0.82 : 0.92), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.klmsMacCommandButtonBorder.opacity(colorScheme == .dark ? 0.72 : 0.92), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct MacMailPasteInputBox: View {
    @Binding var mailText: String
    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color {
        macMailThemeAccent(for: colorScheme)
    }

    private var trimmedText: String {
        mailText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var lineCount: Int {
        let lines = trimmedText.split(whereSeparator: \.isNewline)
        return lines.isEmpty ? 0 : lines.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "text.badge.checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
                    .frame(width: 24, height: 24)
                    .background(accent.opacity(colorScheme == .dark ? 0.22 : 0.13), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    Text("메일 원문 붙여넣기")
                        .font(.caption.weight(.semibold))
                    Text("메일 본문, LMS 외부 공지, 캘린더 안내문을 그대로 붙여넣으면 이 Mac 안에서만 판독합니다. 원문은 저장하지 않습니다.")
                        .font(.caption2)
                        .foregroundStyle(Color.klmsMacSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Text("1단계")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(accent.opacity(colorScheme == .dark ? 0.18 : 0.11), in: Capsule())
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $mailText)
                    .font(.caption)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 122)
                    .padding(7)
                    .background(accent.opacity(colorScheme == .dark ? 0.10 : 0.045), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(accent.opacity(colorScheme == .dark ? 0.28 : 0.18), lineWidth: 1)
                    }
                if mailText.isEmpty {
                    Text("예: 시험 일정, 과제 마감, 첨부파일 안내가 들어 있는 메일 본문")
                        .font(.caption)
                        .foregroundStyle(Color.klmsMacSecondaryText.opacity(0.68))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: 8) {
                Label(trimmedText.isEmpty ? "입력 대기" : "\(lineCount)줄 · \(trimmedText.count)자", systemImage: trimmedText.isEmpty ? "square.and.pencil" : "doc.text.magnifyingglass")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(trimmedText.isEmpty ? Color.klmsMacSecondaryText : accent)
                Spacer(minLength: 0)
                Label("원문은 서버로 보내지 않음", systemImage: "lock.shield")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.klmsMacSecondaryText)
            }
        }
        .padding(10)
        .background(accent.opacity(colorScheme == .dark ? 0.08 : 0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(accent.opacity(colorScheme == .dark ? 0.22 : 0.20), lineWidth: 1)
        }
    }
}

private func macMailThemeAccent(for colorScheme: ColorScheme) -> Color {
    Color.klmsMacCommandAccent
}

private struct MacMailPasteAnalysisResultView: View {
    var analysis: MacMailPasteAnalysis
    var model: KLMSMacModel
    @State private var dashboardEditItem: ServerRelaySyncItem?

    var body: some View {
        if analysis.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Label("판독 결과", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                Text("메일 원문을 붙여넣고 `판독하기`를 누르면 분류, 과목, 일정, 대시보드 반영 후보를 여기에서 확인합니다.")
                    .font(.caption2)
                    .foregroundStyle(Color.klmsMacSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.klmsMacBorder, lineWidth: 1)
            }
        } else {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Label("판독 결과", systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                    Text("2단계")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(analysis.kind.tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(analysis.kind.tint.opacity(0.12), in: Capsule())
                }

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: analysis.kind.systemImage)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(analysis.kind.tint)
                        .frame(width: 28, height: 28)
                        .background(analysis.kind.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(analysis.title.nilIfBlank ?? "제목을 찾지 못했습니다.")
                            .font(.caption.weight(.semibold))
                        Text(analysis.summary)
                            .font(.caption2)
                            .foregroundStyle(Color.klmsMacSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 7)], alignment: .leading, spacing: 7) {
                    MacMailAnalysisPill(title: "분류", value: analysis.kind.title, tint: analysis.kind.tint)
                    MacMailAnalysisPill(title: "과목", value: analysis.course.nilIfBlank ?? "미확인", tint: Color.klmsMacCommandAccent)
                    MacMailAnalysisPill(title: "일시", value: analysis.dueText.nilIfBlank ?? "미확인", tint: Color.klmsMacWarningBorder)
                    MacMailAnalysisPill(title: "신뢰도", value: "\(analysis.confidence)%", tint: analysis.confidence >= 70 ? Color.klmsMacSuccessBorder : Color.klmsMacWarningBorder)
                }

                MacMailAnalysisProcessView(steps: analysis.analysisSteps)

                if !analysis.detectedTargets.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("처리 대상")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.klmsMacSecondaryText)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 7)], alignment: .leading, spacing: 7) {
                            ForEach(analysis.detectedTargets, id: \.self) { target in
                                MacMailAnalysisPill(title: "판독", value: target, tint: analysis.kind.tint)
                            }
                        }
                    }
                }

                if !analysis.urls.isEmpty {
                    Text("본문 링크 \(analysis.urls.count)개 감지")
                        .font(.caption2)
                        .foregroundStyle(Color.klmsMacSecondaryText)
                }

                if analysis.matchedItems.isEmpty {
                    MacMailActionPlanView(lines: analysis.actionPlan)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("관련 KLMS 항목")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.klmsMacSecondaryText)
                        ForEach(analysis.matchedItems.prefix(5)) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Text(item.kindLabel)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(item.tint)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(item.tint.opacity(0.12), in: Capsule())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(2)
                                    Text([item.course, item.due].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption2)
                                        .foregroundStyle(Color.klmsMacSecondaryText)
                                        .lineLimit(2)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(8)
                            .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.klmsMacBorder, lineWidth: 1)
                            }
                        }
                    }
                }

                if !analysis.actionPlan.isEmpty, !analysis.matchedItems.isEmpty {
                    MacMailActionPlanView(lines: analysis.actionPlan)
                }

                if let dashboardItem = analysis.dashboardItem {
                    let registeredItem = model.mailDashboardItems.first { $0.id == dashboardItem.id }
                    let editableItem = registeredItem ?? dashboardItem
                    VStack(alignment: .leading, spacing: 8) {
                        if registeredItem != nil {
                            HStack(spacing: 7) {
                                Label("대시보드 등록됨", systemImage: "checkmark.circle.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.klmsMacSuccessBorder)
                                Spacer(minLength: 0)
                                Button {
                                    dashboardEditItem = editableItem
                                } label: {
                                    Label("수정", systemImage: "pencil")
                                }
                                .buttonStyle(KLMSMacActionButtonStyle())
                                Button(role: .destructive) {
                                    model.removeMailDashboardItem(editableItem)
                                } label: {
                                    Label("제거", systemImage: "minus.circle")
                                }
                                .buttonStyle(KLMSMacActionButtonStyle(tone: .destructive))
                            }
                        } else {
                            HStack(spacing: 8) {
                                Button {
                                    dashboardEditItem = editableItem
                                } label: {
                                    Label("수정", systemImage: "pencil")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(KLMSMacActionButtonStyle())
                                Button {
                                    model.addMailDashboardItem(dashboardItem)
                                } label: {
                                    Label("등록", systemImage: "plus.circle")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(KLMSMacActionButtonStyle(tone: .accent(analysis.kind.tint)))
                            }
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .sheet(item: $dashboardEditItem) { item in
                        MailDashboardItemEditSheet(item: item) { edited in
                            model.addMailDashboardItem(edited)
                        }
                    }
                }
            }
            .padding(10)
            .background(analysis.kind.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(analysis.kind.tint.opacity(0.18), lineWidth: 1)
            }
        }
    }
}

private struct MailDashboardItemEditSheet: View {
    var item: ServerRelaySyncItem
    var onSave: (ServerRelaySyncItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind: String
    @State private var course: String
    @State private var title: String
    @State private var timestamp: String
    @State private var detail: String
    @State private var attachmentCount: String

    private static let kindOptions = ["assignment", "exam", "notice", "file", "assignmentCandidate", "examCandidate"]

    init(item: ServerRelaySyncItem, onSave: @escaping (ServerRelaySyncItem) -> Void) {
        self.item = item
        self.onSave = onSave
        _kind = State(initialValue: Self.kindOptions.contains(item.kind) ? item.kind : "notice")
        _course = State(initialValue: item.course)
        _title = State(initialValue: item.title)
        _timestamp = State(initialValue: item.timestamp)
        _detail = State(initialValue: item.detail)
        _attachmentCount = State(initialValue: String(item.attachmentCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("대시보드 항목 수정")
                .font(.headline)
            Text("대시보드에 반영할 항목의 분류와 내용을 조정합니다. 원문은 저장하지 않습니다.")
                .font(.caption)
                .foregroundStyle(Color.klmsMacSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("분류")
                        .foregroundStyle(Color.klmsMacSecondaryText)
                    Picker("분류", selection: $kind) {
                        ForEach(Self.kindOptions, id: \.self) { value in
                            Text(value.klmsMailDashboardKindName).tag(value)
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("제목")
                        .foregroundStyle(Color.klmsMacSecondaryText)
                    TextField("제목", text: $title)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("과목")
                        .foregroundStyle(Color.klmsMacSecondaryText)
                    TextField("과목명", text: $course)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("일시")
                        .foregroundStyle(Color.klmsMacSecondaryText)
                    TextField("마감/일정", text: $timestamp)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("설명")
                        .foregroundStyle(Color.klmsMacSecondaryText)
                    TextField("설명", text: $detail, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                }
                GridRow {
                    Text("첨부/링크")
                        .foregroundStyle(Color.klmsMacSecondaryText)
                    TextField("0", text: $attachmentCount)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
            }
            HStack {
                Spacer()
                Button("취소") {
                    dismiss()
                }
                .buttonStyle(KLMSMacActionButtonStyle())
                Button("저장") {
                    onSave(editedItem)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(KLMSMacActionButtonStyle(tone: .primary))
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 560)
    }

    private var editedItem: ServerRelaySyncItem {
        let count = max(0, Int(attachmentCount.trimmingCharacters(in: .whitespacesAndNewlines)) ?? item.attachmentCount)
        return ServerRelaySyncItem(
            id: item.id,
            kind: kind,
            course: course.trimmingCharacters(in: .whitespacesAndNewlines),
            academicTerm: item.academicTerm,
            academicYear: item.academicYear,
            academicSemester: item.academicSemester,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            timestamp: timestamp.trimmingCharacters(in: .whitespacesAndNewlines),
            status: "추가됨",
            detail: detail.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? "추가로 반영한 항목입니다.",
            attachmentCount: count,
            updatedAt: ServerRelaySyncItem.isoTimestamp(),
            isRead: item.isRead,
            isImportant: item.isImportant,
            isHidden: item.isHidden
        )
    }
}

private struct MacMailAnalysisPill: View {
    var title: String
    var value: String
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.klmsMacSecondaryText)
            Text(value)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct MacMailAnalysisStep: Identifiable {
    var id: String
    var title: String
    var detail: String
    var systemImage: String
    var tint: Color
}

private struct MacMailAnalysisProcessView: View {
    var steps: [MacMailAnalysisStep]
    @State private var isExpanded = true

    var body: some View {
        if !steps.isEmpty {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(steps) { step in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: step.systemImage)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(step.tint)
                                .frame(width: 20, height: 20)
                                .background(step.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.title)
                                    .font(.caption.weight(.semibold))
                                Text(step.detail)
                                    .font(.caption2)
                                    .foregroundStyle(Color.klmsMacSecondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(7)
                        .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: 7))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(Color.klmsMacBorder, lineWidth: 1)
                        }
                    }
                }
                .padding(.top, 8)
            } label: {
                HStack(spacing: 7) {
                    Label("분석 과정", systemImage: "list.bullet.clipboard")
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                    Text("\(steps.count)단계")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.klmsMacSecondaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(KLMSMacPressFeedbackButtonStyle())
            .padding(9)
            .background(Color.klmsMacCardBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.klmsMacBorder, lineWidth: 1)
            }
        }
    }
}

private struct MacMailActionPlanView: View {
    var lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("추천 처리")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.klmsMacSecondaryText)
            ForEach(lines, id: \.self) { line in
                Label(line, systemImage: "checkmark.circle")
                    .font(.caption2)
                    .foregroundStyle(Color.klmsMacSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.klmsMacBorder, lineWidth: 1)
        }
    }
}

private struct MailCalendarCreateSheet: View {
    var analysis: MacMailPasteAnalysis
    var onSave: (MailCalendarDraft) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var startAt: String
    @State private var dueAt: String
    @State private var location: String

    init(analysis: MacMailPasteAnalysis, onSave: @escaping (MailCalendarDraft) -> Void) {
        self.analysis = analysis
        self.onSave = onSave
        _title = State(initialValue: analysis.calendarTitle)
        _startAt = State(initialValue: analysis.calendarStartInput)
        _dueAt = State(initialValue: analysis.calendarEndInput)
        _location = State(initialValue: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("메일 일정 등록")
                .font(.headline)
            Text("Apple Calendar에 새 일정을 추가합니다. 시간은 `2026-06-17 13:00` 형식으로 확인해 주세요.")
                .font(.caption)
                .foregroundStyle(Color.klmsMacSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("제목")
                        .foregroundStyle(Color.klmsMacSecondaryText)
                    TextField("일정 제목", text: $title)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("시작")
                        .foregroundStyle(Color.klmsMacSecondaryText)
                    TextField("2026-06-17 13:00", text: $startAt)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("종료")
                        .foregroundStyle(Color.klmsMacSecondaryText)
                    TextField("비워 두면 1시간", text: $dueAt)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("장소")
                        .foregroundStyle(Color.klmsMacSecondaryText)
                    TextField("장소", text: $location)
                        .textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Spacer()
                Button("취소") {
                    dismiss()
                }
                .buttonStyle(KLMSMacActionButtonStyle())
                Button("등록") {
                    onSave(MailCalendarDraft(
                        title: title,
                        startAt: startAt,
                        dueAt: dueAt,
                        location: location,
                        notes: analysis.notes
                    ))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(KLMSMacActionButtonStyle(tone: .success))
            }
        }
        .padding(18)
        .frame(width: 540)
    }
}

private struct MailCalendarDraft {
    var title: String
    var startAt: String
    var dueAt: String
    var location: String
    var notes: String
}

private enum MacMailPasteDetectedKind: String {
    case none
    case assignment
    case exam
    case notice
    case file

    var title: String {
        switch self {
        case .none:
            "미분류"
        case .assignment:
            "과제 후보"
        case .exam:
            "시험 후보"
        case .notice:
            "공지 후보"
        case .file:
            "파일 후보"
        }
    }

    var systemImage: String {
        switch self {
        case .none:
            "questionmark.circle"
        case .assignment:
            "checklist"
        case .exam:
            "calendar"
        case .notice:
            "note.text"
        case .file:
            "doc"
        }
    }

    var tint: Color {
        switch self {
        case .none:
            Color.klmsMacSecondaryText
        case .assignment:
            Color.klmsMacWarningBorder
        case .exam:
            Color.klmsMacSuccessBorder
        case .notice:
            Color.klmsMacCommandAccent
        case .file:
            Color.klmsMacSecondaryText
        }
    }

    var dashboardKind: String? {
        switch self {
        case .assignment:
            "assignment"
        case .exam:
            "exam"
        case .notice:
            "notice"
        case .file:
            "file"
        case .none:
            nil
        }
    }
}

private struct MacMailPasteMatchedItem: Identifiable {
    var id: String
    var kindLabel: String
    var title: String
    var course: String
    var due: String
    var searchText: String
    var tint: Color
}

private struct MacMailPasteAnalysis {
    var kind: MacMailPasteDetectedKind
    var title: String
    var course: String
    var dueText: String
    var urls: [String]
    var confidence: Int
    var matchedItems: [MacMailPasteMatchedItem]
    var suggestedAction: String
    var calendarStartInput: String
    var calendarEndInput: String
    var rawText: String
    var analysisSteps: [MacMailAnalysisStep]

    static let empty = MacMailPasteAnalysis(
        kind: .none,
        title: "",
        course: "",
        dueText: "",
        urls: [],
        confidence: 0,
        matchedItems: [],
        suggestedAction: "",
        calendarStartInput: "",
        calendarEndInput: "",
        rawText: "",
        analysisSteps: []
    )

    var isEmpty: Bool {
        kind == .none && title.isEmpty && course.isEmpty && dueText.isEmpty && urls.isEmpty && matchedItems.isEmpty
    }

    var canCreateCalendarEvent: Bool {
        kind == .exam || kind == .assignment
    }

    var dashboardItem: ServerRelaySyncItem? {
        guard let dashboardKind = kind.dashboardKind else {
            return nil
        }
        let itemTitle = title.nilIfBlank ?? kind.title
        let id = "mail-\(ServerRelaySyncItem.stableID(kind: dashboardKind, parts: [course, itemTitle, dueText]))"
        let detail = [
            "추가됨",
            confidence > 0 ? "신뢰도 \(confidence)%" : nil,
            urls.isEmpty ? nil : "링크 \(urls.count)개",
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
        return ServerRelaySyncItem(
            id: id,
            kind: dashboardKind,
            course: course,
            title: itemTitle,
            timestamp: calendarStartInput.nilIfBlank ?? dueText,
            status: "추가됨",
            detail: detail,
            attachmentCount: kind == .file ? max(1, urls.count) : urls.count,
            updatedAt: ServerRelaySyncItem.isoTimestamp()
        )
    }

    var calendarTitle: String {
        let base = title.nilIfBlank ?? kind.title
        return course.nilIfBlank.map { "\($0) · \(base)" } ?? base
    }

    var notes: String {
        [
            course.nilIfBlank.map { "과목: \($0)" },
            dueText.nilIfBlank.map { "메일에서 감지한 일시: \($0)" },
            rawText.nilIfBlank,
        ]
        .compactMap { $0 }
        .joined(separator: "\n\n")
    }

    var summary: String {
        if !matchedItems.isEmpty {
            return "현재 KLMS 동기화 결과 \(matchedItems.count)개와 연결될 가능성이 있습니다."
        }
        if kind == .none {
            return "과제, 시험, 공지 중 어느 항목인지 확실하지 않습니다."
        }
        return "\(kind.title)로 보입니다. 일정 정보가 있으면 캘린더 처리까지 이어갈 수 있습니다."
    }

    var detectedTargets: [String] {
        var targets: [String] = []
        switch kind {
        case .assignment:
            targets.append("과제 후보")
        case .exam:
            targets.append("시험/캘린더 후보")
        case .notice:
            targets.append("공지 후보")
        case .file:
            targets.append("파일 후보")
        case .none:
            break
        }
        if !dueText.isEmpty {
            targets.append("일정/마감 감지")
        }
        if !matchedItems.isEmpty {
            targets.append("기존 KLMS 항목 연결")
        }
        if !urls.isEmpty {
            targets.append("링크 포함")
        }
        var seen = Set<String>()
        return targets.filter { seen.insert($0).inserted }
    }

    var actionPlan: [String] {
        if isEmpty { return [] }
        var lines: [String] = []
        if !matchedItems.isEmpty {
            lines.append("기존 KLMS 항목과 맞아 보입니다. 대시보드에서 해당 항목을 펼쳐 상태를 확인하세요.")
        }
        switch kind {
        case .assignment:
            lines.append("과제로 판독했습니다. 마감이 있으면 미리알림/캘린더 등록 대상입니다.")
        case .exam:
            lines.append("시험 또는 퀴즈로 판독했습니다. 캘린더 등록 대상입니다.")
        case .notice:
            lines.append("공지로 판독했습니다. 일정 문구가 있으면 캘린더 등록 여부를 확인하세요.")
        case .file:
            lines.append("파일 또는 첨부 자료 안내로 판독했습니다. 파일 동기화 후 파일 대시보드와 대조하세요.")
        case .none:
            lines.append("분류가 애매합니다. 제목, 과목명, 날짜가 들어간 메일 본문 전체를 붙여넣어 주세요.")
        }
        if canCreateCalendarEvent {
            lines.append("필요하면 아래 버튼으로 Apple Calendar에 직접 등록할 수 있습니다.")
        }
        var seen = Set<String>()
        return lines.filter { seen.insert($0).inserted }
    }
}

private enum MacMailPasteAnalyzer {
    static func analyze(_ rawText: String, snapshot: EngineSnapshot) -> MacMailPasteAnalysis {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .empty }
        let urls = regexMatches("https?://[^\\s>\\]]+", in: text)
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let items = searchableItems(from: snapshot)
        let knownCourses = Array(Set(items.map(\.course).filter { !$0.isEmpty })).sorted { $0.count > $1.count }
        let scores = kindScores(in: text)
        let kind = detectKind(in: text)
        let course = detectCourse(in: text, lines: lines, knownCourses: knownCourses)
        let title = detectTitle(lines: lines, kind: kind, course: course)
        let dueText = detectDueText(in: text)
        let matchedItems = matchItems(items: items, text: text, kind: kind, title: title, course: course, dueText: dueText)
        let calendarInput = calendarInputs(from: dueText)
        let confidence = confidenceScore(kind: kind, title: title, course: course, dueText: dueText, matchedItems: matchedItems)
        let steps = analysisSteps(
            kind: kind,
            assignmentScore: scores.assignmentScore,
            examScore: scores.examScore,
            fileScore: scores.fileScore,
            course: course,
            title: title,
            dueText: dueText,
            calendarInput: calendarInput,
            matchedItems: matchedItems,
            urls: urls
        )
        return MacMailPasteAnalysis(
            kind: kind,
            title: title,
            course: course,
            dueText: dueText,
            urls: urls,
            confidence: confidence,
            matchedItems: matchedItems,
            suggestedAction: suggestedAction(kind: kind, matchedItems: matchedItems),
            calendarStartInput: calendarInput.start,
            calendarEndInput: calendarInput.end,
            rawText: text,
            analysisSteps: steps
        )
    }

    private static func searchableItems(from snapshot: EngineSnapshot) -> [MacMailPasteMatchedItem] {
        let content = snapshot.legacyState?.content
        var items: [MacMailPasteMatchedItem] = []
        items += (content?.assignments ?? []).map { matchedItem($0, kindLabel: "과제", tint: Color.klmsMacWarningBorder) }
        items += (content?.assignmentCandidates ?? []).map { matchedItem($0, kindLabel: "과제 후보", tint: Color.klmsMacWarningBorder) }
        items += (content?.examItems ?? []).map { matchedItem($0, kindLabel: "시험", tint: Color.klmsMacSuccessBorder) }
        items += (content?.examCandidates ?? []).map { matchedItem($0, kindLabel: "시험 후보", tint: Color.klmsMacSuccessBorder) }
        items += (content?.helpDeskItems ?? []).map { matchedItem($0, kindLabel: "헬프데스크", tint: Color.klmsMacCommandAccent) }
        items += snapshot.courseFileManifest.map { file in
            MacMailPasteMatchedItem(
                id: "파일-\(file.url.nilIfBlank ?? file.relativePath)",
                kindLabel: "파일",
                title: file.filename,
                course: file.course,
                due: file.klmsTimestampText.nilIfBlank ?? file.klmsTimestamp,
                searchText: [file.filename, file.course, file.relativePath, file.klmsTimestampText, file.url].joined(separator: " "),
                tint: Color.klmsMacSecondaryText
            )
        }
        items += (snapshot.noticeDigest?.notices ?? []).map { notice in
            MacMailPasteMatchedItem(
                id: notice.id,
                kindLabel: "공지",
                title: notice.title,
                course: notice.course,
                due: notice.postedAt,
                searchText: [notice.title, notice.course, notice.postedAt, notice.url].joined(separator: " "),
                tint: Color.klmsMacCommandAccent
            )
        }
        return items
    }

    private static func matchedItem(_ item: StateItem, kindLabel: String, tint: Color) -> MacMailPasteMatchedItem {
        MacMailPasteMatchedItem(
            id: "\(kindLabel)-\(item.id)",
            kindLabel: kindLabel,
            title: item.title,
            course: item.course,
            due: item.due.nilIfBlank ?? item.syncDue,
            searchText: [
                item.title,
                item.course,
                item.due,
                item.syncDue,
                item.location,
                item.coverageSummary,
                item.url,
            ].joined(separator: " "),
            tint: tint
        )
    }

    private static func kindScores(in text: String) -> (assignmentScore: Int, examScore: Int, fileScore: Int) {
        let lower = text.lowercased()
        let assignmentScore = keywordScore(lower, weightedKeywords: [
            ("written assignment", 7),
            ("problem set", 6),
            ("due date", 6),
            ("deadline", 6),
            ("assignment", 5),
            ("homework", 5),
            ("submission", 4),
            ("submit", 4),
            ("project", 3),
            ("essay", 3),
            ("paper", 3),
            ("과제", 6),
            ("숙제", 5),
            ("제출", 5),
            ("마감", 5),
            ("레포트", 4),
            ("보고서", 4),
        ])
        let examScore = keywordScore(lower, weightedKeywords: [
            ("final exam", 7),
            ("midterm exam", 7),
            ("기말고사", 7),
            ("중간고사", 7),
            ("quiz", 5),
            ("exam", 5),
            ("시험", 5),
            ("퀴즈", 5),
            ("midterm", 3),
            ("final", 2),
            ("중간", 2),
            ("기말", 2),
        ])
        let fileScore = keywordScore(lower, weightedKeywords: [
            ("attachment", 6),
            ("attached", 6),
            ("file", 5),
            ("pdf", 5),
            ("slides", 4),
            ("material", 4),
            ("첨부", 6),
            ("파일", 5),
            ("자료", 5),
            ("강의자료", 5),
            ("슬라이드", 4),
        ])
        return (assignmentScore, examScore, fileScore)
    }

    private static func detectKind(in text: String) -> MacMailPasteDetectedKind {
        let scores = kindScores(in: text)
        let assignmentScore = scores.assignmentScore
        let examScore = scores.examScore
        let fileScore = scores.fileScore
        if assignmentScore >= examScore, assignmentScore >= fileScore, assignmentScore > 0 {
            return .assignment
        }
        if examScore >= assignmentScore, examScore >= fileScore, examScore > 0 {
            return .exam
        }
        if fileScore > 0 { return .file }
        return .notice
    }

    private static func analysisSteps(
        kind: MacMailPasteDetectedKind,
        assignmentScore: Int,
        examScore: Int,
        fileScore: Int,
        course: String,
        title: String,
        dueText: String,
        calendarInput: (start: String, end: String),
        matchedItems: [MacMailPasteMatchedItem],
        urls: [String]
    ) -> [MacMailAnalysisStep] {
        var steps: [MacMailAnalysisStep] = [
            MacMailAnalysisStep(
                id: "kind",
                title: "분류 판단",
                detail: "과제 \(assignmentScore), 시험 \(examScore), 파일 \(fileScore) 점수를 비교해 \(kind.title)로 분류했습니다.",
                systemImage: kind.systemImage,
                tint: kind.tint
            ),
        ]

        let courseDetail: String
        if course.isEmpty {
            courseDetail = "본문과 현재 KLMS 항목에서 과목명이나 과목 코드를 찾지 못했습니다."
        } else if let code = firstCapture("\\(([A-Z]{2,}\\d{2,4}[A-Z]?)\\)$", in: course) {
            courseDetail = "메일의 \(code) 코드를 현재 KLMS 과목명/별칭표로 풀었습니다: \(course)"
        } else {
            courseDetail = "본문 또는 현재 KLMS 항목에서 과목명을 찾았습니다: \(course)"
        }
        steps.append(MacMailAnalysisStep(id: "course", title: "과목 해석", detail: courseDetail, systemImage: "books.vertical", tint: Color.klmsMacCommandAccent))

        let titleDetail: String
        if title.isEmpty {
            titleDetail = "제목, Subject, 시험/과제 핵심 문구에서 사용할 제목을 찾지 못했습니다."
        } else if ["기말고사", "중간고사", "퀴즈", "시험 안내", "과제 안내"].contains(title) {
            titleDetail = "본문의 핵심 키워드로 제목을 추론했습니다: \(title)"
        } else {
            titleDetail = "Subject 또는 본문 첫 유효 줄에서 제목을 잡았습니다: \(title)"
        }
        steps.append(MacMailAnalysisStep(id: "title", title: "제목 추론", detail: titleDetail, systemImage: "text.quote", tint: Color.klmsMacSecondaryText))

        let dateDetail: String
        if dueText.isEmpty {
            dateDetail = "마감, 일정, 시험 시간 같은 날짜 문구를 찾지 못했습니다."
        } else if !calendarInput.start.isEmpty {
            dateDetail = "\(dueText)를 캘린더 입력값 \(calendarInput.start)로 변환했습니다."
        } else {
            dateDetail = "날짜 문구 \(dueText)는 찾았지만 캘린더 시간으로 변환하지 못했습니다."
        }
        steps.append(MacMailAnalysisStep(id: "date", title: "일정 해석", detail: dateDetail, systemImage: "calendar.badge.clock", tint: Color.klmsMacWarningBorder))

        let matchDetail = matchedItems.isEmpty
            ? "현재 동기화된 KLMS 항목과 직접 연결되는 항목은 아직 없습니다."
            : "현재 동기화된 KLMS 항목 \(matchedItems.count)개와 제목, 과목, 일정 정보가 겹칩니다."
        steps.append(MacMailAnalysisStep(id: "match", title: "기존 항목 비교", detail: matchDetail, systemImage: "link", tint: matchedItems.isEmpty ? Color.klmsMacSecondaryText : Color.klmsMacSuccessBorder))

        if !urls.isEmpty {
            steps.append(MacMailAnalysisStep(id: "links", title: "링크 감지", detail: "본문에서 URL \(urls.count)개를 찾았습니다. KLMS 링크가 있으면 다음 동기화와 대조할 수 있습니다.", systemImage: "link.circle", tint: Color.klmsMacCommandAccent))
        }
        return steps
    }

    private static func detectCourse(in text: String, lines: [String], knownCourses: [String]) -> String {
        if let known = knownCourses.first(where: { text.localizedCaseInsensitiveContains($0) }) {
            return known
        }
        if let captured = firstCapture("(?:과목|강의|Course)[:：]\\s*([^\\n]+)", in: text) {
            return resolvedCourseDisplay(for: captured, knownCourses: knownCourses) ?? captured
        }
        if let captured = firstCapture("(?:TA|조교)\\s*(?:for|of|[:：])\\s*([A-Z]{2,}\\s*\\d{2,4}[A-Z]?)", in: text) {
            return resolvedCourseDisplay(for: captured, knownCourses: knownCourses) ?? captured.replacingOccurrences(of: " ", with: "")
        }
        if let captured = firstCapture("([A-Z]{2,}\\s*\\d{2,4}[A-Z]?)\\s*(?:TA|조교)", in: text) {
            return resolvedCourseDisplay(for: captured, knownCourses: knownCourses) ?? captured.replacingOccurrences(of: " ", with: "")
        }
        if let captured = firstCapture("\\b([A-Z]{2,}\\s*\\.?\\s*\\d{2,4}[A-Z]?)\\b", in: text),
           let resolved = resolvedCourseDisplay(for: captured, knownCourses: knownCourses) {
            return resolved
        }
        if let bracket = firstCapture("^\\s*\\[([^\\]\\n]{2,40})\\]", in: lines.first ?? "") {
            return resolvedCourseDisplay(for: bracket, knownCourses: knownCourses) ?? bracket
        }
        return ""
    }

    private static func resolvedCourseDisplay(for rawCourseOrCode: String, knownCourses: [String]) -> String? {
        let code = normalizedCourseCode(rawCourseOrCode)
        guard !code.isEmpty else { return nil }
        if let known = knownCourseName(for: code, knownCourses: knownCourses) {
            return "\(known) (\(code))"
        }
        if let fallback = fallbackCourseCodeAliases[code] {
            return "\(fallback) (\(code))"
        }
        return code == rawCourseOrCode.trimmingCharacters(in: .whitespacesAndNewlines) ? nil : code
    }

    private static func normalizedCourseCode(_ raw: String) -> String {
        let compact = raw
            .uppercased()
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.range(of: #"^[A-Z]{2,}\d{2,4}[A-Z]?$"#, options: .regularExpression) != nil else {
            return ""
        }
        return compact
    }

    private static func knownCourseName(for code: String, knownCourses: [String]) -> String? {
        switch code {
        case "EE488":
            return knownCourses.first {
                $0.localizedCaseInsensitiveContains("전자공학을 위한 사이버 보안 개론")
            } ?? knownCourses.first {
                $0.localizedCaseInsensitiveContains("Introduction to Cybersecurity for EE")
            }
        default:
            return nil
        }
    }

    private static let fallbackCourseCodeAliases: [String: String] = [
        "EE488": "전기 전자공학특강<전자공학을 위한 사이버 보안 개론>",
    ]

    private static func detectTitle(lines: [String], kind: MacMailPasteDetectedKind, course: String) -> String {
        if let subject = lines.first(where: { line in
            let lower = line.lowercased()
            return lower.hasPrefix("subject:") || line.hasPrefix("제목:") || line.hasPrefix("제목：")
        }) {
            return cleanTitle(subject)
        }
        if let inferred = inferredTitle(lines: lines, kind: kind, course: course) {
            return inferred
        }
        if let title = lines.first(where: { line in
            let lower = line.lowercased()
            return !lower.hasPrefix("from:")
                && !lower.hasPrefix("to:")
                && !lower.hasPrefix("date:")
                && !lower.hasPrefix("sent:")
                && !line.hasPrefix("보낸 사람:")
                && !line.hasPrefix("받는 사람:")
                && !line.hasPrefix("날짜:")
                && !line.hasPrefix("https://")
                && !line.hasPrefix("http://")
                && !isMailGreetingOrSignature(line)
        }) {
            return cleanTitle(title)
        }
        return ""
    }

    private static func inferredTitle(lines: [String], kind: MacMailPasteDetectedKind, course: String) -> String? {
        let joined = lines.joined(separator: "\n").lowercased()
        switch kind {
        case .exam:
            if joined.contains("final exam") || joined.contains("기말고사") {
                return "기말고사"
            }
            if joined.contains("midterm exam") || joined.contains("중간고사") {
                return "중간고사"
            }
            if joined.contains("quiz") || joined.contains("퀴즈") {
                return "퀴즈"
            }
            return "시험 안내"
        case .assignment:
            if let line = lines.first(where: { line in
                let lower = line.lowercased()
                return lower.contains("assignment") || lower.contains("homework") || lower.contains("과제")
            }) {
                return cleanTitle(line)
            }
            return "과제 안내"
        case .file:
            if let line = lines.first(where: { line in
                let lower = line.lowercased()
                return lower.contains("attachment") || lower.contains("file") || lower.contains("첨부") || lower.contains("파일") || lower.contains("자료")
            }) {
                return cleanTitle(line)
            }
            return "파일 안내"
        case .notice:
            return nil
        case .none:
            return nil
        }
    }

    private static func isMailGreetingOrSignature(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.hasPrefix("dear ")
            || lower == "hi,"
            || lower.hasPrefix("hi, ")
            || lower.hasPrefix("hello")
            || lower.hasPrefix("best regards")
            || lower.hasPrefix("regards")
            || lower.hasPrefix("thanks")
            || line.hasPrefix("학생 여러분")
            || line.hasPrefix("안녕하세요")
            || line.hasPrefix("감사합니다")
            || line.hasPrefix("질문이 있으면")
    }

    private static func cleanTitle(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Subject:", "subject:", "제목:", "제목：", "[KLMS]", "KLMS:"] {
            if title.hasPrefix(prefix) {
                title.removeFirst(prefix.count)
                title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if let range = title.range(of: "^\\[[^\\]]+\\]\\s*", options: .regularExpression) {
            title.removeSubrange(range)
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func detectDueText(in text: String) -> String {
        if let captured = firstCapture("(?:due|deadline|exam schedule|schedule|마감|제출|일시|일정|시험일|시험 일정|시험일정|시험 시간|시험시간)[:：]?\\s*([^\\n]{1,160})", in: text) {
            return dateSnippet(in: captured) ?? captured
        }
        if let subjectDate = dateSnippet(in: text) {
            return subjectDate
        }
        let datePatterns = [
            "\\d{4}\\s*[년.-]\\s*\\d{1,2}\\s*[월.-]\\s*\\d{1,2}\\s*일?(?:[^\\n]{0,40})?",
            "(?:January|Jan|February|Feb|March|Mar|April|Apr|May|June|Jun|July|Jul|August|Aug|September|Sep|October|Oct|November|Nov|December|Dec)\\s+\\d{1,2}(?:st|nd|rd|th)?(?:,?\\s*\\d{4})?(?:[^\\n]{0,50})?",
            "\\d{1,2}/\\d{1,2}(?:/\\d{2,4})?(?:[^\\n]{0,30})?",
        ]
        for pattern in datePatterns {
            if let match = regexMatches(pattern, in: text).first {
                return match.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return ""
    }

    private static func matchItems(
        items: [MacMailPasteMatchedItem],
        text: String,
        kind: MacMailPasteDetectedKind,
        title: String,
        course: String,
        dueText: String
    ) -> [MacMailPasteMatchedItem] {
        let lowerText = text.lowercased()
        let normalizedText = normalizeMailText(text)
        let normalizedCourse = normalizeMailText(course)
        let normalizedDue = normalizeMailText(dueText)
        let detectedTitleTokens = titleTokens(title).map(normalizeMailText)
        let scored = items.compactMap { item -> (MacMailPasteMatchedItem, Int)? in
            guard kind == .none || item.matches(kind: kind) else {
                return nil
            }
            var score = 0
            if item.matches(kind: kind) {
                score += 2
            }
            let itemCourse = normalizeMailText(item.course)
            if !normalizedCourse.isEmpty,
               !itemCourse.isEmpty,
               (itemCourse.contains(normalizedCourse) || normalizedCourse.contains(itemCourse)) {
                score += 3
            }
            if !item.title.isEmpty && lowerText.contains(item.title.lowercased()) {
                score += 8
            } else {
                let itemTitleText = normalizeMailText(item.title)
                var tokenHits = titleTokens(item.title)
                    .map(normalizeMailText)
                    .filter { !$0.isEmpty && normalizedText.contains($0) }
                    .count
                if !detectedTitleTokens.isEmpty, !itemTitleText.isEmpty {
                    tokenHits += detectedTitleTokens.filter { !$0.isEmpty && itemTitleText.contains($0) }.count
                }
                if tokenHits >= 2 {
                    score += min(5, tokenHits)
                }
            }
            if !normalizedDue.isEmpty && normalizeMailText(item.searchText).contains(normalizedDue) {
                score += 1
            }
            guard score >= 5 else { return nil }
            return (item, score)
        }
        return scored
            .sorted {
                if $0.1 != $1.1 {
                    return $0.1 > $1.1
                }
                return $0.0.title.localizedStandardCompare($1.0.title) == .orderedAscending
            }
            .map(\.0)
    }

    private static func confidenceScore(
        kind: MacMailPasteDetectedKind,
        title: String,
        course: String,
        dueText: String,
        matchedItems: [MacMailPasteMatchedItem]
    ) -> Int {
        if !matchedItems.isEmpty {
            return 90
        }
        var score = kind == .none ? 20 : 42
        if !title.isEmpty {
            score += 18
        }
        if !course.isEmpty {
            score += 14
        }
        if !dueText.isEmpty {
            score += 16
        }
        return min(score, 82)
    }

    private static func suggestedAction(kind: MacMailPasteDetectedKind, matchedItems: [MacMailPasteMatchedItem]) -> String {
        if !matchedItems.isEmpty {
            return "기존 KLMS 항목과 맞아 보입니다. 대시보드에서 해당 항목의 상태를 확인하세요."
        }
        switch kind {
        case .assignment:
            return "과제 후보로 보입니다. KLMS에 없는 메일 전용 마감이라면 캘린더에 수동 등록하세요."
        case .exam:
            return "시험 후보로 보입니다. KLMS 동기화에 아직 잡히지 않았다면 캘린더에 수동 등록하세요."
        case .notice:
            return "공지 후보로 보입니다. 일정이 포함된 공지라면 날짜를 확인한 뒤 캘린더에 등록할 수 있습니다."
        case .file:
            return "파일 후보로 보입니다. 파일 대시보드에 임시로 반영한 뒤 실제 파일 동기화와 대조하세요."
        case .none:
            return "분류가 확실하지 않습니다. 제목, 과목명, 마감일이 포함된 본문 전체를 붙여넣어 주세요."
        }
    }

    private static func calendarInputs(from dueText: String) -> (start: String, end: String) {
        guard let date = parseMailDate(dueText) else {
            return ("", "")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return (formatter.string(from: date), formatter.string(from: date.addingTimeInterval(60 * 60)))
    }

    private static func parseMailDate(_ raw: String) -> Date? {
        var text = (dateSnippet(in: raw) ?? raw)
            .replacingOccurrences(of: #"(\d)(st|nd|rd|th)"#, with: "$1", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"(?i)\bat\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "오전", with: "AM")
            .replacingOccurrences(of: "오후", with: "PM")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: #"[()]"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s*(월요일|화요일|수요일|목요일|금요일|토요일|일요일|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday),?\s*"#, with: " ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"(\d{1,2})\s*시\s*(\d{1,2})\s*분"#, with: "$1:$2", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(\d{1,2})\s*시"#, with: "$1:00", options: .regularExpression)
        let currentYear = Calendar(identifier: .gregorian).component(.year, from: Date())
        let candidates = [
            text,
            "\(currentYear) \(text)",
        ]
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        let formats = [
            ("ko_KR", "yyyy년 M월 d일 a h:mm"),
            ("ko_KR", "yyyy년 M월 d일 H:mm"),
            ("ko_KR", "yyyy M월 d일 a h:mm"),
            ("ko_KR", "yyyy M월 d일 H:mm"),
            ("en_US_POSIX", "yyyy MMMM d, h:mm a"),
            ("en_US_POSIX", "yyyy MMM d, h:mm a"),
            ("en_US_POSIX", "yyyy MMMM d h:mm a"),
            ("en_US_POSIX", "yyyy MMM d h:mm a"),
            ("en_US_POSIX", "yyyy MMMM d, HH:mm"),
            ("en_US_POSIX", "yyyy MMM d, HH:mm"),
            ("en_US_POSIX", "yyyy MMMM d HH:mm"),
            ("en_US_POSIX", "yyyy MMM d HH:mm"),
            ("en_US_POSIX", "yyyy M/d HH:mm"),
            ("en_US_POSIX", "yyyy M/d/yyyy HH:mm"),
        ]
        for candidate in candidates {
            for (locale, format) in formats {
                formatter.locale = Locale(identifier: locale)
                formatter.dateFormat = format
                if let date = formatter.date(from: candidate) {
                    return date
                }
            }
        }
        return nil
    }

    private static func dateSnippet(in text: String) -> String? {
        let patterns = [
            "(?:\\d{4}\\s*년\\s*)?\\d{1,2}\\s*월\\s*\\d{1,2}\\s*일(?:\\s*(?:월요일|화요일|수요일|목요일|금요일|토요일|일요일))?(?:\\s*(?:오전|오후|AM|PM)?\\s*\\d{1,2}(?::\\d{2}|\\s*시(?:\\s*\\d{1,2}\\s*분)?))?",
            "\\d{4}\\s*[.-]\\s*\\d{1,2}\\s*[.-]\\s*\\d{1,2}(?:\\s*(?:오전|오후|AM|PM)?\\s*\\d{1,2}:\\d{2})?",
            "(?:January|Jan|February|Feb|March|Mar|April|Apr|May|June|Jun|July|Jul|August|Aug|September|Sep|October|Oct|November|Nov|December|Dec)\\s+\\d{1,2}(?:st|nd|rd|th)?(?:,?\\s*\\d{4})?(?:,?\\s*(?:at\\s*)?(?:(?:AM|PM|오전|오후)\\s*)?\\d{1,2}:\\d{2}(?:\\s*(?:AM|PM))?)?",
            "\\d{1,2}/\\d{1,2}(?:/\\d{2,4})?(?:\\s*(?:AM|PM|오전|오후)?\\s*\\d{1,2}:\\d{2})?",
        ]
        for pattern in patterns {
            if let match = regexMatches(pattern, in: text).first {
                return match
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "().,"))
            }
        }
        return nil
    }

    private static func titleTokens(_ title: String) -> [String] {
        title
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 }
    }

    private static func keywordScore(_ text: String, weightedKeywords: [(String, Int)]) -> Int {
        weightedKeywords.reduce(0) { partialResult, keyword in
            partialResult + (text.contains(keyword.0) ? keyword.1 : 0)
        }
    }

    private static func normalizeMailText(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func regexMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            return String(text[swiftRange])
        }
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension MacMailPasteMatchedItem {
    func matches(kind: MacMailPasteDetectedKind) -> Bool {
        switch kind {
        case .assignment:
            return kindLabel.contains("과제")
        case .exam:
            return kindLabel.contains("시험")
        case .notice:
            return kindLabel == "공지"
        case .file:
            return kindLabel == "파일"
        case .none:
            return false
        }
    }
}

private struct CalendarEventEditSheet: View {
    var change: CalendarChange
    var action: ServerRelayItemActionKind
    var onSave: (CalendarEventEdit) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var startAt: String
    @State private var dueAt: String
    @State private var location: String

    init(change: CalendarChange, action: ServerRelayItemActionKind, onSave: @escaping (CalendarEventEdit) -> Void) {
        self.change = change
        self.action = action
        self.onSave = onSave
        let defaults = change.editDefaults
        _title = State(initialValue: defaults.title)
        _startAt = State(initialValue: defaults.startAt)
        _dueAt = State(initialValue: defaults.dueAt)
        _location = State(initialValue: defaults.location)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(action == .calendarCreate ? "캘린더 일정 등록" : "캘린더 내용 수정")
                .font(.headline)
            Text(action == .calendarCreate
                ? "Apple Calendar에 새 이벤트를 등록합니다. 제목과 시작 시간은 반드시 확인해 주세요."
                : "Apple Calendar에 저장된 이벤트를 직접 수정합니다. 비워 둔 시간/장소는 변경하지 않습니다.")
                .font(.caption)
                .foregroundStyle(Color.klmsMacSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("제목")
                        .foregroundStyle(Color.klmsMacSecondaryText)
                    TextField("일정 제목", text: $title)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("시작")
                        .foregroundStyle(Color.klmsMacSecondaryText)
                    TextField("2026-06-17 13:00", text: $startAt)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("종료")
                        .foregroundStyle(Color.klmsMacSecondaryText)
                    TextField("2026-06-17 16:00", text: $dueAt)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("장소")
                        .foregroundStyle(Color.klmsMacSecondaryText)
                    TextField("장소", text: $location)
                        .textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Spacer()
                Button("취소") {
                    dismiss()
                }
                .buttonStyle(KLMSMacActionButtonStyle())
                Button(action == .calendarCreate ? "등록" : "저장") {
                    onSave(CalendarEventEdit(title: title, startAt: startAt, dueAt: dueAt, location: location))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(KLMSMacActionButtonStyle(tone: action == .calendarCreate ? .success : .primary))
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
                .foregroundStyle(Color.klmsMacSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text(change.nextActionText)
                .font(.caption2)
                .foregroundStyle(Color.klmsMacSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text(change.actionButtonHelpText)
                .font(.caption2)
                .foregroundStyle(Color.klmsMacSecondaryText.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsMacWarningBackground, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.klmsMacWarningBorder.opacity(0.24), lineWidth: 1)
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

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct EmptyDetailText: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Color.klmsMacSecondaryText)
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
