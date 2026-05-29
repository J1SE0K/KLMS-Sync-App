import XCTest
@testable import KLMSShared

final class DashboardDataModelTests: XCTestCase {
    func testManualOverrideStoreUpdatesKnownSectionsAndPreservesOtherSections() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("klms-dashboard-overrides-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let url = directory.appendingPathComponent("manual_assignment_overrides.json")
        try """
        {
          "assignments": {},
          "class_times": {"Course": "월 10:00-11:00"},
          "notice_filters": {"ignored_keywords": ["설문"]}
        }
        """.write(to: url, atomically: true, encoding: .utf8)

        let item = try decodeStateItem(url: "https://klms.kaist.ac.kr/mod/assign/view.php?id=1")
        let store = ManualOverrideStore(url: url)
        try store.saveAssignmentStatus("completed", for: item)

        let snapshot = try store.load()
        XCTAssertEqual(snapshot.assignmentStatus(for: item), "completed")

        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertNotNil(raw?["class_times"])
        XCTAssertNotNil(raw?["notice_filters"])
    }

    func testManualOverrideStoreMergesMissingOverridesWithoutReplacingCanonicalValues() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("klms-dashboard-overrides-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let targetURL = directory.appendingPathComponent("canonical_manual_assignment_overrides.json")
        let sourceURL = directory.appendingPathComponent("configured_manual_assignment_overrides.json")
        try """
        {
          "assignments": {
            "https://klms.kaist.ac.kr/mod/assign/view.php?id=1": "ignored"
          },
          "exams": {
            "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=1": {"status": "ignored"}
          }
        }
        """.write(to: targetURL, atomically: true, encoding: .utf8)
        try """
        {
          "assignments": {
            "https://klms.kaist.ac.kr/mod/assign/view.php?id=1": "completed",
            "https://klms.kaist.ac.kr/mod/assign/view.php?id=2": "completed"
          },
          "exams": {
            "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=1": {"status": "approved"},
            "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=2": {"status": "approved", "location": "E3"}
          }
        }
        """.write(to: sourceURL, atomically: true, encoding: .utf8)

        let changed = try ManualOverrideStore(url: targetURL).mergeMissingOverrides(from: sourceURL)
        XCTAssertTrue(changed)

        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: targetURL)) as? [String: Any]
        let assignments = raw?["assignments"] as? [String: String]
        let exams = raw?["exams"] as? [String: [String: String]]

        XCTAssertEqual(assignments?["https://klms.kaist.ac.kr/mod/assign/view.php?id=1"], "ignored")
        XCTAssertEqual(assignments?["https://klms.kaist.ac.kr/mod/assign/view.php?id=2"], "completed")
        XCTAssertEqual(exams?["https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=1"]?["status"], "ignored")
        XCTAssertEqual(exams?["https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=2"]?["status"], "approved")
        XCTAssertEqual(exams?["https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=2"]?["location"], "E3")
    }

    func testManualOverrideStoreSavesExamOverrideUsingResolvableKey() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("klms-dashboard-exam-overrides-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let item = try decodeStateItem(
            url: "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=2",
            title: "Midterm",
            course: "Algorithms"
        )
        let store = ManualOverrideStore(url: directory.appendingPathComponent("manual_assignment_overrides.json"))
        try store.saveExamOverride(ExamOverride(status: "approved", location: "E3-1"), for: item)

        let snapshot = try store.load()
        let override = snapshot.examOverride(for: item)
        XCTAssertEqual(override.status, "approved")
        XCTAssertEqual(override.location, "E3-1")
    }

    func testManualCompletedOverrideIsAppliedToVisibleStateImmediately() throws {
        let item = try decodeStateItem(url: "https://klms.kaist.ac.kr/mod/assign/view.php?id=42")
        let state = LegacySyncState(content: .init(assignments: [item]))
        let updated = state.applyingManualOverrides(.init(assignments: [item.url: "completed"]))

        XCTAssertEqual(updated.content.assignments.count, 0)
        XCTAssertEqual(updated.content.completedAssignments.count, 1)
        XCTAssertEqual(updated.content.completedAssignments.first?.recordStatus, "completed")
        XCTAssertEqual(updated.content.completedAssignments.first?.completionReason, "manual_completed")
        XCTAssertEqual(updated.content.assignmentRecords.first?.recordStatus, "completed")
    }

    func testExamOverridePromotesCandidateToVisibleExamImmediately() throws {
        let item = try decodeStateItem(
            url: "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=8",
            title: "기말고사",
            course: "영미 단편소설",
            category: "exam_candidate",
            syncDue: "2099-06-04T15:30:00+09:00"
        )
        let key = ManualOverridesSnapshot.preferredExamOverrideKey(for: item)
        let state = LegacySyncState(content: .init(examCandidates: [item]))
        let updated = state.applyingManualOverrides(.init(
            exams: [
                key: ExamOverride(
                    status: "approved",
                    due: "2099년 6월 4일 오후 2:30 - 오후 3:30",
                    syncStart: "2099-06-04T14:30:00+09:00",
                    syncDue: "2099-06-04T15:30:00+09:00",
                    location: "강의실",
                    coverage: "전체 범위"
                )
            ]
        ))

        XCTAssertEqual(updated.content.examCandidates.count, 0)
        XCTAssertEqual(updated.content.examItems.count, 1)
        XCTAssertEqual(updated.content.examItems.first?.category, "exam")
        XCTAssertEqual(updated.content.examItems.first?.syncStart, "2099-06-04T14:30:00+09:00")
        XCTAssertEqual(updated.content.examItems.first?.location, "강의실")
        XCTAssertEqual(updated.content.examItems.first?.coverageSummary, "전체 범위")
    }

    func testPastExamsAreHiddenFromDashboardState() throws {
        let exam = try decodeStateItem(
            url: "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=9",
            title: "중간고사",
            course: "영미 단편소설",
            category: "exam",
            syncDue: "2020-04-16T15:30:00+09:00"
        )
        let candidate = try decodeStateItem(
            url: "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=10",
            title: "기말고사",
            course: "영미 단편소설",
            category: "exam_candidate",
            syncDue: "2020-06-04T15:30:00+09:00"
        )
        let state = LegacySyncState(content: .init(examItems: [exam], examCandidates: [candidate]))
        let updated = state.applyingManualOverrides(.init())

        XCTAssertEqual(updated.content.examItems.count, 0)
        XCTAssertEqual(updated.content.examCandidates.count, 0)
    }

    func testClearedManualCompletedOverrideRestoresVisibleAssignment() throws {
        let item = try decodeStateItem(
            url: "https://klms.kaist.ac.kr/mod/assign/view.php?id=43",
            recordStatus: "completed",
            completionReason: "manual_completed"
        )
        let state = LegacySyncState(content: .init(
            completedAssignments: [item],
            assignmentRecords: [item]
        ))

        let updated = state.applyingManualOverrides(.init())

        XCTAssertEqual(updated.content.assignments.count, 1)
        XCTAssertEqual(updated.content.assignments.first?.recordStatus, "active")
        XCTAssertEqual(updated.content.completedAssignments.count, 0)
        XCTAssertEqual(updated.content.assignmentRecords.first?.recordStatus, "active")
    }

    func testManualOverrideStoreMigratesCompositeAssignmentKeyToUrlKey() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("klms-dashboard-assignment-key-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let item = try decodeStateItem(
            url: "https://klms.kaist.ac.kr/mod/assign/view.php?id=44",
            title: "Essay"
        )
        let url = directory.appendingPathComponent("manual_assignment_overrides.json")
        try """
        {
          "assignments": {
            "\(item.url)::Essay": "ignored"
          }
        }
        """.write(to: url, atomically: true, encoding: .utf8)

        let store = ManualOverrideStore(url: url)
        try store.saveAssignmentStatus("completed", for: item, currentKey: "\(item.url)::Essay")
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let assignments = raw?["assignments"] as? [String: Any]

        XCTAssertEqual(assignments?[item.url] as? String, "completed")
        XCTAssertNil(assignments?["\(item.url)::Essay"])
    }

    func testNoticeUserStateStoreMarksNoticeReadAndImportant() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("klms-dashboard-notice-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let notice = try JSONDecoder().decode(NoticeDigestEntry.self, from: Data("""
        {
          "url": "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=2",
          "course": "Algorithms",
          "title": "Notice",
          "fingerprint": "abc"
        }
        """.utf8))
        let store = NoticeUserStateStore(url: directory.appendingPathComponent("notice_user_state.json"))
        try store.setRead(true, notice: notice)
        try store.setImportant(true, notice: notice)
        try store.setHidden(true, notice: notice)

        let state = try store.load().notices[notice.noticeIdentifier]
        XCTAssertEqual(state?.readFingerprint, "abc")
        XCTAssertEqual(state?.important, true)
        XCTAssertEqual(state?.hidden, true)
    }

    func testAppUserStateStoreTracksHiddenAndTrashedFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("klms-dashboard-app-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let store = AppUserStateStore(url: directory.appendingPathComponent("app_user_state.json"))
        try store.setHidden(
            true,
            key: "file-key",
            title: "Slides.pdf",
            course: "Algorithms",
            path: "/tmp/Slides.pdf",
            url: "https://klms.kaist.ac.kr/file",
            bucket: .files
        )
        try store.setIgnored(
            true,
            key: "quarantine-key",
            title: "Suspicious.pdf",
            course: "격리",
            path: "/tmp/Suspicious.pdf",
            url: "",
            bucket: .quarantine
        )

        let state = try store.load()
        XCTAssertEqual(state.files["file-key"]?.hidden, true)
        XCTAssertEqual(state.files["file-key"]?.isHiddenLike, true)
        XCTAssertEqual(state.quarantine["quarantine-key"]?.ignored, true)
        XCTAssertEqual(state.quarantine["quarantine-key"]?.isHiddenLike, true)
    }

    func testAppUserStateRestoreClearsTrashedMarker() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("klms-dashboard-app-state-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let store = AppUserStateStore(url: directory.appendingPathComponent("app_user_state.json"))
        try store.markTrashed(
            key: "file-key",
            title: "Slides.pdf",
            course: "Algorithms",
            path: "/tmp/Slides.pdf",
            url: "https://klms.kaist.ac.kr/file",
            bucket: .files
        )
        XCTAssertEqual(try store.load().files["file-key"]?.isHiddenLike, true)

        try store.setHidden(
            false,
            key: "file-key",
            title: "Slides.pdf",
            course: "Algorithms",
            path: "/tmp/Slides.pdf",
            url: "https://klms.kaist.ac.kr/file",
            bucket: .files
        )

        let state = try store.load().files["file-key"]
        XCTAssertEqual(state?.hidden, false)
        XCTAssertNil(state?.trashedAt)
        XCTAssertEqual(state?.isHiddenLike, false)
    }

    func testCommandRunHistoryStoresNewestRunsFirstAndTrimsOutput() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("klms-dashboard-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let store = CommandRunHistoryStore(url: directory.appendingPathComponent("history.json"), maxRecords: 2)
        let result = KLMSCommandResult(
            invocation: KLMSEngineCommand.noticeSync.invocation(),
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 3),
            exitCode: 0,
            standardOutput: (0..<130).map { "line-\($0)" }.joined(separator: "\n"),
            standardError: "",
            authDigits: nil
        )

        let history = try store.append(result)

        XCTAssertEqual(history.records.count, 1)
        XCTAssertEqual(history.records.first?.command, .noticeSync)
        XCTAssertEqual(history.records.first?.elapsedSecondsText, "2s")
        XCTAssertFalse(history.records.first?.outputTail.contains("line-0") ?? true)
        XCTAssertTrue(history.records.first?.outputTail.contains("line-129") ?? false)
        XCTAssertEqual(store.load().records.first?.command, .noticeSync)
    }

    func testCancelledCommandHistoryIsNotAttentionFailure() {
        let record = CommandRunRecord(
            command: .fullSync,
            dryRun: false,
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 3),
            exitCode: 15,
            wasCancelled: true,
            authDigits: "74",
            outputTail: "KAIST 인증 번호: 74"
        )

        XCTAssertEqual(record.statusText, "중단됨")
        XCTAssertFalse(record.succeeded)
        XCTAssertFalse(record.needsAttention)
    }

    func testCancelledCommandHistoryRedactsAuthDigits() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("klms-dashboard-cancel-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let store = CommandRunHistoryStore(url: directory.appendingPathComponent("history.json"))
        let result = KLMSCommandResult(
            invocation: KLMSEngineCommand.fullSync.invocation(),
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 3),
            exitCode: 15,
            standardOutput: "KAIST 인증 번호: 74\nstatus=timeout digits=74",
            standardError: "",
            authDigits: "74",
            wasCancelled: true
        )

        let history = try store.append(result)

        XCTAssertNil(history.records.first?.authDigits)
        XCTAssertEqual(history.records.first?.outputTail, "KAIST 인증 번호: --\nstatus=timeout digits=--")
        XCTAssertEqual(store.load().records.first?.outputTail, "KAIST 인증 번호: --\nstatus=timeout digits=--")
    }

    func testAppDataBackupCreatesAndRestoresPrivateState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("klms-dashboard-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let paths = KLMSPaths(engineRoot: directory)
        try FileManager.default.createDirectory(at: paths.cacheURL, withIntermediateDirectories: true)
        try "KLMS_SSO_LOGIN_ID=\"user\"\n".write(to: paths.configURL, atomically: true, encoding: .utf8)
        try "{\"assignments\":{}}\n".write(to: paths.overridesURL, atomically: true, encoding: .utf8)

        let manager = AppDataBackupManager(paths: paths)
        let backup = try manager.createBackup(now: Date(timeIntervalSince1970: 1_800_000_000))
        try "KLMS_SSO_LOGIN_ID=\"changed\"\n".write(to: paths.configURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(backup.fileCount, 2)
        XCTAssertEqual(manager.latestBackup()?.id, backup.id)
        _ = try manager.restoreLatestBackup()

        let restored = try String(contentsOf: paths.configURL, encoding: .utf8)
        XCTAssertTrue(restored.contains("user"))
    }

    func testAcademicTermInferenceUsesExplicitCourseNameAndDates() throws {
        XCTAssertEqual(AcademicTerm.infer(course: "Algorithms_2026_Spring")?.displayName, "2026년 봄학기")
        XCTAssertEqual(AcademicTerm.infer(course: "Data 2026년 2학기")?.displayName, "2026년 가을학기")
        XCTAssertEqual(AcademicTerm.infer(dateTexts: ["2026-05-23T08:55:35Z"])?.displayName, "2026년 봄학기")
        XCTAssertEqual(AcademicTerm.infer(dateTexts: ["2026년 1월 10일"])?.displayName, "2025년 가을학기")
        XCTAssertEqual(
            AcademicTerm.infer(dateTexts: ["5월 23일"], generatedAt: "2026-05-23T08:55:35Z")?.displayName,
            "2026년 봄학기"
        )
    }

    func testStateAndNoticeExposeAcademicTerm() throws {
        let item = try decodeStateItem(
            url: "https://klms.kaist.ac.kr/mod/assign/view.php?id=45",
            title: "Final report",
            course: "Course_2026_Fall"
        )
        XCTAssertEqual(item.academicTerm?.displayName, "2026년 가을학기")

        let notice = try JSONDecoder().decode(NoticeDigestEntry.self, from: Data("""
        {
          "url": "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=2&bwid=3",
          "course": "Algorithms",
          "title": "Notice",
          "posted_at": "2026-04-02",
          "fingerprint": "def"
        }
        """.utf8))

        XCTAssertEqual(notice.academicTerm(generatedAt: "2026-05-23T08:55:35Z")?.displayName, "2026년 봄학기")
    }

    func testVisibleCountsExcludeHiddenItemsAndKeepThemInHiddenSummary() throws {
        let visibleAssignment = try decodeStateItem(url: "https://klms.kaist.ac.kr/mod/assign/view.php?id=100")
        let hiddenAssignment = try decodeStateItem(url: "https://klms.kaist.ac.kr/mod/assign/view.php?id=101")
        let visibleHelpDesk = try decodeStateItem(
            url: "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=3&bwid=1",
            title: "Question"
        )
        let hiddenHelpDesk = try decodeStateItem(
            url: "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=3&bwid=2",
            title: "Ignored question"
        )
        let visibleExam = try decodeStateItem(
            url: "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=4&bwid=1",
            title: "Final",
            category: "exam",
            syncDue: "2099-06-01T09:00:00+09:00"
        )
        let hiddenExam = try decodeStateItem(
            url: "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=4&bwid=2",
            title: "Not exam",
            category: "exam",
            syncDue: "2099-06-02T09:00:00+09:00"
        )
        let pastHiddenExam = try decodeStateItem(
            url: "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=4&bwid=3",
            title: "Past not exam",
            category: "exam",
            syncDue: "2020-06-02T09:00:00+09:00"
        )
        let rawState = LegacySyncState(content: .init(
            assignments: [visibleAssignment, hiddenAssignment],
            examItems: [visibleExam, hiddenExam, pastHiddenExam],
            helpDeskItems: [visibleHelpDesk, hiddenHelpDesk]
        ))
        let overrides = ManualOverridesSnapshot(
            assignments: [
                ManualOverridesSnapshot.preferredAssignmentOverrideKey(for: hiddenAssignment): "ignored",
                ManualOverridesSnapshot.preferredAssignmentOverrideKey(for: hiddenHelpDesk): "ignored",
            ],
            exams: [
                ManualOverridesSnapshot.preferredExamOverrideKey(for: hiddenExam): ExamOverride(status: "ignored"),
                ManualOverridesSnapshot.preferredExamOverrideKey(for: pastHiddenExam): ExamOverride(status: "ignored"),
            ]
        )

        let visibleNotice = try decodeNotice(url: "https://klms.kaist.ac.kr/notice-visible", title: "Visible")
        let hiddenNotice = try decodeNotice(url: "https://klms.kaist.ac.kr/notice-hidden", title: "Hidden")
        let noticeDigest = NoticeDigest(
            noticeCount: 2,
            courses: [NoticeCourseDigest(course: "Course", notices: [visibleNotice, hiddenNotice])]
        )
        let noticeState = NoticeUserStateFile(notices: [
            hiddenNotice.noticeIdentifier: NoticeInteractionState(title: hiddenNotice.title, hidden: true)
        ])
        let appState = AppUserStateFile(
            files: [
                "https://klms.kaist.ac.kr/file-hidden": FileInteractionState(
                    title: "Hidden.pdf",
                    url: "https://klms.kaist.ac.kr/file-hidden",
                    hidden: true
                )
            ],
            quarantine: [
                "https://klms.kaist.ac.kr/q-hidden": FileInteractionState(
                    title: "Quarantine.pdf",
                    url: "https://klms.kaist.ac.kr/q-hidden",
                    ignored: true
                )
            ]
        )
        let downloadResult = try JSONDecoder().decode(CourseFileDownloadResult.self, from: Data("""
        {
          "newFilesCopiedCount": 2,
          "results": [
            {"url": "https://klms.kaist.ac.kr/file-visible", "relative_path": "Visible.pdf", "copied_to_new_files_inbox": true},
            {"url": "https://klms.kaist.ac.kr/file-hidden", "relative_path": "Hidden.pdf", "copied_to_new_files_inbox": true}
          ]
        }
        """.utf8))
        let quarantineReport = try JSONDecoder().decode(QuarantineReport.self, from: Data("""
        {
          "quarantineCount": 2,
          "records": [
            {"url": "https://klms.kaist.ac.kr/q-visible", "quarantine_path": "/tmp/visible.pdf", "quarantine_relative_path": "visible.pdf"},
            {"url": "https://klms.kaist.ac.kr/q-hidden", "quarantine_path": "/tmp/hidden.pdf", "quarantine_relative_path": "hidden.pdf"}
          ]
        }
        """.utf8))

        let snapshot = EngineSnapshot(
            rawLegacyState: rawState,
            legacyState: rawState.applyingManualOverrides(overrides),
            manualOverrides: overrides,
            noticeDigest: noticeDigest,
            noticeUserState: noticeState,
            appUserState: appState,
            downloadResult: downloadResult,
            quarantineReport: quarantineReport
        )

        XCTAssertEqual(snapshot.visibleCounts.assignments, 1)
        XCTAssertEqual(snapshot.visibleCounts.exams, 1)
        XCTAssertEqual(snapshot.visibleCounts.helpDesk, 1)
        XCTAssertEqual(snapshot.visibleCounts.notices, 1)
        XCTAssertEqual(snapshot.visibleCounts.newFiles, 1)
        XCTAssertEqual(snapshot.visibleCounts.quarantine, 1)
        XCTAssertEqual(snapshot.hiddenSummary.assignments, 2)
        XCTAssertEqual(snapshot.hiddenSummary.exams, 1)
        XCTAssertEqual(snapshot.hiddenSummary.notices, 1)
        XCTAssertEqual(snapshot.hiddenSummary.files, 1)
        XCTAssertEqual(snapshot.hiddenSummary.quarantine, 1)
        XCTAssertEqual(snapshot.hiddenSummary.total, 6)
    }

    private func decodeStateItem(
        url: String,
        title: String = "Item",
        course: String = "Course",
        category: String = "assignment",
        due: String = "",
        syncDue: String = "",
        recordStatus: String = "",
        completionReason: String = ""
    ) throws -> StateItem {
        try JSONDecoder().decode(StateItem.self, from: Data("""
        {
          "url": "\(url)",
          "title": "\(title)",
          "course": "\(course)",
          "category": "\(category)",
          "due": "\(due)",
          "sync_due": "\(syncDue)",
          "record_status": "\(recordStatus)",
          "completion_reason": "\(completionReason)"
        }
        """.utf8))
    }

    private func decodeNotice(url: String, title: String) throws -> NoticeDigestEntry {
        try JSONDecoder().decode(NoticeDigestEntry.self, from: Data("""
        {
          "url": "\(url)",
          "course": "Course",
          "title": "\(title)",
          "fingerprint": "\(title)-fingerprint"
        }
        """.utf8))
    }
}
