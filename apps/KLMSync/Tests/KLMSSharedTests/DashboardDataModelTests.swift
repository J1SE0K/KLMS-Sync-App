import XCTest
@testable import KLMSShared

final class DashboardDataModelTests: XCTestCase {
    func testCourseFileManifestDecodesKLMSTimestampForLatestSort() throws {
        let payload = """
        [
          {
            "filename": "자료.pdf",
            "relative_path": "Course/resources/자료.pdf",
            "url": "https://klms.kaist.ac.kr/mod/resource/view.php?id=1",
            "source_url": "https://klms.kaist.ac.kr/mod/assign/view.php?id=10",
            "course": "Course",
            "absolute_path": "/tmp/자료.pdf",
            "local_downloaded_at": "2026-05-30 10:00 KST",
            "klms_timestamp": "2026-05-29T09:00:00+09:00",
            "klms_timestamp_epoch": 1779984000,
            "klms_timestamp_text": "2026-05-29 09:00",
            "bucket": "assignment-attachments"
          }
        ]
        """.data(using: .utf8)!

        let entries = try JSONDecoder().decode([CourseFileManifestEntry].self, from: payload)

        XCTAssertEqual(entries.first?.klmsTimestamp, "2026-05-29T09:00:00+09:00")
        XCTAssertEqual(entries.first?.klmsTimestampEpoch, 1_779_984_000)
        XCTAssertEqual(entries.first?.klmsTimestampText, "2026-05-29 09:00")
    }

    func testEngineSnapshotStoreMergesLocalCourseFilesMissingFromManifest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("klms-dashboard-file-merge-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let paths = KLMSPaths(engineRoot: directory)
        try FileManager.default.createDirectory(at: paths.cacheURL, withIntermediateDirectories: true)
        let courseRoot = paths.courseFilesURL
        let existingFile = courseRoot.appendingPathComponent("Course/resources/1주차/Existing.pdf")
        let localOnlyFile = courseRoot.appendingPathComponent("Course/resources/2주차/Local Only.pdf")
        let hiddenSystemFile = courseRoot.appendingPathComponent("Course/resources/.DS_Store")
        for url in [existingFile, localOnlyFile, hiddenSystemFile] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("file".utf8).write(to: url)
        }
        try writeManifest(
            [
                [
                    "filename": "Existing.pdf",
                    "relative_path": "Course/resources/1주차/Existing.pdf",
                    "url": "https://klms.kaist.ac.kr/mod/resource/view.php?id=1",
                    "source_url": "https://klms.kaist.ac.kr/course/view.php?id=1",
                    "course": "Course",
                    "absolute_path": existingFile.path,
                    "local_downloaded_at": "2026-05-30 00:00 KST",
                    "bucket": "resources",
                ],
            ],
            to: paths.courseFileManifestURL
        )

        let snapshot = EngineSnapshotStore(paths: paths).load()

