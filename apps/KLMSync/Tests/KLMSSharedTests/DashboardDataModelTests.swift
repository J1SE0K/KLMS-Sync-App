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
        == files finish 2026-06-07 23:32:13 KST status=0 duration_s=338 ==
        == core finish 2026-06-07 23:32:31 KST status=0 duration_s=18 ==
        == notice finish 2026-06-07 23:33:30 KST status=0 duration_s=59 ==
        \(filler)
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

        XCTAssertEqual(record.stageDurations.map(\.stage), ["files", "core", "notice"])
        XCTAssertEqual(record.stageDurations.map(\.seconds), [338, 18, 59])
        XCTAssertTrue(record.outputTail.contains("== 단계별 실행시간 files=338s core=18s notice=59s"))
        XCTAssertEqual(KLMSStageDurationParser.parse(from: record.outputTail).map(\.seconds), [338, 18, 59])
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
        let macRootBody = try sourceBody(
            after: "struct MenuBarRootView: View",
            in: mac,
            description: "Mac root view"
        )

        XCTAssertTrue(mac.contains("ScrollView(.vertical, showsIndicators: true)"))
        XCTAssertTrue(mac.contains(".scrollIndicators(.visible)"))
        XCTAssertTrue(mac.contains("private struct WholeScreenVerticalScrollView"))
        XCTAssertFalse(mac.contains("GeometryReader { geometry in"))
        XCTAssertFalse(mac.contains("minHeight: geometry.size.height"))
        XCTAssertTrue(macRootBody.contains("WholeScreenVerticalScrollView"))
        XCTAssertTrue(macRootBody.contains(".frame(maxWidth: .infinity, alignment: .topLeading)"))
        XCTAssertFalse(macRootBody.contains("maxHeight: .infinity"))
        XCTAssertFalse(mac.contains("ScrollView(.horizontal)"))
        XCTAssertTrue(ios.contains("ScrollView(.vertical, showsIndicators: true)"))
        XCTAssertTrue(ios.contains(".scrollIndicators(.visible)"))
        XCTAssertTrue(ios.contains("private struct WholeScreenVerticalScrollView"))
        XCTAssertFalse(ios.contains("GeometryReader { geometry in"))
        XCTAssertFalse(ios.contains("minHeight: geometry.size.height"))
    }

    func testMacDashboardWindowFollowsApprovedWorkstationMockup() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appRoot = packageRoot.appendingPathComponent("Sources/KLMSMac/KLMSMacApp.swift")
        let viewRoot = packageRoot.appendingPathComponent("Sources/KLMSMac/MenuBarRootView.swift")
        let detailRoot = packageRoot.appendingPathComponent("Sources/KLMSMac/DashboardDetailView.swift")
        let app = try String(contentsOf: appRoot, encoding: .utf8)
        let view = try String(contentsOf: viewRoot, encoding: .utf8)
        let detail = try String(contentsOf: detailRoot, encoding: .utf8)
        let workstationLayout = try sourceStructBody(named: "MacWorkstationLayoutView", in: view)
        let navigationView = try sourceStructBody(named: "WorkspaceNavigationView", in: view)
        let commandPanel = try sourceStructBody(named: "CommandPanelView", in: view)
        let pressFeedbackStyle = try sourceBody(
            after: "private struct MacPressFeedbackButtonStyle: ButtonStyle",
            in: view,
            description: "Mac press feedback button style"
        )
        let rootActionButtonStyle = try sourceBody(
            after: "private struct KLMSMacRootActionButtonStyle: ButtonStyle",
            in: view,
            description: "Mac root action button style"
        )
        let actionButtonStyle = try sourceBody(
            after: "private struct KLMSMacActionButtonStyle: ButtonStyle",
            in: detail,
            description: "Mac action button style"
        )
        let detailPressFeedbackStyle = try sourceBody(
            after: "private struct KLMSMacPressFeedbackButtonStyle: ButtonStyle",
            in: detail,
            description: "Mac detail press feedback button style"
        )
        let iconButtonStyle = try sourceBody(
            after: "private struct KLMSMacIconButtonStyle: ButtonStyle",
            in: detail,
            description: "Mac icon button style"
        )
        let verifyCheckRow = try sourceStructBody(named: "VerifyCheckExplanationRowView", in: view)
        let issueRowView = try sourceStructBody(named: "IssueRowView", in: view)
        let dashboardFilterBar = try sourceStructBody(named: "DashboardFilterBarView", in: detail)
        let yearFieldIndex = try XCTUnwrap(dashboardFilterBar.range(of: "yearPickerField")?.lowerBound)
        let semesterFieldIndex = try XCTUnwrap(dashboardFilterBar.range(of: "semesterPickerField")?.lowerBound)
        let courseFieldIndex = try XCTUnwrap(dashboardFilterBar.range(of: "coursePickerField")?.lowerBound)

        XCTAssertTrue(app.contains("MenuBarRootView(model: model)"))
        XCTAssertLessThan(dashboardFilterBar.distance(from: dashboardFilterBar.startIndex, to: yearFieldIndex), dashboardFilterBar.distance(from: dashboardFilterBar.startIndex, to: courseFieldIndex))
        XCTAssertLessThan(dashboardFilterBar.distance(from: dashboardFilterBar.startIndex, to: semesterFieldIndex), dashboardFilterBar.distance(from: dashboardFilterBar.startIndex, to: courseFieldIndex))
        XCTAssertTrue(app.contains("KLMSMacWorkspaceRootContainerView(model: model)"))
        XCTAssertTrue(app.contains("@objc(KLMSApplication)"))
        XCTAssertTrue(app.contains("final class KLMSApplication: NSApplication"))
        XCTAssertTrue(app.contains("override func sendEvent(_ event: NSEvent)"))
        XCTAssertTrue(app.contains("private static func isQuitShortcut(_ event: NSEvent) -> Bool"))
        XCTAssertTrue(app.contains("@main"))
        XCTAssertTrue(app.contains("final class KLMSAppDelegate: NSObject, NSApplicationDelegate"))
        XCTAssertFalse(app.contains("struct KLMSMacApp: App"))
        XCTAssertFalse(app.contains("Window(\"KLMS Sync\", id: KLMSMacWindowID.dashboard)"))
        XCTAssertFalse(app.contains("WindowGroup(\"KLMS Sync\")"))
        XCTAssertTrue(app.contains("NSWindow("))
        XCTAssertTrue(app.contains("contentRect: NSRect(origin: .zero, size: initialSize)"))
        XCTAssertFalse(app.contains(".defaultSize(width: KLMSWindowMetrics.initialWidth, height: KLMSWindowMetrics.initialHeight)"))
        XCTAssertFalse(app.contains(".windowResizability(.contentMinSize)"))
        XCTAssertFalse(app.contains("CommandGroup(replacing: .newItem)"))
        XCTAssertFalse(app.contains("MenuBarExtra"))
        XCTAssertTrue(app.contains("Task { @MainActor in"))
        XCTAssertTrue(app.contains("KLMSDashboardWindowCoordinator.shared.showDashboardWindow()"))
        XCTAssertTrue(app.contains("KLMSDashboardWindowCoordinator.shared.setModel(model)"))
        XCTAssertTrue(app.contains("static let initialWidth: CGFloat = 1080"))
        XCTAssertTrue(app.contains("static let minWidth: CGFloat = 540"))
        XCTAssertTrue(app.contains("configureApplicationMenu()"))
        XCTAssertTrue(app.contains("NSApp.mainMenu = mainMenu"))
        XCTAssertTrue(app.contains("NSMenuItem(title: \"KLMS Sync 종료\", action: #selector(quitFromMenu), keyEquivalent: \"q\")"))
        XCTAssertTrue(app.contains("quitItem.keyEquivalentModifierMask = [.command]"))
        XCTAssertTrue(app.contains("private var quitKeyMonitor: Any?"))
        XCTAssertTrue(app.contains("configureQuitKeyMonitor()"))
        XCTAssertTrue(app.contains("NSEvent.addLocalMonitorForEvents(matching: .keyDown)"))
        XCTAssertTrue(app.contains("event.charactersIgnoringModifiers?.lowercased() == \"q\""))
        XCTAssertTrue(app.contains("event.keyCode == 12"))
        let buildScript = try String(
            contentsOf: packageRoot
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("tools/build_klms_mac_app.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(buildScript.contains("<key>NSPrincipalClass</key>"))
        XCTAssertTrue(buildScript.contains("<string>KLMSApplication</string>"))
        XCTAssertTrue(app.contains("func scheduleBootstrapIfNeeded(delay: TimeInterval = 0.2)"))
        XCTAssertTrue(app.contains("scheduleBootstrapIfNeeded(delay: 2.5)"))
        XCTAssertTrue(app.contains("func applicationShouldHandleReopen"))
        XCTAssertTrue(app.contains("if !KLMSDashboardWindowCoordinator.shared.hasVisibleDashboardWindow"))
        XCTAssertFalse(app.contains("func applicationShouldOpenUntitledFile"))
        XCTAssertFalse(app.contains("func applicationOpenUntitledFile"))
        XCTAssertTrue(app.contains("var hasVisibleDashboardWindow: Bool"))
        XCTAssertTrue(app.contains("window.identifier?.rawValue == KLMSMacWindowID.dashboard"))
        XCTAssertTrue(app.contains("window.frame.width >= KLMSWindowMetrics.minWidth"))
        XCTAssertTrue(app.contains("window.identifier = NSUserInterfaceItemIdentifier(KLMSMacWindowID.dashboard)"))
        XCTAssertFalse(app.contains("func scheduleDashboardOpenRetry"))
        XCTAssertFalse(app.contains("KLMSDashboardWindowCoordinator.shared.scheduleDashboardOpenRetry()"))
        XCTAssertTrue(app.contains("restoreDashboardFrameIfNeeded(window, size: initialSize)"))
        XCTAssertTrue(app.contains("private var pendingDashboardWindowOpen = false"))
        XCTAssertTrue(app.contains("func setModel(_ model: KLMSMacModel)"))
        XCTAssertTrue(app.contains("guard pendingDashboardWindowOpen else"))
        XCTAssertTrue(app.contains("pendingDashboardWindowOpen = true"))
        XCTAssertTrue(app.contains("NSApp.setActivationPolicy(.regular)"))
        XCTAssertTrue(app.contains("NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)"))
        XCTAssertTrue(app.contains("NSMenuItem(title: \"KLMS Sync 열기\""))
        XCTAssertTrue(app.contains("NSMenuItem(title: \"상태 갱신\""))
        XCTAssertTrue(app.contains("item.button?.image = NSImage(systemSymbolName: model.menuBarSystemImage"))
        XCTAssertFalse(app.contains("KLMSMenuBarQuickMenu(model: model)"))
        XCTAssertFalse(app.contains(".menuBarExtraStyle(.menu)"))
        XCTAssertFalse(app.contains(".menuBarExtraStyle(.window)"))
        XCTAssertFalse(app.contains("Button(\"KLMS Sync 열기\")"))
        XCTAssertFalse(app.contains("Button(\"상태 갱신\")"))
        XCTAssertFalse(app.contains("if !flag {"))
        XCTAssertFalse(app.contains("MacDesignWindowRootView(model: model)"))
        XCTAssertFalse(app.contains("KLMSMacWindowRootContainerView(model: model)"))
        XCTAssertFalse(app.contains("Window(\"KLMS Sync 진단\""))
        XCTAssertFalse(app.contains("Settings {"))
        XCTAssertFalse(app.contains("settingsWidth"))
        XCTAssertFalse(app.contains("settingsHeight"))
        XCTAssertFalse(app.contains("KLMSDiagnosticWindowCoordinator"))
        XCTAssertFalse(app.contains("KLMSDiagnosticRootContainerView"))
        XCTAssertFalse(view.contains("struct MacDesignWindowRootView"))
        XCTAssertFalse(view.contains("MacDesignWorkspace"))
        XCTAssertFalse(view.contains("MacDesignMetricKind"))
        XCTAssertFalse(view.contains("private struct SectionPickerView"))

        XCTAssertFalse(view.contains("DashboardLogSummaryPanelView(model: model)"))
        XCTAssertTrue(view.contains("DashboardSummaryView(model: model)"))
        XCTAssertTrue(view.contains("CommandStageDurationSummaryView(durations: stageDurations)"))
        XCTAssertFalse(view.contains("private let klmsMacInteractionDetailDelayNanoseconds"))
        XCTAssertTrue(view.contains("@State private var isArchiveMetricsExpanded = false"))
        XCTAssertTrue(view.contains("private struct DashboardArchiveMetricSection"))
        XCTAssertTrue(view.contains("isArchiveMetricsExpanded ? archiveMetrics : []"))
        XCTAssertTrue(view.contains("CollapsibleSectionBox(title: \"실행 로그\", systemImage: \"clock.arrow.circlepath\", isExpanded: $isHistoryExpanded)"))
        XCTAssertTrue(view.contains("if isHistoryExpanded {\n                let filtered = filteredRecords"))
        XCTAssertTrue(app.contains(".onChange(of: appearanceMode)"))
        XCTAssertTrue(app.contains("Self.schedulePlatformAppearance(newValue)"))
        XCTAssertTrue(app.contains("NSApp.appearance = appearance"))
        XCTAssertTrue(app.contains("window.appearance = appearance"))
        XCTAssertTrue(app.contains("NSAppearance(named: .aqua)"))
        XCTAssertTrue(app.contains("NSAppearance(named: .darkAqua)"))
        XCTAssertFalse(view.contains("metric.systemImage"))
        XCTAssertFalse(view.contains("row.systemImage"))
        XCTAssertTrue(view.contains("\"gauge.with.dots.needle.67percent\""))
        XCTAssertTrue(view.contains("private var chipText: String"))
        XCTAssertTrue(view.contains("return \"OK\""))
        XCTAssertFalse(workstationLayout.contains("@State private var displayedSection"))
        XCTAssertTrue(workstationLayout.contains("switch selectedSection"))
        XCTAssertFalse(workstationLayout.contains("deferDisplayedSection(newSection)"))
        XCTAssertTrue(workstationLayout.contains("case .settings:"))
        XCTAssertTrue(workstationLayout.contains("SettingsView(model: model)"))
        XCTAssertFalse(workstationLayout.contains("guard klmsMacInteractionDetailDelayNanoseconds > 0 else"))
        XCTAssertFalse(workstationLayout.contains("await Task.yield()"))
        XCTAssertFalse(view.contains("@Environment(\\.openSettings)"))
        XCTAssertFalse(view.contains("openSettings()"))
        XCTAssertFalse(view.contains("KLMSDiagnosticWindowCoordinator.shared.showDiagnosticsWindow()"))
        XCTAssertFalse(view.contains("withAnimation(.snappy(duration: 0.10))"))
        XCTAssertFalse(view.contains("withAnimation(.easeInOut(duration: 0.10))"))
        XCTAssertFalse(view.contains(".transition(.opacity.combined(with: .move(edge: .top)))"))
        XCTAssertFalse(detail.contains("withAnimation(.snappy(duration: 0.10))"))
        XCTAssertFalse(detail.contains(".transition(.opacity.combined(with: .move(edge: .top)))"))
        XCTAssertTrue(navigationView.contains("RoundedRectangle(cornerRadius: 10)"))
        XCTAssertTrue(navigationView.contains("guard selection != section else { return }"))
        XCTAssertTrue(navigationView.contains("Image(systemName: section.systemImage)"))
        XCTAssertTrue(navigationView.contains(".frame(width: 30, height: 30)"))
        XCTAssertTrue(navigationView.contains("Color.klmsMacSelectedBorder.opacity(0.18)"))
        XCTAssertTrue(navigationView.contains("Color.klmsMacSubtleCardBackground.opacity(0.72)"))
        XCTAssertTrue(navigationView.contains("Image(systemName: \"chevron.right\")"))
        XCTAssertTrue(navigationView.contains("isSelected ? Color.klmsMacSelectedBackground.opacity(0.96) : Color.klmsMacSubtleCardBackground.opacity(0.34)"))
        XCTAssertTrue(navigationView.contains(".overlay(alignment: .leading)"))
        XCTAssertTrue(navigationView.contains(".frame(width: 3)"))
        XCTAssertTrue(navigationView.contains("isSelected ? Color.klmsMacSelectedBorder.opacity(0.92) : Color.klmsMacCommandBorder.opacity(0.42)"))
        XCTAssertTrue(navigationView.contains(".frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)"))
        XCTAssertTrue(view.contains("case settings"))
        XCTAssertTrue(view.contains("case .settings:"))
        XCTAssertTrue(view.contains("case files"))
        XCTAssertTrue(view.contains("case notices"))
        XCTAssertTrue(view.contains("case tasks"))
        XCTAssertTrue(view.contains("case calendar"))
        XCTAssertTrue(view.contains("\"설정\""))
        XCTAssertTrue(view.contains("\"gearshape\""))
        XCTAssertTrue(view.contains("\"과제/시험\""))
        XCTAssertTrue(view.contains("TaskAndExamWorkspaceView(model: model)"))
        XCTAssertTrue(view.contains("DashboardDetailPanelView(kind: .files, model: model)"))
        XCTAssertTrue(view.contains("DashboardDetailPanelView(kind: .notices, model: model)"))
        XCTAssertTrue(view.contains("DashboardDetailPanelView(kind: .calendar, model: model)"))
        XCTAssertTrue(commandPanel.contains(".font(.system(size: 18, weight: .black, design: .rounded))"))
        XCTAssertTrue(commandPanel.contains(".padding(.horizontal, 14)"))
        XCTAssertTrue(commandPanel.contains(".padding(.vertical, 15)"))
        XCTAssertTrue(commandPanel.contains(".font(.system(size: 11, weight: .heavy, design: .rounded))"))
        XCTAssertTrue(commandPanel.contains(".padding(.horizontal, 8)"))
        XCTAssertTrue(commandPanel.contains(".buttonStyle(MacPressFeedbackButtonStyle())"))
        XCTAssertTrue(commandPanel.contains(".buttonStyle(MacPressFeedbackButtonStyle(cornerRadius: 12))"))
        XCTAssertTrue(commandPanel.contains("let isRunning = model.runningCommand == command"))
        XCTAssertTrue(commandPanel.contains("Text(isRunning ? \"전체 동기화 중단\" : \"전체 동기화\")"))
        XCTAssertTrue(commandPanel.contains("Image(systemName: isRunning ? \"stop.fill\" : \"play.fill\")"))
        XCTAssertTrue(commandPanel.contains("Color.klmsMacCommandButtonPressedBackground : Color.klmsMacCommandButtonBackground.opacity(0.88)"))
        XCTAssertTrue(commandPanel.contains(".disabled(model.runningCommand != nil && !isRunning)"))
        XCTAssertTrue(commandPanel.contains("private func runOrCancel(_ command: KLMSEngineCommand)"))
        XCTAssertTrue(view.contains(".font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())"))
        XCTAssertTrue(view.contains(".buttonStyle(MacPressFeedbackButtonStyle(cornerRadius: 13))"))
        XCTAssertTrue(view.contains(".buttonStyle(MacPressFeedbackButtonStyle(cornerRadius: 14))"))
        XCTAssertFalse(view.contains(".buttonStyle(.plain)"))
        XCTAssertFalse(detail.contains(".buttonStyle(.plain)"))
        XCTAssertFalse(detail.contains(".buttonStyle(.borderless)"))
        XCTAssertTrue(pressFeedbackStyle.contains("var cornerRadius: CGFloat = 10"))
        XCTAssertTrue(pressFeedbackStyle.contains("RoundedRectangle(cornerRadius: cornerRadius)"))
        XCTAssertTrue(detailPressFeedbackStyle.contains("var cornerRadius: CGFloat = 10"))
        XCTAssertTrue(detailPressFeedbackStyle.contains("RoundedRectangle(cornerRadius: cornerRadius)"))
        XCTAssertFalse(pressFeedbackStyle.contains(".scaleEffect(configuration.isPressed"))
        XCTAssertTrue(pressFeedbackStyle.contains("Color.klmsMacCommandButtonPressedOverlay"))
        XCTAssertFalse(pressFeedbackStyle.contains("Color.klmsMacPrimaryCommandButtonBorder.opacity(configuration.isPressed ? 0.52 : 0.0)"))
        XCTAssertFalse(detailPressFeedbackStyle.contains("Color.klmsMacPrimaryCommandButtonBorder.opacity(configuration.isPressed ? 0.52 : 0.0)"))
        XCTAssertFalse(pressFeedbackStyle.contains("duration: 0.035"))
        XCTAssertFalse(dashboardFilterBar.contains("ViewThatFits"))
        XCTAssertTrue(dashboardFilterBar.contains("searchControl"))
        XCTAssertTrue(dashboardFilterBar.contains("rangeControl"))
        XCTAssertTrue(dashboardFilterBar.contains("displayControl"))
        XCTAssertTrue(view.contains("alpha: 0.105"))
        XCTAssertTrue(view.contains("alpha: 0.140"))
        XCTAssertTrue(rootActionButtonStyle.contains("background(isPressed: configuration.isPressed)"))
        XCTAssertTrue(rootActionButtonStyle.contains("Color.klmsMacCommandButtonPressedBackground"))
        XCTAssertTrue(rootActionButtonStyle.contains("Color.klmsMacPrimaryCommandButtonPressedBackground"))
        XCTAssertTrue(rootActionButtonStyle.contains("AnyShapeStyle("))
        XCTAssertTrue(rootActionButtonStyle.contains("LinearGradient("))
        XCTAssertTrue(rootActionButtonStyle.contains("Color.white"))
        XCTAssertTrue(rootActionButtonStyle.contains("Color.klmsMacDangerBorder.opacity(isPressed ? 0.92 : 0.84)"))
        XCTAssertFalse(rootActionButtonStyle.contains("Color.klmsMacDangerBackground"))
        XCTAssertTrue(actionButtonStyle.contains("Color.klmsMacCommandButtonPressedBackground"))
        XCTAssertTrue(actionButtonStyle.contains("Color.klmsMacPrimaryCommandButtonPressedBackground"))
        XCTAssertTrue(iconButtonStyle.contains("Color.klmsMacCommandButtonPressedBackground"))
        XCTAssertTrue(iconButtonStyle.contains("Color.klmsMacPrimaryCommandButtonBorder.opacity(0.46)"))
        XCTAssertTrue(iconButtonStyle.contains(".frame(width: 26, height: 26)"))
        XCTAssertTrue(commandPanel.contains("Color.klmsMacCommandButtonBackground.opacity(0.90)"))
        XCTAssertFalse(commandPanel.contains(".background(Color.klmsMacDangerBackground, in: RoundedRectangle(cornerRadius: 10))"))
        XCTAssertTrue(verifyCheckRow.contains(".background(Color.klmsMacSubtleCardBackground"))
        XCTAssertTrue(verifyCheckRow.contains(".frame(width: 3)"))
        XCTAssertTrue(verifyCheckRow.contains("isIssue ? 0.34 : 0.18"))
        XCTAssertFalse(verifyCheckRow.contains("return Color.klmsMacDangerBackground"))
        XCTAssertTrue(issueRowView.contains(".background(Color.klmsMacSubtleCardBackground"))
        XCTAssertTrue(issueRowView.contains(".frame(width: 3)"))
        XCTAssertFalse(issueRowView.contains("issue.severity.color.opacity(0.12)"))
        XCTAssertFalse(commandPanel.contains(".font(.title3.weight(.heavy))"))
        XCTAssertTrue(actionButtonStyle.contains("RoundedRectangle(cornerRadius: 10)"))
        XCTAssertTrue(actionButtonStyle.contains(".padding(.vertical, 8)"))
        XCTAssertTrue(actionButtonStyle.contains("background(isPressed: configuration.isPressed)"))
        XCTAssertTrue(actionButtonStyle.contains("return isPressed ? Color.klmsMacCommandButtonPressedBackground : Color.klmsMacCommandButtonBackground.opacity(0.90)"))
        XCTAssertTrue(actionButtonStyle.contains("Color.klmsMacDangerBorder.opacity(isPressed ? 0.78 : 0.48)"))
        XCTAssertFalse(actionButtonStyle.contains("Color.klmsMacDangerBackground"))
    }

    func testMacAndIOSUseSeparatedLightAndDarkThemeTokens() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let macRoot = packageRoot.appendingPathComponent("Sources/KLMSMac/MenuBarRootView.swift")
        let macDetailRoot = packageRoot.appendingPathComponent("Sources/KLMSMac/DashboardDetailView.swift")
        let macSettingsRoot = packageRoot.appendingPathComponent("Sources/KLMSMac/SettingsView.swift")
        let iosRoot = packageRoot.appendingPathComponent("Sources/KLMSiOS/KLMSiOSApp.swift")
        let mac = try String(contentsOf: macRoot, encoding: .utf8)
        let macDetail = try String(contentsOf: macDetailRoot, encoding: .utf8)
        let macSettings = try String(contentsOf: macSettingsRoot, encoding: .utf8)
        let macDesignSources = [mac, macDetail, macSettings].joined(separator: "\n")
        let ios = try String(contentsOf: iosRoot, encoding: .utf8)
        let macSettingsButtonStyle = try sourceBody(
            after: "private struct KLMSMacSettingsButtonStyle: ButtonStyle",
            in: macSettings,
            description: "Mac settings button style"
        )

        XCTAssertTrue(mac.contains("static func klmsMacAdaptiveColor(light: NSColor, dark: NSColor)"))
        XCTAssertTrue(mac.contains("var borderColor: Color = .klmsMacBorder"))
        XCTAssertTrue(mac.contains("light: NSColor(red: 0.973, green: 0.969, blue: 0.949"))
        XCTAssertTrue(mac.contains("dark: NSColor(red: 0.063, green: 0.063, blue: 0.059"))
        XCTAssertTrue(mac.contains("light: NSColor(red: 0.165, green: 0.165, blue: 0.153"))
        XCTAssertTrue(mac.contains("dark: NSColor(red: 0.941, green: 0.875, blue: 0.722"))
        XCTAssertTrue(mac.contains("light: NSColor(red: 1.000, green: 0.980, blue: 0.941"))
        XCTAssertFalse(mac.contains("static var klmsMacCommandAccent: Color {\n        klmsMacAdaptiveColor(\n            light: NSColor(red: 0.090"))
        XCTAssertTrue(ios.contains("light: UIColor(red: 0.812, green: 0.788, blue: 0.718"))
        XCTAssertTrue(ios.contains("dark: UIColor(red: 0.318, green: 0.298, blue: 0.251"))
        XCTAssertFalse(ios.contains("light: UIColor(red: 0.862, green: 0.840, blue: 0.782"))
        XCTAssertFalse(ios.contains("dark: UIColor(red: 0.251, green: 0.239, blue: 0.208"))
        XCTAssertFalse(ios.contains("static var klmsCommandAccent: Color {\n        #if canImport(UIKit)\n        return klmsAdaptiveColor(\n            light: UIColor(red: 0.090"))
        XCTAssertTrue(mac.contains("static var klmsMacPrimaryText: Color"))
        XCTAssertTrue(mac.contains("static var klmsMacSecondaryText: Color"))
        XCTAssertTrue(mac.contains("static var klmsMacPrimaryCommandButtonForeground: Color"))
        XCTAssertTrue(mac.contains("static var klmsMacSecondaryCommandButtonForeground: Color"))
        XCTAssertTrue(mac.contains(".foregroundStyle(Color.klmsMacPrimaryCommandButtonForeground)"))
        XCTAssertTrue(macSettings.contains(".buttonStyle(KLMSMacSettingsButtonStyle())"))
        XCTAssertTrue(macSettings.contains(".buttonStyle(KLMSMacSettingsButtonStyle(tone: .destructive))"))
        XCTAssertTrue(macSettingsButtonStyle.contains("Color.klmsMacCommandButtonPressedBackground"))
        XCTAssertTrue(macSettingsButtonStyle.contains("Color.klmsMacPrimaryCommandButtonBorder.opacity(0.46)"))
        XCTAssertTrue(macSettingsButtonStyle.contains("Color.klmsMacDangerBorder.opacity(isPressed ? 0.78 : 0.48)"))
        XCTAssertTrue(mac.contains("Image(systemName: isRunning ? \"stop.fill\" : \"play.fill\")"))
        XCTAssertTrue(mac.contains(".font(.headline.weight(.black))"))
        XCTAssertFalse(macDesignSources.contains(".foregroundStyle(.secondary)"))
        XCTAssertFalse(macDesignSources.contains("return .secondary"))
        XCTAssertFalse(macDesignSources.contains("Color.secondary"))
        XCTAssertFalse(macDesignSources.contains("Color.primary"))
        XCTAssertFalse(macDesignSources.contains(".accentColor"))
        XCTAssertFalse(macDesignSources.contains("Color(nsColor: .controlBackgroundColor)"))
        XCTAssertFalse(macDesignSources.contains("Color(nsColor: .textBackgroundColor)"))
        XCTAssertFalse(macDesignSources.contains(".background(.quinary"))
        XCTAssertFalse(macDesignSources.contains(".background(.background"))
        XCTAssertNil(macDesignSources.range(of: #"foregroundStyle\([^\n]*(\.secondary|\.tertiary|\.primary|\.blue|\.green|\.orange|\.red|\.purple|Color\.secondary|Color\.primary|\.accentColor)"#, options: .regularExpression))
        XCTAssertNil(macDesignSources.range(of: #"tint\([^\n]*(\.secondary|\.blue|\.green|\.orange|\.red|\.purple|\.accentColor)"#, options: .regularExpression))
        XCTAssertNil(macDesignSources.range(of: #"stroke\(\.quaternary"#, options: .regularExpression))
        XCTAssertNil(macDesignSources.range(of: #"return result\.succeeded \? \.(green|orange)"#, options: .regularExpression))
        XCTAssertNil(macDesignSources.range(of: #"return record\.succeeded \? \.(green|orange)"#, options: .regularExpression))

        XCTAssertTrue(ios.contains("static func klmsAdaptiveColor(light: UIColor, dark: UIColor)"))
        XCTAssertTrue(ios.contains("static func klmsAppKitAdaptiveColor(light: NSColor, dark: NSColor)"))
        XCTAssertTrue(ios.contains("light: UIColor(red: 0.973, green: 0.969, blue: 0.949"))
        XCTAssertTrue(ios.contains("dark: UIColor(red: 0.063, green: 0.063, blue: 0.059"))
        XCTAssertTrue(ios.contains("light: UIColor(red: 0.165, green: 0.165, blue: 0.153"))
        XCTAssertTrue(ios.contains("dark: UIColor(red: 0.941, green: 0.875, blue: 0.722"))
        XCTAssertTrue(ios.contains("static var klmsCommandButtonPressedBackground: Color"))
        XCTAssertTrue(ios.contains("static var klmsCommandButtonPressedOverlay: Color"))
        XCTAssertTrue(ios.contains("static var klmsPrimaryCommandButtonPressedBackground: Color"))
        XCTAssertTrue(ios.contains("light: UIColor(red: 0.812, green: 0.788, blue: 0.718"))
        XCTAssertTrue(ios.contains("dark: UIColor(red: 0.318, green: 0.298, blue: 0.251"))
        XCTAssertTrue(ios.contains("light: UIColor(red: 1.000, green: 0.980, blue: 0.941"))
        XCTAssertTrue(ios.contains("static var klmsPrimaryText: Color"))
        XCTAssertTrue(ios.contains("static var klmsSecondaryText: Color"))
        XCTAssertTrue(ios.contains("private struct KLMSCardButtonStyle: ButtonStyle"))
        XCTAssertTrue(ios.contains("static var klmsSecondaryCommandButtonForeground: Color"))
        XCTAssertTrue(ios.contains("primaryCommandSystemImage(isRunning: isRunning, isDisabled: isDisabled)"))
        XCTAssertTrue(ios.contains(".font(.headline.weight(.black))"))
        XCTAssertFalse(ios.contains(".foregroundStyle(.secondary)"))
        XCTAssertFalse(ios.contains("return .secondary"))
        XCTAssertFalse(ios.contains("Color.secondary"))
        XCTAssertFalse(ios.contains("Color.primary"))
        XCTAssertFalse(ios.contains(".accentColor"))
        XCTAssertFalse(ios.contains(".background(.quinary"))
        XCTAssertFalse(ios.contains(".background(.background"))
        XCTAssertNil(ios.range(of: #"foregroundStyle\([^\n]*(\.secondary|\.primary|Color\.secondary|Color\.primary|\.accentColor)"#, options: .regularExpression))
        XCTAssertNil(ios.range(of: #"tint\([^\n]*(\.secondary|\.accentColor)"#, options: .regularExpression))
        XCTAssertNil(ios.range(of: #"stroke\(\.quaternary"#, options: .regularExpression))
    }

    func testMacAndIOSDirectInteractionAnimationsStayFast() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let macRoot = packageRoot.appendingPathComponent("Sources/KLMSMac/MenuBarRootView.swift")
        let macDetailRoot = packageRoot.appendingPathComponent("Sources/KLMSMac/DashboardDetailView.swift")
        let macModelRoot = packageRoot.appendingPathComponent("Sources/KLMSMac/KLMSMacModel.swift")
        let iosRoot = packageRoot.appendingPathComponent("Sources/KLMSiOS/KLMSiOSApp.swift")
        let sources = try [
            String(contentsOf: macRoot, encoding: .utf8),
            String(contentsOf: macDetailRoot, encoding: .utf8),
            String(contentsOf: macModelRoot, encoding: .utf8),
            String(contentsOf: iosRoot, encoding: .utf8),
        ].joined(separator: "\n")

        XCTAssertFalse(sources.contains("duration: 0.04"))
        XCTAssertFalse(sources.contains("withAnimation(.linear(duration:"))
        XCTAssertFalse(sources.contains(".scaleEffect(configuration.isPressed"))
        XCTAssertFalse(sources.contains(".shadow(color: isSelected ?"))
        XCTAssertNil(
            sources.range(
                of: #"withAnimation\([^\n]*duration: 0\.(1[6-9]|[2-9][0-9]?)"#,
                options: .regularExpression
            ),
            "직접 누르는 UI의 전환 애니메이션은 0.10초 이하로 유지해야 합니다."
        )
        XCTAssertTrue(sources.contains("private static let liveCommandOutputMaxCharacters = 8_000"))
        XCTAssertTrue(sources.contains("private static let liveAuthObservationMaxCharacters = 4_000"))
        XCTAssertTrue(sources.contains("appendLiveAuthObservation(displayChunk)"))
        XCTAssertFalse(sources.contains("let currentOutput = liveCommandOutputBuffer"))
        XCTAssertTrue(sources.contains("private static let liveCommandOutputPublishIntervalNanoseconds: UInt64 = 500_000_000"))
        XCTAssertTrue(sources.contains("private var cachedLiveProgressLine: String?"))
        XCTAssertTrue(sources.contains("private var cachedCurrentPhaseText: String?"))
        XCTAssertTrue(sources.contains("private static func extractLiveProgressLine(from text: String) -> String?"))
        XCTAssertTrue(sources.contains("private static let runningSnapshotRefreshIntervalNanoseconds: UInt64 = 3_000_000_000"))
        XCTAssertTrue(sources.contains("private let dashboardDetailExpansionDelayNanoseconds: UInt64 = 45_000_000"))
        XCTAssertTrue(sources.contains("private struct DeferredDashboardExpansion"))
        XCTAssertTrue(sources.contains("reloadManualOverrideState()"))
        XCTAssertTrue(sources.contains("reloadNoticeInteractionState()"))
        XCTAssertTrue(sources.contains("reloadFileInteractionState()"))
        XCTAssertFalse(sources.contains("try NoticeUserStateStore(url: paths.noticeUserStateURL).setRead(isRead, notice: notice)\n            reloadSnapshot()"))
        XCTAssertFalse(sources.contains("try AppUserStateStore(url: paths.appUserStateURL).setHidden(")
            && sources.contains("bucket: .files\n            )\n            reloadSnapshot()"))
    }

    func testMacFileDashboardAvoidsPerRowFilesystemTasks() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let detailRoot = packageRoot.appendingPathComponent("Sources/KLMSMac/DashboardDetailView.swift")
        let detail = try String(contentsOf: detailRoot, encoding: .utf8)
        let fileRow = try sourceStructBody(named: "FileRowView", in: detail)
        let fileItem = try sourceBody(
            after: "private struct DashboardFileItem",
            in: detail,
            description: "DashboardFileItem"
        )

        XCTAssertFalse(fileRow.contains(".task(id: item.path)"))
        XCTAssertFalse(fileRow.contains("FileManager.default.fileExists"))
        XCTAssertTrue(fileRow.contains("let pathExists = item.pathExists"))
        XCTAssertTrue(fileItem.contains("var pathExists: Bool = false"))
        XCTAssertTrue(fileItem.contains("private var searchBlob: String = \"\""))
        XCTAssertTrue(fileItem.contains("courseSortKey = course.normalizedFileSortKey"))
        XCTAssertTrue(detail.contains("private struct DashboardFileData"))
        XCTAssertTrue(detail.contains("var manifestFiles: [DashboardFileItem]"))
        XCTAssertTrue(detail.contains("var newFiles: [DashboardFileItem]"))
        XCTAssertTrue(detail.contains("var missingFiles: [DashboardFileItem]"))
        XCTAssertTrue(detail.contains("var quarantineFiles: [DashboardFileItem]"))
        XCTAssertTrue(detail.contains("struct Signature: Equatable, Sendable"))
        XCTAssertTrue(detail.contains("fileDataTask = Task { @MainActor in"))
        XCTAssertTrue(detail.contains("Task.detached(priority: .userInitiated)"))
        XCTAssertFalse(detail.contains("let initialFileData = DashboardFileData(snapshot: resolvedSnapshot)"))
        XCTAssertFalse(detail.contains("dashboardMissingPathSet(from: model.snapshot)"))
        XCTAssertFalse(detail.contains("private func dashboardFilePathExists"))
        XCTAssertTrue(detail.contains("static let initialVisibleLimit = 6"))
        XCTAssertTrue(detail.contains("static let increment = 10"))
        XCTAssertTrue(detail.contains("private struct DashboardRowDisclosureButton"))
        XCTAssertTrue(detail.contains("private struct DeferredDashboardExpansion"))
        XCTAssertEqual(detail.components(separatedBy: "@ObservedObject var model: KLMSMacModel").count - 1, 0)
        XCTAssertTrue(detail.contains("struct DashboardDetailPanelView: View, @preconcurrency Equatable"))
        XCTAssertTrue(detail.contains("struct DashboardRenderSignature: Equatable"))
        XCTAssertTrue(fileRow.contains("@State private var isExpanded = false"))
        XCTAssertTrue(fileRow.contains("if isExpanded, !item.path.isEmpty"))
        XCTAssertTrue(fileRow.contains("DeferredDashboardExpansion(isExpanded: isExpanded)"))
        XCTAssertTrue(fileRow.contains("actionBar(hidden: hidden, pathExists: pathExists)"))
    }

    func testIOSDashboardAndSettingsFollowDesignNavigation() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repoRoot = packageRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let iosRoot = packageRoot.appendingPathComponent("Sources/KLMSiOS/KLMSiOSApp.swift")
        let designSpecRoot = repoRoot.appendingPathComponent("docs/superpowers/specs/2026-06-14-klms-sync-app-visual-redesign.md")
        let ios = try String(contentsOf: iosRoot, encoding: .utf8)
        let designSpec = try String(contentsOf: designSpecRoot, encoding: .utf8)
        let statusScreen = try sourceStructBody(named: "CompanionStatusScreen", in: ios)
        let settingsScreen = try sourceStructBody(named: "CompanionSettingsScreen", in: ios)
        let sectionContent = try sourceStructBody(named: "CompanionSectionContent", in: ios)
        let compactRoot = try sourceStructBody(named: "CompanionTabRootView", in: ios)
        let compactTabBar = try sourceStructBody(named: "CompanionCompactTabBar", in: ios)
        let dashboardSyncCard = try sourceStructBody(named: "RemoteDashboardSyncCard", in: ios)
        let metricOverview = try sourceStructBody(named: "RemoteDashboardMetricOverview", in: ios)
        let metricTile = try sourceStructBody(named: "RemoteMetricTile", in: ios)
        let compactSelectedRow = try sourceStructBody(named: "CompactDashboardSelectedRow", in: ios)
        let cardButtonStyle = try sourceBody(
            after: "private struct KLMSCardButtonStyle: ButtonStyle",
            in: ios,
            description: "KLMS card button style"
        )
        let actionButtonStyle = try sourceBody(
            after: "private struct KLMSActionButtonStyle: ButtonStyle",
            in: ios,
            description: "KLMS action button style"
        )
        let toolbarButtonStyle = try sourceBody(
            after: "private struct KLMSToolbarButtonStyle: ButtonStyle",
            in: ios,
            description: "KLMS toolbar button style"
        )
        let relayConnectionPanel = try sourceStructBody(named: "ServerRelayConnectionPanel", in: ios)
        let immediateSettingsPanel = try sourceStructBody(named: "CompanionImmediateSettingsPanel", in: ios)
        let remoteSettingsPanel = try sourceStructBody(named: "RemoteSettingsPanel", in: ios)
        let remoteSettingGroupSection = try sourceStructBody(named: "RemoteSettingGroupSection", in: ios)
        let remoteDiagnosticPanel = try sourceStructBody(named: "RemoteDiagnosticPanel", in: ios)
        let remotePrivacyNote = try sourceStructBody(named: "RemotePrivacyNote", in: ios)
        let remoteCommandPanel = try sourceStructBody(named: "RemoteCommandPanel", in: ios)
        let mailCalendarCreateForm = try sourceStructBody(named: "MailCalendarCreateForm", in: ios)
        let mailDashboardItemEditForm = try sourceStructBody(named: "MailDashboardItemEditForm", in: ios)
        let calendarEventEditForm = try sourceStructBody(named: "CalendarEventEditForm", in: ios)
        let remoteSettingRow = try sourceStructBody(named: "RemoteSettingRow", in: ios)
        let dashboardMetricCategory = try sourceBody(
            after: "private enum DashboardMetricCategory: String, CaseIterable, Identifiable",
            in: ios,
            description: "iOS dashboard metric category"
        )
        let remoteChangeSummaryKind = try sourceBody(
            after: "private enum RemoteChangeSummaryKind: String, CaseIterable, Identifiable",
            in: ios,
            description: "iOS remote change summary kind"
        )
        let calendarChangeDetailRow = try sourceStructBody(named: "DashboardCalendarChangeDetailRow", in: ios)
        let remoteChangeSummary = try sourceStructBody(named: "RemoteDashboardChangeSummary", in: ios)
        let flowChipLayout = try sourceStructBody(named: "FlowChipLayout", in: ios)
        let remoteChangeSummaryDetail = try sourceStructBody(named: "RemoteChangeSummaryDetailPanel", in: ios)
        let inlineItemDetail = try sourceStructBody(named: "ServerSyncItemInlineDetailPanel", in: ios)
        let sheetItemDetail = try sourceStructBody(named: "ServerSyncItemDetailView", in: ios)
        let serverSyncDataRow = try sourceStructBody(named: "ServerSyncDataRow", in: ios)
        let sharedRunLogRow = try sourceStructBody(named: "SharedRunLogRow", in: ios)
        let remoteCommandRow = try sourceStructBody(named: "RemoteCommandRow", in: ios)
        let remoteCancelControl = try sourceStructBody(named: "RemoteCancelControl", in: ios)
        let remoteVerifyCheckRow = try sourceStructBody(named: "RemoteVerifyCheckRow", in: ios)
        let errorBanner = try sourceStructBody(named: "ErrorBanner", in: ios)
        let companionSection = try sourceBody(
            after: "private enum CompanionAppSection: String, CaseIterable, Identifiable, Hashable",
            in: ios,
            description: "iOS companion app section"
        )

        XCTAssertTrue(companionSection.contains("case status"))
        XCTAssertTrue(companionSection.contains("case files"))
        XCTAssertTrue(companionSection.contains("case notices"))
        XCTAssertTrue(companionSection.contains("case tasks"))
        XCTAssertTrue(companionSection.contains("case calendar"))
        XCTAssertTrue(companionSection.contains("case history"))
        XCTAssertTrue(companionSection.contains("case settings"))
        XCTAssertTrue(companionSection.contains("return \"대시보드\""))
        XCTAssertTrue(companionSection.contains("return \"상태\""))
        XCTAssertTrue(companionSection.contains("return \"파일\""))
        XCTAssertTrue(companionSection.contains("return \"공지\""))
        XCTAssertTrue(companionSection.contains("return \"과제/시험\""))
        XCTAssertTrue(companionSection.contains("return \"캘린더\""))
        XCTAssertTrue(companionSection.contains("return \"로그\""))
        XCTAssertTrue(companionSection.contains("return \"설정\""))
        XCTAssertTrue(ios.contains("static var compactTabs: [CompanionAppSection]"))
        XCTAssertTrue(ios.contains("static var compactTabs: [CompanionAppSection] {\n        [.status, .files, .history, .settings]"))
        XCTAssertTrue(ios.contains("static var workstationSections: [CompanionAppSection] {\n        [.status, .files, .tasks, .notices, .calendar, .history, .settings]"))
        XCTAssertTrue(compactRoot.contains("CompanionCompactTabBar"))
        XCTAssertLessThan(
            compactRoot.range(of: "CompanionSectionContent(section: selectedSection, model: model)")?.lowerBound ?? compactRoot.endIndex,
            compactRoot.range(of: "CompanionCompactTabBar(selectedSection: $selectedSection)")?.lowerBound ?? compactRoot.startIndex,
            "iPhone compact layout should keep content first and place the tab bar at the bottom, matching the design preview."
        )
        XCTAssertFalse(compactRoot.contains("TabView"))
        XCTAssertFalse(compactRoot.contains(".tabItem"))
        XCTAssertTrue(compactTabBar.contains("ForEach(Array(compactRows.enumerated()), id: \\.offset)"))
        XCTAssertTrue(compactTabBar.contains("private var compactRows: [[CompanionAppSection]]"))
        XCTAssertTrue(compactTabBar.contains("CompanionAppSection.compactTabs"))
        XCTAssertFalse(compactTabBar.contains("[.status, .history, .settings]"))
        XCTAssertFalse(compactTabBar.contains("[.status, .files, .notices, .tasks]"))
        XCTAssertFalse(compactTabBar.contains("[.calendar, .history, .settings]"))
        XCTAssertFalse(compactTabBar.contains("withAnimation(.easeOut(duration: 0.12))"))
        XCTAssertFalse(compactTabBar.contains(".animation(.easeOut(duration: 0.10), value: isSelected)"))
        XCTAssertTrue(compactTabBar.contains("Image(systemName: section.systemImage)"))
        XCTAssertTrue(compactTabBar.contains("Text(section.compactTitle)"))
        XCTAssertTrue(compactTabBar.contains(".frame(maxWidth: .infinity, minHeight: 44)"))
        XCTAssertFalse(compactTabBar.contains("private func compactTabMinWidth(for section: CompanionAppSection) -> CGFloat"))
        XCTAssertFalse(compactTabBar.contains("ScrollView(.horizontal"))
        XCTAssertFalse(compactTabBar.contains(".frame(maxWidth: .infinity, minHeight: 34)"))
        XCTAssertTrue(compactTabBar.contains("? Color.klmsSelectedBackground.opacity(0.96)"))
        XCTAssertTrue(compactTabBar.contains(": Color.klmsSubtleCardBackground.opacity(0.62)"))
        XCTAssertTrue(compactTabBar.contains("isSelected ? Color.klmsSelectedBorder.opacity(0.92) : Color.klmsBorder.opacity(0.42)"))
        XCTAssertFalse(compactTabBar.contains(".shadow(color: isSelected ? Color.klmsSelectedBorder.opacity(0.10) : Color.clear"))
        XCTAssertTrue(compactTabBar.contains(".buttonStyle(KLMSCardButtonStyle())"))
        XCTAssertFalse(compactTabBar.contains("Label(section.compactTitle"))
        XCTAssertTrue(compactTabBar.contains(".padding(6)"))
        XCTAssertFalse(compactTabBar.contains(".padding(.horizontal, 6)"))
        XCTAssertFalse(compactTabBar.contains(".padding(7)"))
        XCTAssertFalse(compactTabBar.contains(".frame(height: 56)"))
        XCTAssertTrue(compactTabBar.contains("RoundedRectangle(cornerRadius: 14)"))
        XCTAssertTrue(compactTabBar.contains("RoundedRectangle(cornerRadius: 10)"))
        XCTAssertTrue(sectionContent.contains("CompanionDashboardCategoryScreen(title: \"파일\", category: .files"))
        XCTAssertTrue(sectionContent.contains("CompanionDashboardCategoryScreen(title: \"공지\", category: .notices"))
        XCTAssertTrue(sectionContent.contains("CompanionTasksScreen"))
        XCTAssertTrue(sectionContent.contains("CompanionDashboardCategoryScreen(title: \"캘린더\", category: .calendar"))
        XCTAssertTrue(sectionContent.contains("CompanionSettingsScreen"))
        XCTAssertTrue(statusScreen.contains("CompanionScreenContainer(title: \"대시보드\""))
        XCTAssertFalse(statusScreen.contains("RemoteDashboardStatusStrip"))
        XCTAssertFalse(statusScreen.contains("shouldShowCompactStatusStrip"))
        XCTAssertFalse(statusScreen.contains(".transition(.opacity.combined(with: .move(edge: .top)))"))
        XCTAssertTrue(statusScreen.contains("RemoteDashboardSyncCard"))
        XCTAssertTrue(statusScreen.contains("RemoteDashboardMetricOverview"))
        XCTAssertTrue(statusScreen.contains("statusDetailColumn"))
        XCTAssertTrue(statusScreen.contains("DashboardCategoryInlineDetailPanel(category: category, model: model)"))
        XCTAssertTrue(statusScreen.contains("HStack(alignment: .top, spacing: 16)"))
        XCTAssertTrue(statusScreen.contains(".frame(minWidth: 320, idealWidth: 380, maxWidth: 430"))
        XCTAssertFalse(statusScreen.contains("WorkstationDashboardDetailPanel"))
        XCTAssertFalse(metricOverview.contains("CompactDashboardSelectionPanel(category: selectedCategory, model: model)"))
        XCTAssertFalse(metricOverview.contains("RemoteChangeSummaryDetailPanel(kind: selectedChangeSummary, model: model)"))
        XCTAssertFalse(statusScreen.contains("RemoteLogSummaryPanel"))
        XCTAssertFalse(statusScreen.contains("RemoteCommandPanel"))
        XCTAssertTrue(dashboardSyncCard.contains("RemoteCancelControl(model: model, compact: compact)"))
        XCTAssertTrue(dashboardSyncCard.contains("MailPasteAnalyzerPanel(model: model)"))
        XCTAssertFalse(remoteCommandPanel.contains("MailPasteAnalyzerPanel"))
        XCTAssertFalse(statusScreen.contains("RecentRemoteCommandsView"))

        XCTAssertTrue(settingsScreen.contains("ServerRelayConnectionPanel"))
        XCTAssertTrue(settingsScreen.contains("CompanionImmediateSettingsPanel"))
        XCTAssertFalse(settingsScreen.contains("CompanionAppearancePanel"))
        XCTAssertTrue(settingsScreen.contains("RemoteSettingsPanel"))
        XCTAssertTrue(settingsScreen.contains("RemoteDiagnosticPanel"))
        XCTAssertFalse(settingsScreen.contains("RemoteLogSummaryPanel"))
        XCTAssertFalse(settingsScreen.contains("RecentRemoteCommandsView"))
        XCTAssertTrue(immediateSettingsPanel.contains("DisclosureGroup(isExpanded: $isExpanded)"))
        XCTAssertTrue(remoteSettingsPanel.contains("DisclosureGroup(isExpanded: $isExpanded)"))
        XCTAssertTrue(remoteSettingsPanel.contains("Color.klmsCardBackground, in: RoundedRectangle(cornerRadius: 14)"))
        XCTAssertTrue(remoteSettingGroupSection.contains("RoundedRectangle(cornerRadius: 12)"))
        XCTAssertTrue(remoteSettingGroupSection.contains("isExpanded ? Color.klmsSelectedBorder.opacity(0.48) : Color.klmsBorder.opacity(0.86)"))
        XCTAssertTrue(remoteDiagnosticPanel.contains("상태 검사와 권한 점검은 필요할 때만 펼치세요."))
        XCTAssertTrue(remoteDiagnosticPanel.contains("CompanionExpansionBadge(isExpanded: isPanelExpanded)"))
        XCTAssertTrue(remoteDiagnosticPanel.contains("RoundedRectangle(cornerRadius: 14)"))
        XCTAssertTrue(remoteDiagnosticPanel.contains("CompanionExpansionBadge(isExpanded: isAdvancedExpanded, compact: true)"))
        XCTAssertTrue(relayConnectionPanel.contains("@State private var isExpanded = false"))
        XCTAssertTrue(relayConnectionPanel.contains("DisclosureGroup(isExpanded: $isExpanded)"))
        XCTAssertTrue(relayConnectionPanel.contains("Label(\"서버 연결 정보\", systemImage: \"link\")"))
        XCTAssertFalse(relayConnectionPanel.contains("Label(\"서버 릴레이 정보\", systemImage: \"link\")"))
        XCTAssertTrue(remotePrivacyNote.contains("DisclosureGroup(isExpanded: $isExpanded)"))
        XCTAssertTrue(remotePrivacyNote.contains("서버에 무엇이 올라가는지 확인할 때만 펼치세요."))
        XCTAssertTrue(remotePrivacyNote.contains("CompanionExpansionBadge(isExpanded: isExpanded)"))
        XCTAssertTrue(remotePrivacyNote.contains("RoundedRectangle(cornerRadius: 14)"))
        XCTAssertTrue(dashboardSyncCard.contains("primaryCommandTitle(isRunning: isRunning, isDisabled: isDisabled)"))
        XCTAssertTrue(dashboardSyncCard.contains("primaryCommandSystemImage(isRunning: isRunning, isDisabled: isDisabled)"))
        XCTAssertTrue(dashboardSyncCard.contains("return \"Mac 연결 필요\""))
        XCTAssertTrue(dashboardSyncCard.contains("if isDisabled { return Color.klmsCommandButtonBackground.opacity(0.92) }"))
        XCTAssertFalse(dashboardSyncCard.contains(".opacity(commandDisabled(for: .fullSync)"))
        XCTAssertTrue(dashboardSyncCard.contains("private func isCommandActive(_ kind: RemoteCommandKind) -> Bool"))
        XCTAssertTrue(dashboardSyncCard.contains("private func runOrCancel(_ kind: RemoteCommandKind)"))
        XCTAssertTrue(dashboardSyncCard.contains("model.latestDisplayStatus?.isInFlight == true && model.latestCommand?.kind == kind"))
        XCTAssertTrue(dashboardSyncCard.contains(".font(.system(size: 19, weight: .heavy, design: .rounded))"))
        XCTAssertTrue(dashboardSyncCard.contains("Text(syncStateTitle)"))
        XCTAssertFalse(dashboardSyncCard.contains("Label(syncStateTitle"))
        XCTAssertFalse(dashboardSyncCard.contains("Mac 앱에 실행 요청을 보냅니다."))
        XCTAssertTrue(dashboardSyncCard.contains(".font(.system(size: 11, weight: .bold, design: .rounded))"))
        XCTAssertTrue(dashboardSyncCard.contains(".padding(11)"))
        XCTAssertTrue(dashboardSyncCard.contains("GridItem(.flexible(minimum: 0), spacing: 7)"))
        XCTAssertTrue(dashboardSyncCard.contains("LazyVGrid(columns: secondaryColumns, spacing: 7)"))
        XCTAssertTrue(dashboardSyncCard.contains("ForEach(secondaryCommands, id: \\.self)"))
        XCTAssertFalse(dashboardSyncCard.contains("if compact {\n                LazyVGrid(columns: secondaryColumns"))
        XCTAssertTrue(designSpec.contains("바로 아래에 `파일`, `과제/시험`, `공지` 개별 실행 버튼을 3열로 둔다."))
        XCTAssertTrue(designSpec.contains("설정: 앱 안의 왼쪽 작업 공간에서 처리한다. 별도 macOS Settings 창을 띄우지 않는다."))
        XCTAssertTrue(dashboardSyncCard.contains(".padding(.horizontal, 5)"))
        XCTAssertTrue(metricOverview.contains("if horizontalSizeClass == .regular"))
        XCTAssertFalse(metricOverview.contains("Text(title)"))
        XCTAssertTrue(metricTile.contains("Color.klmsCardBackground"))
        XCTAssertTrue(metricTile.contains(".font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())"))
        XCTAssertTrue(metricTile.contains(".font(.system(size: 11, weight: .bold, design: .rounded))"))
        XCTAssertTrue(metricTile.contains(".padding(11)"))
        XCTAssertFalse(metricTile.contains(".padding(.horizontal, 12)"))
        XCTAssertFalse(metricTile.contains(".padding(.vertical, 8)"))
        XCTAssertTrue(metricTile.contains("RoundedRectangle(cornerRadius: 14)"))
        XCTAssertTrue(compactSelectedRow.contains("RoundedRectangle(cornerRadius: 14)"))
        XCTAssertTrue(cardButtonStyle.contains("Color.klmsCommandButtonPressedOverlay"))
        XCTAssertTrue(cardButtonStyle.contains("@Environment(\\.isEnabled)"))
        XCTAssertFalse(cardButtonStyle.contains(".opacity(configuration.isPressed ? 0.96 : 1.0)"))
        XCTAssertTrue(actionButtonStyle.contains("RoundedRectangle(cornerRadius: 10)"))
        XCTAssertTrue(actionButtonStyle.contains(".font(.system(size: 12, weight: .semibold, design: .rounded))"))
        XCTAssertTrue(actionButtonStyle.contains(".padding(.horizontal, 8)"))
        XCTAssertTrue(actionButtonStyle.contains(".padding(.vertical, 10)"))
        XCTAssertTrue(actionButtonStyle.contains("background(isPressed: configuration.isPressed)"))
        XCTAssertTrue(actionButtonStyle.contains("return AnyShapeStyle(isPressed ? Color.klmsCommandButtonPressedBackground : Color.klmsCommandButtonBackground.opacity(0.90))"))
        XCTAssertTrue(actionButtonStyle.contains("return AnyShapeStyle(isPressed ? Color.klmsPrimaryCommandButtonPressedBackground : Color.klmsPrimaryCommandButtonBackground)"))
        XCTAssertTrue(actionButtonStyle.contains("LinearGradient("))
        XCTAssertTrue(actionButtonStyle.contains("Color.white"))
        XCTAssertFalse(actionButtonStyle.contains("Color.klmsDangerBackground"))
        XCTAssertTrue(actionButtonStyle.contains("return AnyShapeStyle(isPressed ? Color.klmsSuccessBorder.opacity(0.20) : Color.klmsSuccessBackground)"))
        XCTAssertTrue(actionButtonStyle.contains("return AnyShapeStyle(color.opacity(isPressed ? 0.18 : 0.10))"))
        XCTAssertTrue(actionButtonStyle.contains("Color.klmsPrimaryCommandButtonBorder.opacity(isPressed ? 0.72 : 1.0)"))
        XCTAssertTrue(actionButtonStyle.contains("Color.klmsDangerBorder.opacity(isPressed ? 0.92 : 0.84)"))
        XCTAssertTrue(toolbarButtonStyle.contains("RoundedRectangle(cornerRadius: 9)"))
        XCTAssertTrue(toolbarButtonStyle.contains(".padding(.horizontal, 9)"))
        XCTAssertTrue(toolbarButtonStyle.contains("Color.klmsCommandButtonPressedBackground"))
        XCTAssertTrue(toolbarButtonStyle.contains("Color.klmsPrimaryCommandButtonPressedBackground"))
        XCTAssertTrue(mailCalendarCreateForm.contains(".buttonStyle(KLMSToolbarButtonStyle())"))
        XCTAssertTrue(mailCalendarCreateForm.contains(".buttonStyle(KLMSToolbarButtonStyle(tone: .success))"))
        XCTAssertTrue(mailDashboardItemEditForm.contains(".buttonStyle(KLMSToolbarButtonStyle())"))
        XCTAssertTrue(mailDashboardItemEditForm.contains(".buttonStyle(KLMSToolbarButtonStyle(tone: .primary))"))
        XCTAssertTrue(calendarEventEditForm.contains(".buttonStyle(KLMSToolbarButtonStyle())"))
        XCTAssertTrue(calendarEventEditForm.contains(".buttonStyle(KLMSToolbarButtonStyle(tone: action == .calendarCreate ? .success : .primary))"))
        XCTAssertTrue(sheetItemDetail.contains(".buttonStyle(KLMSToolbarButtonStyle())"))
        XCTAssertTrue(remoteSettingRow.contains("Text(setting.value.nilIfEmpty ?? \"선택\")"))
        XCTAssertTrue(remoteSettingRow.contains("Label(setting.boolValue ? \"켜짐\" : \"꺼짐\""))
        XCTAssertTrue(remoteSettingRow.contains(".buttonStyle(KLMSActionButtonStyle())"))
        XCTAssertTrue(remoteCancelControl.contains("Image(systemName: \"stop.circle\")"))
        XCTAssertTrue(remoteCancelControl.contains(".background(Color.klmsSubtleCardBackground"))
        XCTAssertFalse(remoteCancelControl.contains(".background(Color.klmsDangerBackground"))
        XCTAssertTrue(remoteVerifyCheckRow.contains(".background(Color.klmsSubtleCardBackground"))
        XCTAssertTrue(remoteVerifyCheckRow.contains(".frame(width: 3)"))
        XCTAssertTrue(remoteVerifyCheckRow.contains("isIssue ? 0.34 : 0.18"))
        XCTAssertFalse(remoteVerifyCheckRow.contains("return Color.klmsDangerBackground"))
        XCTAssertTrue(errorBanner.contains(".background(Color.klmsSubtleCardBackground"))
        XCTAssertFalse(errorBanner.contains(".background(Color.klmsDangerBackground"))
        XCTAssertFalse(actionButtonStyle.contains(".padding(.horizontal, 10)"))
        XCTAssertFalse(actionButtonStyle.contains(".padding(.vertical, 8)"))
        XCTAssertTrue(relayConnectionPanel.contains("RoundedRectangle(cornerRadius: 14)"))
        XCTAssertTrue(relayConnectionPanel.contains("RoundedRectangle(cornerRadius: 10)"))
        XCTAssertTrue(immediateSettingsPanel.contains("RoundedRectangle(cornerRadius: 14)"))
        XCTAssertTrue(immediateSettingsPanel.contains("DisclosureGroup(isExpanded: $isExpanded)"))
        XCTAssertTrue(immediateSettingsPanel.contains("CompanionImmediateSettingRow("))
        XCTAssertTrue(immediateSettingsPanel.contains("Text(\"바로 반영되는 설정\")"))
        XCTAssertTrue(immediateSettingsPanel.contains("Toggle(\"원격 실행에서 공지 메모도 갱신\""))
        XCTAssertTrue(dashboardSyncCard.contains("return \"파일\""))
        XCTAssertTrue(dashboardSyncCard.contains("return \"과제/시험\""))
        XCTAssertTrue(dashboardSyncCard.contains("return \"공지\""))
        XCTAssertTrue(dashboardSyncCard.contains(".buttonStyle(KLMSCardButtonStyle(cornerRadius: 12))"))
        XCTAssertTrue(remoteCommandPanel.contains("primaryCommandTitle(isRunning: isRunning, isDisabled: isDisabled)"))
        XCTAssertTrue(remoteCommandPanel.contains("primaryCommandSystemImage(isRunning: isRunning, isDisabled: isDisabled)"))
        XCTAssertTrue(remoteCommandPanel.contains("Color.klmsPrimaryCommandButtonForeground"))
        XCTAssertTrue(remoteCommandPanel.contains("return \"Mac 연결 필요\""))
        XCTAssertTrue(remoteCommandPanel.contains("if isDisabled { return Color.klmsCommandButtonBackground.opacity(0.92) }"))
        XCTAssertTrue(remoteCommandPanel.contains(".buttonStyle(KLMSCardButtonStyle(cornerRadius: 12))\n        .disabled(isDisabled)"))
        XCTAssertTrue(remoteCommandPanel.contains("private func isCommandActive(_ kind: RemoteCommandKind) -> Bool"))
        XCTAssertTrue(remoteCommandPanel.contains("private func runOrCancel(_ kind: RemoteCommandKind)"))
        XCTAssertTrue(remoteCommandPanel.contains("model.latestDisplayStatus?.isInFlight == true && model.latestCommand?.kind == kind"))
        XCTAssertFalse(remoteCommandPanel.contains("Mac 앱에 실행 요청을 보냅니다."))
        XCTAssertTrue(remoteCommandPanel.contains(".font(.system(size: 11, weight: .bold, design: .rounded))"))
        XCTAssertTrue(remoteCommandPanel.contains(".font(.system(size: 18, weight: .heavy, design: .rounded))"))
        XCTAssertTrue(remoteCommandPanel.contains(".padding(.horizontal, 5)"))
        XCTAssertTrue(remoteCommandPanel.contains("return \"파일\""))
        XCTAssertTrue(remoteCommandPanel.contains("return \"과제/시험\""))
        XCTAssertTrue(remoteCommandPanel.contains("return \"공지\""))
        XCTAssertTrue(ios.contains("private func companionItemKindTint(_ kind: String) -> Color"))
        XCTAssertTrue(dashboardMetricCategory.contains("Color.klmsWarningBorder"))
        XCTAssertTrue(dashboardMetricCategory.contains("Color.klmsSuccessBorder"))
        XCTAssertTrue(dashboardMetricCategory.contains("Color.klmsCommandAccent"))
        XCTAssertTrue(dashboardMetricCategory.contains("Color.klmsSecondaryText"))
        XCTAssertTrue(remoteChangeSummaryKind.contains("Color.klmsCommandAccent"))
        XCTAssertTrue(remoteChangeSummaryKind.contains("Color.klmsSecondaryText"))
        XCTAssertTrue(remoteChangeSummaryKind.contains("Color.klmsDangerBorder"))
        XCTAssertTrue(remoteChangeSummaryKind.contains("var chipBackground: Color"))
        XCTAssertTrue(remoteChangeSummaryKind.contains("Color.klmsDangerBackground"))
        XCTAssertTrue(remoteChangeSummaryKind.contains("var chipBorder: Color"))
        XCTAssertTrue(relayConnectionPanel.contains("Color.klmsSuccessBorder"))
        XCTAssertTrue(calendarChangeDetailRow.contains("Color.klmsSuccessBorder"))
        XCTAssertTrue(calendarChangeDetailRow.contains("Color.klmsCommandAccent"))
        XCTAssertTrue(calendarChangeDetailRow.contains("Color.klmsDangerBorder"))
        XCTAssertTrue(remoteChangeSummary.contains("entries.filter { $0.kind != selectedKind }"))
        XCTAssertTrue(remoteChangeSummary.contains("if !visibleEntries.isEmpty"))
        XCTAssertTrue(remoteChangeSummary.contains("FlowChipLayout(entries: visibleEntries"))
        XCTAssertTrue(flowChipLayout.contains("Image(systemName: entry.kind.systemImage)"))
        XCTAssertTrue(flowChipLayout.contains(".foregroundStyle(entry.kind.tint)"))
        XCTAssertTrue(flowChipLayout.contains(".foregroundStyle(Color.klmsPrimaryText)"))
        XCTAssertTrue(flowChipLayout.contains("let isSelected = selectedKind == entry.kind"))
        XCTAssertTrue(flowChipLayout.contains("isSelected\n                            ? Color.klmsSelectedBackground.opacity(0.96)"))
        XCTAssertTrue(flowChipLayout.contains(": entry.kind.chipBackground"))
        XCTAssertTrue(flowChipLayout.contains(": entry.kind.chipBorder"))
        XCTAssertTrue(flowChipLayout.contains("GridItem(.adaptive(minimum: 128), spacing: 7)"))
        XCTAssertFalse(flowChipLayout.contains("entry.kind.tint.opacity(0.10)"))
        XCTAssertFalse(flowChipLayout.contains("entry.kind.tint.opacity(0.26)"))
        XCTAssertTrue(flowChipLayout.contains("Color.klmsSelectedBorder.opacity(0.92)"))
        XCTAssertTrue(flowChipLayout.contains(".buttonStyle(KLMSCardButtonStyle())"))
        XCTAssertTrue(remoteChangeSummaryDetail.contains("@State private var visibleItemLimit = CompanionLargeList.initialVisibleLimit"))
        XCTAssertTrue(remoteChangeSummaryDetail.contains("@State private var calendarVisibleLimit = CompanionLargeList.calendarVisibleLimit"))
        XCTAssertTrue(remoteChangeSummaryDetail.contains("@State private var cleanupVisibleLimit = CompanionLargeList.previewVisibleLimit"))
        XCTAssertTrue(remoteChangeSummaryDetail.contains("let visibleChangedItems = changedItems.prefix(visibleItemLimit)"))
        XCTAssertTrue(remoteChangeSummaryDetail.contains("ForEach(visibleChangedItems)"))
        XCTAssertTrue(remoteChangeSummaryDetail.contains("let visibleCalendarItems = changedCalendarItems.prefix(calendarVisibleLimit)"))
        XCTAssertTrue(remoteChangeSummaryDetail.contains("ForEach(visibleCalendarItems)"))
        XCTAssertTrue(remoteChangeSummaryDetail.contains("let visibleReports = fileCleanupReports.prefix(cleanupVisibleLimit)"))
        XCTAssertTrue(remoteChangeSummaryDetail.contains("CompanionShowMoreRowsButton"))
        XCTAssertFalse(remoteChangeSummaryDetail.contains("ForEach(changedItems)"))
        XCTAssertFalse(remoteChangeSummaryDetail.contains("ForEach(changedCalendarItems)"))
        XCTAssertTrue(remoteChangeSummaryDetail.contains(".background(Color.klmsSubtleCardBackground)"))
        XCTAssertTrue(remoteChangeSummaryDetail.contains("Color.klmsBorder.opacity(0.95)"))
        XCTAssertTrue(inlineItemDetail.contains("companionItemKindTint(item.kind)"))
        XCTAssertTrue(sheetItemDetail.contains("companionItemKindTint(item.kind)"))
        XCTAssertTrue(serverSyncDataRow.contains("companionItemKindTint(item.kind)"))
        XCTAssertTrue(serverSyncDataRow.contains("var isSelected = false"))
        XCTAssertTrue(serverSyncDataRow.contains("var accessorySystemImage: String?"))
        XCTAssertTrue(serverSyncDataRow.contains("isSelected ? Color.klmsSelectedBackground.opacity(0.96)"))
        XCTAssertTrue(serverSyncDataRow.contains("isSelected ? Color.klmsSelectedBorder.opacity(0.92) : Color.klmsBorder"))
        XCTAssertFalse(serverSyncDataRow.contains(".shadow(color: isSelected ? Color.klmsSelectedBorder.opacity(0.10) : Color.clear"))
        XCTAssertTrue(sharedRunLogRow.contains("Color.klmsWarningBorder"))
        XCTAssertTrue(sharedRunLogRow.contains("Color.klmsSuccessBorder"))
        XCTAssertTrue(remoteCommandRow.contains("Color.klmsCommandAccent"))
        XCTAssertTrue(remoteCommandRow.contains("Color.klmsWarningBorder"))
        XCTAssertFalse(dashboardMetricCategory.contains(".orange"))
        XCTAssertFalse(dashboardMetricCategory.contains(".green"))
        XCTAssertFalse(dashboardMetricCategory.contains(".brown"))
        XCTAssertFalse(dashboardMetricCategory.contains(".blue"))
        XCTAssertFalse(dashboardMetricCategory.contains(".teal"))
        XCTAssertFalse(remoteChangeSummaryKind.contains(".brown"))
        XCTAssertFalse(remoteChangeSummaryKind.contains(".blue"))
        XCTAssertFalse(remoteChangeSummaryKind.contains(".green"))
        XCTAssertFalse(calendarChangeDetailRow.contains(".green"))
        XCTAssertFalse(calendarChangeDetailRow.contains(".blue"))
        XCTAssertFalse(calendarChangeDetailRow.contains(".red"))
        XCTAssertFalse(inlineItemDetail.contains(".orange"))
        XCTAssertFalse(sheetItemDetail.contains(".orange"))
        XCTAssertFalse(serverSyncDataRow.contains(".orange"))
        XCTAssertFalse(sharedRunLogRow.contains(".orange"))
        XCTAssertFalse(remoteCommandRow.contains(".blue"))
        XCTAssertFalse(remoteCommandRow.contains(".green"))
        XCTAssertFalse(remoteCommandRow.contains(".secondary"))
    }

    func testFileCleanupCardsRequireActualCleanupDetails() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let macRoot = packageRoot.appendingPathComponent("Sources/KLMSMac/MenuBarRootView.swift")
        let macModelRoot = packageRoot.appendingPathComponent("Sources/KLMSMac/KLMSMacModel.swift")
        let macDetail = packageRoot.appendingPathComponent("Sources/KLMSMac/DashboardDetailView.swift")
        let iosRoot = packageRoot.appendingPathComponent("Sources/KLMSiOS/KLMSiOSApp.swift")
        let mac = try String(contentsOf: macRoot, encoding: .utf8)
        let macModel = try String(contentsOf: macModelRoot, encoding: .utf8)
        let detail = try String(contentsOf: macDetail, encoding: .utf8)
        let ios = try String(contentsOf: iosRoot, encoding: .utf8)

        XCTAssertTrue(macModel.contains("prunedFileCount: snapshot.cleanupResult?.actions.filter { $0.action == \"deleted\" }.count ?? 0"))
        XCTAssertFalse(mac.contains("let prunedCount = report?.files.pruned ?? 0"))
        XCTAssertTrue(mac.contains("Metric(\"정리된 파일\", summary.prunedFileCount, detail: .pruned)"))
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
        let settingsForm = try sourceBody(
            after: "private func settingsForm",
            in: macSettings,
            description: "Mac settings form"
        )

        XCTAssertFalse(macSettings.contains("TabView(selection:"))
        XCTAssertFalse(macSettings.contains(".tabItem"))
        XCTAssertFalse(macSettings.contains("settingsSidebar"))
        XCTAssertTrue(macSettings.contains("settingsTabBar"))
        XCTAssertTrue(macSettings.contains("settingsContentPanel"))
        XCTAssertTrue(macSettings.contains("selectedSettingsContent"))
        XCTAssertTrue(macSettings.contains("settingsTabButton"))
        XCTAssertTrue(macSettings.contains("KLMSMacSettingsTabButtonStyle"))
        XCTAssertTrue(macSettings.contains("static var allCases: [SettingsTab] {\n        [.app, .login, .sync, .files, .notice]"))
        XCTAssertTrue(macSettings.contains("\"화면/앱\""))
        XCTAssertTrue(macSettings.contains("Text(\"자주 쓰는 값은 위에, 기술적인 값은 접어서 정리했습니다.\")"))
        XCTAssertTrue(macSettings.contains("Text(selectedTab.scopeLabel)"))
        XCTAssertFalse(macSettings.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(settingsForm.contains("VStack(alignment: .leading, spacing: 12)"))
        XCTAssertFalse(settingsForm.contains("ScrollView(.horizontal"))
        XCTAssertFalse(settingsForm.contains("HStack(alignment: .top"))
        XCTAssertTrue(macSettings.contains(".frame(width: 28, height: 28)"))
        XCTAssertTrue(macSettings.contains("Color.klmsMacSelectedBorder.opacity(0.18)"))
        XCTAssertTrue(macSettings.contains("Color.klmsMacSubtleCardBackground.opacity(0.72)"))
        XCTAssertFalse(macSettings.contains("Image(systemName: \"chevron.right\")"))
        XCTAssertTrue(macSettings.contains("isSelected ? Color.klmsMacSelectedBackground.opacity(0.96) : Color.klmsMacSubtleCardBackground.opacity(0.34)"))
        XCTAssertTrue(macSettings.contains(".overlay(alignment: .bottom)"))
        XCTAssertTrue(macSettings.contains(".frame(height: 3)"))
        XCTAssertTrue(macSettings.contains("isSelected ? Color.klmsMacSelectedBorder.opacity(0.92) : Color.klmsMacCommandBorder.opacity(0.42)"))
        XCTAssertTrue(macSettings.contains("private struct SettingsGroupBox"))
        XCTAssertTrue(macSettings.contains("DisclosureGroup(isExpanded: $isExpanded)"))
        XCTAssertTrue(macSettings.contains("SettingsExpansionBadge(isExpanded: isExpanded)"))
        XCTAssertTrue(macSettings.contains("private struct SettingsExpansionBadge"))
        XCTAssertTrue(macSettings.contains("Image(systemName: isExpanded ? \"chevron.up\" : \"chevron.down\")"))
        XCTAssertTrue(macSettings.contains("Text(isExpanded ? \"접기\" : \"펼치기\")"))
        XCTAssertTrue(macSettings.contains("isExpanded ? Color.klmsMacSelectedBackground.opacity(0.78) : Color.klmsMacSubtleCardBackground"))
        XCTAssertTrue(macSettings.contains("isExpanded ? Color.klmsMacSelectedBorder.opacity(0.58) : Color.klmsMacBorder.opacity(0.68)"))
        XCTAssertTrue(macSettings.contains("defaultExpanded: true"))
        XCTAssertTrue(macSettings.contains("title: \"실행 방식\""))
        XCTAssertTrue(macSettings.contains("title: \"Safari 자동화\""))
        XCTAssertTrue(macSettings.contains("title: \"파일 확인\""))
        XCTAssertTrue(macSettings.contains("title: \"저장 위치\""))
        XCTAssertTrue(macSettings.contains("title: \"문제 분석용 보관\""))
        XCTAssertTrue(macSettings.contains("title: \"바로 반영되는 설정\""))
        XCTAssertTrue(macSettings.contains("title: \"설치와 백업\""))
        XCTAssertTrue(macSettings.contains("SettingsDisclosureLabel("))
        XCTAssertTrue(macSettings.contains("SettingsDisclosureCard {"))
        XCTAssertTrue(macSettings.contains("private struct SettingsActionGroupBox"))
        XCTAssertTrue(macSettings.contains("LazyVGrid(columns: settingsActionColumns, spacing: 8)"))
        XCTAssertTrue(macSettings.contains("Label(\"붙여넣기\", systemImage: \"doc.on.clipboard\")"))
        XCTAssertTrue(macSettings.contains("Label(\"연결 정보 복사\", systemImage: \"doc.on.doc\")"))
        XCTAssertFalse(macSettings.contains("Button(\"붙여넣기\")"))
        XCTAssertFalse(macSettings.contains("Button(\"URL 복사\")"))
        XCTAssertTrue(macSettings.contains("private struct SettingsFieldRow"))
        XCTAssertTrue(macSettings.contains("SettingsFieldRow(description: description)"))
        XCTAssertTrue(macSettings.contains("private func settingsTextInput("))
        XCTAssertTrue(macSettings.contains("Text(title)\n                .font(.caption.weight(.semibold))"))
        XCTAssertTrue(macSettings.contains("settingsTextInput(title, text: binding(key))"))
        XCTAssertTrue(macSettings.contains("title: \"연결 정보\""))
        XCTAssertTrue(macSettings.contains("title: \"릴레이 동작\""))
        XCTAssertTrue(macSettings.contains("title: \"연결 확인\""))
        XCTAssertFalse(macSettings.contains("Section(\""))
        XCTAssertFalse(macSettings.contains("백그라운드 실행 허용"))
        XCTAssertFalse(macSettings.contains("동기화 주기(초)"))
        XCTAssertFalse(macSettings.contains("빠르게"))

        XCTAssertTrue(macModel.contains("앱이 앞에 없어도 로그인 보조"))
        XCTAssertTrue(macModel.contains("공지 내용이 같으면 메모 다시 쓰지 않기"))

        XCTAssertTrue(ios.contains("private struct RemoteSettingGroup"))
        XCTAssertTrue(ios.contains("RemoteSettingGroupSection"))
        XCTAssertTrue(ios.contains("private struct CompanionConnectionInput"))
        XCTAssertTrue(ios.contains("title: \"서버 URL\""))
        XCTAssertTrue(ios.contains("title: \"클라이언트 토큰\""))
        XCTAssertTrue(ios.contains("private struct CompanionImmediateSettingRow"))
        XCTAssertTrue(ios.contains("CompanionImmediateSettingRow("))
        XCTAssertTrue(ios.contains("@State private var isExpanded = true"))
        XCTAssertTrue(ios.contains("@State private var isExpanded = false"))
        XCTAssertTrue(ios.contains("var isDefaultExpanded: Bool"))
        XCTAssertTrue(ios.contains("group.countText"))
        XCTAssertTrue(ios.contains("DisclosureGroup(isExpanded: $isExpanded)"))
        XCTAssertTrue(ios.contains("settingValueSummary"))
        XCTAssertTrue(ios.contains("Text(settingValueSummary)"))
        XCTAssertTrue(ios.contains("private struct CompanionExpansionBadge"))
        XCTAssertTrue(ios.contains("CompanionExpansionBadge(isExpanded: isExpanded)"))
        XCTAssertTrue(ios.contains("CompanionExpansionBadge(isExpanded: isPanelExpanded)"))
        XCTAssertTrue(ios.contains("CompanionExpansionBadge(isExpanded: isAdvancedExpanded, compact: true)"))
        XCTAssertTrue(ios.contains("CompanionExpansionBadge(isExpanded: isExpanded, compact: true)"))
        XCTAssertTrue(ios.contains("Image(systemName: isExpanded ? \"chevron.up\" : \"chevron.down\")"))
        XCTAssertTrue(ios.contains("Text(isExpanded ? \"접기\" : \"펼치기\")"))
        XCTAssertTrue(ios.contains("isExpanded ? Color.klmsSelectedBackground.opacity(0.92) : Color.klmsSubtleCardBackground"))
        XCTAssertTrue(ios.contains("isExpanded ? Color.klmsSelectedBorder.opacity(0.64) : Color.klmsBorder.opacity(0.72)"))
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
        let macModelRoot = packageRoot.appendingPathComponent("Sources/KLMSMac/KLMSMacModel.swift")
        let iosRoot = packageRoot.appendingPathComponent("Sources/KLMSiOS/KLMSiOSApp.swift")
        let mac = try String(contentsOf: macRoot, encoding: .utf8)
        let macModel = try String(contentsOf: macModelRoot, encoding: .utf8)
        let ios = try String(contentsOf: iosRoot, encoding: .utf8)
        let macRootBody = try sourceBody(after: "struct MenuBarRootView: View", in: mac, description: "Mac root view")
        let macNavigationView = try sourceStructBody(named: "WorkspaceNavigationView", in: mac)
        let macMetricTile = try sourceStructBody(named: "MetricTile", in: mac)
        let dashboardTopBarView = try sourceStructBody(named: "DashboardTopBarView", in: mac)
        let macAlertBannerView = try sourceStructBody(named: "MacAlertBannerView", in: mac)
        let macCommandOutputPanelView = try sourceStructBody(named: "CommandOutputPanelView", in: mac)
        let iosHistoryScreen = try sourceStructBody(named: "CompanionHistoryScreen", in: ios)
        let iosSplitRoot = try sourceStructBody(named: "CompanionSplitRootView", in: ios)
        let iosSidebar = try sourceStructBody(named: "WorkstationSidebar", in: ios)
        let iosSidebarButton = try sourceStructBody(named: "CompanionSidebarButton", in: ios)
        let iosHeader = try sourceStructBody(named: "CompanionScreenHeader", in: ios)
        let iosStatusScreen = try sourceStructBody(named: "CompanionStatusScreen", in: ios)
        let iosStatusHeader = try sourceStructBody(named: "RemoteStatusHeader", in: ios)
        let iosDashboardStatusStrip = try sourceStructBody(named: "RemoteDashboardStatusStrip", in: ios)
        let iosMetricOverview = try sourceStructBody(named: "RemoteDashboardMetricOverview", in: ios)
        let iosMetricTile = try sourceStructBody(named: "RemoteMetricTile", in: ios)
        let iosWorkstationMetricCard = try sourceStructBody(named: "WorkstationMetricCard", in: ios)
        let iosRemoteLogSummaryPanel = try sourceStructBody(named: "RemoteLogSummaryPanel", in: ios)
        let iosRemoteLogDetailPanel = try sourceStructBody(named: "RemoteLogDetailPanel", in: ios)
        let iosRemoteLogSummaryRow = try sourceStructBody(named: "RemoteLogSummaryRow", in: ios)
        let iosSharedRunLogRow = try sourceStructBody(named: "SharedRunLogRow", in: ios)
        let topUtilityActions = try sourceStructBody(named: "TopUtilityActionsView", in: mac)
        let iosCardButtonStyle = try sourceBody(
            after: "private struct KLMSCardButtonStyle: ButtonStyle",
            in: ios,
            description: "iOS card button style"
        )

        XCTAssertTrue(mac.contains("case activityLogs"))
        XCTAssertTrue(mac.contains("case diagnostics"))
        XCTAssertTrue(mac.contains("\"로그\""))
        XCTAssertTrue(macModel.contains("var hasClearableVisibleLogs: Bool"))
        XCTAssertTrue(mac.contains(".disabled(model.runningCommand != nil || !model.hasClearableVisibleLogs)"))
        XCTAssertTrue(mac.contains("LinearGradient("))
        XCTAssertTrue(mac.contains("Image(systemName: \"trash\")"))
        XCTAssertTrue(mac.contains(".accessibilityLabel(\"파일 요청 기록 지우기\")"))
        XCTAssertFalse(mac.contains("Label(\"기록 지우기\", systemImage: \"trash\")"))
        XCTAssertTrue(mac.contains("CompactStageDurationRowsView(durations: record.visibleStageDurations)"))
        XCTAssertTrue(mac.contains("record.visibleStageDurations"))
        XCTAssertTrue(mac.contains(".fixedSize(horizontal: true, vertical: false)"))
        XCTAssertTrue(mac.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        XCTAssertFalse(mac.contains("case runLogs"))
        XCTAssertTrue(macRootBody.contains("DashboardTopBarView(model: model, selectedSection: $selectedSection)"))
        XCTAssertTrue(macRootBody.contains("MacAlertBannerView("))
        XCTAssertTrue(macRootBody.contains(".frame(maxWidth: .infinity, alignment: .topLeading)"))
        XCTAssertTrue(macRootBody.contains("MacWorkstationLayoutView("))
        XCTAssertTrue(macModel.contains("@Published private(set) var cachedIssues: [EngineIssue] = []"))
        XCTAssertTrue(macModel.contains("var needsAttention: Bool"))
        XCTAssertTrue(macModel.contains("var attentionSummary: String"))
        XCTAssertTrue(macModel.contains("let nextIssues = nextSnapshot.issues"))
        XCTAssertTrue(macModel.contains("private(set) var dashboardRenderSignature = DashboardRenderSignature"))
        XCTAssertTrue(macModel.contains("dashboardRenderSignature = DashboardRenderSignature(snapshot: snapshot, summary: dashboardSummaryCache)"))
        XCTAssertTrue(mac.contains("IssueSummaryView(issues: model.cachedIssues)"))
        XCTAssertFalse(mac.contains("IssueSummaryView(issues: snapshot.issues)"))
        XCTAssertTrue(mac.contains("renderSignature: model.dashboardRenderSignature"))
        XCTAssertFalse(mac.contains("renderSignature: DashboardRenderSignature(snapshot: model.snapshot, summary: model.dashboardSummaryCache)"))
        let alertRange = try XCTUnwrap(macRootBody.range(of: "MacAlertBannerView("))
        let workstationRange = try XCTUnwrap(macRootBody.range(of: "MacWorkstationLayoutView("))
        XCTAssertLessThan(alertRange.lowerBound, workstationRange.lowerBound)
        XCTAssertFalse(mac.contains("struct MacDesignWindowRootView"))
        XCTAssertTrue(macNavigationView.contains("section.systemImage"))
        XCTAssertTrue(macNavigationView.contains(".frame(width: 30, height: 30)"))
        XCTAssertTrue(macNavigationView.contains("Color.klmsMacSelectedBorder.opacity(0.18)"))
        XCTAssertTrue(macNavigationView.contains("Color.klmsMacSubtleCardBackground.opacity(0.72)"))
        XCTAssertTrue(macNavigationView.contains("Image(systemName: \"chevron.right\")"))
        XCTAssertTrue(macNavigationView.contains("isSelected ? Color.klmsMacSelectedBackground.opacity(0.96) : Color.klmsMacSubtleCardBackground.opacity(0.34)"))
        XCTAssertTrue(macNavigationView.contains(".overlay(alignment: .leading)"))
        XCTAssertTrue(macNavigationView.contains(".frame(width: 3)"))
        XCTAssertTrue(macNavigationView.contains("isSelected ? Color.klmsMacSelectedBorder.opacity(0.92) : Color.klmsMacCommandBorder.opacity(0.42)"))
        XCTAssertTrue(mac.contains("light: NSColor(red: 0.894, green: 0.878, blue: 0.827, alpha: 1.0)"))
        XCTAssertTrue(mac.contains("dark: NSColor(red: 0.224, green: 0.212, blue: 0.184, alpha: 1.0)"))
        XCTAssertTrue(mac.contains("light: NSColor(red: 0.165, green: 0.165, blue: 0.153, alpha: 0.56)"))
        XCTAssertTrue(mac.contains("dark: NSColor(red: 0.941, green: 0.875, blue: 0.722, alpha: 0.48)"))
        XCTAssertTrue(macNavigationView.contains(".frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)"))
        XCTAssertTrue(macNavigationView.contains("guard selection != section else { return }"))
        XCTAssertTrue(macMetricTile.contains("Image(systemName: isSelected ? \"checkmark.circle.fill\" : \"chevron.right\")"))
        XCTAssertTrue(macMetricTile.contains("isSelected ? Color.klmsMacSelectedBackground : Color.klmsMacCardBackground"))
        XCTAssertTrue(macMetricTile.contains("isSelected ? Color.klmsMacSelectedForeground : Color.klmsMacPrimaryText"))
        XCTAssertTrue(macMetricTile.contains("isSelected ? tint.opacity(0.92) : Color.klmsMacBorder"))
        XCTAssertFalse(macMetricTile.contains(".shadow(color: isSelected ? tint.opacity(0.12) : Color.clear"))
        XCTAssertTrue(macMetricTile.contains(".font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())"))
        XCTAssertTrue(dashboardTopBarView.contains("Text(selectedSection.title)"))
        XCTAssertFalse(dashboardTopBarView.contains("Text(\"대시보드\")"))
        XCTAssertTrue(dashboardTopBarView.contains(".font(.system(size: 26, weight: .bold, design: .rounded))"))
        XCTAssertTrue(dashboardTopBarView.contains("Label(runningPhaseLabel, systemImage: \"arrow.triangle.2.circlepath\")"))
        XCTAssertTrue(dashboardTopBarView.contains("return model.currentPhaseText ?? \"진행 중\""))
        XCTAssertTrue(macAlertBannerView.contains("return model.currentPhaseText ?? \"LOG\""))
        XCTAssertTrue(macCommandOutputPanelView.contains("return \"\\(command.displayName) · \\(phase) 진행 중\""))
        let workstationBody = try sourceStructBody(named: "MacWorkstationLayoutView", in: mac)
        XCTAssertFalse(workstationBody.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(workstationBody.contains("HStack(alignment: .top, spacing: 14)"))
        XCTAssertTrue(workstationBody.contains(".frame(width: 280, alignment: .topLeading)"))
        XCTAssertTrue(workstationBody.contains("CommandPanelView(model: model)"))
        XCTAssertLessThan(
            try XCTUnwrap(workstationBody.range(of: "CommandPanelView(model: model)")).lowerBound,
            try XCTUnwrap(workstationBody.range(of: "WorkspaceNavigationView(selection: $selectedSection)")).lowerBound
        )
        XCTAssertTrue(workstationBody.contains("WorkspaceNavigationView(selection: $selectedSection)"))
        XCTAssertTrue(workstationBody.contains("DashboardRuntimePanelView(model: model)"))
        XCTAssertTrue(workstationBody.contains("case .files:"))
        XCTAssertTrue(workstationBody.contains("case .tasks:"))
        XCTAssertTrue(workstationBody.contains("case .notices:"))
        XCTAssertTrue(workstationBody.contains("case .calendar:"))
        XCTAssertTrue(workstationBody.contains("TaskAndExamWorkspaceView(model: model)"))
        XCTAssertLessThan(
            try XCTUnwrap(workstationBody.range(of: "case .files:")).lowerBound,
            try XCTUnwrap(workstationBody.range(of: "case .tasks:")).lowerBound
        )
        XCTAssertLessThan(
            try XCTUnwrap(workstationBody.range(of: "case .tasks:")).lowerBound,
            try XCTUnwrap(workstationBody.range(of: "case .notices:")).lowerBound
        )
        XCTAssertTrue(workstationBody.contains("case .activityLogs:"))
        XCTAssertTrue(workstationBody.contains("LogSummaryPanelView"))
        XCTAssertTrue(workstationBody.contains("RemoteActivityPanelView"))
        XCTAssertTrue(workstationBody.contains("RunLogArchivePanelView"))
        XCTAssertFalse(topUtilityActions.contains("selectedSection = .settings"))
        XCTAssertFalse(topUtilityActions.contains("utilityLabel(\"설정\""))
        XCTAssertTrue(topUtilityActions.contains("utilityLabel(\"열기\", systemImage: \"square.grid.2x2\")"))
        XCTAssertTrue(topUtilityActions.contains("Color.klmsMacSubtleCardBackground"))
        XCTAssertTrue(topUtilityActions.contains("Color.klmsMacCommandBorder"))
        XCTAssertTrue(workstationBody.contains("case .diagnostics:"))
        XCTAssertTrue(workstationBody.contains("VerifyPanelView"))

        let dashboardBody = try sectionBody(in: workstationBody, from: "case .dashboard:", to: "case .activityLogs:")
        XCTAssertTrue(dashboardBody.contains("DashboardSummaryView"))
        XCTAssertFalse(dashboardBody.contains("CommandOutputPanelView"))
        XCTAssertFalse(dashboardBody.contains("LogSummaryPanelView"))
        XCTAssertFalse(dashboardBody.contains("RemoteActivityPanelView"))
        XCTAssertFalse(mac.contains("DashboardLogSummaryPanelView(model: model)"))
        let issueSummaryView = try sourceStructBody(named: "IssueSummaryView", in: mac)
        let issueRowView = try sourceStructBody(named: "IssueRowView", in: mac)
        XCTAssertTrue(issueSummaryView.contains("@State private var isExpanded = false"))
        XCTAssertTrue(issueSummaryView.contains("if isExpanded"))
        XCTAssertTrue(issueSummaryView.contains("ForEach(issues.prefix(3))"))
        XCTAssertTrue(issueRowView.contains(".lineLimit(2)"))
        XCTAssertFalse(issueSummaryView.contains("ForEach(issues.prefix(5))"))

        let diagnosticsBody = try sectionBody(in: workstationBody, from: "case .diagnostics:", to: ".padding(.vertical, 4)")
        XCTAssertLessThan(
            try XCTUnwrap(diagnosticsBody.range(of: "VerifyPanelView")).lowerBound,
            try XCTUnwrap(diagnosticsBody.range(of: "DiagnosticToolsPanelView")).lowerBound
        )
        XCTAssertTrue(diagnosticsBody.contains("DiagnosticToolsPanelView"))
        XCTAssertTrue(diagnosticsBody.contains("DiagnosticStageDurationPanelView"))
        XCTAssertTrue(diagnosticsBody.contains("DiagnosticCommandLogPanelView"))
        XCTAssertFalse(diagnosticsBody.contains("RemoteActivityPanelView"))

        XCTAssertTrue(ios.contains("return \"로그\""))
        XCTAssertTrue(iosHistoryScreen.contains("CompanionScreenContainer(title: \"로그\""))
        XCTAssertTrue(iosStatusHeader.contains("Label(\"현재 단계: \\(runningStageText)\", systemImage: \"arrow.triangle.2.circlepath\")"))
        XCTAssertTrue(iosStatusHeader.contains("private var runningStageText: String?"))
        XCTAssertTrue(iosDashboardStatusStrip.contains("return model.runningPhaseDetail ?? \"진행 중\""))
        XCTAssertTrue(iosHistoryScreen.contains("RemoteLogSummaryPanel"))
        XCTAssertTrue(iosHistoryScreen.contains("SharedRunLogsView"))
        XCTAssertTrue(iosHistoryScreen.contains("RecentServerRequestLogView"))
        XCTAssertTrue(iosHistoryScreen.contains("RecentFileAccessRequestsView"))
        XCTAssertTrue(iosHistoryScreen.contains("RecentRemoteCommandsView"))
        XCTAssertTrue(iosRemoteLogSummaryPanel.contains("Color.klmsCardBackground, in: RoundedRectangle(cornerRadius: 14)"))
        XCTAssertTrue(iosRemoteLogSummaryPanel.contains(".stroke(Color.klmsBorder, lineWidth: 1)"))
        XCTAssertFalse(iosRemoteLogSummaryPanel.contains(".clipShape(RoundedRectangle(cornerRadius: 8))"))
        XCTAssertTrue(iosRemoteLogDetailPanel.contains("RoundedRectangle(cornerRadius: 12)"))
        XCTAssertTrue(iosRemoteLogSummaryRow.contains("isExpanded ? Color.klmsSelectedBackground.opacity(0.96) : Color.klmsSubtleCardBackground.opacity(0.62)"))
        XCTAssertTrue(iosRemoteLogSummaryRow.contains("KLMSCardButtonStyle(cornerRadius: 12)"))
        XCTAssertFalse(iosRemoteLogSummaryRow.contains("KLMSCardButtonStyle(cornerRadius: 8)"))
        XCTAssertTrue(iosSharedRunLogRow.contains("isExpanded ? Color.klmsSelectedBackground.opacity(0.96) : Color.klmsCardBackground"))
        XCTAssertTrue(iosSharedRunLogRow.contains("Color.klmsSelectedBorder.opacity(0.82)"))
        XCTAssertTrue(ios.contains("var hasClearableRemoteLogs: Bool"))
        XCTAssertTrue(ios.contains(".disabled(!model.serverRelayConfigured || model.isSubmitting || !model.hasClearableRemoteLogs)"))
        XCTAssertTrue(ios.contains("LinearGradient("))
        XCTAssertTrue(ios.contains("Image(systemName: \"trash\")"))
        XCTAssertTrue(ios.contains(".accessibilityLabel(\"파일 요청 기록 지우기\")"))
        XCTAssertFalse(ios.contains("Label(\"기록 지우기\", systemImage: \"trash\")"))
        XCTAssertTrue(ios.contains("static var workstationSections"))
        XCTAssertTrue(iosSplitRoot.contains("WorkstationSidebar(selectedSection: $selectedSection)"))
        XCTAssertTrue(iosSplitRoot.contains(".frame(width: 214)"))
        XCTAssertFalse(iosSplitRoot.contains(".frame(width: 154)"))
        XCTAssertTrue(iosSplitRoot.contains("HStack(spacing: 0)"))
        XCTAssertTrue(iosSidebar.contains("CompanionAppSection.workstationSections"))
        XCTAssertTrue(iosSidebar.contains("VStack(alignment: .leading, spacing: 8)"))
        XCTAssertTrue(iosSidebar.contains("Text(\"작업 공간\")"))
        XCTAssertTrue(iosSidebar.contains(".font(.title3.weight(.bold))"))
        XCTAssertTrue(iosSidebar.contains(".padding(.horizontal, 14)"))
        XCTAssertTrue(iosSidebar.contains(".padding(.top, 18)"))
        XCTAssertTrue(iosSidebar.contains("showsIcon: true"))
        XCTAssertTrue(iosSidebar.contains("showsArrow: true"))
        XCTAssertTrue(iosSidebar.contains("isCompact: false"))
        XCTAssertFalse(iosSidebar.contains("isCompact: true"))
        XCTAssertTrue(iosSidebarButton.contains("var isCompact = false"))
        XCTAssertTrue(iosSidebarButton.contains("HStack(spacing: isCompact ? 7 : 10)"))
        XCTAssertTrue(iosSidebarButton.contains(".frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)"))
        XCTAssertTrue(iosSidebarButton.contains("ZStack"))
        XCTAssertTrue(iosSidebarButton.contains("Color.klmsSelectedBorder.opacity(0.18)"))
        XCTAssertTrue(iosSidebarButton.contains("Color.klmsSubtleCardBackground.opacity(0.72)"))
        XCTAssertTrue(iosSidebarButton.contains(".frame(width: isCompact ? 28 : 30, height: isCompact ? 28 : 30)"))
        XCTAssertTrue(iosSidebarButton.contains("Image(systemName: \"chevron.right\")"))
        XCTAssertTrue(iosSidebarButton.contains(".font(.system(size: isCompact ? 12 : 13, weight: isSelected ? .bold : .semibold, design: .rounded))"))
        XCTAssertTrue(iosSidebarButton.contains(".padding(.leading, isCompact ? 7 : 8)"))
        XCTAssertTrue(iosSidebarButton.contains(".padding(.trailing, isCompact ? 8 : 9)"))
        XCTAssertTrue(iosSidebarButton.contains(".padding(.vertical, isCompact ? 8 : 9)"))
        XCTAssertFalse(iosSidebarButton.contains("minHeight: isCompact ? 40 : 36"))
        XCTAssertTrue(iosSidebarButton.contains("Color.klmsSelectedBackground.opacity(0.96)"))
        XCTAssertTrue(iosSidebarButton.contains(": Color.klmsSubtleCardBackground.opacity(0.42)"))
        XCTAssertTrue(iosSidebarButton.contains(".overlay(alignment: .leading)"))
        XCTAssertTrue(iosSidebarButton.contains(".frame(width: 3)"))
        XCTAssertTrue(iosSidebarButton.contains("isSelected ? Color.klmsSelectedBorder.opacity(0.92) : Color.klmsBorder.opacity(0.48)"))
        XCTAssertTrue(ios.contains("light: UIColor(red: 0.894, green: 0.878, blue: 0.827, alpha: 1.0)"))
        XCTAssertTrue(ios.contains("dark: UIColor(red: 0.224, green: 0.212, blue: 0.184, alpha: 1.0)"))
        XCTAssertTrue(ios.contains("light: UIColor(red: 0.165, green: 0.165, blue: 0.153, alpha: 0.56)"))
        XCTAssertTrue(ios.contains("dark: UIColor(red: 0.941, green: 0.875, blue: 0.722, alpha: 0.48)"))
        XCTAssertFalse(iosSidebarButton.contains(".shadow(color: isSelected ? Color.klmsSelectedBorder.opacity(0.10) : Color.clear"))
        XCTAssertTrue(iosSidebarButton.contains(".buttonStyle(KLMSCardButtonStyle())"))
        XCTAssertTrue(iosSidebarButton.contains(".contentShape(RoundedRectangle(cornerRadius: 10))"))
        XCTAssertTrue(iosCardButtonStyle.contains("var cornerRadius: CGFloat = 10"))
        XCTAssertTrue(iosCardButtonStyle.contains("RoundedRectangle(cornerRadius: cornerRadius)"))
        XCTAssertTrue(iosCardButtonStyle.contains("Color.klmsCommandButtonPressedOverlay.opacity(configuration.isPressed ? 1.0 : 0.0)"))
        XCTAssertFalse(iosCardButtonStyle.contains("Color.klmsPrimaryCommandButtonBorder.opacity(configuration.isPressed ? 0.52 : 0.0)"))
        XCTAssertFalse(iosSidebarButton.contains(".animation(.easeOut(duration: 0.10), value: isSelected)"))
        XCTAssertTrue(iosSplitRoot.contains("currentSection"))
        XCTAssertFalse(iosSplitRoot.contains("deferDisplayedSection(newSection ?? .status)"))
        XCTAssertTrue(ios.contains("private struct CompanionSelectableItemListRows"))
        XCTAssertTrue(ios.contains("private struct CompanionInlineItemRowsView"))
        XCTAssertTrue(ios.contains("await Task.yield()"))
        XCTAssertTrue(iosHeader.contains("@Environment(\\.horizontalSizeClass)"))
        XCTAssertTrue(iosHeader.contains("compactHeader"))
        XCTAssertTrue(iosHeader.contains("regularHeader"))
        XCTAssertTrue(iosHeader.contains("Text(\"KLMS Sync\")"))
        XCTAssertFalse(iosHeader.contains("Text(model.statusLine)"))
        XCTAssertTrue(iosStatusScreen.contains("statusDetailColumn"))
        XCTAssertTrue(iosStatusScreen.contains("DashboardCategoryInlineDetailPanel(category: category, model: model)"))
        XCTAssertTrue(iosStatusScreen.contains("HStack(alignment: .top, spacing: 16)"))
        XCTAssertTrue(iosStatusScreen.contains(".frame(minWidth: 320, idealWidth: 380, maxWidth: 430"))
        XCTAssertFalse(iosStatusScreen.contains("WorkstationDashboardDetailPanel"))
        XCTAssertTrue(iosStatusScreen.contains("WorkstationDashboardOverviewPanel(model: model)"))
        XCTAssertFalse(iosMetricOverview.contains("CompactDashboardSelectionPanel(category: selectedCategory, model: model)"))
        XCTAssertFalse(iosStatusScreen.contains("?? .files"))
        XCTAssertTrue(iosMetricOverview.contains("@Environment(\\.horizontalSizeClass)"))
        XCTAssertTrue(iosMetricOverview.contains("private let compactColumns"))
        XCTAssertTrue(iosMetricOverview.contains("private let workstationColumns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: 8), count: 2)"))
        XCTAssertTrue(iosMetricOverview.contains("LazyVGrid(columns: workstationColumns, alignment: .leading, spacing: 8)"))
        XCTAssertTrue(iosMetricOverview.contains("LazyVGrid(columns: compactColumns, alignment: .leading, spacing: 8)"))
        XCTAssertFalse(iosMetricOverview.contains("if horizontalSizeClass == .regular {\n                    VStack(spacing: 8)"))
        XCTAssertTrue(iosMetricOverview.contains("WorkstationMetricCard"))
        XCTAssertFalse(iosMetricOverview.contains("Text(title)"))
        XCTAssertFalse(iosMetricTile.contains("Image(systemName: systemImage)"))
        XCTAssertTrue(iosMetricTile.contains(".font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())"))
        XCTAssertTrue(iosMetricTile.contains("Color.klmsSelectedBackground.opacity(0.96)"))
        XCTAssertTrue(iosMetricTile.contains("Color.klmsSelectedForeground"))
        XCTAssertTrue(iosMetricTile.contains("Color.klmsSelectedBorder.opacity(0.92)"))
        XCTAssertFalse(iosMetricTile.contains(".shadow(color: isSelected ? Color.klmsSelectedBorder.opacity(0.10) : Color.clear"))
        XCTAssertTrue(iosMetricTile.contains(".buttonStyle(KLMSCardButtonStyle(cornerRadius: 14))"))
        XCTAssertTrue(iosWorkstationMetricCard.contains(".padding(11)"))
        XCTAssertTrue(iosWorkstationMetricCard.contains("Text(\"\\(category.title) \\(value)개\")"))
        XCTAssertTrue(iosWorkstationMetricCard.contains(".font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())"))
        XCTAssertTrue(iosWorkstationMetricCard.contains(".font(.system(size: 11, weight: .regular, design: .rounded))"))
        XCTAssertFalse(iosWorkstationMetricCard.contains(".font(.headline.weight(.semibold))"))
        XCTAssertTrue(iosWorkstationMetricCard.contains("RoundedRectangle(cornerRadius: 13)"))
        XCTAssertTrue(iosWorkstationMetricCard.contains("Color.klmsSelectedBackground.opacity(0.96)"))
        XCTAssertTrue(iosWorkstationMetricCard.contains("Color.klmsSelectedBorder.opacity(0.92)"))
        XCTAssertTrue(iosWorkstationMetricCard.contains(".buttonStyle(KLMSCardButtonStyle(cornerRadius: 13))"))
        XCTAssertTrue(ios.contains("private struct WorkstationDashboardOverviewPanel"))
        let iosWorkstationOverviewPanel = try sourceStructBody(named: "WorkstationDashboardOverviewPanel", in: ios)
        XCTAssertTrue(iosWorkstationOverviewPanel.contains("Text(\"대시보드\")"))
        XCTAssertTrue(iosWorkstationOverviewPanel.contains("카드를 누르면 이곳에 상세 목록이 열립니다."))
        XCTAssertTrue(iosWorkstationOverviewPanel.contains("MetricSummary(title: \"파일\", value: status.fileTotal)"))
        XCTAssertTrue(iosWorkstationOverviewPanel.contains("MetricSummary(title: \"공지\", value: status.notices)"))
        XCTAssertTrue(iosWorkstationOverviewPanel.contains("WorkstationChangeSummaryCard(model: model)"))
        XCTAssertFalse(ios.contains("private struct WorkstationDashboardDetailPanel"))
        XCTAssertFalse(ios.contains("private struct WorkstationSelectedItemCard"))
        XCTAssertTrue(ios.contains("private struct WorkstationChangeSummaryCard"))
        XCTAssertFalse(ios.contains("private struct CompactDashboardSelectionPanel"))
        XCTAssertFalse(ios.contains("private struct CompactDashboardEmptyRow"))
        XCTAssertTrue(ios.contains("var workstationDescription"))
        XCTAssertTrue(ios.contains("CompactRemoteStageDurationRowsView(durations: stageDurations)"))
        XCTAssertTrue(ios.contains("RemoteStageDurationSummaryView(durations: stageDurations)"))
        XCTAssertTrue(ios.contains(".fixedSize(horizontal: true, vertical: false)"))
        XCTAssertTrue(ios.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
    }

    func testIOSLargeDashboardListsRenderAllItemsLazily() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let iosRoot = packageRoot.appendingPathComponent("Sources/KLMSiOS/KLMSiOSApp.swift")
        let ios = try String(contentsOf: iosRoot, encoding: .utf8)
        let categoryDetail = try sourceStructBody(named: "DashboardCategoryDetailScreen", in: ios)
        let syncDataPanel = try sourceStructBody(named: "ServerSyncDataPanel", in: ios)
        let inlineDetail = try sourceStructBody(named: "DashboardCategoryInlineDetailPanel", in: ios)
        let selectableRows = try sourceStructBody(named: "CompanionSelectableItemListRows", in: ios)
        let inlineRows = try sourceStructBody(named: "CompanionInlineItemRowsView", in: ios)
        let metricDetailPanel = try sourceStructBody(named: "DashboardMetricDetailPanel", in: ios)
        let workstationCategory = try sourceStructBody(named: "WorkstationDashboardCategoryWorkspace", in: ios)
        let workstationTasks = try sourceStructBody(named: "WorkstationTasksWorkspace", in: ios)
        let compactSelectedRow = try sourceStructBody(named: "CompactDashboardSelectedRow", in: ios)
        let recentFileRequests = try sourceStructBody(named: "RecentFileAccessRequestsView", in: ios)
        let companionModel = try sourceBody(
            after: "final class CompanionModel: ObservableObject",
            in: ios,
            description: "CompanionModel"
        )

        XCTAssertTrue(ios.contains("private struct CompanionItemListData"))
        XCTAssertFalse(ios.contains("private let klmsInteractionDetailDelayNanoseconds"))
        XCTAssertTrue(ios.contains(".onChange(of: appearanceMode)"))
        XCTAssertTrue(ios.contains("Self.schedulePlatformAppearance(newValue)"))
        XCTAssertTrue(ios.contains("window.overrideUserInterfaceStyle = style"))
        XCTAssertTrue(ios.contains("style = .unspecified"))
        XCTAssertTrue(ios.contains("style = .light"))
        XCTAssertTrue(ios.contains("style = .dark"))
        XCTAssertTrue(ios.contains("@Published private(set) var dashboardSyncItems: [ServerRelaySyncItem] = []"))
        XCTAssertTrue(ios.contains("@Published private(set) var dashboardSyncItemsRevision = 0"))
        XCTAssertTrue(ios.contains("@Published private(set) var visibleCalendarChangesCache: [CalendarChange] = []"))
        XCTAssertTrue(ios.contains("private func rebuildDashboardDerivedState()"))
        XCTAssertTrue(companionModel.contains("latestFileAccessRequestByItemID"))
        XCTAssertTrue(companionModel.contains("activeItemActionByItemID"))
        XCTAssertTrue(companionModel.contains("activeCalendarActionByID"))
        XCTAssertTrue(companionModel.contains("visibleDashboardItemsByCategoryID"))
        XCTAssertTrue(companionModel.contains("private func rebuildFileAccessLookup()"))
        XCTAssertTrue(companionModel.contains("private func rebuildItemActionLookups()"))
        XCTAssertTrue(companionModel.contains("private func rebuildVisibleCalendarChanges()"))
        XCTAssertTrue(companionModel.contains("func cachedVisibleDashboardItems(for categoryID: String)"))
        XCTAssertTrue(companionModel.contains("func visibleCalendarChanges() -> [CalendarChange] {\n        visibleCalendarChangesCache"))
        XCTAssertFalse(companionModel.contains(".filter { $0.itemID == item.id }"))
        XCTAssertFalse(ios.contains("private struct WorkstationDashboardDetailPanel"))
        XCTAssertTrue(categoryDetail.contains("CompanionSelectableItemListRows("))
        XCTAssertFalse(categoryDetail.contains("@State private var visibleLimit"))
        XCTAssertFalse(categoryDetail.contains("@State private var selectedItemID"))
        XCTAssertFalse(categoryDetail.contains("ForEach(filtered)"))
        XCTAssertTrue(selectableRows.contains("@State private var visibleLimit = CompanionLargeList.initialVisibleLimit"))
        XCTAssertTrue(ios.contains("static let initialVisibleLimit = 10"))
        XCTAssertTrue(ios.contains("static let previewVisibleLimit = 8"))
        XCTAssertTrue(ios.contains("static let calendarVisibleLimit = 10"))
        XCTAssertTrue(selectableRows.contains("@State private var selectedItemID"))
        XCTAssertFalse(selectableRows.contains("@State private var deferredSelectionTask"))
        XCTAssertTrue(selectableRows.contains("LazyVStack(alignment: .leading, spacing: 8)"))
        XCTAssertTrue(selectableRows.contains("let visibleItems = items.prefix(visibleLimit)"))
        XCTAssertTrue(selectableRows.contains("ForEach(visibleItems)"))
        XCTAssertTrue(selectableRows.contains("CompanionShowMoreRowsButton("))
        XCTAssertTrue(ios.contains("private struct CompanionShowMoreRowsButton"))
        XCTAssertTrue(ios.contains("Text(\"더 보기\")"))
        XCTAssertTrue(selectableRows.contains("ServerSyncDataRow(item: item, isSelected: selectedItemID == item.id)"))
        XCTAssertTrue(selectableRows.contains(".buttonStyle(KLMSCardButtonStyle())"))
        XCTAssertTrue(selectableRows.contains("onSelect(item)"))
        XCTAssertFalse(selectableRows.contains("guard klmsInteractionDetailDelayNanoseconds > 0 else"))
        XCTAssertFalse(selectableRows.contains("try? await Task.sleep(nanoseconds: klmsInteractionDetailDelayNanoseconds)"))
        XCTAssertFalse(categoryDetail.contains("ForEach(filtered)"))
        XCTAssertFalse(categoryDetail.contains("private var baseItems"))
        XCTAssertFalse(categoryDetail.contains("private var filteredItems"))
        XCTAssertFalse(categoryDetail.contains("initialVisibleLimit(for: category)"))
        XCTAssertFalse(categoryDetail.contains("incrementVisibleLimit(for: category)"))
        XCTAssertTrue(syncDataPanel.contains("@State private var cachedListData"))
        XCTAssertTrue(syncDataPanel.contains(".task(id: listInputKey)"))
        XCTAssertTrue(syncDataPanel.contains("Task.detached(priority: .userInitiated)"))
        XCTAssertTrue(syncDataPanel.contains("CompanionSelectableItemListRows("))
        XCTAssertFalse(syncDataPanel.contains("@State private var selectedItemID"))
        XCTAssertFalse(syncDataPanel.contains("private var filteredItems"))
        XCTAssertTrue(inlineDetail.contains("let listData = await Task.detached(priority: .userInitiated)"))
        XCTAssertTrue(inlineDetail.contains("@State private var cachedListData"))
        XCTAssertTrue(inlineDetail.contains(".task(id: listInputKey)"))
        XCTAssertTrue(inlineDetail.contains("await rebuildCachedListData()"))
        XCTAssertTrue(inlineDetail.contains("CompanionInlineItemRowsView("))
        XCTAssertTrue(inlineDetail.contains("presentation: itemPresentation"))
        XCTAssertTrue(inlineDetail.contains("externalSelectedItemID: externallySelectedItemID"))
        XCTAssertTrue(inlineDetail.contains("onSelectItem: onSelectItem"))
        XCTAssertTrue(inlineRows.contains("presentation == .externalDetail"))
        XCTAssertTrue(inlineRows.contains("onSelectItem(item)"))
        XCTAssertTrue(inlineRows.contains("accessorySystemImage(isSelected: isSelected)"))
        XCTAssertTrue(inlineRows.contains(".buttonStyle(KLMSCardButtonStyle())"))
        XCTAssertFalse(inlineRows.contains("@State private var detailItemID"))
        XCTAssertTrue(inlineRows.contains("@State private var visibleLimit = CompanionLargeList.initialVisibleLimit"))
        XCTAssertTrue(inlineRows.contains("LazyVStack(alignment: .leading, spacing: 8)"))
        XCTAssertTrue(inlineRows.contains("ForEach(visibleItems)"))
        XCTAssertTrue(inlineRows.contains("CompanionShowMoreRowsButton("))
        XCTAssertFalse(inlineRows.contains("Self.initialVisibleLimit(for: category)"))
        XCTAssertTrue(metricDetailPanel.contains("LazyVStack(alignment: .leading, spacing: 8)"))
        XCTAssertTrue(metricDetailPanel.contains("@State private var visibleLimit = CompanionLargeList.previewVisibleLimit"))
        XCTAssertTrue(metricDetailPanel.contains("let visibleItems = filtered.prefix(visibleLimit)"))
        XCTAssertTrue(metricDetailPanel.contains("ForEach(visibleItems)"))
        XCTAssertTrue(metricDetailPanel.contains("CompanionShowMoreRowsButton"))
        XCTAssertTrue(metricDetailPanel.contains(".buttonStyle(KLMSCardButtonStyle())"))
        XCTAssertFalse(metricDetailPanel.contains("ForEach(filtered)"))
        XCTAssertFalse(metricDetailPanel.contains("외 \\(filtered.count"))
        XCTAssertTrue(inlineDetail.contains("@State private var calendarVisibleLimit = CompanionLargeList.calendarVisibleLimit"))
        XCTAssertTrue(inlineDetail.contains("let visibleChanges = calendarChanges.prefix(calendarVisibleLimit)"))
        XCTAssertTrue(inlineDetail.contains("ForEach(visibleChanges)"))
        XCTAssertFalse(inlineDetail.contains("ForEach(calendarChanges)"))
        XCTAssertTrue(inlineRows.contains("presentation == .inlineDetail && selectedItemID == item.id"))
        XCTAssertFalse(inlineRows.contains("guard klmsInteractionDetailDelayNanoseconds > 0 else"))
        XCTAssertFalse(inlineRows.contains("await Task.yield()"))
        XCTAssertFalse(inlineRows.contains("try? await Task.sleep(nanoseconds: klmsInteractionDetailDelayNanoseconds)"))
        XCTAssertFalse(inlineRows.contains("private func increaseVisibleLimit()"))
        XCTAssertFalse(selectableRows.contains("private func increaseVisibleLimit()"))
        XCTAssertFalse(inlineRows.contains("@ObservedObject var model"))
        XCTAssertFalse(compactSelectedRow.contains("@ObservedObject var model"))
        XCTAssertFalse(inlineDetail.contains("private var filteredItems"))
        XCTAssertTrue(workstationCategory.contains("itemPresentation: .externalDetail"))
        XCTAssertTrue(workstationCategory.contains("externallySelectedItemID: activeSelectedItemID"))
        XCTAssertTrue(workstationCategory.contains("WorkstationExternalDetailPanel"))
        XCTAssertTrue(workstationCategory.contains("selectedItemID = item.id"))
        XCTAssertTrue(workstationTasks.contains("taskPanel(.assignments)"))
        XCTAssertTrue(workstationTasks.contains("taskPanel(.exams)"))
        XCTAssertTrue(workstationTasks.contains("WorkstationExternalDetailPanel"))
        XCTAssertTrue(recentFileRequests.contains("LazyVStack(spacing: 8)"))
        XCTAssertTrue(recentFileRequests.contains("ForEach(requests.prefix(30))"))
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
        let mailPastePanel = try sourceStructBody(named: "MailPasteAnalyzerPanel", in: ios)
        let mailPasteResult = try sourceStructBody(named: "MailPasteAnalysisResultView", in: ios)
        let mailAnalysisProcess = try sourceStructBody(named: "MailAnalysisProcessView", in: ios)
        let remoteCalendarPanel = try sourceStructBody(named: "RemoteCalendarActionPanel", in: ios)

        XCTAssertTrue(statusScreen.contains("selectedChangeSummary"))
        XCTAssertTrue(statusScreen.contains("RemoteChangeSummaryDetailPanel"))
        let dashboardSyncCard = try sourceStructBody(named: "RemoteDashboardSyncCard", in: ios)

        XCTAssertTrue(dashboardSyncCard.contains("MailPasteAnalyzerPanel"))
        XCTAssertFalse(runScreen.contains("MailPasteAnalyzerPanel"))
        let iosMailPanelIndex = try XCTUnwrap(dashboardSyncCard.range(of: "MailPasteAnalyzerPanel")?.lowerBound)
        let iosFullSyncIndex = try XCTUnwrap(dashboardSyncCard.range(of: "dashboardPrimaryButton")?.lowerBound)
        XCTAssertTrue(iosMailPanelIndex < iosFullSyncIndex)
        XCTAssertTrue(dashboardInlineDetail.contains("if category == .calendar"))
        XCTAssertFalse(dashboardInlineDetail.contains("MailPasteAnalyzerPanel"))
        XCTAssertTrue(ios.contains("private enum RemoteChangeSummaryKind"))
        XCTAssertTrue(ios.contains("RemoteDashboardChangeSummary("))
        XCTAssertTrue(ios.contains("onChangeSummaryTap"))
        XCTAssertTrue(ios.contains("UIPasteboard.general.string"))
        XCTAssertTrue(ios.contains("MailPasteAnalyzer.analyze"))
        XCTAssertTrue(mailPastePanel.contains("@State private var deferredAnalysisTask"))
        XCTAssertTrue(mailPastePanel.contains("scheduleAnalysis()"))
        XCTAssertTrue(mailPastePanel.contains(".buttonStyle(KLMSCardButtonStyle())"))
        XCTAssertTrue(mailPastePanel.contains(".onChange(of: model.dashboardSyncItemsRevision)"))
        XCTAssertFalse(mailPastePanel.contains(".onChange(of: model.syncItems)"))
        XCTAssertTrue(mailPasteResult.contains(".buttonStyle(KLMSCardButtonStyle())"))
        XCTAssertTrue(mailAnalysisProcess.contains(".buttonStyle(KLMSCardButtonStyle())"))
        XCTAssertTrue(ios.contains("메일 원문 붙여넣기"))
        XCTAssertTrue(ios.contains("원문은 서버로 보내지 않음"))
        XCTAssertTrue(ios.contains("판독 결과"))
        XCTAssertTrue(ios.contains("메일·캘린더 분석"))
        XCTAssertTrue(ios.contains("Mac 캘린더에 등록"))
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
        XCTAssertTrue(ios.contains(".unmatchedMailDashboardItems(comparedTo: syncItems)"))
        XCTAssertTrue(ios.contains("resolvedCalendarChangeIDs"))
        XCTAssertTrue(ios.contains("recordResolvedCalendarChanges(itemActions)"))
        XCTAssertTrue(ios.contains("action.action.resolvesCalendarChange"))
        XCTAssertTrue(ios.contains("activeAction: model.activeCalendarAction(for: change)"))
        XCTAssertTrue(ios.contains("activeAction.status.displayName"))
        XCTAssertTrue(ios.contains("let defaults = change.editDefaults"))
        XCTAssertTrue(ios.contains("case .calendarCreate, .calendarEdit, .calendarApply, .calendarDelete:"))
        XCTAssertTrue(ios.contains("&& action.status != .failed"))
        XCTAssertTrue(ios.contains("&& action.status != .macUnavailable"))
        XCTAssertFalse(ios.contains("didSubmitCommand"))
        XCTAssertTrue(ios.contains("\"캘린더 일정 등록\""))
        XCTAssertTrue(ios.contains("\"캘린더 내용 수정\""))
        XCTAssertTrue(ios.contains("\"캘린더 일정 삭제\""))
        XCTAssertTrue(ios.contains("Label(\"등록\", systemImage: \"calendar.badge.plus\")"))
        XCTAssertTrue(ios.contains("Label(\"수정\", systemImage: \"pencil\")"))
        XCTAssertTrue(ios.contains("change.isDeletedAction"))
        XCTAssertTrue(ios.contains("Label(\"확인\", systemImage: \"checkmark.circle\")"))
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
        let calendarActionButton = try sourceStructBody(named: "CalendarActionButton", in: detail)
        let dashboardSummary = try sourceStructBody(named: "DashboardSummaryContentView", in: mac)
        let commandPanel = try sourceStructBody(named: "CommandPanelView", in: mac)

        XCTAssertFalse(calendarDetail.contains("MacMailPasteAnalyzerPanel"))
        XCTAssertFalse(calendarGuide.contains("model.run(.verify)"))
        XCTAssertTrue(calendarGuide.contains("model.run(.coreSync)"))
        XCTAssertFalse(calendarGuide.contains("model.run(.doctor)"))
        XCTAssertFalse(calendarGuide.contains("캘린더 확인"))
        XCTAssertTrue(calendarGuide.contains("KLMS 기준 반영"))
        XCTAssertTrue(calendarGuide.contains("캘린더에서 열기"))
        XCTAssertTrue(calendarActionButton.contains("Color.klmsMacCommandButtonBackground.opacity(0.92)"))
        XCTAssertTrue(calendarActionButton.contains("Color.klmsMacCommandButtonBorder.opacity(0.95)"))
        XCTAssertFalse(calendarActionButton.contains("tint.opacity(0.10)"))
        XCTAssertFalse(calendarActionButton.contains("tint.opacity(0.24)"))
        XCTAssertFalse(dashboardSummary.contains("MacMailPasteAnalyzerPanel"))
        XCTAssertFalse(dashboardSummary.contains("@State private var displayedDetail"))
        XCTAssertTrue(mac.contains("private struct DashboardSummaryContentView: View, @preconcurrency Equatable"))
        XCTAssertFalse(mac.contains("Metric(\"완료 기록\", summary.completedAssignmentCount, detail: .assignmentRecords)"))
        XCTAssertFalse(detail.contains("hasher.combine(summary.completedAssignmentCount)"))
        XCTAssertTrue(dashboardSummary.contains("private func metricColumn("))
        XCTAssertTrue(dashboardSummary.contains("private func dashboardDetailColumn(kind: DashboardDetailKind)"))
        XCTAssertTrue(dashboardSummary.contains("DashboardDetailPanelView("))
        XCTAssertTrue(dashboardSummary.contains("renderSignature: renderSignature"))
        XCTAssertFalse(dashboardSummary.contains(".frame(minWidth: 340, idealWidth: 420, maxWidth: 500"))
        XCTAssertTrue(dashboardSummary.contains("VStack(alignment: .leading, spacing: 12)"))
        XCTAssertFalse(dashboardSummary.contains("await Task.yield()"))
        XCTAssertTrue(dashboardSummary.contains("guard selectedDetail != detail else"))
        XCTAssertFalse(dashboardSummary.contains("@State private var displayedDetail"))
        XCTAssertTrue(commandPanel.contains("MacMailPasteAnalyzerPanel"))
        let macMailPanelIndex = try XCTUnwrap(commandPanel.range(of: "MacMailPasteAnalyzerPanel")?.lowerBound)
        let macFullSyncIndex = try XCTUnwrap(commandPanel.range(of: "primaryCommandActionCard(primaryCommand)")?.lowerBound)
        XCTAssertTrue(macMailPanelIndex < macFullSyncIndex)
        XCTAssertTrue(detail.contains("메일·캘린더 분석"))
        XCTAssertTrue(detail.contains("메일 원문 붙여넣기"))
        XCTAssertTrue(detail.contains("원문은 서버로 보내지 않음"))
        XCTAssertTrue(detail.contains("판독 결과"))
        XCTAssertTrue(detail.contains("캘린더에 등록"))
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
        XCTAssertTrue(model.contains("if let change = try? serverRelayCalendarChange(for: action)"))
        XCTAssertTrue(model.contains("applyServerRelayMailDashboardRemoveAction"))
        XCTAssertTrue(model.contains("case .mailDashboardRemove"))
        XCTAssertTrue(model.contains("runningAction.action == .calendarCreate"))
        XCTAssertTrue(model.contains("mailCalendarChanges()"))
        XCTAssertTrue(model.contains("visibleCalendarChanges(from: snapshot).map(serverRelayCalendarChange)"))
        XCTAssertTrue(model.contains("mailDashboardStateItems(kind: String)"))
        XCTAssertTrue(model.contains("resolvedCalendarChangeIDs"))
        XCTAssertTrue(model.contains("location: serverRelayPublicText(change.location)"))
        XCTAssertTrue(model.contains("func openCalendarEvent(change: CalendarChange) async -> Bool"))
        XCTAssertTrue(model.contains("change.isDeletedAction"))
        XCTAssertTrue(model.contains("캘린더 변경 항목 제거 완료"))
        XCTAssertTrue(model.contains("calendarItemExternalIdentifier"))
        XCTAssertTrue(model.contains("show targetEvent"))
        XCTAssertTrue(model.contains("persistResolvedCalendarChangeIDs()"))
        XCTAssertTrue(model.contains("let mailChanges = mailCalendarChanges().filter { !isCalendarChangeResolved($0) }"))
        XCTAssertTrue(model.contains("visibleCalendarChanges(from snapshot: EngineSnapshot)"))
        XCTAssertTrue(model.contains("dashboardSummaryCache"))
        XCTAssertTrue(model.contains("private func rebuildDashboardSummaryCache()"))
        XCTAssertTrue(detail.contains("model.mailDashboardStateItems(kind: \"assignment\")"))
        XCTAssertTrue(detail.contains("model.mailDashboardStateItems(kind: \"exam\")"))
        XCTAssertTrue(detail.contains("!model.isCalendarChangeResolved(change)"))
        XCTAssertTrue(detail.contains("isUserVisibleCalendarChange"))
        XCTAssertTrue(detail.contains("model.mailCalendarChanges().count"))
        XCTAssertTrue(detail.contains("let defaults = change.editDefaults"))
        XCTAssertTrue(detail.contains("캘린더 내용 수정 완료"))
        XCTAssertTrue(calendarRow.contains("model.createCalendarEvent(change: change, edit: change.editDefaults)"))
        XCTAssertFalse(calendarRow.contains("calendarSheetAction = .calendarCreate"))
        XCTAssertTrue(calendarRow.contains("Label(\"확인\", systemImage: \"checkmark.circle\")"))
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

    func testMacMailDashboardDerivedDataIsCachedOffRenderPath() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let macModelRoot = packageRoot.appendingPathComponent("Sources/KLMSMac/KLMSMacModel.swift")
        let model = try String(contentsOf: macModelRoot, encoding: .utf8)
        let mailItems = try sourceBody(
            after: "func mailDashboardItems(kind: String)",
            in: model,
            description: "Mac mail dashboard items accessor"
        )
        let mailCalendar = try sourceBody(
            after: "func mailCalendarChanges()",
            in: model,
            description: "Mac mail calendar changes accessor"
        )
        let rebuildCache = try sourceBody(
            after: "private func rebuildMailDashboardCaches()",
            in: model,
            description: "Mac mail dashboard cache rebuild"
        )
        let addMailItem = try sourceBody(
            after: "func addMailDashboardItem",
            in: model,
            description: "Mac mail dashboard add"
        )
        let removeMailItem = try sourceBody(
            after: "private func removeMailDashboardItem",
            in: model,
            description: "Mac mail dashboard remove"
        )
        let applySnapshot = try sourceBody(
            after: "private func applySnapshot",
            in: model,
            description: "Mac snapshot apply"
        )

        XCTAssertTrue(mailItems.contains("cachedMailDashboardItemsByKind[kind] ?? []"))
        XCTAssertFalse(mailItems.contains("currentServerRelayBaseSyncItems()"))
        XCTAssertTrue(mailCalendar.contains("cachedMailCalendarChanges"))
        XCTAssertFalse(mailCalendar.contains("currentServerRelayBaseSyncItems()"))
        XCTAssertTrue(rebuildCache.contains("unmatchedMailDashboardItems(comparedTo: currentServerRelayBaseSyncItems())"))
        XCTAssertTrue(rebuildCache.contains("rebuildDashboardSummaryCache()"))
        XCTAssertTrue(addMailItem.contains("rebuildMailDashboardCaches()"))
        XCTAssertTrue(removeMailItem.contains("rebuildMailDashboardCaches()"))
        XCTAssertTrue(applySnapshot.contains("replaceSnapshot(nextSnapshot)"))
        XCTAssertTrue(model.contains("private struct SnapshotSourceSignature: Equatable"))
        XCTAssertTrue(model.contains("private var lastSnapshotSourceSignature"))
        XCTAssertTrue(model.contains("guard force || lastSnapshotSourceSignature != signature else"))
        XCTAssertTrue(model.contains("self.loadEngineSnapshot(force: false)"))
        XCTAssertTrue(model.contains("self.replaceSnapshot(loadedSnapshot)"))
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
        XCTAssertTrue(ios.contains("private struct WorkstationSidebar"))
        XCTAssertTrue(ios.contains("guard selectedSection != section else { return }"))
        XCTAssertFalse(ios.contains("guard displayedSection != section else"))
        XCTAssertFalse(ios.contains("guard displayedDashboardPreview != category || displayedChangeSummary != nil else"))
        XCTAssertTrue(ios.contains("HStack(spacing: 0)"))
        XCTAssertTrue(ios.contains("WorkstationSidebar(selectedSection: $selectedSection)"))
        XCTAssertTrue(ios.contains(".frame(width: 214)"))
        XCTAssertFalse(ios.contains(".frame(width: 154)"))
        XCTAssertTrue(ios.contains("private struct CompanionTabRootView"))
        XCTAssertTrue(ios.contains("private struct CompanionSectionContent"))
        XCTAssertTrue(ios.contains("CompanionSplitRootView(model: model, selectedSection: $selectedSection)"))
        XCTAssertTrue(ios.contains("CompanionTabRootView(model: model)"))
        XCTAssertTrue(ios.contains("private struct WorkstationDashboardCategoryWorkspace"))
        XCTAssertTrue(ios.contains("private struct WorkstationTasksWorkspace"))
        XCTAssertTrue(ios.contains("private struct WorkstationExternalDetailPanel"))
        XCTAssertTrue(ios.contains("category.supportsWorkstationSelectionWorkspace"))
        XCTAssertTrue(ios.contains("horizontalSizeClass == .regular"))
        XCTAssertTrue(ios.contains(".frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)"))
        XCTAssertFalse(ios.contains(".frame(maxWidth: .infinity, minHeight: isCompact ? 40 : 36, alignment: .leading)"))
        XCTAssertTrue(ios.contains("private var screenContent: some View"))
        XCTAssertTrue(ios.contains("NavigationStack {\n                    screenContent"))
        XCTAssertFalse(ios.contains(".listStyle(.sidebar)"))
        XCTAssertFalse(ios.contains(".navigationSplitViewColumnWidth"))
        XCTAssertFalse(ios.contains("Mac 앱에 실행 요청을 보냅니다."))
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
        XCTAssertTrue(ios.contains("private static func relayRefreshScope(for message: URLSessionWebSocketTask.Message) -> RelayRefreshScope"))
        XCTAssertTrue(ios.contains("if reason.hasPrefix(\"file-access:\")"))
        XCTAssertTrue(ios.contains("return .fileAccess"))
        XCTAssertTrue(ios.contains("if reason.hasPrefix(\"commands:\")"))
        XCTAssertTrue(ios.contains("reason == \"commands:pending\" ? .commandRequest : .state"))
        XCTAssertTrue(ios.contains("if reason.hasPrefix(\"item-actions:\")"))
        XCTAssertTrue(ios.contains("return .itemActions"))
        XCTAssertTrue(ios.contains("if reason.hasPrefix(\"setting-actions:\")"))
        XCTAssertTrue(ios.contains("return .settingActions"))
        XCTAssertTrue(ios.contains("if reason == \"state\" || reason == \"updated\""))
        XCTAssertTrue(ios.contains("return .state"))

        XCTAssertFalse(macModel.contains("serverRelayPollingTask"))
        XCTAssertFalse(macModel.contains("configureServerRelayPolling"))
        XCTAssertFalse(macModel.contains("serverRelayIdlePollingIntervalNanoseconds"))
        XCTAssertFalse(macModel.contains("serverRelayActivePollingIntervalNanoseconds"))
        XCTAssertTrue(macModel.contains("private static func serverRelayEventNeedsWorkerRefresh"))
        XCTAssertTrue(macModel.contains("reason == \"commands:pending\""))
        XCTAssertTrue(macModel.contains("private static let serverRelayFallbackPollIntervalNanoseconds: UInt64 = 120_000_000_000"))
        XCTAssertTrue(macModel.contains("private static let serverRelayActiveSyncDataPublishMinimumInterval: TimeInterval = 20"))
        XCTAssertTrue(macModel.contains("private static let serverRelayActiveStatusPublishMinimumInterval: TimeInterval = 1.0"))
        XCTAssertFalse(macModel.contains("await processServerRelayCommands(silent: true)\n                }\n            } catch"))
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
        XCTAssertTrue(macView.contains("DashboardTopBarView(model: model, selectedSection: $selectedSection)"))
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
        XCTAssertTrue(queueRefresh.contains("connectionMessage = \"새로고침 중입니다. 끝나는 대로 바로 반영합니다.\""))
        XCTAssertTrue(queueRefresh.contains("isRefreshing = true"))
        XCTAssertTrue(ios.contains("connectionMessage = \"새로고침 완료\""))
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
        XCTAssertTrue(refreshBody.contains("async let commandsTask = Self.fetchRecentCommandsIfNeeded(scope.fetchesCommands"))
        XCTAssertTrue(refreshBody.contains("async let syncDataTask"))
        XCTAssertTrue(refreshBody.contains("async let fileRequestsTask = Self.fetchRecentFileAccessRequestsIfNeeded(scope.fetchesFileRequests"))
        XCTAssertTrue(refreshBody.contains("async let itemActionsTask = Self.fetchRecentItemActionsIfNeeded(scope.fetchesItemActions"))
        XCTAssertTrue(refreshBody.contains("async let requestLogTask = Self.fetchRecentRequestLogIfNeeded(scope.fetchesRequestLog"))
        XCTAssertTrue(refreshBody.contains("async let settingActionsTask = Self.fetchRecentSettingActionsIfNeeded(scope.fetchesSettingActions"))
        XCTAssertTrue(ios.contains("private static func fetchSyncDataIfNeeded"))
        XCTAssertTrue(ios.contains("struct RelayRefreshScope: Equatable"))
        XCTAssertTrue(ios.contains("scope.formUnion(newScope)"))
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