        XCTAssertEqual(snapshot.courseFileManifest.count, 2)
        XCTAssertTrue(snapshot.courseFileManifest.contains { $0.relativePath == "Course/resources/1주차/Existing.pdf" })
        let localOnly = try XCTUnwrap(snapshot.courseFileManifest.first {
            $0.relativePath == "Course/resources/2주차/Local Only.pdf"
        })
        XCTAssertEqual(localOnly.filename, "Local Only.pdf")
        XCTAssertEqual(localOnly.course, "Course")
        XCTAssertEqual(localOnly.bucket, "resources")
        XCTAssertTrue(localOnly.absolutePath.hasSuffix("/Course/resources/2주차/Local Only.pdf"))
        XCTAssertFalse(snapshot.courseFileManifest.contains { $0.filename == ".DS_Store" })
    }

    func testEngineSnapshotStoreDoesNotDuplicateLocalFileWithDifferentUnicodeNormalization() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("klms-dashboard-file-normalization-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let paths = KLMSPaths(engineRoot: directory)
        try FileManager.default.createDirectory(at: paths.cacheURL, withIntermediateDirectories: true)
        let composedRelativePath = "카페/resources/1주차/자료.pdf"
        let decomposedRelativePath = (composedRelativePath as NSString).decomposedStringWithCanonicalMapping
        let localFile = paths.courseFilesURL.appendingPathComponent(decomposedRelativePath)
        try FileManager.default.createDirectory(
            at: localFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("file".utf8).write(to: localFile)
        try writeManifest(
            [
                [
                    "filename": "자료.pdf",
                    "relative_path": composedRelativePath,
                    "url": "https://klms.kaist.ac.kr/mod/resource/view.php?id=2",
                    "source_url": "https://klms.kaist.ac.kr/course/view.php?id=2",
                    "course": "카페",
                    "absolute_path": localFile.path,
                    "local_downloaded_at": "2026-05-30 00:00 KST",
                    "bucket": "resources",
                ],
            ],
            to: paths.courseFileManifestURL
        )

        let snapshot = EngineSnapshotStore(paths: paths).load()

        XCTAssertEqual(snapshot.courseFileManifest.count, 1)
        XCTAssertEqual(snapshot.courseFileManifest.first?.relativePath, composedRelativePath)
    }

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

    func testDuplicateAssignmentsWithDifferentNoticeUrlsDisplayOnce() throws {
        let first = try decodeStateItem(
            url: "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1193350&bwid=432642",
            title: "Project 3",
            course: "데이타베이스 개론",
            syncDue: "2026-05-31T23:59:00+09:00"
        )
        let second = try decodeStateItem(
            url: "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1193350&bwid=432643",
            title: "Project 3",
            course: "데이타베이스 개론",
            syncDue: "2026-05-31T23:59:00+09:00"
        )
        let state = LegacySyncState(content: .init(assignments: [first, second]))
        let updated = state.applyingManualOverrides(.init())

        XCTAssertEqual(updated.content.assignments.count, 1)
    }

    func testSameCourseboardIdDifferentAssignmentsDisplaySeparately() throws {
        let written = try decodeStateItem(
            url: "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1189554&bwid=432001",
            title: "Written Assignment 2",
            course: "영미 단편소설",
            syncDue: "2026-05-20T23:59:00+09:00"
        )
        let programming = try decodeStateItem(
            url: "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1189554&bwid=432002",
            title: "Programming Assignment 2",
            course: "영미 단편소설",
            syncDue: "2026-05-20T23:59:00+09:00"
        )
        let state = LegacySyncState(content: .init(assignments: [written, programming]))
        let updated = state.applyingManualOverrides(.init())

        XCTAssertEqual(updated.content.assignments.count, 2)
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
        XCTAssertEqual(updated.content.pastExams.count, 1)
        XCTAssertEqual(updated.content.examRecords.count, 2)
        XCTAssertEqual(updated.content.pastExams.first?.recordStatus, "completed")
        XCTAssertEqual(updated.content.pastExams.first?.completionReason, "past_due")
    }

    func testPastHelpDeskMovesToCompletedRecords() throws {
        let past = try decodeStateItem(
            url: "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=2&bwid=11",
            title: "중간고사 헬프데스크",
            course: "알고리즘 개론",
            category: "help_desk",
            syncDue: "2020-03-31T12:00:00+09:00"
        )
        let future = try decodeStateItem(
            url: "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=2&bwid=12",
            title: "기말고사 헬프데스크",
            course: "알고리즘 개론",
            category: "help_desk",
            syncDue: "2099-06-30T12:00:00+09:00"
        )
        let state = LegacySyncState(content: .init(helpDeskItems: [past, future]))
        let updated = state.applyingManualOverrides(.init())

        XCTAssertEqual(updated.content.helpDeskItems.map(\.title), ["기말고사 헬프데스크"])
        XCTAssertEqual(updated.content.completedAssignments.map(\.title), ["중간고사 헬프데스크"])
        XCTAssertEqual(updated.content.completedAssignments.first?.recordStatus, "completed")
        XCTAssertEqual(updated.content.completedAssignments.first?.completionReason, "past_due")
        XCTAssertEqual(updated.content.completedAssignments.first?.autoCompleted, true)
        XCTAssertEqual(updated.content.assignmentRecords.map(\.title), ["중간고사 헬프데스크"])
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

    func testNoticeIdentifierPrefersStableArticleIDOverURL() throws {
        let notice = try JSONDecoder().decode(NoticeDigestEntry.self, from: Data("""
        {
          "url": "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=222&page=2&bwid=333",
          "article_id": "435776",
          "course": "Algorithms",
          "title": "Notice",
          "fingerprint": "abc"
        }
        """.utf8))

        XCTAssertEqual(notice.noticeIdentifier, "article:435776")
        XCTAssertEqual(notice.legacyNoticeIdentifiers.first, notice.url)
        XCTAssertFalse(notice.legacyNoticeIdentifiers.contains(notice.noticeIdentifier))
    }

    func testNoticeUserStateMigratesLegacyURLKeyToArticleID() throws {
        let notice = try JSONDecoder().decode(NoticeDigestEntry.self, from: Data("""
        {
          "url": "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=222&page=2&bwid=333",
          "article_id": "435776",
          "course": "Algorithms",
          "title": "Notice",
          "fingerprint": "abc"
        }
        """.utf8))
        let digest = NoticeDigest(
            generatedAt: "2026-06-01T00:00:00+09:00",
            noticeCount: 1,
            courses: [NoticeCourseDigest(course: "Algorithms", notices: [notice])]
        )
        let state = NoticeUserStateFile(notices: [
            notice.url: NoticeInteractionState(
                title: "Old title",
                course: "Algorithms",
                url: notice.url,
                fingerprint: "old",
                readFingerprint: "abc",
                readAt: "2026-05-31 12:00 KST",
                important: true
            )
        ])

        let migrated = state.migratingLegacyNoticeKeys(for: digest)

        XCTAssertNil(migrated.notices[notice.url])
        XCTAssertEqual(migrated.notices["article:435776"]?.readFingerprint, "abc")
        XCTAssertEqual(migrated.notices["article:435776"]?.readAt, "2026-05-31 12:00 KST")
        XCTAssertEqual(migrated.notices["article:435776"]?.important, true)
        XCTAssertEqual(migrated.notices["article:435776"]?.title, "Notice")
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

    func testCommandRunHistoryPersistsStageDurationSummaryAfterTrim() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("klms-dashboard-history-stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let filler = (0..<140).map { "[files] download line-\($0)" }.joined(separator: "\n")
        let output = """
        == core finish 2026-06-07 23:25:36 KST status=0 duration_s=18 ==
        == notice finish 2026-06-07 23:26:35 KST status=0 duration_s=59 ==
        \(filler)
        == files finish 2026-06-07 23:32:13 KST status=0 duration_s=338 ==
        """
        let store = CommandRunHistoryStore(url: directory.appendingPathComponent("history.json"), maxRecords: 2)
        let result = KLMSCommandResult(
            invocation: KLMSEngineCommand.fullSync.invocation(),
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 400),
            exitCode: 0,
            standardOutput: output,
            standardError: "",
            authDigits: nil
        )

        let history = try store.append(result)
        let record = try XCTUnwrap(history.records.first)

        XCTAssertEqual(record.stageDurations.map(\.stage), ["core", "notice", "files"])
        XCTAssertEqual(record.stageDurations.map(\.seconds), [18, 59, 338])
        XCTAssertTrue(record.outputTail.contains("== 단계별 실행시간 core=18s notice=59s files=338s"))
        XCTAssertEqual(KLMSStageDurationParser.parse(from: record.outputTail).map(\.seconds), [18, 59, 338])
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

    func testCommandRunHistoryClearPersistsEmptyHistory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("klms-dashboard-clear-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let store = CommandRunHistoryStore(url: directory.appendingPathComponent("history.json"))
        _ = try store.append(KLMSCommandResult(
            invocation: KLMSEngineCommand.fullSync.invocation(),
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 3),
            exitCode: 0,
            standardOutput: "done",
            standardError: "",
            authDigits: nil
        ))

        let cleared = try store.clear()

        XCTAssertEqual(cleared.records.count, 0)
        XCTAssertEqual(store.load().records.count, 0)
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

    func testMacAndIOSUseWholeScreenVerticalScroll() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let macRoot = packageRoot.appendingPathComponent("Sources/KLMSMac/MenuBarRootView.swift")
        let iosRoot = packageRoot.appendingPathComponent("Sources/KLMSiOS/KLMSiOSApp.swift")
        let mac = try String(contentsOf: macRoot, encoding: .utf8)
        let ios = try String(contentsOf: iosRoot, encoding: .utf8)

        XCTAssertTrue(mac.contains("ScrollView(.vertical, showsIndicators: true)"))
        XCTAssertTrue(mac.contains(".scrollIndicators(.visible)"))
        XCTAssertTrue(mac.contains("private struct WholeScreenVerticalScrollView"))
        XCTAssertTrue(mac.contains("GeometryReader { geometry in"))
        XCTAssertTrue(mac.contains("minHeight: geometry.size.height"))
        XCTAssertFalse(mac.contains("ScrollView(.horizontal)"))
        XCTAssertTrue(ios.contains("ScrollView(.vertical, showsIndicators: true)"))
        XCTAssertTrue(ios.contains(".scrollIndicators(.visible)"))
        XCTAssertTrue(ios.contains("private struct WholeScreenVerticalScrollView"))
        XCTAssertTrue(ios.contains("GeometryReader { geometry in"))
        XCTAssertTrue(ios.contains("minHeight: geometry.size.height"))
    }

    func testMacAndIOSUseSeparatedLightAndDarkThemeTokens() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let macRoot = packageRoot.appendingPathComponent("Sources/KLMSMac/MenuBarRootView.swift")
        let iosRoot = packageRoot.appendingPathComponent("Sources/KLMSiOS/KLMSiOSApp.swift")
        let mac = try String(contentsOf: macRoot, encoding: .utf8)
        let ios = try String(contentsOf: iosRoot, encoding: .utf8)

        XCTAssertTrue(mac.contains("static func klmsMacAdaptiveColor(light: NSColor, dark: NSColor)"))
        XCTAssertTrue(mac.contains("var borderColor: Color = .klmsMacBorder"))
        XCTAssertTrue(mac.contains("light: NSColor(calibratedWhite: 0.940"))
        XCTAssertTrue(mac.contains("dark: NSColor(calibratedWhite: 0.010"))
        XCTAssertTrue(mac.contains("light: NSColor(calibratedWhite: 0.950"))
        XCTAssertTrue(mac.contains("light: NSColor(calibratedWhite: 0.760"))
        XCTAssertTrue(mac.contains("light: NSColor(calibratedWhite: 0.075"))
        XCTAssertTrue(mac.contains("static var klmsMacSecondaryCommandButtonForeground: Color"))
        XCTAssertTrue(mac.contains(".foregroundStyle(Color.klmsMacCommandButtonForeground.opacity(0.88))"))

        XCTAssertTrue(ios.contains("static func klmsAdaptiveColor(light: UIColor, dark: UIColor)"))
        XCTAssertTrue(ios.contains("static func klmsAppKitAdaptiveColor(light: NSColor, dark: NSColor)"))
        XCTAssertTrue(ios.contains("light: UIColor(white: 0.940"))
        XCTAssertTrue(ios.contains("dark: UIColor(white: 0.010"))
        XCTAssertTrue(ios.contains("light: UIColor(white: 0.950"))
        XCTAssertTrue(ios.contains("light: UIColor(white: 0.760"))
        XCTAssertTrue(ios.contains("light: UIColor(white: 0.075"))
        XCTAssertTrue(ios.contains("static var klmsSecondaryCommandButtonForeground: Color"))
        XCTAssertTrue(ios.contains(".foregroundStyle(Color.klmsCommandButtonForeground.opacity(0.88))"))
    }

    func testIOSStatusAndRunScreensDoNotDuplicatePrimaryControls() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let iosRoot = packageRoot.appendingPathComponent("Sources/KLMSiOS/KLMSiOSApp.swift")
        let ios = try String(contentsOf: iosRoot, encoding: .utf8)
        let statusScreen = try sourceStructBody(named: "CompanionStatusScreen", in: ios)
        let runScreen = try sourceStructBody(named: "CompanionRunScreen", in: ios)

        XCTAssertTrue(statusScreen.contains("RemoteStatusHeader"))
        XCTAssertTrue(statusScreen.contains("DashboardCategoryInlineDetailPanel"))
        XCTAssertFalse(statusScreen.contains("RemoteLogSummaryPanel"))
        XCTAssertFalse(statusScreen.contains("RemoteCommandPanel"))
        XCTAssertFalse(statusScreen.contains("RemoteCancelControl"))
        XCTAssertFalse(statusScreen.contains("RecentRemoteCommandsView"))

        XCTAssertTrue(runScreen.contains("RemoteCommandPanel"))
        XCTAssertTrue(runScreen.contains("RemoteCancelControl"))
        XCTAssertTrue(runScreen.contains("RemoteSettingsPanel"))
        XCTAssertFalse(runScreen.contains("RemoteLogSummaryPanel"))
        XCTAssertFalse(runScreen.contains("RemoteRunRequestHistoryPanel"))
        XCTAssertFalse(runScreen.contains("RemoteStatusHeader"))
        XCTAssertFalse(runScreen.contains("RemoteChangeSummaryPanel"))
    }

    func testFileCleanupCardsRequireActualCleanupDetails() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let macRoot = packageRoot.appendingPathComponent("Sources/KLMSMac/MenuBarRootView.swift")
        let macDetail = packageRoot.appendingPathComponent("Sources/KLMSMac/DashboardDetailView.swift")
        let iosRoot = packageRoot.appendingPathComponent("Sources/KLMSiOS/KLMSiOSApp.swift")
        let mac = try String(contentsOf: macRoot, encoding: .utf8)
        let detail = try String(contentsOf: macDetail, encoding: .utf8)
        let ios = try String(contentsOf: iosRoot, encoding: .utf8)

        XCTAssertTrue(mac.contains("snapshot.cleanupResult?.actions.filter { $0.action == \"deleted\" }.count ?? 0"))
        XCTAssertFalse(mac.contains("let prunedCount = report?.files.pruned ?? 0"))
        XCTAssertTrue(mac.contains("Metric(\"정리된 파일\", prunedCount, detail: .pruned)"))
        XCTAssertTrue(detail.contains("case .pruned:"))
        XCTAssertTrue(detail.contains("\"정리된 파일\""))
        XCTAssertTrue(detail.contains("정리된 파일 기록이 없습니다."))
        XCTAssertFalse(detail.contains("\"삭제된 파일\""))

        XCTAssertTrue(ios.contains("private var hasFileCleanupDetails"))
        XCTAssertTrue(ios.contains("if hasVisibleChangeSummary"))
        XCTAssertTrue(ios.contains("hasFileCleanupDetails: hasFileCleanupDetails"))
        XCTAssertTrue(ios.contains("guard kind != .fileCleanup || hasFileCleanupDetails else { return nil }"))
    }

    func testSettingsPanelsAreGroupedAndUseNaturalKoreanCopy() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let macSettingsRoot = packageRoot.appendingPathComponent("Sources/KLMSMac/SettingsView.swift")
        let macModelRoot = packageRoot.appendingPathComponent("Sources/KLMSMac/KLMSMacModel.swift")
        let iosRoot = packageRoot.appendingPathComponent("Sources/KLMSiOS/KLMSiOSApp.swift")
        let macSettings = try String(contentsOf: macSettingsRoot, encoding: .utf8)
        let macModel = try String(contentsOf: macModelRoot, encoding: .utf8)
        let ios = try String(contentsOf: iosRoot, encoding: .utf8)

        XCTAssertTrue(macSettings.contains("Section(\"실행 방식\")"))
        XCTAssertTrue(macSettings.contains("Section(\"Safari 자동화\")"))
        XCTAssertTrue(macSettings.contains("Section(\"파일 확인\")"))
        XCTAssertTrue(macSettings.contains("Section(\"저장 위치\")"))
        XCTAssertTrue(macSettings.contains("Section(\"문제 분석용 보관\")"))
        XCTAssertTrue(macSettings.contains("Section(\"연결 정보\")"))
        XCTAssertTrue(macSettings.contains("Section(\"릴레이 동작\")"))
        XCTAssertTrue(macSettings.contains("Section(\"연결 확인\")"))
        XCTAssertFalse(macSettings.contains("백그라운드 실행 허용"))
        XCTAssertFalse(macSettings.contains("동기화 주기(초)"))
        XCTAssertFalse(macSettings.contains("빠르게"))

        XCTAssertTrue(macModel.contains("앱이 앞에 없어도 로그인 보조"))
        XCTAssertTrue(macModel.contains("공지 내용이 같으면 메모 다시 쓰지 않기"))

        XCTAssertTrue(ios.contains("private struct RemoteSettingGroup"))
        XCTAssertTrue(ios.contains("RemoteSettingGroupSection"))
        XCTAssertTrue(ios.contains("\"Safari\""))
        XCTAssertTrue(ios.contains("\"공지 메모\""))
        XCTAssertFalse(ios.contains("Text(setting.key)"))
    }

    func testMacAndIOSUseDedicatedLogScreensForRequestHistory() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let macRoot = packageRoot.appendingPathComponent("Sources/KLMSMac/MenuBarRootView.swift")
        let iosRoot = packageRoot.appendingPathComponent("Sources/KLMSiOS/KLMSiOSApp.swift")
        let mac = try String(contentsOf: macRoot, encoding: .utf8)
        let ios = try String(contentsOf: iosRoot, encoding: .utf8)
        let macRootBody = try sourceBody(after: "struct MenuBarRootView: View", in: mac, description: "Mac root view")
        let iosHistoryScreen = try sourceStructBody(named: "CompanionHistoryScreen", in: ios)

        XCTAssertTrue(mac.contains("case activityLogs"))
        XCTAssertTrue(mac.contains("case diagnostics"))
        XCTAssertTrue(mac.contains("\"로그\""))
        XCTAssertTrue(macRootBody.contains("case .activityLogs:"))
        XCTAssertTrue(macRootBody.contains("LogSummaryPanelView"))
        XCTAssertTrue(macRootBody.contains("RemoteActivityPanelView"))
        XCTAssertTrue(macRootBody.contains("RunLogArchivePanelView"))
        XCTAssertTrue(mac.contains("CompactStageDurationRowsView(durations: record.visibleStageDurations)"))
        XCTAssertTrue(mac.contains("record.visibleStageDurations"))
        XCTAssertTrue(mac.contains(".fixedSize(horizontal: true, vertical: false)"))
        XCTAssertTrue(mac.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        XCTAssertTrue(macRootBody.contains("case .diagnostics:"))
        XCTAssertTrue(macRootBody.contains("VerifyPanelView"))
        XCTAssertFalse(mac.contains("case runLogs"))

        let dashboardBody = try sectionBody(in: macRootBody, from: "case .dashboard:", to: "case .activityLogs:")
        XCTAssertTrue(dashboardBody.contains("DashboardSummaryView"))
        XCTAssertTrue(dashboardBody.contains("CommandOutputPanelView"))
        XCTAssertFalse(dashboardBody.contains("LogSummaryPanelView"))
        XCTAssertFalse(dashboardBody.contains("RemoteActivityPanelView"))

        let diagnosticsBody = try sectionBody(in: macRootBody, from: "case .diagnostics:", to: ".padding(.vertical, 4)")
        XCTAssertTrue(diagnosticsBody.contains("DiagnosticToolsPanelView"))
        XCTAssertTrue(diagnosticsBody.contains("DiagnosticCommandLogPanelView"))
        XCTAssertFalse(diagnosticsBody.contains("RemoteActivityPanelView"))

        XCTAssertTrue(ios.contains("return \"로그\""))
        XCTAssertTrue(iosHistoryScreen.contains("CompanionScreenContainer(title: \"로그\""))
        XCTAssertTrue(iosHistoryScreen.contains("RemoteLogSummaryPanel"))
        XCTAssertTrue(iosHistoryScreen.contains("SharedRunLogsView"))
        XCTAssertTrue(iosHistoryScreen.contains("RecentServerRequestLogView"))
        XCTAssertTrue(iosHistoryScreen.contains("RecentFileAccessRequestsView"))
        XCTAssertTrue(iosHistoryScreen.contains("RecentRemoteCommandsView"))
        XCTAssertTrue(ios.contains("CompactRemoteStageDurationRowsView(durations: stageDurations)"))
        XCTAssertTrue(ios.contains("RemoteStageDurationSummaryView(durations: stageDurations)"))
        XCTAssertTrue(ios.contains(".fixedSize(horizontal: true, vertical: false)"))
        XCTAssertTrue(ios.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
    }

    func testIOSCalendarDetailHasMailPasteAnalyzerAndSharedCalendarActionLabels() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let iosRoot = packageRoot.appendingPathComponent("Sources/KLMSiOS/KLMSiOSApp.swift")
        let ios = try String(contentsOf: iosRoot, encoding: .utf8)
        let statusScreen = try sourceStructBody(named: "CompanionStatusScreen", in: ios)
        let runScreen = try sourceStructBody(named: "RemoteCommandPanel", in: ios)
        let dashboardInlineDetail = try sourceStructBody(named: "DashboardCategoryInlineDetailPanel", in: ios)
        let remoteCalendarPanel = try sourceStructBody(named: "RemoteCalendarActionPanel", in: ios)

        XCTAssertTrue(statusScreen.contains("selectedChangeSummary"))
        XCTAssertTrue(statusScreen.contains("RemoteChangeSummaryDetailPanel"))
        XCTAssertFalse(statusScreen.contains("MailPasteAnalyzerPanel"))
        XCTAssertTrue(runScreen.contains("MailPasteAnalyzerPanel"))
        let iosMailPanelIndex = try XCTUnwrap(runScreen.range(of: "MailPasteAnalyzerPanel")?.lowerBound)
        let iosFullSyncIndex = try XCTUnwrap(runScreen.range(of: "primaryCommandActionCard(primaryCommand)")?.lowerBound)
        XCTAssertTrue(iosMailPanelIndex < iosFullSyncIndex)
        XCTAssertTrue(dashboardInlineDetail.contains("if category == .calendar"))
        XCTAssertFalse(dashboardInlineDetail.contains("MailPasteAnalyzerPanel"))
        XCTAssertTrue(ios.contains("private enum RemoteChangeSummaryKind"))
        XCTAssertTrue(ios.contains("RemoteDashboardChangeSummary("))
        XCTAssertTrue(ios.contains("onChangeSummaryTap"))
        XCTAssertTrue(ios.contains("UIPasteboard.general.string"))
        XCTAssertTrue(ios.contains("MailPasteAnalyzer.analyze"))
        XCTAssertTrue(ios.contains("메일 원문 붙여넣기"))
        XCTAssertTrue(ios.contains("원문은 서버로 보내지 않음"))
        XCTAssertTrue(ios.contains("판독 결과"))
        XCTAssertTrue(ios.contains("메일 내용 자동 판독"))
        XCTAssertTrue(ios.contains("캘린더 반영"))
        XCTAssertTrue(ios.contains("MailAnalysisProcessView"))
        XCTAssertTrue(ios.contains("분석 과정"))
        XCTAssertTrue(ios.contains("analysisSteps"))
        XCTAssertTrue(ios.contains("assignmentScore"))
        XCTAssertTrue(ios.contains("examScore"))
        XCTAssertTrue(ios.contains("메일의 \\(code) 코드를 현재 KLMS 과목명/별칭표로 풀었습니다"))
        XCTAssertTrue(ios.contains("guard kind == .none || item.kind.matches(mailKind: kind)"))
        XCTAssertTrue(ios.contains("처리 대상"))
        XCTAssertTrue(ios.contains("추천 처리"))
        XCTAssertTrue(ios.contains("dateSnippet(in:"))
        XCTAssertTrue(ios.contains("keywordScore(lower, weightedKeywords:"))
        XCTAssertTrue(ios.contains("(\"written assignment\", 7)"))
        XCTAssertTrue(ios.contains("(\"final\", 2)"))
        XCTAssertTrue(ios.contains("yyyy MMMM d, HH:mm"))
        XCTAssertTrue(ios.contains("detectTitle(lines: lines, kind: kind, course: course)"))
        XCTAssertTrue(ios.contains("TA|조교"))
        XCTAssertTrue(ios.contains("resolvedCourseDisplay(for: captured, knownCourses: knownCourses)"))
        XCTAssertTrue(ios.contains("\"EE488\": \"전기 전자공학특강<전자공학을 위한 사이버 보안 개론>\""))
        XCTAssertTrue(ios.contains("isMailGreetingOrSignature"))
        XCTAssertTrue(ios.contains("exam schedule"))
        XCTAssertTrue(ios.contains("yyyy MMMM d h:mm a"))
        XCTAssertTrue(ios.contains("월요일|화요일|수요일"))
        XCTAssertTrue(ios.contains("normalizeMailText(item.searchText).contains(normalizedDue)"))
        XCTAssertTrue(ios.contains("Mac 캘린더에 등록"))
        XCTAssertTrue(ios.contains("MailDashboardItemEditForm"))
        XCTAssertTrue(ios.contains("submitRemoveMailDashboardItem"))
        XCTAssertTrue(ios.contains("action: .mailDashboardRemove"))
        XCTAssertTrue(ios.contains("Label(\"등록\", systemImage: \"plus.circle\")"))
        XCTAssertTrue(ios.contains("Label(\"제거\", systemImage: \"minus.circle\")"))
        XCTAssertTrue(ios.contains("createManualCalendarAction"))
        XCTAssertTrue(ios.contains("action: .calendarCreate"))
        XCTAssertTrue(ios.contains("activeCalendarAction(for change: CalendarChange)"))
        XCTAssertTrue(ios.contains("visibleCalendarChanges()"))
        XCTAssertTrue(ios.contains("mailDashboardItems.compactMap(\\.mailCalendarChange)"))
        XCTAssertTrue(ios.contains("resolvedCalendarChangeIDs"))
        XCTAssertTrue(ios.contains("recordResolvedCalendarChanges(itemActions)"))
        XCTAssertTrue(ios.contains("action.action.resolvesCalendarChange"))
        XCTAssertTrue(ios.contains("activeAction: model.activeCalendarAction(for: change)"))
        XCTAssertTrue(ios.contains("activeAction.status.displayName"))
        XCTAssertTrue(ios.contains("let defaults = change.editDefaults"))
        XCTAssertTrue(ios.contains("case .calendarEdit, .calendarApply, .calendarDelete:"))
        XCTAssertFalse(ios.contains("didSubmitCommand"))
        XCTAssertTrue(ios.contains("\"캘린더 일정 등록\""))
        XCTAssertTrue(ios.contains("\"캘린더 내용 수정\""))
        XCTAssertTrue(ios.contains("\"캘린더 일정 삭제\""))
        XCTAssertTrue(ios.contains("Label(\"등록\", systemImage: \"calendar.badge.plus\")"))
        XCTAssertTrue(ios.contains("Label(\"수정\", systemImage: \"pencil\")"))
        XCTAssertTrue(ios.contains("Label(\"삭제\", systemImage: \"calendar.badge.minus\")"))
        XCTAssertFalse(ios.contains("\"등록/캘린더\""))
        XCTAssertFalse(ios.contains("\"수정/캘린더\""))
        XCTAssertFalse(ios.contains("case .calendarDelete:\n            \"KLMS 기준 반영\""))
        XCTAssertFalse(remoteCalendarPanel.contains("model.createCommand"))
        XCTAssertFalse(remoteCalendarPanel.contains("RemoteCommandKind.verify"))
        XCTAssertFalse(remoteCalendarPanel.contains("RemoteCommandKind.coreSync"))
        XCTAssertFalse(remoteCalendarPanel.contains("RemoteCommandKind.doctor"))
        XCTAssertTrue(remoteCalendarPanel.contains("캘린더에서 열기"))
    }

    func testMacCalendarDashboardHasMailPasteCalendarRegistration() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let detailRoot = packageRoot.appendingPathComponent("Sources/KLMSMac/DashboardDetailView.swift")
        let modelRoot = packageRoot.appendingPathComponent("Sources/KLMSMac/KLMSMacModel.swift")
        let detail = try String(contentsOf: detailRoot, encoding: .utf8)
        let macRoot = packageRoot.appendingPathComponent("Sources/KLMSMac/MenuBarRootView.swift")
        let mac = try String(contentsOf: macRoot, encoding: .utf8)
        let model = try String(contentsOf: modelRoot, encoding: .utf8)
        let calendarDetail = try sourceStructBody(named: "CalendarDetailView", in: detail)
        let calendarRow = try sourceStructBody(named: "CalendarChangeRowView", in: detail)
        let calendarGuide = try sourceStructBody(named: "CalendarActionGuideView", in: detail)
        let dashboardSummary = try sourceStructBody(named: "DashboardSummaryView", in: mac)
        let commandPanel = try sourceStructBody(named: "CommandPanelView", in: mac)

        XCTAssertFalse(calendarDetail.contains("MacMailPasteAnalyzerPanel"))
        XCTAssertFalse(calendarGuide.contains("model.run(.verify)"))
        XCTAssertFalse(calendarGuide.contains("model.run(.coreSync)"))
        XCTAssertFalse(calendarGuide.contains("model.run(.doctor)"))
        XCTAssertFalse(calendarGuide.contains("캘린더 확인"))
        XCTAssertTrue(calendarGuide.contains("캘린더에서 열기"))
        XCTAssertFalse(dashboardSummary.contains("MacMailPasteAnalyzerPanel"))
        XCTAssertTrue(commandPanel.contains("MacMailPasteAnalyzerPanel"))
        let macMailPanelIndex = try XCTUnwrap(commandPanel.range(of: "MacMailPasteAnalyzerPanel")?.lowerBound)
        let macFullSyncIndex = try XCTUnwrap(commandPanel.range(of: "primaryCommandActionCard(primaryCommand)")?.lowerBound)
        XCTAssertTrue(macMailPanelIndex < macFullSyncIndex)
        XCTAssertTrue(detail.contains("메일 내용 자동 판독"))
        XCTAssertTrue(detail.contains("메일 원문 붙여넣기"))
        XCTAssertTrue(detail.contains("원문은 서버로 보내지 않음"))
        XCTAssertTrue(detail.contains("판독 결과"))
        XCTAssertTrue(detail.contains("캘린더 반영"))
        XCTAssertTrue(detail.contains("MacMailAnalysisProcessView"))
        XCTAssertTrue(detail.contains("분석 과정"))
        XCTAssertTrue(detail.contains("analysisSteps"))
        XCTAssertTrue(detail.contains("assignmentScore"))
        XCTAssertTrue(detail.contains("examScore"))
        XCTAssertTrue(detail.contains("메일의 \\(code) 코드를 현재 KLMS 과목명/별칭표로 풀었습니다"))
        XCTAssertTrue(detail.contains("guard kind == .none || item.matches(kind: kind)"))
        XCTAssertTrue(detail.contains("처리 대상"))
        XCTAssertTrue(detail.contains("추천 처리"))
        XCTAssertTrue(detail.contains("dateSnippet(in:"))
        XCTAssertTrue(detail.contains("keywordScore(lower, weightedKeywords:"))
        XCTAssertTrue(detail.contains("(\"written assignment\", 7)"))
        XCTAssertTrue(detail.contains("(\"final\", 2)"))
        XCTAssertTrue(detail.contains("yyyy MMMM d, HH:mm"))
        XCTAssertTrue(detail.contains("detectTitle(lines: lines, kind: kind, course: course)"))
        XCTAssertTrue(detail.contains("TA|조교"))
        XCTAssertTrue(detail.contains("resolvedCourseDisplay(for: captured, knownCourses: knownCourses)"))
        XCTAssertTrue(detail.contains("\"EE488\": \"전기 전자공학특강<전자공학을 위한 사이버 보안 개론>\""))
        XCTAssertTrue(detail.contains("isMailGreetingOrSignature"))
        XCTAssertTrue(detail.contains("exam schedule"))
        XCTAssertTrue(detail.contains("yyyy MMMM d h:mm a"))
        XCTAssertTrue(detail.contains("월요일|화요일|수요일"))
        XCTAssertTrue(detail.contains("normalizeMailText(item.searchText).contains(normalizedDue)"))
        XCTAssertTrue(detail.contains("캘린더에 등록"))
        XCTAssertTrue(detail.contains("MailDashboardItemEditSheet"))
        XCTAssertTrue(detail.contains("Label(\"등록\", systemImage: \"plus.circle\")"))
        XCTAssertTrue(detail.contains("Label(\"제거\", systemImage: \"minus.circle\")"))
        XCTAssertTrue(detail.contains("NSPasteboard.general.string"))
        XCTAssertTrue(detail.contains("MacMailPasteAnalyzer.analyze"))
        XCTAssertTrue(model.contains("func createManualCalendarEvent"))
        XCTAssertTrue(model.contains("EKEvent(eventStore: store)"))
        XCTAssertTrue(model.contains("applyServerRelayCalendarCreateAction"))
        XCTAssertTrue(model.contains("applyServerRelayMailDashboardRemoveAction"))
        XCTAssertTrue(model.contains("case .mailDashboardRemove"))
        XCTAssertTrue(model.contains("runningAction.action == .calendarCreate"))
        XCTAssertTrue(model.contains("mailCalendarChanges()"))
        XCTAssertTrue(model.contains("visibleCalendarChanges(from: snapshot).map(serverRelayCalendarChange)"))
        XCTAssertTrue(model.contains("mailDashboardStateItems(kind: String)"))
        XCTAssertTrue(model.contains("resolvedCalendarChangeIDs"))
        XCTAssertTrue(model.contains("location: serverRelayPublicText(change.location)"))
        XCTAssertTrue(model.contains("func openCalendarEvent(change: CalendarChange) async -> Bool"))
        XCTAssertTrue(model.contains("show event id"))
        XCTAssertTrue(model.contains("visibleCalendarChanges(from snapshot: EngineSnapshot)"))
        XCTAssertTrue(detail.contains("model.mailDashboardStateItems(kind: \"assignment\")"))
        XCTAssertTrue(detail.contains("model.mailDashboardStateItems(kind: \"exam\")"))
        XCTAssertTrue(detail.contains("!model.isCalendarChangeResolved(change)"))
        XCTAssertTrue(detail.contains("isUserVisibleCalendarChange"))
        XCTAssertTrue(detail.contains("model.mailCalendarChanges().count"))
        XCTAssertTrue(detail.contains("let defaults = change.editDefaults"))
        XCTAssertTrue(detail.contains("캘린더 내용 수정 완료"))
        XCTAssertTrue(calendarRow.contains("model.createCalendarEvent(change: change, edit: change.editDefaults)"))
        XCTAssertFalse(calendarRow.contains("calendarSheetAction = .calendarCreate"))
        XCTAssertTrue(calendarRow.contains("model.openCalendarEvent(change: change)"))
        XCTAssertTrue(mac.contains("calendarAttentionCount"))
        XCTAssertTrue(detail.contains("Task.sleep(nanoseconds: 1_500_000_000)"))
        XCTAssertTrue(detail.contains("editStatusText = nil"))
    }

    func testAuthStatusDoesNotPromoteAlreadyLoggedInToAuthCompleted() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let iosRoot = packageRoot.appendingPathComponent("Sources/KLMSiOS/KLMSiOSApp.swift")
        let macRoot = packageRoot.appendingPathComponent("Sources/KLMSMac/KLMSMacModel.swift")
        let ios = try String(contentsOf: iosRoot, encoding: .utf8)
        let mac = try String(contentsOf: macRoot, encoding: .utf8)

        XCTAssertTrue(mac.contains("lastAuthStatusMessageForRemote"))
        XCTAssertFalse(mac.contains("authStatusMessage ?? \"인증 완료됨\""))
        XCTAssertTrue(mac.contains("notifiedAlreadyLoggedInForCurrentRun = false"))
        XCTAssertTrue(ios.contains("authStatusDisplayTitle"))
        XCTAssertTrue(ios.contains("isAlreadyLoggedInMessage"))
        XCTAssertTrue(ios.contains("return !Self.isAlreadyLoggedInMessage(message)"))
    }

    func testIOSCompanionUsesAdaptiveIPadNavigation() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let iosRoot = packageRoot.appendingPathComponent("Sources/KLMSiOS/KLMSiOSApp.swift")
        let projectRoot = packageRoot
            .appendingPathComponent("Xcode/KLMSiOS/KLMSiOS.xcodeproj/project.pbxproj")
        let ios = try String(contentsOf: iosRoot, encoding: .utf8)
        let project = try String(contentsOf: projectRoot, encoding: .utf8)

        XCTAssertTrue(project.contains("TARGETED_DEVICE_FAMILY = \"1,2\";"))
        XCTAssertTrue(project.contains("INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad"))
        XCTAssertTrue(ios.contains("@Environment(\\.horizontalSizeClass)"))
        XCTAssertTrue(ios.contains("private struct CompanionSplitRootView"))
        XCTAssertTrue(ios.contains("NavigationSplitView"))
        XCTAssertTrue(ios.contains("private struct CompanionTabRootView"))
        XCTAssertTrue(ios.contains("private struct CompanionSectionContent"))
        XCTAssertTrue(ios.contains("CompanionSplitRootView(model: model, selectedSection: $selectedSection)"))
        XCTAssertTrue(ios.contains("CompanionTabRootView(model: model)"))
        XCTAssertTrue(ios.contains(".navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)"))
        XCTAssertTrue(ios.contains(".frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)"))
        XCTAssertTrue(ios.contains("private var screenContent: some View"))
        XCTAssertTrue(ios.contains("NavigationStack {\n                    screenContent"))
        XCTAssertTrue(ios.contains("iPhone/iPad는 KLMS를 직접 읽지 않고"))
        XCTAssertTrue(ios.contains("iPhone/iPad/Windows용 클라이언트 토큰"))
        XCTAssertFalse(ios.contains("iPhone은 KLMS를 직접 읽지 않고"))
        XCTAssertFalse(ios.contains("iPhone/Windows용 클라이언트 토큰"))
    }

    func testMacAndIOSServerRelayUseWebSocketInsteadOfPeriodicPolling() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let iosRoot = packageRoot.appendingPathComponent("Sources/KLMSiOS/KLMSiOSApp.swift")
        let macModelRoot = packageRoot.appendingPathComponent("Sources/KLMSMac/KLMSMacModel.swift")
        let sharedRoot = packageRoot.appendingPathComponent("Sources/KLMSShared/RemoteCommandModels.swift")
        let ios = try String(contentsOf: iosRoot, encoding: .utf8)
        let macModel = try String(contentsOf: macModelRoot, encoding: .utf8)
        let shared = try String(contentsOf: sharedRoot, encoding: .utf8)

        XCTAssertTrue(macModel.contains("webSocketTask(with: store.eventStreamRequest(role: \"worker\"))"))
        XCTAssertTrue(ios.contains("webSocketTask(with: store.eventStreamRequest(role: \"client\"))"))
        XCTAssertTrue(ios.contains("await model.startServerRelayRealtime()"))

        XCTAssertFalse(macModel.contains("serverRelayPollingTask"))
        XCTAssertFalse(macModel.contains("configureServerRelayPolling"))
        XCTAssertFalse(macModel.contains("serverRelayIdlePollingIntervalNanoseconds"))
        XCTAssertFalse(macModel.contains("serverRelayActivePollingIntervalNanoseconds"))
        XCTAssertFalse(ios.contains("pollRecentCommands"))
        XCTAssertFalse(ios.contains("Task.sleep(nanoseconds: interval)"))
        XCTAssertFalse(ios.contains("Task.sleep(nanoseconds: 250_000_000)"))

        XCTAssertTrue(macModel.contains("waitSeconds: 0"))
        XCTAssertFalse(macModel.contains("waitSeconds: runningCommand == nil ? 20 : 0"))
        XCTAssertTrue(shared.contains("path: \"/v1/worker/inbox\""))
    }

    func testLogClearPreservesActiveCancellationAndFileRequests() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let iosRoot = packageRoot.appendingPathComponent("Sources/KLMSiOS/KLMSiOSApp.swift")
        let macModelRoot = packageRoot.appendingPathComponent("Sources/KLMSMac/KLMSMacModel.swift")
        let macViewRoot = packageRoot.appendingPathComponent("Sources/KLMSMac/MenuBarRootView.swift")
        let ios = try String(contentsOf: iosRoot, encoding: .utf8)
        let macModel = try String(contentsOf: macModelRoot, encoding: .utf8)
        let macView = try String(contentsOf: macViewRoot, encoding: .utf8)

        let iosApplyLogClear = try sourceBody(
            after: "private func applyLogClear(scope: ServerRelayLogClearScope)",
            in: ios,
            description: "iOS applyLogClear"
        )
        XCTAssertTrue(iosApplyLogClear.contains("recentCommands = recentCommands.filter { $0.status.isInFlight }"))
        XCTAssertTrue(iosApplyLogClear.contains("recentFileAccessRequests = recentFileAccessRequests.filter { $0.status.isInFlight }"))
        XCTAssertFalse(iosApplyLogClear.contains("pendingCancelCommandID = nil"))
        XCTAssertFalse(iosApplyLogClear.contains("pendingCancelRequestedAt = nil"))

        let macClearLogs = try sourceBody(
            after: "func clearVisibleLogsAndServerRelayLogs() async",
            in: macModel,
            description: "Mac visible log clear"
        )
        XCTAssertTrue(macClearLogs.contains("clearTransientRunState()"))
        XCTAssertTrue(macClearLogs.contains("clearLocalStoredLogs()"))
        XCTAssertTrue(macClearLogs.contains("await clearServerRelayLogs(scope: .all)"))
        XCTAssertTrue(macModel.contains("let result = try await store.clearDisplayLogs(scope: scope)"))
        XCTAssertTrue(macModel.contains("CommandRunHistoryStore(url: paths.appHistoryURL).clear()"))
        XCTAssertTrue(macModel.contains("reason == \"sync-data:run-logs-clear\""))
        XCTAssertTrue(macView.contains("await model.clearVisibleLogsAndServerRelayLogs()"))
        XCTAssertTrue(macView.contains("TopUtilityActionsView(model: model)"))
    }

    func testIOSRefreshAndDisplayClearShowImmediateFeedback() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let iosRoot = packageRoot.appendingPathComponent("Sources/KLMSiOS/KLMSiOSApp.swift")
        let ios = try String(contentsOf: iosRoot, encoding: .utf8)

        let queueRefresh = try sourceBody(
            after: "private func queueRefreshIfNeeded",
            in: ios,
            description: "iOS queued refresh feedback"
        )
        XCTAssertTrue(queueRefresh.contains("connectionMessage = \"진행 중인 상태 갱신이 끝나면 바로 반영합니다.\""))
        XCTAssertTrue(queueRefresh.contains("isRefreshing = true"))
        XCTAssertTrue(ios.contains("connectionMessage = \"상태 갱신 완료\""))
    }

    func testIOSRelayRefreshFetchesRemotePanelsConcurrently() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let iosRoot = packageRoot.appendingPathComponent("Sources/KLMSiOS/KLMSiOSApp.swift")
        let ios = try String(contentsOf: iosRoot, encoding: .utf8)
        let refreshBody = try sourceBody(
            after: "func refreshRecent(",
            in: ios,
            description: "iOS relay refresh"
        )

        XCTAssertTrue(refreshBody.contains("async let responseTask = serverRelayStore.fetchStatusResponse()"))
        XCTAssertTrue(refreshBody.contains("async let commandsTask"))
        XCTAssertTrue(refreshBody.contains("async let syncDataTask"))
        XCTAssertTrue(refreshBody.contains("async let fileRequestsTask"))
        XCTAssertTrue(refreshBody.contains("async let itemActionsTask"))
        XCTAssertTrue(refreshBody.contains("async let requestLogTask"))
        XCTAssertTrue(refreshBody.contains("async let settingActionsTask"))
        XCTAssertTrue(ios.contains("private static func fetchSyncDataIfNeeded"))
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

    private func writeManifest(_ payload: [[String: Any]], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    private func sourceStructBody(named name: String, in source: String) throws -> String {
        let marker = "private struct \(name): View"
        return try sourceBody(after: marker, in: source, description: "SwiftUI view struct \(name)")
    }

    private func sourceBody(after marker: String, in source: String, description: String) throws -> String {
        guard let startRange = source.range(of: marker),
              let bodyStart = source[startRange.upperBound...].firstIndex(of: "{") else {
            throw NSError(domain: "DashboardDataModelTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Missing \(description)",
            ])
        }

        var depth = 0
        var index = bodyStart
        while index < source.endIndex {
            let char = source[index]
            if char == "{" {
                depth += 1
            } else if char == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[bodyStart...index])
                }
            }
            index = source.index(after: index)
        }

        throw NSError(domain: "DashboardDataModelTests", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Unterminated \(description)",
        ])
    }

    private func sectionBody(in source: String, from startMarker: String, to endMarker: String) throws -> String {
        guard let startRange = source.range(of: startMarker),
              let endRange = source[startRange.upperBound...].range(of: endMarker) else {
            throw NSError(domain: "DashboardDataModelTests", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Missing section \(startMarker) -> \(endMarker)",
            ])
        }
        return String(source[startRange.upperBound..<endRange.lowerBound])
    }
}
