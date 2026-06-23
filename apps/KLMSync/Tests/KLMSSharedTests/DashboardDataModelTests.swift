import XCTest
@testable import KLMSShared

final class DashboardDataModelTests: XCTestCase {
    func testDashboardSortsAssignmentsByDeadlineBeforeTitle() throws {
        let late = try decodeStateItem(
            url: "https://klms.kaist.ac.kr/mod/assign/view.php?id=2",
            title: "A 늦은 과제",
            course: "알고리즘 개론",
            syncDue: "2026-06-20T14:59:00Z"
        )
        let noDate = try decodeStateItem(
            url: "https://klms.kaist.ac.kr/mod/assign/view.php?id=3",
            title: "B 날짜 없는 과제",
            course: "알고리즘 개론"
        )
        let early = try decodeStateItem(
            url: "https://klms.kaist.ac.kr/mod/assign/view.php?id=1",
            title: "Z 빠른 과제",
            course: "데이타베이스 개론",
            syncDue: "2026-06-10T14:59:00Z"
        )
        let content = LegacySyncState.Content(assignments: [late, noDate, early])
            .applyingManualOverrides(ManualOverridesSnapshot())

        XCTAssertEqual(content.assignments.map(\.title), ["Z 빠른 과제", "A 늦은 과제", "B 날짜 없는 과제"])
    }

    func testDashboardSortsExamsByStartDateBeforeDueDate() throws {
        let afternoon = try decodeStateItem(
            url: "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=2",
            title: "A 오후 시험",
            course: "데이타베이스 개론",
            category: "exam",
            syncDue: "2026-07-17T07:00:00Z",
            syncStart: "2026-07-17T04:00:00Z"
        )
        let morning = try decodeStateItem(
            url: "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1",
            title: "Z 오전 시험",
            course: "전기전자공학특강",
            category: "exam",
            syncDue: "2026-07-17T02:30:00Z",
            syncStart: "2026-07-17T00:00:00Z"
        )
        let content = LegacySyncState.Content(examItems: [afternoon, morning])
            .applyingManualOverrides(ManualOverridesSnapshot())

        XCTAssertEqual(content.examItems.map(\.title), ["Z 오전 시험", "A 오후 시험"])
    }

    func testDashboardSortsKoreanAssignmentAndExamDates() throws {
        let lateAssignment = try decodeStateItem(
            url: "https://klms.kaist.ac.kr/mod/assign/view.php?id=20",
            title: "A 늦은 한글 과제",
            course: "알고리즘 개론",
            due: "2026년 6월 20일(토요일) 오후 11:59"
        )
        let earlyAssignment = try decodeStateItem(
            url: "https://klms.kaist.ac.kr/mod/assign/view.php?id=10",
            title: "Z 빠른 한글 과제",
            course: "알고리즘 개론",
            due: "2026년 6월 9일 화요일 오후 11시 59분"
        )
        let assignments = LegacySyncState.Content(assignments: [lateAssignment, earlyAssignment])
            .applyingManualOverrides(ManualOverridesSnapshot())
        XCTAssertEqual(assignments.assignments.map(\.title), ["Z 빠른 한글 과제", "A 늦은 한글 과제"])

        let afternoonExam = try decodeStateItem(
            url: "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=20",
            title: "A 오후 한글 시험",
            course: "데이타베이스 개론",
            category: "exam",
            due: "2026년 6월 17일(수요일) 오후 1:00 - 오후 4:00"
        )
        let morningExam = try decodeStateItem(
            url: "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=10",
            title: "Z 오전 한글 시험",
            course: "전기 전자공학특강",
            category: "exam",
            due: "2026년 6월 17일 수요일 오전 9시"
        )
        let exams = LegacySyncState.Content(examItems: [afternoonExam, morningExam])
            .applyingManualOverrides(ManualOverridesSnapshot())
        XCTAssertEqual(exams.examItems.map(\.title), ["Z 오전 한글 시험", "A 오후 한글 시험"])
    }

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

    func testCommandRunHistoryRemoveRecordPersistsRemainingRuns() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("klms-dashboard-remove-history-\(UUID().uuidString)", isDirectory: true)
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
            standardOutput: "full",
            standardError: "",
            authDigits: nil
        ))
        let beforeRemove = try store.append(KLMSCommandResult(
            invocation: KLMSEngineCommand.noticeSync.invocation(),
            startedAt: Date(timeIntervalSince1970: 4),
            finishedAt: Date(timeIntervalSince1970: 6),
            exitCode: 1,
            standardOutput: "notice",
            standardError: "",
            authDigits: nil
        ))
        let noticeID = try XCTUnwrap(beforeRemove.records.first?.id)

        let afterRemove = try store.removeRecord(id: noticeID)

        XCTAssertEqual(afterRemove.records.count, 1)
        XCTAssertEqual(afterRemove.records.first?.command, .fullSync)
        XCTAssertEqual(store.load().records.map(\.command), [.fullSync])
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
        XCTAssertTrue(mac.contains("WholeScreenVerticalScrollView(resetID: MacWorkspaceScrollResetKey(section: selectedSection, nonce: scrollResetNonce))"))
        XCTAssertTrue(mac.contains("@State private var scrollResetNonce = 0"))
        XCTAssertTrue(mac.contains("private func resetCurrentSectionScroll()"))
        XCTAssertTrue(mac.contains("private enum KLMSMacScrollAnchor: Hashable"))
        XCTAssertTrue(mac.contains("private struct MacWorkspaceScrollResetKey: Equatable"))
        XCTAssertTrue(mac.contains("ScrollViewReader { proxy in"))
        XCTAssertTrue(mac.contains(".id(KLMSMacScrollAnchor.top)"))
        XCTAssertTrue(mac.contains(".onChange(of: resetID)"))
        XCTAssertTrue(mac.contains("@State private var scrollResetTask: Task<Void, Never>?"))
        XCTAssertTrue(mac.contains("scrollResetTask = Task { @MainActor in"))
        XCTAssertTrue(mac.contains("await Task.yield()"))
        XCTAssertTrue(mac.contains("guard !Task.isCancelled else { return }"))
        XCTAssertTrue(mac.contains("proxy.scrollTo(KLMSMacScrollAnchor.top, anchor: .top)"))
        XCTAssertFalse(mac.contains("withAnimation(.easeInOut(duration: 0.08)) {\n                    proxy.scrollTo(KLMSMacScrollAnchor.top, anchor: .top)"))
        XCTAssertTrue(mac.contains(".scrollIndicators(.visible)"))
        XCTAssertTrue(mac.contains("private struct WholeScreenVerticalScrollView"))
        XCTAssertFalse(mac.contains("GeometryReader { geometry in"))
        XCTAssertFalse(mac.contains("minHeight: geometry.size.height"))
        XCTAssertTrue(macRootBody.contains("WholeScreenVerticalScrollView"))
        XCTAssertTrue(macRootBody.contains("MacWorkspaceSidebarView("))
        XCTAssertTrue(macRootBody.contains("resetCurrentSectionScroll: resetCurrentSectionScroll"))
        XCTAssertTrue(mac.contains("case .settings:\n                DeferredMacWorkspacePanel(\n                    id: \"workspace-settings\""))
        XCTAssertTrue(mac.contains("contentDelayNanoseconds: MacWorkspacePanelTiming.heavyListContentDelayNanoseconds\n                ) {\n                    SettingsView(model: model)"))
        XCTAssertTrue(mac.contains("if let error = model.errorMessage, !error.isEmpty"))
        XCTAssertTrue(mac.contains("Text(error)"))
        XCTAssertTrue(mac.contains(".lineLimit(2)\n                    .textSelection(.enabled)"))
        XCTAssertTrue(mac.contains(".help(error)"))
        XCTAssertTrue(mac.contains(".accessibilityLabel(\"오류. \\(error)\")"))
        XCTAssertTrue(mac.contains("MacWorkspaceRenderedAccessibilityMarker(section: selectedSection)"))
        XCTAssertTrue(mac.contains("MacWorkspacePanelAccessibilityMarker(section: selectedSection)"))
        XCTAssertTrue(mac.contains("MacWorkspaceContainerAccessibilityMarker(section: selectedSection)"))
        XCTAssertTrue(mac.contains(".accessibilityIdentifier(\"workspace-rendered-section-marker-\\(section.rawValue)\")"))
        XCTAssertTrue(mac.contains(".accessibilityIdentifier(\"workspace-panel-marker-workspace-\\(section.rawValue)\")"))
        XCTAssertTrue(mac.contains(".accessibilityIdentifier(\"workspace-container-marker-\\(section.rawValue)\")"))
        XCTAssertTrue(mac.contains(".accessibilityIdentifier(\"workspace-panel-marker-\\(id)\")"))
        XCTAssertTrue(mac.contains("var accessibilitySummary: String"))
        XCTAssertTrue(mac.contains("\"대시보드 화면 · 전체 동기화 · 변경 요약\""))
        XCTAssertTrue(macRootBody.contains(".frame(width: 264, alignment: .topLeading)"))
        XCTAssertTrue(macRootBody.contains(".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)"))
        XCTAssertTrue(macRootBody.contains(".accessibilityElement(children: .contain)"))
        XCTAssertTrue(macRootBody.contains(".frame(maxWidth: .infinity, alignment: .topLeading)"))
        XCTAssertTrue(mac.contains("Rectangle()\n                    .fill(Color.klmsMacBorder.opacity(0.76))"))
        XCTAssertFalse(mac.contains("ScrollView(.horizontal)"))
        XCTAssertTrue(ios.contains("ScrollView(.vertical, showsIndicators: true)"))
        XCTAssertTrue(ios.contains(".scrollIndicators(.visible)"))
        XCTAssertTrue(ios.contains("private struct WholeScreenVerticalScrollView"))
        XCTAssertFalse(ios.contains("GeometryReader { geometry in"))
        XCTAssertFalse(ios.contains("minHeight: geometry.size.height"))
    }

    func testMacWorkspaceAccessibilitySmokeScriptTargetsNavigation() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repoRoot = packageRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptRoot = repoRoot.appendingPathComponent("tools/smoke_klms_mac_accessibility.swift")
        let basicActionsScriptRoot = repoRoot.appendingPathComponent("tools/smoke_klms_mac_basic_actions.swift")
        let probeRoot = repoRoot.appendingPathComponent("tools/probe_klms_mac_tab_response.swift")
        let script = try String(contentsOf: scriptRoot, encoding: .utf8)
        let basicActionsScript = try String(contentsOf: basicActionsScriptRoot, encoding: .utf8)
        let probe = try String(contentsOf: probeRoot, encoding: .utf8)

        XCTAssertTrue(script.contains("WorkspaceSmokeTarget(rawValue: \"dashboard\", title: \"대시보드\", expectedTexts: [\"전체 동기화\"])"))
        XCTAssertTrue(script.contains("WorkspaceSmokeTarget(rawValue: \"files\", title: \"파일\", expectedTexts: [\"파일 목록\", \"필터와 검색\"])"))
        XCTAssertTrue(script.contains("WorkspaceSmokeTarget(rawValue: \"tasks\", title: \"과제/시험\", expectedTexts: [\"과제\", \"시험\", \"필터와 검색\"])"))
        XCTAssertTrue(script.contains("WorkspaceSmokeTarget(rawValue: \"notices\", title: \"공지\", expectedTexts: [\"공지 분류\"])"))
        XCTAssertTrue(script.contains("WorkspaceSmokeTarget(rawValue: \"calendar\", title: \"캘린더\", expectedTexts: [\"캘린더 일정\", \"KLMS 기준 반영\"])"))
        XCTAssertTrue(script.contains("WorkspaceSmokeTarget(rawValue: \"activityLogs\", title: \"로그\", expectedTexts: [\"실행 로그 지우기\", \"서버 로그 지우기\"])"))
        XCTAssertTrue(script.contains("WorkspaceSmokeTarget(rawValue: \"diagnostics\", title: \"진단\", expectedTexts: [\"상태 검사\", \"권한/환경 진단\"])"))
        XCTAssertTrue(script.contains("WorkspaceSmokeTarget(rawValue: \"settings\", title: \"설정\", expectedTexts: [\"바로 반영되는 설정\"])"))
        XCTAssertTrue(script.contains("for target in workspaceTargets"))
        XCTAssertTrue(script.contains("var scrollIdentifier: String { \"workspace-scroll-\\(rawValue)\" }"))
        XCTAssertTrue(script.contains("var panelIdentifier: String { \"workspace-panel-workspace-\\(rawValue)\" }"))
        XCTAssertTrue(script.contains("var renderedIdentifier: String { \"workspace-container-marker-\\(rawValue)\" }"))
        XCTAssertTrue(script.contains("try verifyWorkspaceContentLayout(appElement: appElement, target: target)"))
        XCTAssertTrue(script.contains("private func verifyWorkspaceContentLayout("))
        XCTAssertTrue(script.contains("scrollFrame.width >= 420"))
        XCTAssertTrue(script.contains("scrollFrame.minX >= buttonFrame.maxX - 16"))
        XCTAssertTrue(script.contains("scroll area overlaps the sidebar"))
        XCTAssertTrue(script.contains("panelFrame.minX >= scrollFrame.minX - horizontalSlack"))
        XCTAssertTrue(script.contains("container frame is too narrow"))
        XCTAssertFalse(script.contains("waitForSelectedValue(identifier: target.buttonIdentifier, in: appElement, timeout: timeout)"))
        XCTAssertFalse(script.contains("waitForSelectedValue(on: button, timeout: timeout)"))
        XCTAssertTrue(script.contains("let requiredIdentifiers = [target.renderedIdentifier]"))
        XCTAssertFalse(script.contains("let requiredIdentifiers = [target.panelIdentifier, target.renderedIdentifier]"))
        XCTAssertTrue(script.contains("waitForElements(withIdentifiers: requiredIdentifiers, in: appElement, timeout: timeout)"))
        XCTAssertTrue(script.contains("private func findIdentifiers("))
        XCTAssertTrue(script.contains("KLMS_MAC_AX_SCREENSHOT_DIR"))
        XCTAssertTrue(script.contains("try captureScreenshotIfRequested(named: \"workspace-\\(target.rawValue)\")"))
        XCTAssertTrue(script.contains("try captureScreenshotIfRequested(named: identifier)"))
        XCTAssertTrue(script.contains("captureFailureScreenshotIfRequested()"))
        XCTAssertTrue(script.contains("try captureScreenshotIfRequested(named: \"failure-current-window\")"))
        XCTAssertTrue(script.contains("private func visibleDashboardWindowID() -> Int?"))
        XCTAssertTrue(script.contains("private func captureWindowUsingScreencapture(windowID: Int, to outputURL: URL) -> Bool"))
        XCTAssertTrue(script.contains("process.executableURL = URL(fileURLWithPath: \"/usr/sbin/screencapture\")"))
        XCTAssertTrue(script.contains("process.arguments = [\"-x\", \"-l\", String(windowID), outputURL.path]"))
        XCTAssertFalse(script.contains("for identifier in [target.panelIdentifier, target.renderedIdentifier]"))
        XCTAssertFalse(script.contains("for identifier in [target.scrollIdentifier, target.panelIdentifier, target.renderedIdentifier]"))
        XCTAssertTrue(script.contains("waitForElement(withIdentifier: identifier, in: appElement, timeout: 0.1)"))
        XCTAssertTrue(script.contains("for expectedText in target.expectedTexts"))
        XCTAssertTrue(script.contains("workspaceContentMissing(String)"))
        XCTAssertTrue(script.contains("private struct SettingsSmokeTarget"))
        XCTAssertTrue(script.contains("for target in settingsTargets"))
        XCTAssertTrue(script.contains("var identifier: String { \"settings-\\(rawValue)\" }"))
        XCTAssertTrue(script.contains("SettingsSmokeTarget(rawValue: \"app\", expectedText: \"바로 반영되는 설정\")"))
        XCTAssertTrue(script.contains("SettingsSmokeTarget(rawValue: \"login\", expectedText: \"KAIST 아이디\")"))
        XCTAssertTrue(script.contains("SettingsSmokeTarget(rawValue: \"sync\", expectedText: \"Safari 자동화\")"))
        XCTAssertTrue(script.contains("SettingsSmokeTarget(rawValue: \"files\", expectedText: \"파일 확인\")"))
        XCTAssertTrue(script.contains("SettingsSmokeTarget(rawValue: \"notice\", expectedText: \"메모 이름\")"))
        XCTAssertTrue(script.contains("openDashboardWindowIfNeeded(appElement: appElement)"))
        XCTAssertTrue(script.contains("bringKLMSAppForward(app: app, appElement: appElement)"))
        XCTAssertTrue(script.contains("activateApplicationBundle()"))
        XCTAssertTrue(script.contains("process.executableURL = URL(fileURLWithPath: \"/usr/bin/open\")"))
        XCTAssertTrue(script.contains("process.arguments = [\"-b\", bundleID]"))
        XCTAssertTrue(script.contains("activateApplicationWithAppleScript()"))
        XCTAssertTrue(script.contains("app.activate(options: [.activateAllWindows])"))
        XCTAssertFalse(script.contains(".activateIgnoringOtherApps"))
        XCTAssertTrue(script.contains("AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)"))
        XCTAssertTrue(script.contains("sessionDiagnostics()"))
        XCTAssertTrue(script.contains("CGSessionCopyCurrentDictionary()"))
        XCTAssertTrue(script.contains("frontmost-app name="))
        XCTAssertTrue(script.contains("identifierMatches(stringAttribute($0, \"AXIdentifier\" as CFString), expected: identifier)"))
        XCTAssertTrue(script.contains("waitForSelectedValue(identifier: identifier"))
        XCTAssertTrue(script.contains("\"AXIdentifier\" as CFString"))
        XCTAssertTrue(script.contains("AXUIElementPerformAction(button, kAXPressAction as CFString)"))
        XCTAssertTrue(script.contains("ok: KLMS Mac workspace accessibility navigation is responsive"))
        XCTAssertTrue(script.contains("smoke failed: \\(error)"))
        XCTAssertTrue(script.contains("visibleWindowDiagnostics()"))
        XCTAssertTrue(script.contains("accessibilityTreeUnavailable(frontmostApp: String?)"))
        XCTAssertTrue(script.contains("hasUsableAccessibilityWindow(in: appElement)"))
        XCTAssertTrue(basicActionsScript.contains("sendCommandQ()"))
        XCTAssertTrue(basicActionsScript.contains("tell application \\\"System Events\\\" to keystroke \\\"q\\\" using command down"))
        XCTAssertTrue(basicActionsScript.contains("Command-Q terminates KLMS Sync"))
        XCTAssertTrue(basicActionsScript.contains("\"전체 동기화\""))
        XCTAssertTrue(basicActionsScript.contains("\"전체 기록 지우기\""))
        XCTAssertTrue(basicActionsScript.contains("\"실행 로그 지우기\""))
        XCTAssertTrue(basicActionsScript.contains("\"서버 로그 지우기\""))
        XCTAssertTrue(basicActionsScript.contains("KLMS_MAC_SMOKE_SKIP_CMD_Q"))
        XCTAssertTrue(probe.contains("private let runCount = max(1, Int(environment[\"KLMS_MAC_TAB_PROBE_RUNS\"]"))
        XCTAssertTrue(probe.contains("private let averageLimit = Double(environment[\"KLMS_MAC_TAB_AVERAGE_LIMIT_MS\"]"))
        XCTAssertTrue(probe.contains("private let slowestLimit = Double(environment[\"KLMS_MAC_TAB_SLOWEST_LIMIT_MS\"]"))
        XCTAssertTrue(probe.contains("== probe \\(runIndex)/\\(runCount) =="))
        XCTAssertTrue(probe.contains("series_average=\\(Int(seriesAverage.rounded()))ms"))
        XCTAssertTrue(probe.contains("worst_run_average=\\(Int(worstAverage.rounded()))ms"))
        XCTAssertTrue(probe.contains("case performanceLimitExceeded(String)"))
        XCTAssertTrue(probe.contains("average=\\(Int(average.rounded()))ms"))
        XCTAssertTrue(probe.contains("private struct ProbeRunResult"))
        XCTAssertTrue(probe.contains("private func runSingleProbe(appElement: AXUIElement) throws -> ProbeRunResult"))
        XCTAssertTrue(probe.contains("ProbeTarget(rawValue: \"activityLogs\")"))
        XCTAssertTrue(probe.contains("ProbeTarget(rawValue: \"diagnostics\")"))
        XCTAssertTrue(probe.contains("var selectionIdentifier: String { \"workspace-container-marker-\\(rawValue)\" }"))
        XCTAssertFalse(probe.contains("var contentIdentifier: String"))
        XCTAssertTrue(probe.contains("let requiredIdentifiers = [target.selectionIdentifier]"))
        XCTAssertTrue(probe.contains("waitForElements(withIdentifiers: requiredIdentifiers, in: appElement, timeout: timeout)"))
        XCTAssertTrue(probe.contains("private func findIdentifiers("))
        XCTAssertTrue(probe.contains("workspaceContentMissing(String)"))
        XCTAssertFalse(probe.contains("waitForSelectedValue(on element: AXUIElement"))
        XCTAssertTrue(probe.contains("findElement(in: root, maxDepth: 32, maxNodes: 35_000, predicate:"))
        XCTAssertTrue(probe.contains("value == expected || value == \"\\(expected):\""))
        XCTAssertFalse(probe.contains("value.contains(expected)"))
        XCTAssertTrue(probe.contains("private func runProbe() throws"))
        XCTAssertTrue(probe.contains("bringKLMSAppForward(app: app, appElement: appElement)"))
        XCTAssertTrue(probe.contains("activateApplicationBundle()"))
        XCTAssertTrue(probe.contains("process.executableURL = URL(fileURLWithPath: \"/usr/bin/open\")"))
        XCTAssertTrue(probe.contains("process.arguments = [\"-b\", bundleID]"))
        XCTAssertTrue(probe.contains("activateApplicationWithAppleScript()"))
        XCTAssertTrue(probe.contains("app.activate(options: [.activateAllWindows])"))
        XCTAssertFalse(probe.contains(".activateIgnoringOtherApps"))
        XCTAssertTrue(probe.contains("AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)"))
        XCTAssertTrue(probe.contains("sessionDiagnostics()"))
        XCTAssertTrue(probe.contains("CGSessionCopyCurrentDictionary()"))
        XCTAssertTrue(probe.contains("frontmost-app name="))
        XCTAssertTrue(probe.contains("probe failed: \\(error)"))
        XCTAssertTrue(probe.contains("visibleWindowDiagnostics()"))
        XCTAssertTrue(probe.contains("accessibilityTreeUnavailable(frontmostApp: String?)"))
        XCTAssertTrue(probe.contains("hasUsableAccessibilityWindow(in: appElement)"))
        XCTAssertTrue(probe.contains("FileHandle.standardError.write"))
        XCTAssertTrue(probe.contains("var stack: [(AXUIElement, Int)]"))
        XCTAssertTrue(probe.contains("var visited = Set<CFHashCode>()"))
        XCTAssertTrue(probe.contains("childElements(of: element).reversed()"))
        XCTAssertTrue(probe.contains("kAXWindowsAttribute as CFString"))
        XCTAssertTrue(probe.contains("\"AXVisibleChildren\" as CFString"))
        XCTAssertFalse(probe.contains("queue.removeFirst()"))
    }

    func testIOSDeviceInstallHelperWaitsForUnavailableDevices() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repoRoot = packageRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildScriptRoot = repoRoot.appendingPathComponent("tools/build_klms_ios_device.sh")
        let installScriptRoot = repoRoot.appendingPathComponent("tools/install_klms_ios_device.sh")
        let launchCheckScriptRoot = repoRoot.appendingPathComponent("tools/verify_klms_ios_device_launch.sh")
        let readinessScriptRoot = repoRoot.appendingPathComponent("tools/verify_klms_app_readiness.sh")
        let readmeRoot = packageRoot.appendingPathComponent("README.md")
        let buildScript = try String(contentsOf: buildScriptRoot, encoding: .utf8)
        let installScript = try String(contentsOf: installScriptRoot, encoding: .utf8)
        let launchCheckScript = try String(contentsOf: launchCheckScriptRoot, encoding: .utf8)
        let readinessScript = try String(contentsOf: readinessScriptRoot, encoding: .utf8)
        let readme = try String(contentsOf: readmeRoot, encoding: .utf8)

        XCTAssertTrue(buildScript.contains("BUILD_LOG=\"${IOS_DEVICE_BUILD_LOG:-$(mktemp -t klms-ios-device-build.XXXXXX)}\""))
        XCTAssertTrue(buildScript.contains("sanitize_xcodebuild_output()"))
        XCTAssertTrue(buildScript.contains("2>&1 | sanitize_xcodebuild_output | tee \"$BUILD_LOG\""))
        XCTAssertTrue(buildScript.contains("KLMS_REPO_ROOT=\"$ROOT_DIR\""))
        XCTAssertTrue(buildScript.contains("<repo-root>"))
        XCTAssertTrue(buildScript.contains("<home>"))
        XCTAssertTrue(buildScript.contains("Apple Development: <redacted>"))
        XCTAssertTrue(buildScript.contains("<app-identifier>"))
        XCTAssertTrue(buildScript.contains("<bundle-id>"))
        XCTAssertTrue(buildScript.contains("<email>"))
        XCTAssertTrue(buildScript.contains("<provisioning-profile-id>"))
        XCTAssertTrue(buildScript.contains("xcodebuild_status=${pipestatus[1]}"))
        XCTAssertTrue(buildScript.contains("IOS_ALLOW_PROVISIONING_UPDATES"))
        XCTAssertTrue(buildScript.contains("XCODEBUILD_PROVISIONING_ARGS=(-allowProvisioningUpdates)"))
        XCTAssertTrue(buildScript.contains("\"${XCODEBUILD_PROVISIONING_ARGS[@]}\""))
        XCTAssertTrue(buildScript.contains("Xcode signing credentials are not usable"))
        XCTAssertTrue(buildScript.contains("Invalid credentials in keychain|missing Xcode-Username"))
        XCTAssertTrue(buildScript.contains("update apps/KLMSync/Config/KLMSiOS.local.xcconfig with that account's Team ID and a unique bundle identifier"))
        XCTAssertTrue(buildScript.contains("xcconfig_value()"))
        XCTAssertTrue(buildScript.contains("Local iOS signing config is missing a real KLMS_IOS_DEVELOPMENT_TEAM"))
        XCTAssertTrue(buildScript.contains("Local iOS signing config is missing a unique KLMS_IOS_BUNDLE_IDENTIFIER"))
        XCTAssertTrue(buildScript.contains("\"$local_team\" == \"YOURTEAMID\""))
        XCTAssertTrue(buildScript.contains("\"$local_bundle\" == \"com.example.KLMSync.iOS\""))
        XCTAssertTrue(buildScript.contains("\"$local_bundle\" == \"com.local.KLMSync.iOS\""))
        XCTAssertTrue(buildScript.contains("Full xcodebuild log: $BUILD_LOG"))
        XCTAssertTrue(installScript.contains("WAIT_FOR_AVAILABLE_SECONDS=\"${IOS_DEVICE_WAIT_FOR_AVAILABLE_SECONDS:-45}\""))
        XCTAssertTrue(installScript.contains("DISCOVERY_POLL_SECONDS=\"${IOS_DEVICE_DISCOVERY_POLL_SECONDS:-3}\""))
        XCTAssertTrue(installScript.contains("LAUNCH_RETRY_COUNT=\"${IOS_DEVICE_LAUNCH_RETRIES:-2}\""))
        XCTAssertTrue(installScript.contains("LAUNCH_RETRY_DELAY_SECONDS=\"${IOS_DEVICE_LAUNCH_RETRY_DELAY_SECONDS:-2}\""))
        XCTAssertTrue(installScript.contains("TUNNEL_WARMUP_SECONDS=\"${IOS_DEVICE_TUNNEL_WARMUP_SECONDS:-15}\""))
        XCTAssertTrue(installScript.contains("IOS_DEVICE_OPEN_SETTINGS_ON_BLOCKED"))
        XCTAssertTrue(installScript.contains("IOS_DEVICE_TRUST_RETRY_SECONDS"))
        XCTAssertTrue(installScript.contains("IOS_DEVICE_TRUST_RETRY_POLL_SECONDS"))
        XCTAssertTrue(installScript.contains("open_device_settings_for_trust()"))
        XCTAssertTrue(installScript.contains("retry_launch_after_trust()"))
        XCTAssertTrue(installScript.contains("waiting up to ${TRUST_RETRY_SECONDS}s for developer trust"))
        XCTAssertTrue(installScript.contains("com.apple.Preferences"))
        XCTAssertTrue(installScript.contains("opened Settings on the device for developer trust"))
        XCTAssertTrue(installScript.contains("warm_device_connection()"))
        XCTAssertTrue(installScript.contains("current_epoch_seconds()"))
        XCTAssertTrue(installScript.contains("/bin/date +%s"))
        XCTAssertTrue(installScript.contains("wait_for_ios_devices()"))
        XCTAssertTrue(installScript.contains("discovered_devices=\"$(wait_for_ios_devices)\""))
        XCTAssertTrue(installScript.contains("discovery_status=$?"))
        XCTAssertTrue(installScript.contains("quiet_unavailable"))
        XCTAssertTrue(installScript.contains("launch_ready = tunnel_state == \"connected\""))
        XCTAssertTrue(installScript.contains("device_label=\"${device_rest%%$'\\t'*}\""))
        XCTAssertTrue(installScript.contains("install_one_device \"$target_device\" \"$device_label\" \"$launch_ready\""))
        XCTAssertTrue(installScript.contains("Waiting up to ${WAIT_FOR_AVAILABLE_SECONDS}s for an unlocked iPhone/iPad to become available"))
        XCTAssertTrue(installScript.contains("MANUAL_LAUNCH_STATUS=4"))
        XCTAssertTrue(installScript.contains("BLOCKED_LAUNCH_STATUS=5"))
        XCTAssertTrue(installScript.contains("launched_count=$(( launched_count + 1 ))"))
        XCTAssertTrue(installScript.contains("installed_only_count=$(( installed_only_count + 1 ))"))
        XCTAssertTrue(installScript.contains("installed_count=$(( installed_count + 1 ))"))
        XCTAssertTrue(installScript.contains("pending_launch_count=$(( pending_launch_count + 1 ))"))
        XCTAssertTrue(installScript.contains("blocked_launch_count=$(( blocked_launch_count + 1 ))"))
        XCTAssertTrue(installScript.contains("manual_launch_count=$(( manual_launch_count + 1 ))"))
        XCTAssertTrue(installScript.contains("install-summary installed=${installed_count} launched=${launched_count} installed_only=${installed_only_count} pending=${pending_launch_count} blocked=${blocked_launch_count} manual_launch_needed=${manual_launch_count} failed=${failed_count}"))
        XCTAssertTrue(installScript.contains("LaunchServicesDataMismatch|LaunchServices GUID"))
        XCTAssertTrue(installScript.contains("launch verification is waiting for iOS app registration"))
        XCTAssertTrue(installScript.contains("profile has not been explicitly trusted"))
        XCTAssertTrue(installScript.contains("Settings > General > VPN & Device Management"))
        XCTAssertTrue(
            installScript.range(of: "installed; launch-check blocked")!.lowerBound
                < installScript.range(of: "installed; launch-check pending")!.lowerBound
        )
        XCTAssertTrue(installScript.contains("installed; launch-check pending"))
        XCTAssertTrue(installScript.contains("installed; launch-check blocked"))
        XCTAssertTrue(installScript.contains("rerun this install command"))
        XCTAssertFalse(installScript.contains("RequestDenied|Security"))
        XCTAssertFalse(installScript.contains("EPOCHSECONDS"))
        XCTAssertFalse(installScript.contains("klms-ios-devices.XXXXXX.json"))
        XCTAssertTrue(launchCheckScript.contains("DEVICE_IDENTIFIER=\"${IOS_DEVICE_IDENTIFIER:-${1:-all}}\""))
        XCTAssertTrue(launchCheckScript.contains("REQUIRED_DEVICE_TYPES=\"${IOS_DEVICE_REQUIRE_TYPES:-}\""))
        XCTAssertTrue(launchCheckScript.contains("TUNNEL_WARMUP_SECONDS=\"${IOS_DEVICE_TUNNEL_WARMUP_SECONDS:-15}\""))
        XCTAssertTrue(launchCheckScript.contains("IOS_DEVICE_OPEN_SETTINGS_ON_BLOCKED"))
        XCTAssertTrue(launchCheckScript.contains("IOS_DEVICE_TRUST_RETRY_SECONDS"))
        XCTAssertTrue(launchCheckScript.contains("IOS_DEVICE_TRUST_RETRY_POLL_SECONDS"))
        XCTAssertTrue(launchCheckScript.contains("open_device_settings_for_trust()"))
        XCTAssertTrue(launchCheckScript.contains("retry_launch_after_trust()"))
        XCTAssertTrue(launchCheckScript.contains("waiting up to ${TRUST_RETRY_SECONDS}s for developer trust"))
        XCTAssertTrue(launchCheckScript.contains("com.apple.Preferences"))
        XCTAssertTrue(launchCheckScript.contains("opened Settings on the device for developer trust"))
        XCTAssertTrue(launchCheckScript.contains("warm_device_connection()"))
        XCTAssertTrue(launchCheckScript.contains("array_contains()"))
        XCTAssertTrue(launchCheckScript.contains("launch_ready = 1 if tunnel_state == \"connected\" else 0"))
        XCTAssertTrue(launchCheckScript.contains("launch-checking-${#device_entries[@]}-ios-devices"))
        XCTAssertTrue(launchCheckScript.contains("BLOCKED_LAUNCH_STATUS=5"))
        XCTAssertTrue(launchCheckScript.contains("pending_launch_count=$(( pending_launch_count + 1 ))"))
        XCTAssertTrue(launchCheckScript.contains("blocked_launch_count=$(( blocked_launch_count + 1 ))"))
        XCTAssertTrue(launchCheckScript.contains("launch-check-summary launched=${launched_count} launched_types=${(j:,:)launched_device_types} pending=${pending_launch_count} blocked=${blocked_launch_count} manual_launch_needed=${manual_launch_count} failed=${failed_count}"))
        XCTAssertTrue(launchCheckScript.contains("print -r -- \"${device_label}: launch-verified\""))
        XCTAssertTrue(launchCheckScript.contains("print -ru2 -- \"${device_label}: launch-check blocked"))
        XCTAssertTrue(launchCheckScript.contains("print -ru2 -- \"${device_label}: launch-check pending"))
        XCTAssertTrue(
            launchCheckScript.range(of: "launch-check blocked")!.lowerBound
                < launchCheckScript.range(of: "launch-check pending. Unlock")!.lowerBound
        )
        XCTAssertTrue(launchCheckScript.contains("launch-check missing"))
        XCTAssertTrue(launchCheckScript.contains("required_device_types=(\"${(@s:,:)REQUIRED_DEVICE_TYPES}\")"))
        XCTAssertTrue(launchCheckScript.contains("redact_bundle_id <\"$LAUNCH_OUTPUT\""))
        XCTAssertTrue(launchCheckScript.contains("print(f\"{identifier}\\t{hardware.get('deviceType', 'device')}\\t{launch_ready}\\t{tunnel_state}\")"))
        XCTAssertFalse(launchCheckScript.contains("RequestDenied|Security"))
        XCTAssertFalse(launchCheckScript.contains("properties.get(\"name\")"))
        XCTAssertTrue(readinessScript.contains("KLMS Sync readiness check"))
        XCTAssertTrue(readinessScript.contains("sanitize_output()"))
        XCTAssertTrue(readinessScript.contains("set -uo pipefail"))
        XCTAssertFalse(readinessScript.contains("set -euo pipefail"))
        XCTAssertTrue(readinessScript.contains("record_step \"swift-tests\""))
        XCTAssertTrue(readinessScript.contains("record_step \"mac-build\""))
        XCTAssertTrue(readinessScript.contains("record_step \"mac-relaunch\""))
        XCTAssertTrue(readinessScript.contains("relaunch_mac_app()"))
        XCTAssertTrue(readinessScript.contains("mac-build|mac-relaunch|mac-accessibility-smoke|mac-basic-actions|mac-tab-response"))
        XCTAssertTrue(readinessScript.contains("record_step \"mac-accessibility-smoke\""))
        XCTAssertTrue(readinessScript.contains("record_step \"mac-basic-actions\""))
        XCTAssertTrue(readinessScript.contains("record_step \"mac-tab-response\""))
        XCTAssertTrue(readinessScript.contains("record_step \"ios-signed-build\""))
        XCTAssertTrue(readinessScript.contains("record_step \"ios-device-launch\""))
        XCTAssertTrue(readinessScript.contains("IOS_DEVICE_REQUIRE_TYPES=iPhone,iPad"))
        XCTAssertTrue(readinessScript.contains("print_failure_hint()"))
        XCTAssertTrue(readinessScript.contains("ios-device-launch:4"))
        XCTAssertTrue(readinessScript.contains("ios-device-launch:5"))
        XCTAssertTrue(readinessScript.contains("iOS build and signing are ready, but device trust is blocked"))
        XCTAssertTrue(readinessScript.contains("return 0"))
        XCTAssertTrue(readinessScript.contains("readiness-summary status=ok swift_tests=${swift_state} mac=${mac_state} ios_build=${ios_build_state} ios_launch=${ios_launch_state}"))
        XCTAssertTrue(readinessScript.contains("readiness-summary status=fail swift_tests=${swift_state} mac=${mac_state} ios_build=${ios_build_state} ios_launch=${ios_launch_state}"))
        XCTAssertTrue(readinessScript.contains("ios_launch_state=\"skipped\""))
        XCTAssertTrue(readinessScript.contains("swift_state=\"failed\""))
        XCTAssertTrue(readinessScript.contains("mac_state=\"failed\""))
        XCTAssertTrue(readinessScript.contains("ios_build_state=\"failed\""))
        XCTAssertTrue(readinessScript.contains("ios_launch_state=\"failed\""))
        XCTAssertTrue(readinessScript.contains("<repo-root>"))
        XCTAssertTrue(readinessScript.contains("<home>"))
        XCTAssertTrue(readinessScript.contains("<bundle-id>"))
        XCTAssertFalse(readinessScript.contains("local status="))

        XCTAssertTrue(readme.contains("waits up to 45 seconds for paired iPhone/iPad devices to become available"))
        XCTAssertTrue(readme.contains("IOS_DEVICE_WAIT_FOR_AVAILABLE_SECONDS=0"))
        XCTAssertTrue(readme.contains("IOS_ALLOW_PROVISIONING_UPDATES=1 tools/build_klms_ios_device.sh"))
        XCTAssertTrue(readme.contains("If the signed build says `No Accounts`, `Invalid credentials in keychain`, or `No profiles for ...`"))
        XCTAssertTrue(readme.contains("uses that account's current Team ID and a unique bundle identifier"))
        XCTAssertTrue(readme.contains("Device build output is sanitized by default."))
        XCTAssertTrue(readme.contains("Local home/repo paths"))
        XCTAssertTrue(readme.contains("Team IDs, app identifiers, provisioning profile IDs, signing hashes, and account emails are replaced with placeholders"))
        XCTAssertTrue(readme.contains("validates `Config/KLMSiOS.local.xcconfig` before it starts `xcodebuild`"))
        XCTAssertTrue(readme.contains("The install helper builds first by default"))
        XCTAssertTrue(readme.contains("install-summary installed=... launched=... installed_only=... pending=... blocked=... manual_launch_needed=... failed=..."))
        XCTAssertTrue(readme.contains("IOS_DEVICE_LAUNCH_RETRIES"))
        XCTAssertTrue(readme.contains("IOS_DEVICE_LAUNCH_RETRY_DELAY_SECONDS"))
        XCTAssertTrue(readme.contains("It still exits non-zero when a requested launch could not be verified."))
        XCTAssertTrue(readme.contains("installed; launch-check pending"))
        XCTAssertTrue(readme.contains("IOS_DEVICE_TUNNEL_WARMUP_SECONDS"))
        XCTAssertTrue(readme.contains("IOS_DEVICE_OPEN_SETTINGS_ON_BLOCKED=0"))
        XCTAssertTrue(readme.contains("IOS_DEVICE_OPEN_SETTINGS_TIMEOUT_SECONDS"))
        XCTAssertTrue(readme.contains("IOS_DEVICE_TRUST_RETRY_SECONDS"))
        XCTAssertTrue(readme.contains("IOS_DEVICE_TRUST_RETRY_POLL_SECONDS"))
        XCTAssertTrue(readme.contains("installed; launch-check blocked"))
        XCTAssertTrue(readme.contains("iOS is still refreshing app registration"))
        XCTAssertTrue(readme.contains("Settings > General > VPN & Device Management"))
        XCTAssertTrue(readme.contains("trust the developer app"))
        XCTAssertTrue(readme.contains("the app is already installed"))
        XCTAssertTrue(readme.contains("rerun the same install command"))
        XCTAssertTrue(readme.contains("tools/verify_klms_app_readiness.sh"))
        XCTAssertTrue(readme.contains("requires both an iPhone and an iPad"))
        XCTAssertTrue(readme.contains("Mac accessibility smoke"))
        XCTAssertTrue(readme.contains("Mac tab-response probe"))
        XCTAssertTrue(readme.contains("signed iOS build"))
        XCTAssertTrue(readme.contains("tools/verify_klms_ios_device_launch.sh"))
        XCTAssertTrue(readme.contains("launch-check-summary launched=... launched_types=... pending=... blocked=... manual_launch_needed=... failed=..."))
        XCTAssertTrue(readme.contains("Xcode account login and iOS device trust are separate"))
        XCTAssertTrue(readme.contains("IOS_DEVICE_REQUIRE_TYPES=iPhone,iPad"))
        XCTAssertTrue(readme.contains("redacts that identifier from error output"))
    }

    func testMacDashboardWindowFollowsApprovedWorkstationMockup() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appRoot = packageRoot.appendingPathComponent("Sources/KLMSMac/KLMSMacApp.swift")
        let viewRoot = packageRoot.appendingPathComponent("Sources/KLMSMac/MenuBarRootView.swift")
        let detailRoot = packageRoot.appendingPathComponent("Sources/KLMSMac/DashboardDetailView.swift")
        let modelRoot = packageRoot.appendingPathComponent("Sources/KLMSMac/KLMSMacModel.swift")
        let app = try String(contentsOf: appRoot, encoding: .utf8)
        let view = try String(contentsOf: viewRoot, encoding: .utf8)
        let detail = try String(contentsOf: detailRoot, encoding: .utf8)
        let macModel = try String(contentsOf: modelRoot, encoding: .utf8)
        let workstationLayout = try sourceStructBody(named: "MacWorkstationLayoutView", in: view)
        let dashboardSummaryContent = try sourceStructBody(named: "DashboardSummaryContentView", in: view)
        let navigationView = try sourceStructBody(named: "WorkspaceNavigationView", in: view)
        let macAlertBannerTone = try sourceBody(
            after: "private enum MacAlertBannerTone",
            in: view,
            description: "Mac alert banner tone"
        )
        let commandPanel = try sourceStructBody(named: "CommandPanelView", in: view)
        let metricGrid = try sourceBody(
            after: "struct MetricGrid: View",
            in: view,
            description: "Mac metric grid"
        )
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
        let logTextBlock = try sourceStructBody(named: "LogTextBlock", in: view)
        let logSummaryDetail = try sourceStructBody(named: "LogSummaryDetailView", in: view)
        let currentRunLogCard = try sourceStructBody(named: "CurrentRunLogCardView", in: view)
        let dashboardRuntimePanel = try sourceStructBody(named: "DashboardRuntimePanelView", in: view)
        let dashboardFilterBar = try sourceStructBody(named: "DashboardFilterBarView", in: detail)
        let dashboardControlBox = try sourceBody(
            after: "private struct DashboardControlBox<Content: View>: View",
            in: detail,
            description: "dashboard filter control box"
        )
        let dashboardRangeField = try sourceBody(
            after: "private struct DashboardRangeField<Content: View>: View",
            in: detail,
            description: "dashboard filter range field"
        )
        let noticeListView = try sourceStructBody(named: "NoticeListView", in: detail)
        let stateItemRowView = try sourceStructBody(named: "StateItemRowView", in: detail)
        let noticeRowView = try sourceStructBody(named: "NoticeRowView", in: detail)
        let fileRowView = try sourceStructBody(named: "FileRowView", in: detail)
        let noticeBaseSignature = try sourceBody(
            after: "private struct NoticeDashboardBaseInputSignature: Equatable",
            in: detail,
            description: "notice dashboard base signature"
        )
        let noticeCategoryPickerView = try sourceStructBody(named: "NoticeCategoryPickerView", in: detail)
        let yearFieldIndex = try XCTUnwrap(dashboardFilterBar.range(of: "yearPickerField")?.lowerBound)
        let semesterFieldIndex = try XCTUnwrap(dashboardFilterBar.range(of: "semesterPickerField")?.lowerBound)
        let courseFieldIndex = try XCTUnwrap(dashboardFilterBar.range(of: "coursePickerField")?.lowerBound)

        XCTAssertTrue(app.contains("MenuBarRootView(model: model)"))
        XCTAssertTrue(dashboardRuntimePanel.contains("@State private var isExpanded = false"))
        XCTAssertFalse(dashboardRuntimePanel.contains("@AppStorage(\"KLMSMacRuntimePanelExpanded\")"))
        XCTAssertLessThan(dashboardFilterBar.distance(from: dashboardFilterBar.startIndex, to: yearFieldIndex), dashboardFilterBar.distance(from: dashboardFilterBar.startIndex, to: courseFieldIndex))
        XCTAssertLessThan(dashboardFilterBar.distance(from: dashboardFilterBar.startIndex, to: semesterFieldIndex), dashboardFilterBar.distance(from: dashboardFilterBar.startIndex, to: courseFieldIndex))
        XCTAssertTrue(dashboardFilterBar.contains("filterHeader"))
        XCTAssertTrue(dashboardFilterBar.contains("searchControl"))
        XCTAssertTrue(dashboardFilterBar.contains("rangeControl"))
        XCTAssertTrue(dashboardFilterBar.contains("displayControl"))
        XCTAssertFalse(dashboardFilterBar.contains("@State private var isExpanded"))
        XCTAssertFalse(dashboardFilterBar.contains("collapsedActiveFilterSummary"))
        XCTAssertFalse(dashboardFilterBar.contains("DashboardFilterExpansionBadge"))
        XCTAssertFalse(detail.contains("private struct DashboardFilterExpansionBadge"))
        XCTAssertFalse(dashboardControlBox.contains(".stroke(Color.klmsMacBorder"))
        XCTAssertFalse(dashboardControlBox.contains(".background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle"))
        XCTAssertFalse(dashboardRangeField.contains(".stroke(Color.klmsMacBorder"))
        XCTAssertTrue(dashboardRangeField.contains("HStack(alignment: .center"))
        XCTAssertTrue(dashboardRangeField.contains(".frame(minWidth: minWidth, minHeight: 34, maxHeight: 40, alignment: .leading)"))
        XCTAssertFalse(dashboardRangeField.contains("VStack(alignment: .leading, spacing: 5)"))
        XCTAssertTrue(detail.contains("private func noticeMatchesDashboardBaseFilters("))
        XCTAssertTrue(noticeListView.contains("@State private var presentation: NoticeDashboardPresentation"))
        XCTAssertTrue(noticeListView.contains("@State private var presentationSignature: NoticeDashboardInputSignature?"))
        XCTAssertTrue(noticeListView.contains("@State private var renderedFilters: DashboardDetailFilters?"))
        XCTAssertTrue(noticeListView.contains("@State private var presentationTask: Task<Void, Never>?"))
        XCTAssertTrue(noticeListView.contains("@State private var isPreparingPresentation = true"))
        XCTAssertTrue(noticeListView.contains("_presentation = State(initialValue: NoticeDashboardPresentation())"))
        XCTAssertTrue(noticeListView.contains("DashboardListPreparingView(text: \"공지 목록을 준비하는 중입니다.\")"))
        XCTAssertTrue(detail.contains("static let filterRebuildDelayNanoseconds: UInt64 = 8_000_000"))
        XCTAssertTrue(detail.contains("func shouldDebounceComparedTo(_ previous: DashboardDetailFilters?) -> Bool"))
        XCTAssertTrue(detail.contains("previous.searchText = searchText"))
        XCTAssertTrue(detail.contains("let shouldDelay = !isPreparingPresentation && filters.shouldDebounceComparedTo(renderedFilters)"))
        XCTAssertTrue(detail.contains("try? await Task.sleep(nanoseconds: DashboardLargeList.filterRebuildDelayNanoseconds)"))
        XCTAssertFalse(noticeListView.contains("_presentation = State(initialValue: NoticeDashboardPresentation(category: defaultCategory, filters: filters, snapshot: snapshot))"))
        XCTAssertTrue(noticeListView.contains("private var inputBaseSignature: NoticeDashboardBaseInputSignature"))
        XCTAssertTrue(noticeListView.contains("NoticeDashboardInputSignature(category: category, baseSignature: inputBaseSignature)"))
        XCTAssertTrue(noticeListView.contains("rebuildPresentationIfNeeded"))
        XCTAssertFalse(noticeListView.contains("await Task.yield()"))
        XCTAssertFalse(noticeListView.contains("let presentation = noticePresentation"))
        XCTAssertFalse(noticeListView.contains("private var noticePresentation"))
        XCTAssertTrue(noticeListView.contains("NoticeCategoryPickerView(\n                category: $category,\n                counts: presentation.counts"))
        XCTAssertTrue(noticeListView.contains("noticeRows(presentation.notices)"))
        XCTAssertTrue(noticeRowView.contains("작업 \\(isExpanded ? \"펼쳐짐\" : \"접힘\")"))
        XCTAssertTrue(noticeRowView.contains(".accessibilityHint(isExpanded ? \"공지 작업 접기\" : \"공지 작업 펼치기\")"))
        XCTAssertFalse(noticeRowView.contains("작업 \\(isExpanded ? \"접기\" : \"작업 펼치기\")"))
        XCTAssertTrue(detail.contains("private struct NoticeDashboardBaseInputSignature: Equatable"))
        XCTAssertTrue(detail.contains("private struct NoticeDashboardInputSignature: Equatable"))
        XCTAssertTrue(detail.contains("private struct NoticeDashboardPresentation: Sendable"))
        XCTAssertTrue(noticeBaseSignature.contains("Self.combineNoticeSignatureSamples(notices, into: &hasher)"))
        XCTAssertTrue(noticeBaseSignature.contains("private static func combineNoticeSignatureSamples"))
        XCTAssertTrue(noticeBaseSignature.contains("for index in notices.indices.prefix(4)"))
        XCTAssertTrue(noticeBaseSignature.contains("for index in notices.indices.suffix(4)"))
        XCTAssertFalse(noticeBaseSignature.contains("for (index, notice) in notices.enumerated()"))
        XCTAssertTrue(noticeBaseSignature.contains("var stateFingerprint = 0"))
        XCTAssertTrue(noticeBaseSignature.contains("stateFingerprint ^= itemHasher.finalize()"))
        XCTAssertFalse(noticeBaseSignature.contains(".sorted(by:"))
        XCTAssertTrue(detail.contains("init(category: NoticeListCategory, filters: DashboardDetailFilters, snapshot: EngineSnapshot)"))
        XCTAssertTrue(detail.contains("let normalizedQuery = filters.searchText.trimmingCharacters(in: .whitespacesAndNewlines)"))
        XCTAssertTrue(detail.contains("normalizedQuery: normalizedQuery"))
        XCTAssertTrue(detail.contains("normalizedQuery query: String"))
        XCTAssertFalse(detail.contains("var searchableFields = [term?.displayName ?? \"\", notice.title, notice.course, notice.postedAt, notice.summary, notice.url]"))
        XCTAssertFalse(detail.contains(".joined(separator: \" \")\n        .localizedCaseInsensitiveContains(query)"))
        XCTAssertTrue(noticeListView.contains("let nextPresentation = await Task.detached(priority: .userInitiated)"))
        XCTAssertTrue(noticeListView.contains("presentation = nextPresentation"))
        XCTAssertTrue(noticeListView.contains("renderedFilters = filters"))
        XCTAssertTrue(detail.contains("var counts: [NoticeListCategory: Int]"))
        XCTAssertTrue(detail.contains("counts[item, default: 0] += 1"))
        XCTAssertTrue(noticeCategoryPickerView.contains("var counts: [NoticeListCategory: Int]"))
        XCTAssertTrue(noticeCategoryPickerView.contains("counts[item, default: 0]"))
        XCTAssertFalse(noticeCategoryPickerView.contains("private func count(for category"))
        XCTAssertTrue(app.contains("KLMSMacWorkspaceRootContainerView(model: model)"))
        XCTAssertFalse(app.contains("@objc(KLMSApplication)"))
        XCTAssertFalse(app.contains("final class KLMSApplication: NSApplication"))
        XCTAssertFalse(app.contains("override func sendEvent(_ event: NSEvent)"))
        XCTAssertFalse(app.contains("private static func isQuitShortcut(_ event: NSEvent) -> Bool"))
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
        XCTAssertTrue(app.contains("@MainActor\n    static func main()"))
        XCTAssertTrue(app.contains("KLMSLaunchState.clearSavedApplicationState()"))
        XCTAssertTrue(app.contains("UserDefaults.standard.set(false, forKey: \"NSQuitAlwaysKeepsWindows\")"))
        XCTAssertTrue(app.contains("app.finishLaunching()"))
        XCTAssertTrue(app.contains("app.run()"))
        XCTAssertFalse(app.contains("NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)"))
        XCTAssertFalse(app.contains("DispatchQueue.main.async {\n            KLMSDashboardWindowCoordinator.shared.showIfNoVisibleDashboardWindow()"))
        XCTAssertTrue(app.contains("KLMSDashboardWindowCoordinator.shared.showDashboardWindow()"))
        XCTAssertTrue(app.contains("func applicationDidBecomeActive"))
        XCTAssertTrue(app.contains("KLMSDashboardWindowCoordinator.shared.showDashboardWindow()"))
        XCTAssertTrue(app.contains("KLMSDashboardWindowCoordinator.shared.setModel(model)"))
        XCTAssertTrue(app.contains("static let initialWidth: CGFloat = 1080"))
        XCTAssertTrue(app.contains("static let minWidth: CGFloat = 540"))
        XCTAssertTrue(app.contains("configureApplicationMenu()"))
        XCTAssertTrue(app.contains("NSApp.mainMenu = mainMenu"))
        XCTAssertTrue(app.contains("NSMenuItem(title: \"KLMS Sync 종료\", action: #selector(NSApplication.terminate(_:)), keyEquivalent: \"q\")"))
        XCTAssertTrue(app.contains("quitItem.keyEquivalentModifierMask = [.command]"))
        XCTAssertTrue(app.contains("quitItem.target = NSApp"))
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
        XCTAssertFalse(buildScript.contains("<key>NSPrincipalClass</key>"))
        XCTAssertFalse(buildScript.contains("<string>KLMSApplication</string>"))
        XCTAssertTrue(buildScript.contains("<key>NSQuitAlwaysKeepsWindows</key>"))
        XCTAssertTrue(buildScript.contains("<false/>"))
        XCTAssertTrue(app.contains("func scheduleBootstrapIfNeeded(delay: TimeInterval = 0.2)"))
        XCTAssertTrue(app.contains("scheduleBootstrapIfNeeded(delay: 2.5)"))
        XCTAssertTrue(app.contains("func applicationShouldHandleReopen"))
        XCTAssertFalse(app.contains("if !KLMSDashboardWindowCoordinator.shared.hasVisibleDashboardWindow"))
        XCTAssertTrue(app.contains("KLMSDashboardWindowCoordinator.shared.showDashboardWindow()\n        return false"))
        XCTAssertFalse(app.contains("func applicationShouldOpenUntitledFile"))
        XCTAssertFalse(app.contains("func applicationOpenUntitledFile"))
        XCTAssertTrue(app.contains("var hasVisibleDashboardWindow: Bool"))
        XCTAssertTrue(app.contains("window.identifier?.rawValue == KLMSMacWindowID.dashboard"))
        XCTAssertTrue(app.contains("window.frame.width >= KLMSWindowMetrics.minWidth"))
        XCTAssertTrue(app.contains("window.identifier = NSUserInterfaceItemIdentifier(KLMSMacWindowID.dashboard)"))
        XCTAssertTrue(app.contains("window.setAccessibilityIdentifier(KLMSMacWindowID.dashboard)"))
        XCTAssertFalse(app.contains("window.setAccessibilityElement(true)"))
        XCTAssertFalse(app.contains("window.setAccessibilityRole(.window)"))
        XCTAssertFalse(app.contains("window.setAccessibilityTitle(\"KLMS Sync\")"))
        XCTAssertTrue(app.contains("hostingController.view.setAccessibilityIdentifier(\"klms-dashboard-root\")"))
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
        XCTAssertTrue(rootActionButtonStyle.contains(".frame(minWidth: 40, minHeight: 40)"))
        XCTAssertTrue(actionButtonStyle.contains(".frame(minWidth: 40, minHeight: 40)"))
        XCTAssertTrue(iconButtonStyle.contains(".frame(width: 44, height: 44)"))
        XCTAssertTrue(stateItemRowView.contains(".contentShape(Rectangle())"))
        XCTAssertTrue(noticeRowView.contains(".contentShape(Rectangle())"))
        XCTAssertTrue(fileRowView.contains(".contentShape(Rectangle())"))

        XCTAssertFalse(view.contains("DashboardLogSummaryPanelView"))
        XCTAssertFalse(dashboardSummaryContent.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertFalse(dashboardSummaryContent.contains("DashboardLogSummaryPanelView(model: model)"))
        XCTAssertFalse(dashboardSummaryContent.contains(".frame(width: 285, alignment: .topLeading)"))
        XCTAssertTrue(dashboardSummaryContent.contains("@State private var renderedDetail: DashboardDetailKind?"))
        XCTAssertTrue(dashboardSummaryContent.contains("@State private var detailRenderTask: Task<Void, Never>?"))
        XCTAssertTrue(dashboardSummaryContent.contains("dashboardDetailContent(renderedDetail: currentRenderedDetail)"))
        XCTAssertFalse(dashboardSummaryContent.contains("@State private var displayedDetail"))
        XCTAssertFalse(dashboardSummaryContent.contains("@State private var detailDisplayTask"))
        XCTAssertTrue(dashboardSummaryContent.contains("private func selectDashboardDetail"))
        XCTAssertTrue(dashboardSummaryContent.contains("await Task.yield()"))
        XCTAssertTrue(dashboardSummaryContent.contains("guard selectedDetail != detail || renderedDetail != detail else"))
        XCTAssertTrue(dashboardSummaryContent.contains("selectedDetail = detail"))
        XCTAssertTrue(dashboardSummaryContent.contains("guard !Task.isCancelled, selectedDetail == detail else { return }"))
        XCTAssertTrue(dashboardSummaryContent.contains("renderedDetail = detail"))
        XCTAssertFalse(dashboardSummaryContent.contains("""
        if displayedDetail == detail {
            detailDisplayTask = nil
            return
        }
        displayedDetail = nil
        """))
        XCTAssertTrue(metricGrid.contains("GridItem(.flexible(minimum: 128), spacing: 8)"))
        XCTAssertTrue(metricGrid.contains("let count = min(max(metrics.count, 1), 4)"))
        XCTAssertTrue(metricGrid.contains("@State private var hoveredMetricID"))
        XCTAssertTrue(metricGrid.contains("let isHovered = hoveredMetricID == metric.id"))
        XCTAssertTrue(metricGrid.contains("MetricTile(metric: metric, isSelected: isSelected, isHovered: isHovered && isInteractive)"))
        XCTAssertTrue(metricGrid.contains(".accessibilityLabel(\"\\(metric.label) \\(metric.value)개\")"))
        XCTAssertTrue(metricGrid.contains(".accessibilityValue(isSelected ? \"선택됨\" : \"선택 안 됨\")"))
        XCTAssertTrue(metricGrid.contains(".accessibilityHint(isInteractive ? \"\\(metric.label) 상세를 엽니다.\" : \"현재 상태만 표시합니다.\")"))
        XCTAssertTrue(metricGrid.contains(".accessibilityElement(children: .combine)"))
        XCTAssertTrue(metricGrid.contains(".onHover { hovering in"))
        XCTAssertFalse(metricGrid.contains("GridItem(.adaptive(minimum: 108)"))
        XCTAssertFalse(view.contains("private var dashboardDetailPlaceholder"))
        XCTAssertTrue(view.contains("private struct DashboardDetailHint"))
        XCTAssertTrue(view.contains("카드를 누르면 바로 아래에서 목록과 처리 버튼을 확인할 수 있습니다."))
        XCTAssertFalse(view.contains("선택은 바로 반영했고, 큰 목록만 잠시 뒤에 불러옵니다."))
        XCTAssertFalse(view.contains("private func preferredDetail(in metrics: [Metric]) -> DashboardDetailKind?"))
        XCTAssertFalse(view.contains("metrics.first(where: { $0.detail == .files })?.detail"))
        XCTAssertTrue(view.contains("return nil"))
        XCTAssertTrue(view.contains("DashboardSummaryView(model: model)"))
        XCTAssertTrue(view.contains("CommandStageDurationSummaryView(durations: stageDurations)"))
        XCTAssertFalse(commandPanel.contains("DashboardStageDurationStripView(durations: stageDurations)"))
        XCTAssertFalse(commandPanel.contains("CommandStageDurationSummaryView(durations: stageDurations)"))
        XCTAssertFalse(view.contains("private struct DashboardStageDurationStripView"))
        XCTAssertFalse(commandPanel.contains("KLMSStageDurationParser.parse"))
        XCTAssertTrue(macModel.contains("@Published private(set) var liveStageDurations: [KLMSStageDuration] = []"))
        XCTAssertTrue(macModel.contains("@Published private(set) var latestCommandHistoryStageDurations: [KLMSStageDuration] = []"))
        XCTAssertTrue(macModel.contains("rebuildCommandHistoryStageDurationCache()"))
        XCTAssertTrue(macModel.contains("let nextStageDurations = KLMSStageDurationParser.parse(from: liveCommandOutputBuffer)"))
        XCTAssertTrue(macModel.contains("@Published private(set) var lastCommandDisplayOutput = \"\""))
        XCTAssertTrue(macModel.contains("rebuildLastCommandDisplayOutputCache()"))
        XCTAssertTrue(macModel.contains("private static func lastCommandDisplayOutput(from result: KLMSCommandResult?) -> String"))
        XCTAssertTrue(logSummaryDetail.contains("return model.lastCommandDisplayOutput"))
        XCTAssertTrue(currentRunLogCard.contains("return model.lastCommandDisplayOutput"))
        XCTAssertFalse(logSummaryDetail.contains("result.combinedOutput.klmsDisplayText"))
        XCTAssertFalse(currentRunLogCard.contains("result.combinedOutput.klmsDisplayText"))
        XCTAssertFalse(currentRunLogCard.contains("private static func boundedOutput"))
        XCTAssertTrue(view.contains("return model.latestCommandHistoryStageDurations"))
        XCTAssertFalse(view.contains("first(where: { !$0.outputTail.trimmingCharacters"))
        XCTAssertFalse(commandPanel.contains("private static func boundedStageDurationSource(_ output: String) -> String"))
        XCTAssertTrue(view.contains("DiagnosticStageDurationPanelView(model: model)"))
        XCTAssertTrue(view.contains("CompactStageDurationRowsView(durations: record.visibleStageDurations)"))
        let compactStageRowsEarly = try sourceStructBody(named: "CompactStageDurationRowsView", in: view)
        XCTAssertTrue(compactStageRowsEarly.contains("private static let visibleLimit = 4"))
        XCTAssertTrue(compactStageRowsEarly.contains("ForEach(visibleDurations)"))
        XCTAssertFalse(view.contains("KLMSStageDurationParser.parse(from: outputTail)"))
        XCTAssertFalse(commandPanel.contains("KLMSStageDurationParser.parse(from: model.liveCommandOutput)"))
        XCTAssertFalse(view.contains("? (model.lastCommandResult?.combinedOutput ?? \"\")"))
        XCTAssertTrue(view.contains("private struct MacAlertBannerView"))
        XCTAssertTrue(view.contains("private struct NextActionPanelView"))
        XCTAssertTrue(view.contains("minimumScaleFactor(0.86)"))
        XCTAssertTrue(view.contains("minimumScaleFactor(0.85)"))
        XCTAssertFalse(view.contains("private let klmsMacInteractionDetailDelayNanoseconds"))
        XCTAssertTrue(view.contains("@State private var isArchiveMetricsExpanded = false"))
        XCTAssertTrue(view.contains("private struct DashboardArchiveMetricSection"))
        XCTAssertTrue(view.contains(".accessibilityLabel(\"기록과 보관 \\(totalCount)개 \\(isExpanded ? \"펼쳐짐\" : \"접힘\")\")"))
        XCTAssertTrue(view.contains(".accessibilityHint(isExpanded ? \"기록과 보관 접기\" : \"기록과 보관 펼치기\")"))
        XCTAssertTrue(view.contains("archiveExpanded ? archiveMetrics : []"))
        XCTAssertTrue(view.contains("@State private var isHistoryExpanded = false"))
        XCTAssertTrue(view.contains("if !isHistoryExpanded"))
        XCTAssertTrue(view.contains("Text(\"\\(records.count)개\")"))
        XCTAssertTrue(view.contains("@State private var showingSystemLogs = false"))
        XCTAssertTrue(view.contains(".accessibilityLabel(\"실행 로그 지우기\")"))
        XCTAssertTrue(view.contains(".accessibilityLabel(\"서버 로그 지우기\")"))
        XCTAssertTrue(view.contains("private struct KLMSMacCompactDangerIconButtonStyle"))
        XCTAssertTrue(view.contains(".buttonStyle(KLMSMacCompactDangerIconButtonStyle())"))
        XCTAssertTrue(view.contains("if isHistoryExpanded {\n                    let summary = RunLogArchiveSummary(records: records)"))
        XCTAssertTrue(view.contains("if isHistoryExpanded {\n                let filtered = filteredRecords"))
        XCTAssertTrue(view.contains("private let primaryVisibleIssueCount = 1"))
        XCTAssertTrue(view.contains("VerifyDiagnosticSummary("))
        XCTAssertTrue(view.contains("DoctorDiagnosticSummary("))
        XCTAssertFalse(view.contains("let primaryIssues = Array(issueChecks.prefix(primaryVisibleIssueCount))"))
        XCTAssertFalse(view.contains("let remainingIssues = Array(issueChecks.dropFirst(primaryVisibleIssueCount))"))
        XCTAssertTrue(view.contains("title: \"원본 보기\""))
        XCTAssertTrue(view.contains("private struct DiagnosticChecksDisclosure"))
        XCTAssertTrue(view.contains("LogTextBlock(text: record.outputTail)"))
        XCTAssertTrue(logTextBlock.contains("title: \"원본 로그 보기\""))
        XCTAssertTrue(logTextBlock.contains("DiagnosticChecksDisclosure("))
        XCTAssertFalse(logTextBlock.contains("DisclosureGroup(isExpanded: $isRawExpanded)"))
        XCTAssertTrue(logTextBlock.contains("@State private var highlights: [KLMSLogHighlight]"))
        XCTAssertTrue(logTextBlock.contains("let boundedText = Self.boundedText(text, detailed: detailed)"))
        XCTAssertTrue(logTextBlock.contains("private let highlightSourceText: String"))
        XCTAssertTrue(logTextBlock.contains("self.highlightSourceText = Self.boundedHighlightSourceText(boundedText, detailed: detailed)"))
        XCTAssertTrue(logTextBlock.contains("self._highlights = State(initialValue: [])"))
        XCTAssertTrue(logTextBlock.contains(".task(id: highlightSourceText)"))
        XCTAssertTrue(logTextBlock.contains("Task.detached(priority: .utility)"))
        XCTAssertTrue(logTextBlock.contains("private static func boundedHighlightSourceText"))
        XCTAssertTrue(logTextBlock.contains("let maxCharacters = detailed ? 6_000 : 3_000"))
        XCTAssertTrue(logTextBlock.contains("let text = highlightSourceText"))
        XCTAssertFalse(logTextBlock.contains("self.highlights = KLMSReadableLogParser.highlights(from: boundedText)"))
        XCTAssertTrue(logTextBlock.contains("ReadableLogHighlightsView(highlights: highlights, detailed: detailed)"))
        XCTAssertFalse(logTextBlock.contains("ReadableLogHighlightsView(highlights: KLMSReadableLogParser.highlights"))
        XCTAssertTrue(app.contains(".onChange(of: appearanceMode)"))
        XCTAssertTrue(app.contains("Self.schedulePlatformAppearance(newValue)"))
        XCTAssertTrue(app.contains("NSApp.appearance = appearance"))
        XCTAssertTrue(app.contains("window.appearance = appearance"))
        XCTAssertTrue(app.contains("NSAppearance(named: .aqua)"))
        XCTAssertTrue(app.contains("NSAppearance(named: .darkAqua)"))
        XCTAssertFalse(view.contains("metric.systemImage"))
        XCTAssertFalse(view.contains("row.systemImage"))
        XCTAssertTrue(view.contains("\"gauge.with.dots.needle.67percent\""))
        XCTAssertTrue(view.contains("var chipText: String"))
        XCTAssertTrue(view.contains("return \"확인\""))
        XCTAssertFalse(workstationLayout.contains("@State private var displayedSection"))
        XCTAssertTrue(workstationLayout.contains("switch selectedSection"))
        XCTAssertFalse(workstationLayout.contains("deferDisplayedSection(newSection)"))
        XCTAssertTrue(workstationLayout.contains("case .settings:"))
        XCTAssertTrue(workstationLayout.contains("DeferredMacWorkspacePanel(id: \"workspace-dashboard\", contentIdentifier: \"workspace-content-dashboard\""))
        XCTAssertTrue(workstationLayout.contains("DashboardSummaryView(model: model)"))
        XCTAssertFalse(workstationLayout.contains("DeferredDashboardSummaryView"))
        XCTAssertTrue(workstationLayout.contains("id: \"workspace-files\""))
        XCTAssertTrue(workstationLayout.contains("id: \"workspace-tasks\""))
        XCTAssertTrue(workstationLayout.contains("contentDelayNanoseconds: MacWorkspacePanelTiming.heavyListContentDelayNanoseconds"))
        XCTAssertTrue(workstationLayout.contains("DeferredMacWorkspacePanel(id: \"workspace-notices\""))
        XCTAssertTrue(workstationLayout.contains("DeferredMacWorkspacePanel(id: \"workspace-calendar\""))
        XCTAssertTrue(workstationLayout.contains("id: \"workspace-activityLogs\""))
        XCTAssertTrue(workstationLayout.contains("id: \"workspace-diagnostics\""))
        XCTAssertTrue(workstationLayout.contains("id: \"workspace-settings\""))
        XCTAssertTrue(workstationLayout.contains("SettingsView(model: model)"))
        XCTAssertFalse(workstationLayout.contains("guard klmsMacInteractionDetailDelayNanoseconds > 0 else"))
        XCTAssertFalse(view.contains("DashboardSummaryLoadingPlaceholder"))
        XCTAssertFalse(view.contains("대시보드 항목을 준비하는 중입니다."))
        XCTAssertTrue(dashboardSummaryContent.contains("await Task.yield()"))
        XCTAssertFalse(dashboardSummaryContent.contains("detailDisplayTask?.cancel()"))
        XCTAssertTrue(dashboardSummaryContent.contains("detailRenderTask?.cancel()"))
        XCTAssertTrue(dashboardSummaryContent.contains("dashboardDetailContent(renderedDetail: currentRenderedDetail)"))
        XCTAssertFalse(view.contains("@Environment(\\.openSettings)"))
        XCTAssertFalse(view.contains("openSettings()"))
        XCTAssertFalse(view.contains("KLMSDiagnosticWindowCoordinator.shared.showDiagnosticsWindow()"))
        XCTAssertFalse(view.contains("withAnimation(.snappy(duration: 0.10))"))
        XCTAssertFalse(view.contains("withAnimation(.easeInOut(duration: 0.10))"))
        XCTAssertFalse(view.contains(".transition(.opacity.combined(with: .move(edge: .top)))"))
        XCTAssertFalse(detail.contains("withAnimation(.snappy(duration: 0.10))"))
        XCTAssertFalse(detail.contains(".transition(.opacity.combined(with: .move(edge: .top)))"))
        XCTAssertTrue(navigationView.contains("RoundedRectangle(cornerRadius: 12)"))
        XCTAssertTrue(navigationView.contains("WorkspaceNavigationSelectionMarker(section: selection)"))
        XCTAssertTrue(navigationView.contains("let isSelected = selection == section"))
        XCTAssertTrue(navigationView.contains("guard selection != section else {"))
        XCTAssertTrue(navigationView.contains("resetCurrentSectionScroll()"))
        XCTAssertTrue(navigationView.contains("select(section)"))
        XCTAssertFalse(navigationView.contains("@State private var displayedSelection"))
        XCTAssertFalse(navigationView.contains("@State private var selectionCommitTask: Task<Void, Never>?"))
        XCTAssertFalse(navigationView.contains("selectionCommitTask = Task { @MainActor in"))
        XCTAssertFalse(navigationView.contains("await Task.yield()"))
        XCTAssertTrue(navigationView.contains("withTransaction(transaction) {\n            selection = section\n        }"))
        XCTAssertTrue(navigationView.contains("selection = section"))
        XCTAssertFalse(navigationView.contains("guard selection != section else { return }"))
        XCTAssertTrue(navigationView.contains("Image(systemName: section.systemImage)"))
        XCTAssertTrue(navigationView.contains(".accessibilityIdentifier(\"workspace-\\(section.rawValue)\")"))
        XCTAssertTrue(navigationView.contains(".frame(width: 30, height: 30)"))
        XCTAssertTrue(navigationView.contains("@State private var hoveredSection"))
        XCTAssertTrue(navigationView.contains("let isHovered = hoveredSection == section"))
        XCTAssertTrue(navigationView.contains("iconBackground(isSelected: isSelected, isHovered: isHovered)"))
        XCTAssertTrue(navigationView.contains("Color.klmsMacSelectedBorder.opacity(0.24)"))
        XCTAssertTrue(navigationView.contains("Color.klmsMacSubtleCardBackground.opacity(0.72)"))
        XCTAssertTrue(navigationView.contains("Image(systemName: \"chevron.right\")"))
        XCTAssertTrue(navigationView.contains("rowBackground(isSelected: isSelected, isHovered: isHovered)"))
        XCTAssertTrue(navigationView.contains("Color.klmsMacSubtleCardBackground.opacity(0.62)"))
        XCTAssertTrue(navigationView.contains("Color.klmsMacSubtleCardBackground.opacity(0.28)"))
        XCTAssertTrue(navigationView.contains(".overlay(alignment: .leading)"))
        XCTAssertTrue(navigationView.contains(".frame(width: isSelected ? 4 : 0)"))
        XCTAssertTrue(navigationView.contains("rowBorder(isSelected: isSelected, isHovered: isHovered)"))
        XCTAssertTrue(navigationView.contains("Color.klmsMacCommandBorder.opacity(0.74)"))
        XCTAssertTrue(navigationView.contains("Color.klmsMacCommandBorder.opacity(0.36)"))
        XCTAssertTrue(navigationView.contains(".onHover { hovering in"))
        XCTAssertTrue(navigationView.contains(".frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)"))
        XCTAssertTrue(macAlertBannerTone.contains("return Color.klmsMacCommandButtonPressedBackground"))
        XCTAssertTrue(macAlertBannerTone.contains("return Color.klmsMacSecondaryCommandButtonForeground"))
        XCTAssertFalse(macAlertBannerTone.contains("return Color.klmsMacPrimaryCommandButtonBackground"))
        XCTAssertFalse(macAlertBannerTone.contains("return Color.klmsMacPrimaryCommandButtonForeground"))
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
        XCTAssertTrue(view.contains("cachedDashboardDetailPanel(kind: .files)"))
        XCTAssertTrue(view.contains("cachedDashboardDetailPanel(kind: .notices)"))
        XCTAssertTrue(view.contains("cachedDashboardDetailPanel(kind: .calendar)"))
        XCTAssertTrue(commandPanel.contains(".font(.system(size: 18, weight: .black, design: .rounded))"))
        XCTAssertTrue(commandPanel.contains("commandStatusStrip"))
        XCTAssertTrue(commandPanel.contains("private var commandStatusDetailText: String"))
        XCTAssertTrue(commandPanel.contains("return model.currentPhaseText.map { \"현재 단계: \\($0)\" } ?? model.liveProgressLine ?? \"실시간 로그를 기다리고 있습니다.\""))
        XCTAssertTrue(commandPanel.contains("Text(model.currentPhaseText ?? \"진행 상황을 확인 중입니다.\")"))
        XCTAssertTrue(commandPanel.contains("Text(model.currentPhaseText ?? \"진행 중\")"))
        XCTAssertTrue(commandPanel.contains(".padding(.horizontal, 14)"))
        XCTAssertTrue(commandPanel.contains(".padding(.vertical, 15)"))
        XCTAssertTrue(commandPanel.contains(".font(.system(size: 11, weight: .heavy, design: .rounded))"))
        XCTAssertTrue(commandPanel.contains(".padding(.horizontal, 8)"))
        XCTAssertTrue(commandPanel.contains(".frame(maxWidth: .infinity, minHeight: 44, alignment: .center)"))
        XCTAssertFalse(commandPanel.contains(".frame(maxWidth: .infinity, minHeight: 42, alignment: .center)"))
        XCTAssertTrue(commandPanel.contains(".buttonStyle(MacPressFeedbackButtonStyle())"))
        XCTAssertTrue(commandPanel.contains(".buttonStyle(MacPressFeedbackButtonStyle(cornerRadius: 12, disabledOpacity: 1.0))"))
        XCTAssertTrue(commandPanel.contains(".buttonStyle(MacPressFeedbackButtonStyle(disabledOpacity: 1.0))"))
        XCTAssertTrue(commandPanel.contains("let isRunning = model.runningCommand == command"))
        XCTAssertTrue(commandPanel.contains("let isDisabled = model.runningCommand != nil && !isRunning"))
        XCTAssertTrue(commandPanel.contains("Text(isRunning ? \"전체 동기화 중단\" : \"전체 동기화\")"))
        XCTAssertTrue(commandPanel.contains("Image(systemName: primaryCommandSystemImage(isRunning: isRunning, isDisabled: isDisabled))"))
        XCTAssertTrue(commandPanel.contains("secondaryCommandSystemImage(isRunning: isRunning, isDisabled: isDisabled)"))
        XCTAssertTrue(commandPanel.contains("return \"lock.fill\""))
        XCTAssertTrue(commandPanel.contains("if isDisabled { return Color.klmsMacSubtleCardBackground.opacity(0.86) }"))
        XCTAssertTrue(commandPanel.contains("if isDisabled { return Color.klmsMacCommandButtonBorder.opacity(0.64) }"))
        XCTAssertTrue(commandPanel.contains("if isDisabled { return Color.klmsMacSubtleCardBackground.opacity(0.70) }"))
        XCTAssertTrue(commandPanel.contains("if isDisabled { return Color.klmsMacCommandButtonBorder.opacity(0.54) }"))
        XCTAssertTrue(commandPanel.contains(".disabled(isDisabled)"))
        XCTAssertTrue(commandPanel.contains("private func runOrCancel(_ command: KLMSEngineCommand)"))
        XCTAssertTrue(view.contains(".font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())"))
        XCTAssertTrue(view.contains(".buttonStyle(MacPressFeedbackButtonStyle(cornerRadius: 13))"))
        XCTAssertTrue(view.contains(".buttonStyle(MacPressFeedbackButtonStyle(cornerRadius: 14))"))
        XCTAssertFalse(view.contains(".buttonStyle(.plain)"))
        XCTAssertFalse(detail.contains(".buttonStyle(.plain)"))
        XCTAssertFalse(detail.contains(".buttonStyle(.borderless)"))
        XCTAssertFalse(detail.contains(".buttonStyle(KLMSMacActionButtonStyle(tone: .primary))"))
        XCTAssertTrue(pressFeedbackStyle.contains("var cornerRadius: CGFloat = 10"))
        XCTAssertTrue(pressFeedbackStyle.contains("var disabledOpacity: Double = 0.48"))
        XCTAssertTrue(pressFeedbackStyle.contains(".opacity(isEnabled ? 1.0 : disabledOpacity)"))
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
        XCTAssertTrue(rootActionButtonStyle.contains("Color.klmsMacDangerCommandButtonForeground"))
        XCTAssertTrue(view.contains("static var klmsMacDangerCommandButtonForeground"))
        XCTAssertTrue(rootActionButtonStyle.contains("Color.klmsMacDangerBorder.opacity(isPressed ? 0.92 : 0.84)"))
        XCTAssertFalse(rootActionButtonStyle.contains("Color.klmsMacDangerBackground"))
        XCTAssertTrue(actionButtonStyle.contains("Color.klmsMacCommandButtonPressedBackground"))
        XCTAssertTrue(actionButtonStyle.contains("Color.klmsMacPrimaryCommandButtonPressedBackground"))
        XCTAssertTrue(iconButtonStyle.contains("Color.klmsMacCommandButtonPressedBackground"))
        XCTAssertTrue(iconButtonStyle.contains("Color.klmsMacPrimaryCommandButtonBorder.opacity(0.46)"))
        XCTAssertTrue(iconButtonStyle.contains(".frame(width: 44, height: 44)"))
        XCTAssertTrue(commandPanel.contains("Color.klmsMacCommandButtonBackground.opacity(0.90)"))
        XCTAssertTrue(commandPanel.contains("return Color.klmsMacCommandButtonBorder.opacity(isRunning ? 1.0 : 0.88)"))
        XCTAssertFalse(commandPanel.contains("isRunning ? Color.klmsMacPrimaryCommandButtonBorder.opacity(0.58)"))
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
        XCTAssertTrue(mac.contains(".foregroundStyle(primaryCommandForeground(isDisabled: isDisabled))"))
        XCTAssertTrue(macSettings.contains(".buttonStyle(KLMSMacSettingsButtonStyle())"))
        XCTAssertTrue(macSettings.contains(".buttonStyle(KLMSMacSettingsButtonStyle(tone: .destructive))"))
        XCTAssertTrue(macSettingsButtonStyle.contains("Color.klmsMacCommandButtonPressedBackground"))
        XCTAssertTrue(macSettingsButtonStyle.contains("Color.klmsMacPrimaryCommandButtonBorder.opacity(0.46)"))
        XCTAssertTrue(macSettingsButtonStyle.contains("Color.klmsMacDangerBorder.opacity(isPressed ? 0.78 : 0.48)"))
        XCTAssertTrue(mac.contains("Image(systemName: primaryCommandSystemImage(isRunning: isRunning, isDisabled: isDisabled))"))
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
        let macSettingsRoot = packageRoot.appendingPathComponent("Sources/KLMSMac/SettingsView.swift")
        let iosRoot = packageRoot.appendingPathComponent("Sources/KLMSiOS/KLMSiOSApp.swift")
        let mac = try String(contentsOf: macRoot, encoding: .utf8)
        let macDetail = try String(contentsOf: macDetailRoot, encoding: .utf8)
        let ios = try String(contentsOf: iosRoot, encoding: .utf8)
        let sources = try [
            mac,
            macDetail,
            String(contentsOf: macModelRoot, encoding: .utf8),
            String(contentsOf: macSettingsRoot, encoding: .utf8),
            ios,
        ].joined(separator: "\n")
        let logTextBlock = try sourceStructBody(named: "LogTextBlock", in: mac)
        let macDeferredExpansion = try sourceBody(
            after: "private struct DeferredDashboardExpansion<Content: View>: View",
            in: macDetail,
            description: "Mac deferred dashboard expansion"
        )
        let macDeferredInteractionExpansion = try sourceBody(
            after: "private struct DeferredMacInteractionExpansion<Content: View>: View",
            in: mac,
            description: "Mac deferred interaction expansion"
        )
        let iosDeferredInteractionExpansion = try sourceBody(
            after: "private struct DeferredInteractionExpansion<Content: View>: View",
            in: ios,
            description: "iPhone/iPad deferred interaction expansion"
        )
        let iosDeferredItemDetailPanel = try sourceStructBody(named: "DeferredServerSyncItemDetailPanel", in: ios)

        XCTAssertFalse(sources.contains("duration: 0.04"))
        XCTAssertFalse(sources.contains("withAnimation(.easeInOut(duration: 0.08))"))
        XCTAssertFalse(sources.contains(".transition(.opacity)"))
        XCTAssertFalse(sources.contains(".transition(.opacity.combined(with: .move(edge: .top)))"))
        XCTAssertFalse(sources.contains("ForEach(Array("))
        XCTAssertFalse(sources.contains(".onTapGesture"))
        XCTAssertFalse(sources.contains("DragGesture("))
        XCTAssertFalse(sources.contains(".gesture("))
        XCTAssertFalse(sources.contains(".simultaneousGesture("))
        XCTAssertFalse(sources.contains(".highPriorityGesture("))
        XCTAssertFalse(sources.contains("? \"선택됨\" : \"\""))
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
        XCTAssertTrue(logTextBlock.contains("@State private var highlights: [KLMSLogHighlight]"))
        XCTAssertTrue(logTextBlock.contains(".task(id: highlightSourceText)"))
        XCTAssertTrue(logTextBlock.contains("Self.boundedHighlightSourceText(boundedText, detailed: detailed)"))
        XCTAssertTrue(logTextBlock.contains("Task.detached(priority: .utility)"))
        XCTAssertTrue(logTextBlock.contains("rawExpandedByDefault: Bool = false"))
        XCTAssertTrue(logTextBlock.contains("title: \"원본 로그 보기\""))
        XCTAssertTrue(logTextBlock.contains("DiagnosticChecksDisclosure("))
        XCTAssertFalse(logTextBlock.contains("DisclosureGroup(isExpanded: $isRawExpanded)"))
        XCTAssertFalse(logTextBlock.contains("self.highlights = KLMSReadableLogParser.highlights(from: boundedText)"))
        XCTAssertTrue(sources.contains("private struct DeferredDashboardExpansion"))
        XCTAssertTrue(macDeferredExpansion.contains("@State private var shouldRender: Bool"))
        XCTAssertTrue(macDeferredExpansion.contains("_shouldRender = State(initialValue: isExpanded)"))
        XCTAssertTrue(macDeferredExpansion.contains(".onAppear"))
        XCTAssertTrue(macDeferredExpansion.contains(".onChange(of: isExpanded)"))
        XCTAssertTrue(macDeferredExpansion.contains("shouldRender = expanded"))
        XCTAssertFalse(macDeferredExpansion.contains(".task(id: isExpanded)"))
        XCTAssertFalse(macDeferredExpansion.contains("await Task.yield()"))
        XCTAssertTrue(macDeferredExpansion.contains("transaction.animation = nil"))
        XCTAssertTrue(macDeferredInteractionExpansion.contains("@State private var shouldRender: Bool"))
        XCTAssertTrue(macDeferredInteractionExpansion.contains("_shouldRender = State(initialValue: isExpanded)"))
        XCTAssertTrue(macDeferredInteractionExpansion.contains(".onAppear"))
        XCTAssertTrue(macDeferredInteractionExpansion.contains(".onChange(of: isExpanded)"))
        XCTAssertTrue(macDeferredInteractionExpansion.contains("shouldRender = expanded"))
        XCTAssertFalse(macDeferredInteractionExpansion.contains(".task(id: isExpanded)"))
        XCTAssertFalse(macDeferredInteractionExpansion.contains("await Task.yield()"))
        XCTAssertTrue(macDeferredInteractionExpansion.contains("transaction.animation = nil"))
        XCTAssertTrue(iosDeferredInteractionExpansion.contains("@State private var shouldRender: Bool"))
        XCTAssertFalse(iosDeferredInteractionExpansion.contains("@State private var renderTask: Task<Void, Never>?"))
        XCTAssertTrue(iosDeferredInteractionExpansion.contains("_shouldRender = State(initialValue: isExpanded)"))
        XCTAssertTrue(iosDeferredInteractionExpansion.contains(".onAppear"))
        XCTAssertTrue(iosDeferredInteractionExpansion.contains("scheduleRender(isExpanded)"))
        XCTAssertTrue(iosDeferredInteractionExpansion.contains(".onChange(of: isExpanded)"))
        XCTAssertTrue(iosDeferredInteractionExpansion.contains("scheduleRender(expanded)"))
        XCTAssertFalse(iosDeferredInteractionExpansion.contains(".task(id: isExpanded)"))
        XCTAssertFalse(iosDeferredInteractionExpansion.contains("await Task.yield()"))
        XCTAssertTrue(iosDeferredInteractionExpansion.contains("shouldRender = expanded"))
        XCTAssertTrue(iosDeferredInteractionExpansion.contains("transaction.animation = nil"))
        XCTAssertFalse(iosDeferredItemDetailPanel.contains("@State private var renderedItemID: String?"))
        XCTAssertFalse(iosDeferredItemDetailPanel.contains("if renderedItemID == item.id"))
        XCTAssertFalse(iosDeferredItemDetailPanel.contains("DeferredServerSyncItemDetailPreparingPanel(item: item)"))
        XCTAssertFalse(iosDeferredItemDetailPanel.contains("renderedItemID = nil"))
        XCTAssertFalse(iosDeferredItemDetailPanel.contains("renderedItemID = item.id"))
        XCTAssertFalse(iosDeferredItemDetailPanel.contains(".task(id: item.id)"))
        XCTAssertFalse(iosDeferredItemDetailPanel.contains(".onDisappear"))
        XCTAssertFalse(iosDeferredItemDetailPanel.contains("await Task.yield()"))
        XCTAssertTrue(iosDeferredItemDetailPanel.contains("ServerSyncItemInlineDetailPanel(item: item, model: model)"))
        XCTAssertTrue(iosDeferredItemDetailPanel.contains(".id(item.id)"))
        XCTAssertFalse(sources.contains("dashboardDetailExpansionDelayNanoseconds"))
        XCTAssertFalse(sources.contains("private let klmsMacInteractionDetailDelayNanoseconds"))
        XCTAssertFalse(sources.contains("private let klmsIOSInteractionDetailDelayNanoseconds"))
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
        let modelRoot = packageRoot.appendingPathComponent("Sources/KLMSMac/KLMSMacModel.swift")
        let detailRoot = packageRoot.appendingPathComponent("Sources/KLMSMac/DashboardDetailView.swift")
        let macRoot = packageRoot.appendingPathComponent("Sources/KLMSMac/MenuBarRootView.swift")
        let macModel = try String(contentsOf: modelRoot, encoding: .utf8)
        let detail = try String(contentsOf: detailRoot, encoding: .utf8)
        let mac = try String(contentsOf: macRoot, encoding: .utf8)
        let macWorkstationLayoutView = try sourceStructBody(named: "MacWorkstationLayoutView", in: mac)
        let stateItemRow = try sourceStructBody(named: "StateItemRowView", in: detail)
        let fileRow = try sourceStructBody(named: "FileRowView", in: detail)
        let fileListContentView = try sourceStructBody(named: "DashboardFileListContentView", in: detail)
        let prunedListView = try sourceStructBody(named: "PrunedListView", in: detail)
        let stateItemListView = try sourceStructBody(named: "StateItemListView", in: detail)
        let dashboardRenderSignature = try sourceBody(
            after: "struct DashboardRenderSignature: Equatable",
            in: detail,
            description: "DashboardRenderSignature"
        )
        let dashboardFileRenderSignature = try sourceBody(
            after: "struct DashboardFileRenderSignature: Equatable, Sendable",
            in: detail,
            description: "DashboardFileRenderSignature"
        )
        let fileItem = try sourceBody(
            after: "private struct DashboardFileItem",
            in: detail,
            description: "DashboardFileItem"
        )
        let fileListPresentation = try sourceBody(
            after: "private struct DashboardFileListPresentation: Sendable",
            in: detail,
            description: "DashboardFileListPresentation"
        )
        let stateItemListPresentation = try sourceBody(
            after: "private struct DashboardStateItemListPresentation: Sendable",
            in: detail,
            description: "DashboardStateItemListPresentation"
        )

        XCTAssertFalse(fileRow.contains(".task(id: item.path)"))
        XCTAssertFalse(fileRow.contains("FileManager.default.fileExists"))
        XCTAssertTrue(fileRow.contains("let pathExists = item.pathExists"))
        XCTAssertTrue(stateItemRow.contains("작업 \\(isExpanded ? \"펼쳐짐\" : \"접힘\")"))
        XCTAssertTrue(stateItemRow.contains(".accessibilityHint(isExpanded ? \"항목 작업 접기\" : \"항목 작업 펼치기\")"))
        XCTAssertFalse(stateItemRow.contains("작업 \\(isExpanded ? \"접기\" : \"작업 펼치기\")"))
        XCTAssertTrue(fileRow.contains("작업 \\(isExpanded ? \"펼쳐짐\" : \"접힘\")"))
        XCTAssertTrue(fileRow.contains(".accessibilityHint(isExpanded ? \"파일 작업 접기\" : \"파일 작업 펼치기\")"))
        XCTAssertFalse(fileRow.contains("작업 \\(isExpanded ? \"접기\" : \"작업 펼치기\")"))
        XCTAssertTrue(fileItem.contains("var pathExists: Bool = false"))
        XCTAssertTrue(fileItem.contains("private var searchBlob: String = \"\""))
        XCTAssertTrue(fileItem.contains("courseSortKey = course.normalizedFileSortKey"))
        XCTAssertTrue(fileItem.contains("private var renderSignatureHash: Int = 0"))
        XCTAssertTrue(fileItem.contains("var renderSignatureValue: Int { renderSignatureHash }"))
        XCTAssertTrue(detail.contains("hasher.combine(file.renderSignatureValue)"))
        XCTAssertTrue(fileListPresentation.contains("let normalizedQuery = filters.searchText.trimmingCharacters(in: .whitespacesAndNewlines)"))
        XCTAssertTrue(fileListPresentation.contains(".filter { $0.matches(filters: filters, normalizedQuery: normalizedQuery) }"))
        XCTAssertTrue(fileItem.contains("func matches(filters: DashboardDetailFilters, normalizedQuery query: String) -> Bool"))
        XCTAssertFalse(fileItem.contains("let query = filters.searchText.trimmingCharacters(in: .whitespacesAndNewlines)"))
        XCTAssertFalse(detail.contains("hasher.combine(file.interaction?.trashedAt ?? \"\")"))
        XCTAssertTrue(detail.contains("private struct DashboardFileData"))
        XCTAssertTrue(detail.contains("var manifestFiles: [DashboardFileItem]"))
        XCTAssertTrue(detail.contains("var newFiles: [DashboardFileItem]"))
        XCTAssertTrue(detail.contains("var missingFiles: [DashboardFileItem]"))
        XCTAssertTrue(detail.contains("var quarantineFiles: [DashboardFileItem]"))
        XCTAssertTrue(detail.contains("private struct DashboardFileListBaseInputSignature: Equatable"))
        XCTAssertTrue(detail.contains("private struct DashboardFileListInputSignature: Equatable"))
        XCTAssertTrue(detail.contains("private struct DashboardFileListPresentation: Sendable"))
        XCTAssertTrue(detail.contains("private struct DashboardFileListContentView"))
        XCTAssertTrue(detail.contains("private var inputBaseSignature: DashboardFileListBaseInputSignature"))
        XCTAssertTrue(detail.contains("DashboardFileListInputSignature(baseSignature: inputBaseSignature, sortOption: sortOption)"))
        XCTAssertTrue(detail.contains("@State private var presentation: DashboardFileListPresentation"))
        XCTAssertTrue(detail.contains("@State private var presentationSignature: DashboardFileListInputSignature?"))
        XCTAssertTrue(fileListContentView.contains("@State private var renderedFilters: DashboardDetailFilters?"))
        XCTAssertTrue(detail.contains("@State private var presentationTask: Task<Void, Never>?"))
        XCTAssertTrue(detail.contains("DashboardListPreparingView(text: \"파일 목록을 준비하는 중입니다.\")"))
        XCTAssertTrue(detail.contains("_presentation = State(initialValue: DashboardFileListPresentation())"))
        XCTAssertTrue(detail.contains("let nextPresentation = await Task.detached(priority: .userInitiated) {\n                DashboardFileListPresentation(files: files, filters: filters, sortOption: sortOption)\n            }.value"))
        XCTAssertTrue(fileListContentView.contains("renderedFilters = filters"))
        XCTAssertFalse(detail.contains("_presentation = State(initialValue: DashboardFileListPresentation(files: files, filters: filters, sortOption: .recent))"))
        XCTAssertFalse(detail.contains("presentation = DashboardFileListPresentation()\n        visibleLimit = DashboardLargeList.initialVisibleLimit\n        isPreparingPresentation = true"))
        XCTAssertTrue(detail.contains("rebuildPresentationIfNeeded"))
        XCTAssertFalse(detail.contains("let filteredFiles = files.filter { $0.matches(filters: filters) }"))
        XCTAssertFalse(detail.contains("let sortedFiles = filteredFiles.sorted(by: sortOption)"))
        XCTAssertFalse(detail.contains("let records = files.filter { $0.matches(filters: filters) }"))
        XCTAssertFalse(detail.contains("let sortedRecords = records.sorted(by: sortOption)"))
        XCTAssertTrue(dashboardRenderSignature.contains("private static func combineNoticeInteractions"))
        XCTAssertTrue(dashboardRenderSignature.contains("private static func combineFileInteractions"))
        XCTAssertTrue(dashboardRenderSignature.contains("private static func combineStateItem"))
        XCTAssertTrue(dashboardRenderSignature.contains("private static func combineNotice"))
        XCTAssertTrue(dashboardRenderSignature.contains("private static func combineFile"))
        XCTAssertTrue(dashboardRenderSignature.contains("private static func combineCalendarChange"))
        XCTAssertFalse(dashboardRenderSignature.contains("Array(items.prefix"))
        XCTAssertFalse(dashboardRenderSignature.contains("Array(notices.prefix"))
        XCTAssertFalse(dashboardRenderSignature.contains("Array(files.prefix"))
        XCTAssertFalse(dashboardRenderSignature.contains("Array(changes.prefix"))
        XCTAssertTrue(dashboardRenderSignature.contains("stateFingerprint ^= itemHasher.finalize()"))
        XCTAssertFalse(dashboardRenderSignature.contains("states.keys.sorted()"))
        XCTAssertTrue(dashboardFileRenderSignature.contains("private static func combineInteractionStates"))
        XCTAssertTrue(dashboardFileRenderSignature.contains("Self.combineInteractionStates(snapshot.appUserState?.files ?? [:], into: &hasher)"))
        XCTAssertTrue(dashboardFileRenderSignature.contains("Self.combineInteractionStates(snapshot.appUserState?.quarantine ?? [:], into: &hasher)"))
        XCTAssertTrue(dashboardFileRenderSignature.contains("stateFingerprint ^= itemHasher.finalize()"))
        XCTAssertFalse(dashboardFileRenderSignature.contains(".sorted(by: { $0.key < $1.key })"))
        XCTAssertTrue(detail.contains("private struct DashboardPrunedListBaseInputSignature: Equatable"))
        XCTAssertTrue(detail.contains("private struct DashboardPrunedListInputSignature: Equatable"))
        XCTAssertTrue(detail.contains("private struct DashboardPrunedListPresentation: Sendable"))
        XCTAssertTrue(prunedListView.contains("private var inputBaseSignature: DashboardPrunedListBaseInputSignature"))
        XCTAssertTrue(prunedListView.contains("@State private var presentation: DashboardPrunedListPresentation"))
        XCTAssertTrue(prunedListView.contains("@State private var presentationSignature: DashboardPrunedListInputSignature?"))
        XCTAssertTrue(prunedListView.contains("@State private var renderedFilters: DashboardDetailFilters?"))
        XCTAssertTrue(prunedListView.contains("@State private var presentationTask: Task<Void, Never>?"))
        XCTAssertTrue(prunedListView.contains("DashboardListPreparingView(text: \"정리 기록을 준비하는 중입니다.\")"))
        XCTAssertTrue(prunedListView.contains("let nextPresentation = await Task.detached(priority: .userInitiated)"))
        XCTAssertTrue(prunedListView.contains("DashboardPrunedListPresentation(snapshot: snapshot, filters: filters, sortOption: sortOption)"))
        XCTAssertFalse(prunedListView.contains("let sortedDeleted = deleted.sorted(by: sortOption)"))
        XCTAssertFalse(prunedListView.contains("private var filteredItems: [DashboardFileItem]"))
        XCTAssertFalse(prunedListView.contains("await Task.yield()"))
        XCTAssertTrue(detail.contains("private struct DashboardStateItemListInputSignature: Equatable"))
        XCTAssertTrue(detail.contains("private struct DashboardStateItemListPresentation: Sendable"))
        XCTAssertTrue(detail.contains("private struct DashboardDetailFilters: Equatable, Sendable"))
        XCTAssertTrue(detail.contains("enum StateItemEditorKind: Sendable"))
        XCTAssertTrue(detail.contains("private var inputSignature: DashboardStateItemListInputSignature"))
        XCTAssertTrue(detail.contains("var itemsSignature: Int?"))
        XCTAssertTrue(detail.contains("itemsSignature: Int? = nil"))
        XCTAssertTrue(detail.contains("DashboardStateItemListInputSignature(\n            items: items,\n            itemsSignature: itemsSignature"))
        XCTAssertTrue(detail.contains("if let itemsSignature {\n            hasher.combine(itemsSignature)\n        } else {"))
        XCTAssertTrue(detail.contains("let signature = inputSignature"))
        XCTAssertTrue(detail.contains("@State private var presentation: DashboardStateItemListPresentation"))
        XCTAssertTrue(detail.contains("@State private var presentationSignature: DashboardStateItemListInputSignature?"))
        XCTAssertTrue(stateItemListView.contains("@State private var renderedFilters: DashboardDetailFilters?"))
        XCTAssertTrue(detail.contains("@State private var presentationTask: Task<Void, Never>?"))
        XCTAssertTrue(detail.contains("@State private var isPreparingPresentation = true"))
        XCTAssertTrue(detail.contains("_presentation = State(initialValue: DashboardStateItemListPresentation())"))
        XCTAssertTrue(detail.contains("_presentationSignature = State(initialValue: nil)"))
        XCTAssertTrue(detail.contains("DashboardListPreparingView(text: \"목록을 준비하는 중입니다.\")"))
        XCTAssertFalse(detail.contains("presentation = DashboardStateItemListPresentation()\n        visibleLimit = DashboardLargeList.initialVisibleLimit\n        isPreparingPresentation = true"))
        XCTAssertFalse(fileListContentView.contains("await Task.yield()"))
        XCTAssertFalse(stateItemListView.contains("await Task.yield()"))
        XCTAssertTrue(detail.contains("let nextPresentation = await Task.detached(priority: .userInitiated)"))
        XCTAssertTrue(detail.contains("DashboardStateItemListPresentation(items: items, editor: editor, filters: filters, snapshot: snapshot)"))
        XCTAssertTrue(stateItemListPresentation.contains("let normalizedQuery = filters.searchText.trimmingCharacters(in: .whitespacesAndNewlines)"))
        XCTAssertTrue(stateItemListPresentation.contains("normalizedQuery: normalizedQuery"))
        XCTAssertTrue(stateItemListPresentation.contains("private static func searchMatches(_ item: StateItem, query: String) -> Bool"))
        XCTAssertFalse(stateItemListPresentation.contains("fields.joined(separator: \" \")"))
        XCTAssertFalse(stateItemListPresentation.contains("searchMatches([\n            item.academicTerm?.displayName ?? \"\""))
        XCTAssertTrue(detail.contains("presentation = nextPresentation"))
        XCTAssertTrue(stateItemListView.contains("renderedFilters = filters"))
        XCTAssertFalse(detail.contains("_presentation = State(initialValue: DashboardStateItemListPresentation(items: items, editor: editor, filters: filters, snapshot: snapshot))"))
        XCTAssertFalse(detail.contains("let visibleItems = filteredItems"))
        XCTAssertFalse(detail.contains("private var filteredItems: [StateItem]"))
        XCTAssertTrue(detail.contains("static let initialVisibleLimit = 5"))
        XCTAssertTrue(detail.contains("struct DashboardFileRenderSignature: Equatable, Sendable"))
        XCTAssertTrue(detail.contains("private var hiddenCount: Int"))
        XCTAssertTrue(detail.contains("struct DashboardFilterOptions: Equatable, Sendable"))
        XCTAssertTrue(detail.contains("private var filterOptions: DashboardFilterOptions"))
        XCTAssertTrue(detail.contains("filterOptions: DashboardFilterOptions? = nil"))
        XCTAssertTrue(detail.contains("self.filterOptions = filterOptions\n            ?? model.dashboardFilterOptions(for: kind)\n            ?? DashboardFilterOptions(kind: kind, snapshot: resolvedSnapshot)"))
        let dashboardFilterOptions = try sourceBody(
            after: "struct DashboardFilterOptions",
            in: detail,
            description: "dashboard filter options"
        )
        let dashboardNewFileFilterOptions = try sourceBody(
            after: "private struct DashboardNewFileFilterOptions",
            in: detail,
            description: "dashboard new file filter options"
        )
        let dashboardFilterOptionSource = try sourceBody(
            after: "private struct DashboardFilterOptionSource",
            in: detail,
            description: "dashboard filter option source"
        )
        XCTAssertTrue(dashboardFilterOptions.contains("if kind == .newFiles"))
        XCTAssertTrue(dashboardFilterOptions.contains("let newFileOptions = DashboardNewFileFilterOptions(snapshot: snapshot)"))
        XCTAssertTrue(dashboardFilterOptions.contains("courses = newFileOptions.courses"))
        XCTAssertTrue(dashboardFilterOptions.contains("years = newFileOptions.years"))
        XCTAssertTrue(dashboardFilterOptions.contains("semesters = newFileOptions.semesters"))
        XCTAssertTrue(dashboardFilterOptions.contains("let source = DashboardFilterOptionSource(kind: kind, snapshot: snapshot)"))
        XCTAssertTrue(dashboardFilterOptions.contains("courses = DashboardCourseFilter.optionLabels(from: source.courses)"))
        XCTAssertTrue(dashboardFilterOptions.contains("let termOptions = DashboardTermFilter.options(from: source.terms)"))
        XCTAssertFalse(dashboardFilterOptions.contains("DashboardCourseFilter.options(for: kind, snapshot: snapshot)"))
        XCTAssertFalse(dashboardFilterOptions.contains("DashboardTermFilter.options(for: kind, snapshot: snapshot)"))
        XCTAssertTrue(detail.contains("years = termOptions.years"))
        XCTAssertTrue(detail.contains("semesters = termOptions.semesters"))
        XCTAssertTrue(detail.contains("static func options(from terms: [AcademicTerm?])"))
        XCTAssertTrue(dashboardFilterOptionSource.contains("private static func stateItems(_ items: [StateItem])"))
        XCTAssertTrue(dashboardFilterOptionSource.contains("for item in items"))
        XCTAssertTrue(dashboardFilterOptionSource.contains("courses.append(item.course)"))
        XCTAssertTrue(dashboardFilterOptionSource.contains("terms.append(item.academicTerm)"))
        XCTAssertTrue(dashboardFilterOptionSource.contains("private static func hidden(snapshot: EngineSnapshot)"))
        XCTAssertTrue(dashboardFilterOptionSource.contains("appendHiddenStateItems("))
        XCTAssertTrue(dashboardNewFileFilterOptions.contains("let manifestLookup = Self.manifestLookup(snapshot.courseFileManifest)"))
        XCTAssertTrue(dashboardNewFileFilterOptions.contains("for item in downloadItems"))
        XCTAssertTrue(dashboardNewFileFilterOptions.contains("courses.append(manifest?.course ?? \"\")"))
        XCTAssertTrue(dashboardNewFileFilterOptions.contains("terms.append(manifest?.academicTerm ?? AcademicTerm.infer"))
        XCTAssertTrue(dashboardNewFileFilterOptions.contains("self.courses = DashboardCourseFilter.optionLabels(from: courses)"))
        XCTAssertTrue(dashboardNewFileFilterOptions.contains("let termOptions = DashboardTermFilter.options(from: terms)"))
        XCTAssertTrue(macModel.contains("@Published private(set) var dashboardFilterOptionsByKind: [DashboardDetailKind: DashboardFilterOptions] = [:]"))
        XCTAssertTrue(macModel.contains("func dashboardFilterOptions(for kind: DashboardDetailKind) -> DashboardFilterOptions?"))
        XCTAssertTrue(macModel.contains("dashboardFilterOptionsByKind = Dictionary("))
        XCTAssertTrue(macModel.contains("(kind, DashboardFilterOptions(kind: kind, snapshot: snapshot))"))
        XCTAssertTrue(detail.contains("var courses: [String]"))
        XCTAssertTrue(detail.contains("var years: [String]"))
        XCTAssertTrue(detail.contains("var semesters: [String]"))
        XCTAssertTrue(detail.contains("courses: filterOptions.courses"))
        XCTAssertTrue(detail.contains("years: filterOptions.years"))
        XCTAssertTrue(detail.contains("semesters: filterOptions.semesters"))
        let dashboardCourseFilter = try sourceBody(
            after: "private enum DashboardCourseFilter",
            in: detail,
            description: "dashboard course filter"
        )
        let newFileCourseOptions = try sourceBody(
            after: "private static func newFileCourseOptions",
            in: dashboardCourseFilter,
            description: "new file course filter"
        )
        XCTAssertTrue(dashboardCourseFilter.contains("case .newFiles:\n            courses = newFileCourseOptions(snapshot: snapshot)"))
        XCTAssertFalse(dashboardCourseFilter.contains("case .files, .newFiles:"))
        XCTAssertTrue(newFileCourseOptions.contains("let manifestLookup = courseManifestLookup(snapshot.courseFileManifest)"))
        XCTAssertTrue(newFileCourseOptions.contains("manifestLookup.byURL[item.url]"))
        XCTAssertTrue(newFileCourseOptions.contains("manifestLookup.byRelativePath[item.relativePath]"))
        XCTAssertFalse(newFileCourseOptions.contains("snapshot.courseFileManifest.map(\\.course)"))
        let dashboardTermFilter = try sourceBody(
            after: "private enum DashboardTermFilter",
            in: detail,
            description: "dashboard term filter"
        )
        let newFileTerms = try sourceBody(
            after: "private static func newFileTerms",
            in: dashboardTermFilter,
            description: "new file term filter"
        )
        XCTAssertTrue(dashboardTermFilter.contains("private static func manifestLookup(_ manifest: [CourseFileManifestEntry])"))
        XCTAssertTrue(newFileTerms.contains("let manifestLookup = manifestLookup(snapshot.courseFileManifest)"))
        XCTAssertTrue(newFileTerms.contains("manifestLookup.byURL[item.url]"))
        XCTAssertTrue(newFileTerms.contains("manifestLookup.byRelativePath[item.relativePath]"))
        XCTAssertFalse(newFileTerms.contains("snapshot.courseFileManifest.first"))
        XCTAssertFalse(detail.contains("courses: { DashboardCourseFilter.options(for: kind, snapshot: snapshot) }"))
        XCTAssertFalse(detail.contains("years: { DashboardTermFilter.yearOptions(for: kind, snapshot: snapshot) }"))
        XCTAssertFalse(detail.contains("semesters: { DashboardTermFilter.semesterOptions(for: kind, snapshot: snapshot) }"))
        XCTAssertTrue(detail.contains("self.hiddenCount = resolvedSnapshot.hiddenSummary.total"))
        XCTAssertFalse(detail.contains("private var courseOptions: [String]"))
        XCTAssertFalse(detail.contains("private var yearOptions: [String]"))
        XCTAssertFalse(detail.contains("private var semesterOptions: [String]"))
        XCTAssertFalse(detail.contains("self.courseOptions = DashboardCourseFilter.options"))
        XCTAssertFalse(detail.contains("self.yearOptions = DashboardTermFilter.yearOptions"))
        XCTAssertFalse(detail.contains("self.semesterOptions = DashboardTermFilter.semesterOptions"))
        XCTAssertFalse(detail.contains("private var courseOptions: [String] {\n        DashboardCourseFilter.options"))
        XCTAssertFalse(detail.contains("private var yearOptions: [String] {\n        DashboardTermFilter.yearOptions"))
        XCTAssertFalse(detail.contains("private var semesterOptions: [String] {\n        DashboardTermFilter.semesterOptions"))
        XCTAssertTrue(detail.contains("struct DashboardFileRenderSignature: Equatable, Sendable"))
        XCTAssertTrue(detail.contains("private var fileDataRenderSignature: DashboardFileRenderSignature?"))
        XCTAssertTrue(detail.contains("fileRenderSignature: DashboardFileRenderSignature? = nil"))
        XCTAssertTrue(detail.contains("? (fileRenderSignature ?? DashboardFileRenderSignature(snapshot: resolvedSnapshot))"))
        XCTAssertTrue(detail.contains("lhs.fileDataRenderSignature == rhs.fileDataRenderSignature"))
        XCTAssertTrue(detail.contains(".onChange(of: fileDataRenderSignature)"))
        XCTAssertFalse(detail.contains("private var currentFileDataSignature"))
        XCTAssertFalse(detail.contains("return DashboardFileData.Signature(snapshot: snapshot)"))
        XCTAssertFalse(detail.contains("kind.requiresFileData ? DashboardFileData.Signature(snapshot: resolvedSnapshot) : nil"))
        XCTAssertTrue(detail.contains("fileDataTask = Task { @MainActor in"))
        XCTAssertTrue(detail.contains("Task.detached(priority: .userInitiated)"))
        XCTAssertTrue(detail.contains("private enum DashboardFileDataPreloadStore"))
        XCTAssertTrue(detail.contains("DashboardFileDataPreloadStore.cachedData(for: signature)"))
        XCTAssertTrue(detail.contains("DashboardFileDataPreloadStore.store(data)"))
        XCTAssertTrue(detail.contains("struct DashboardFileDataPrewarmView: View"))
        XCTAssertTrue(detail.contains("private static let prewarmDelayNanoseconds: UInt64 = 700_000_000"))
        XCTAssertTrue(detail.contains("Task.detached(priority: .utility)"))
        XCTAssertTrue(detail.contains("inFlightSignature"))
        XCTAssertTrue(detail.contains("beginPrewarmIfNeeded"))
        XCTAssertTrue(mac.contains("DashboardFileDataPrewarmView(\n                snapshot: model.snapshot,\n                signature: model.dashboardFileRenderSignature\n            )"))
        XCTAssertFalse(macWorkstationLayoutView.contains("DashboardFileDataPrewarmView"))
        let dashboardCaseStart = try XCTUnwrap(macWorkstationLayoutView.range(of: "case .dashboard:")?.lowerBound)
        let filesCaseStart = try XCTUnwrap(macWorkstationLayoutView.range(of: "case .files:")?.lowerBound)
        XCTAssertFalse(macWorkstationLayoutView[dashboardCaseStart..<filesCaseStart].contains("DashboardFileDataPrewarmView"))
        XCTAssertFalse(detail.contains("fileData = nil\n        fileDataSignature = signature"))
        XCTAssertFalse(detail.contains("let initialFileData = DashboardFileData(snapshot: resolvedSnapshot)"))
        XCTAssertFalse(mac.contains("DashboardFileDataPrewarmView(snapshot: model.snapshot, signature: DashboardFileRenderSignature(snapshot: model.snapshot))"))
        XCTAssertFalse(detail.contains("dashboardMissingPathSet(from: model.snapshot)"))
        XCTAssertFalse(detail.contains("private func dashboardFilePathExists"))
        XCTAssertTrue(detail.contains("static let increment = 10"))
        XCTAssertTrue(detail.contains("private struct DashboardRowDisclosureButton"))
        XCTAssertTrue(detail.contains("private struct DeferredDashboardExpansion"))
        XCTAssertTrue(detail.contains(".accessibilityLabel(\"KLMS에서 항목 열기\")"))
        XCTAssertTrue(detail.contains(".accessibilityLabel(\"KLMS에서 공지 열기\")"))
        XCTAssertTrue(detail.contains(".accessibilityLabel(\"첨부 파일 Finder에서 보기\")"))
        XCTAssertTrue(detail.contains(".accessibilityLabel(\"파일 Finder에서 보기\")"))
        XCTAssertTrue(detail.contains(".accessibilityLabel(\"KLMS에서 파일 열기\")"))
        let rowDisclosureButton = try sourceStructBody(named: "DashboardRowDisclosureButton", in: detail)
        XCTAssertFalse(rowDisclosureButton.contains("Button {"))
        XCTAssertTrue(rowDisclosureButton.contains("Label(isExpanded ? expandedTitle : collapsedTitle"))
        XCTAssertEqual(detail.components(separatedBy: ".onTapGesture {\n                isExpanded.toggle()\n            }").count - 1, 0)
        XCTAssertTrue(detail.contains("private func dashboardPerformWithoutAnimation"))
        XCTAssertEqual(detail.components(separatedBy: "Button {\n                    isExpanded.toggle()\n                } label:").count - 1, 0)
        XCTAssertGreaterThanOrEqual(detail.components(separatedBy: "dashboardPerformWithoutAnimation {\n                        isExpanded.toggle()\n                    }").count - 1, 3)
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
        let statusSummaryColumn = try sourceBody(
            after: "private var statusSummaryColumn: some View",
            in: statusScreen,
            description: "iOS compact status summary column"
        )
        let statusDetailColumn = try sourceBody(
            after: "private var statusDetailColumn: some View",
            in: statusScreen,
            description: "iPad status detail column"
        )
        let categoryScreen = try sourceStructBody(named: "CompanionDashboardCategoryScreen", in: ios)
        let tasksScreen = try sourceStructBody(named: "CompanionTasksScreen", in: ios)
        let categoryDetailPanel = try sourceStructBody(named: "DashboardCategoryInlineDetailPanel", in: ios)
        XCTAssertTrue(categoryDetailPanel.contains("Text(\"열림\")"))
        XCTAssertTrue(categoryDetailPanel.contains(".accessibilityLabel(\"\\(category.title) 상세 열림. \\(summaryText)\")"))
        let categoryLoadingState = try sourceStructBody(named: "CompanionCategoryDataLoadingState", in: ios)
        let settingsScreen = try sourceStructBody(named: "CompanionSettingsScreen", in: ios)
        let sectionContent = try sourceStructBody(named: "CompanionSectionContent", in: ios)
        let compactRoot = try sourceStructBody(named: "CompanionTabRootView", in: ios)
        let compactTabBar = try sourceStructBody(named: "CompanionCompactTabBar", in: ios)
        let workstationSidebar = try sourceStructBody(named: "WorkstationSidebar", in: ios)
        let sidebarButton = try sourceStructBody(named: "CompanionSidebarButton", in: ios)
        let dashboardSyncCard = try sourceStructBodies(
            named: ["RemoteDashboardSyncCard", "RemoteDashboardSyncSnapshot", "RemoteDashboardSyncCardContent"],
            in: ios
        )
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
        let immediateSettingRow = try sourceBody(
            after: "private struct CompanionImmediateSettingRow<Content: View>: View",
            in: ios,
            description: "iOS immediate settings row"
        )
        let remoteSettingsPanel = try sourceStructBody(named: "RemoteSettingsPanel", in: ios)
        let remoteSettingsPanelContent = try sourceStructBody(named: "RemoteSettingsPanelContent", in: ios)
        let remoteSettingGroupSection = try sourceStructBody(named: "RemoteSettingGroupSection", in: ios)
        let remoteDiagnosticPanel = try sourceStructBody(named: "RemoteDiagnosticPanel", in: ios)
        let remotePrivacyNote = try sourceStructBody(named: "RemotePrivacyNote", in: ios)
        let companionItemListControls = try sourceStructBody(named: "CompanionItemListControls", in: ios)
        let mailPasteAnalyzerPanel = try sourceStructBody(named: "MailPasteAnalyzerPanel", in: ios)
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
        let deferredInlineItemDetail = try sourceStructBody(named: "DeferredServerSyncItemDetailPanel", in: ios)
        let inlineItemDetail = try sourceStructBody(named: "ServerSyncItemInlineDetailPanel", in: ios)
        let serverSyncDataRow = try sourceStructBody(named: "ServerSyncDataRow", in: ios)
        let mailAnalysisResult = try sourceStructBodies(
            named: ["MailPasteAnalysisResultView", "MailPasteAnalysisResultContent"],
            in: ios
        )
        let sharedRunLogRow = try sourceStructBody(named: "SharedRunLogRow", in: ios)
        let serverRequestLogRow = try sourceStructBody(named: "ServerRequestLogRow", in: ios)
        let remoteFileAccessRequestRow = try sourceStructBody(named: "RemoteFileAccessRequestRow", in: ios)
        let remoteCommandRow = try sourceStructBody(named: "RemoteCommandRow", in: ios)
        let remoteRunningStatusBanner = try sourceStructBody(named: "RemoteRunningStatusBanner", in: ios)
        let remoteAttentionStackContent = try sourceStructBody(named: "RemoteAttentionStackContent", in: ios)
        let remoteVerifySummaryPanel = try sourceStructBody(named: "RemoteVerifySummaryPanel", in: ios)
        let remoteVerifyCheckRow = try sourceStructBody(named: "RemoteVerifyCheckRow", in: ios)
        let companionDiagnosticDisclosure = try sourceBody(
            after: "private struct CompanionDiagnosticDisclosure<Content: View>: View",
            in: ios,
            description: "iPhone/iPad diagnostic disclosure"
        )
        let errorBanner = try sourceStructBody(named: "ErrorBanner", in: ios)
        let authSuccessBanner = try sourceStructBody(named: "AuthSuccessBanner", in: ios)
        let authCodeHero = try sourceStructBody(named: "AuthCodeHero", in: ios)
        let loginAttentionBanner = try sourceStructBody(named: "LoginAttentionBanner", in: ios)
        let companionSection = try sourceBody(
            after: "private enum CompanionAppSection: String, CaseIterable, Identifiable, Hashable",
            in: ios,
            description: "iOS companion app section"
        )
        let companionWorkstationMetrics = try sourceBody(
            after: "private enum CompanionWorkstationMetrics",
            in: ios,
            description: "iPad workstation layout metrics"
        )

        XCTAssertTrue(companionSection.contains("case status"))
        XCTAssertTrue(companionSection.contains("case files"))
        XCTAssertTrue(companionSection.contains("case notices"))
        XCTAssertTrue(companionSection.contains("case tasks"))
        XCTAssertTrue(companionSection.contains("case calendar"))
        XCTAssertTrue(companionSection.contains("case history"))
        XCTAssertTrue(companionSection.contains("case settings"))
        XCTAssertFalse(ios.contains("[.files, .assignments, .exams, .notices, .calendar, .quarantine, .helpDesk]"))
        XCTAssertFalse(ios.contains("[.files, .assignments, .exams, .notices, .calendar, .helpDesk]\n            .first"))
        XCTAssertTrue(companionSection.contains("return \"대시보드\""))
        XCTAssertTrue(companionSection.contains("return \"상태\""))
        XCTAssertTrue(companionSection.contains("return \"파일\""))
        XCTAssertTrue(companionSection.contains("return \"공지\""))
        XCTAssertTrue(companionSection.contains("return \"과제/시험\""))
        XCTAssertTrue(companionSection.contains("return \"캘린더\""))
        XCTAssertTrue(companionSection.contains("return \"로그\""))
        XCTAssertTrue(companionSection.contains("return \"설정\""))
        let companionSectionContent = try sourceStructBody(named: "CompanionSectionContent", in: ios)
        for sectionID in ["status", "files", "notices", "tasks", "calendar", "history", "settings"] {
            XCTAssertTrue(
                companionSectionContent.contains(".accessibilityIdentifier(\"companion-section-\\(section.rawValue)\")"),
                "iPhone/iPad section content must expose a stable identifier so device QA can verify \(sectionID) renders after navigation."
            )
        }
        XCTAssertTrue(ios.contains("static var compactTabs: [CompanionAppSection]"))
        XCTAssertTrue(ios.contains("static var compactTabs: [CompanionAppSection] {\n        [.status, .history, .settings]"))
        XCTAssertTrue(ios.contains("static var workstationSections: [CompanionAppSection] {\n        [.status, .files, .notices, .tasks, .calendar, .history, .settings]"))
        XCTAssertTrue(companionWorkstationMetrics.contains("static let horizontalPadding: CGFloat = 22"))
        XCTAssertTrue(companionWorkstationMetrics.contains("static let columnSpacing: CGFloat = 18"))
        XCTAssertTrue(companionWorkstationMetrics.contains("static let metricColumnMinWidth: CGFloat = 332"))
        XCTAssertTrue(companionWorkstationMetrics.contains("static let metricColumnIdealWidth: CGFloat = 448"))
        XCTAssertTrue(companionWorkstationMetrics.contains("static let detailColumnMinWidth: CGFloat = 380"))
        XCTAssertTrue(companionWorkstationMetrics.contains("static let detailColumnIdealWidth: CGFloat = 700"))
        XCTAssertFalse(companionWorkstationMetrics.contains("static let compactCommandColumnMinWidth"))
        XCTAssertFalse(companionWorkstationMetrics.contains("static let compactDetailColumnMinWidth"))
        XCTAssertFalse(companionWorkstationMetrics.contains("static let compactListColumnMinWidth"))
        XCTAssertTrue(companionWorkstationMetrics.contains("static let listColumnMinWidth: CGFloat = 380"))
        XCTAssertTrue(companionWorkstationMetrics.contains("static let listColumnIdealWidth: CGFloat = 560"))
        XCTAssertTrue(companionWorkstationMetrics.contains("static let listColumnMaxWidth: CGFloat = 700"))
        XCTAssertTrue(compactRoot.contains("CompanionCompactTabBar"))
        XCTAssertTrue(compactRoot.contains(".safeAreaInset(edge: .bottom, spacing: 0)"))
        XCTAssertFalse(compactRoot.contains("CompanionCompactTabBar(selectedSection: $selectedSection)\n                .padding(.horizontal, 16)\n                .padding(.top, 7)\n                .padding(.bottom, 10)"))
        XCTAssertLessThan(
            compactRoot.range(of: "CompanionDeferredSectionContent(section: selectedSection, model: model)")?.lowerBound ?? compactRoot.endIndex,
            compactRoot.range(of: "CompanionCompactTabBar(selectedSection: $selectedSection)")?.lowerBound ?? compactRoot.startIndex,
            "iPhone compact layout should keep content first and place the tab bar at the bottom, matching the design preview."
        )
        XCTAssertFalse(compactRoot.contains("TabView"))
        XCTAssertFalse(compactRoot.contains(".tabItem"))
        XCTAssertTrue(compactTabBar.contains("ForEach(compactRows, id: \\.self)"))
        XCTAssertFalse(compactTabBar.contains("ForEach(Array(compactRows.enumerated()), id: \\.offset)"))
        XCTAssertTrue(compactTabBar.contains("private var compactRows: [[CompanionAppSection]]"))
        XCTAssertTrue(compactTabBar.contains("CompanionAppSection.compactTabs"))
        XCTAssertFalse(compactTabBar.contains("[.status, .files, .history, .settings]"))
        XCTAssertFalse(compactTabBar.contains("[.status, .files, .notices, .tasks]"))
        XCTAssertFalse(compactTabBar.contains("[.calendar, .history, .settings]"))
        XCTAssertFalse(compactTabBar.contains("withAnimation(.easeOut(duration: 0.12))"))
        XCTAssertFalse(compactTabBar.contains(".animation(.easeOut(duration: 0.10), value: isSelected)"))
        XCTAssertTrue(compactTabBar.contains("Image(systemName: section.systemImage)"))
        XCTAssertTrue(compactTabBar.contains("Text(section.compactTitle)"))
        XCTAssertTrue(compactTabBar.contains(".accessibilityLabel(section.compactTitle)"))
        XCTAssertTrue(compactTabBar.contains(".accessibilityValue(selectedSection == section ? \"선택됨\" : \"선택 안 됨\")"))
        XCTAssertTrue(compactTabBar.contains(".accessibilityHint(\"\\(section.compactTitle) 탭으로 이동합니다.\")"))
        XCTAssertTrue(compactTabBar.contains(".accessibilityIdentifier(\"companion-compact-tab-\\(section.rawValue)\")"))
        XCTAssertFalse(compactTabBar.contains(".accessibilityLabel(section.title)"))
        XCTAssertTrue(compactTabBar.contains(".frame(maxWidth: .infinity, minHeight: 44)"))
        XCTAssertTrue(workstationSidebar.contains("CompanionAppSection.workstationSections"))
        XCTAssertTrue(sidebarButton.contains(".accessibilityLabel(section.title)"))
        XCTAssertTrue(sidebarButton.contains(".accessibilityIdentifier(\"companion-sidebar-\\(section.rawValue)\")"))
        XCTAssertTrue(sidebarButton.contains(".frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)"))
        XCTAssertFalse(compactTabBar.contains("private func compactTabMinWidth(for section: CompanionAppSection) -> CGFloat"))
        XCTAssertFalse(compactTabBar.contains("ScrollView(.horizontal"))
        XCTAssertFalse(compactTabBar.contains(".frame(maxWidth: .infinity, minHeight: 34)"))
        XCTAssertTrue(compactTabBar.contains("? Color.klmsSelectedBackground"))
        XCTAssertTrue(compactTabBar.contains(": Color.klmsSubtleCardBackground.opacity(0.54)"))
        XCTAssertTrue(compactTabBar.contains("RoundedRectangle(cornerRadius: 12)"))
        XCTAssertTrue(compactTabBar.contains("isSelected ? Color.klmsSelectedBorder : Color.klmsBorder.opacity(0.38)"))
        XCTAssertFalse(compactTabBar.contains(".shadow(color: isSelected ? Color.klmsSelectedBorder.opacity(0.10) : Color.clear"))
        XCTAssertTrue(compactTabBar.contains(".buttonStyle(KLMSCardButtonStyle())"))
        XCTAssertTrue(remoteDiagnosticPanel.contains(".frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)"))
        XCTAssertTrue(companionDiagnosticDisclosure.contains(".accessibilityIdentifier(\"companion-diagnostic-\\(title)\")"))
        XCTAssertTrue(mailPasteAnalyzerPanel.contains(".accessibilityIdentifier(\"mail-paste-analyzer-disclosure\")"))
        XCTAssertTrue(relayConnectionPanel.contains(".accessibilityIdentifier(\"server-relay-disclosure\")"))
        XCTAssertTrue(remoteSettingGroupSection.contains(".accessibilityIdentifier(\"remote-setting-group-\\(group.title)\")"))
        XCTAssertTrue(remoteSettingGroupSection.contains(".contentShape(RoundedRectangle(cornerRadius: 10))"))
        XCTAssertTrue(remoteSettingGroupSection.contains("DeferredInteractionExpansion(isExpanded: isExpanded)"))
        XCTAssertFalse(compactTabBar.contains("Label(section.compactTitle, systemImage:"))
        XCTAssertTrue(compactTabBar.contains(".padding(6)"))
        XCTAssertFalse(compactTabBar.contains(".padding(.horizontal, 6)"))
        XCTAssertFalse(compactTabBar.contains(".padding(7)"))
        XCTAssertFalse(compactTabBar.contains(".frame(height: 56)"))
        XCTAssertTrue(compactTabBar.contains("RoundedRectangle(cornerRadius: 14)"))
        XCTAssertTrue(compactTabBar.contains("RoundedRectangle(cornerRadius: 12)"))
        XCTAssertTrue(sectionContent.contains("CompanionDashboardCategoryScreen(title: \"파일\", category: .files"))
        XCTAssertTrue(sectionContent.contains("CompanionDashboardCategoryScreen(title: \"공지\", category: .notices"))
        XCTAssertTrue(sectionContent.contains("CompanionTasksScreen"))
        XCTAssertTrue(sectionContent.contains("CompanionDashboardCategoryScreen(title: \"캘린더\", category: .calendar"))
        XCTAssertTrue(sectionContent.contains("CompanionSettingsScreen"))
        XCTAssertTrue(statusScreen.contains("CompanionScreenContainer("))
        XCTAssertTrue(statusScreen.contains("title: horizontalSizeClass == .regular ? \"대시보드\" : \"상태\""))
        XCTAssertFalse(statusScreen.contains("showsAttentionStack: false"))
        XCTAssertFalse(statusScreen.contains("CompanionScreenContainer(title: \"대시보드\""))
        XCTAssertFalse(statusScreen.contains("RemoteDashboardStatusStrip"))
        XCTAssertFalse(statusScreen.contains("shouldShowCompactStatusStrip"))
        XCTAssertFalse(statusScreen.contains(".transition(.opacity.combined(with: .move(edge: .top)))"))
        XCTAssertTrue(statusScreen.contains("RemoteDashboardSyncCard"))
        XCTAssertTrue(statusScreen.contains("CompanionDashboardQuickAccessGrid("))
        XCTAssertLessThan(
            try XCTUnwrap(statusScreen.range(of: "CompanionDashboardQuickAccessGrid(")).lowerBound,
            try XCTUnwrap(statusScreen.range(of: "RemoteDashboardMetricOverview(")).lowerBound
        )
        XCTAssertTrue(statusScreen.contains("if horizontalSizeClass != .regular"))
        XCTAssertTrue(statusScreen.contains("private func selectDashboardCategory(_ category: DashboardMetricCategory)"))
        XCTAssertTrue(statusScreen.contains("private func selectChangeSummary(_ kind: RemoteChangeSummaryKind)"))
        XCTAssertTrue(statusScreen.contains("companionPerformWithoutAnimation {\n            selectedChangeSummary = nil\n            selectedDashboardPreview = category\n            displayedDashboardPreview = nil"))
        XCTAssertTrue(statusScreen.contains("deferDashboardPreview(category)"))
        XCTAssertTrue(statusScreen.contains("await Task.yield()"))
        XCTAssertTrue(statusScreen.contains("companionPerformWithoutAnimation {\n            selectedDashboardPreview = nil\n            displayedDashboardPreview = nil\n            selectedChangeSummary = kind"))
        XCTAssertTrue(ios.contains("private struct CompanionDashboardQuickAccessGrid"))
        let quickAccessGrid = try sourceStructBody(named: "CompanionDashboardQuickAccessGrid", in: ios)
        XCTAssertTrue(quickAccessGrid.contains("[.files, .assignments, .exams, .notices, .calendar]"))
        XCTAssertTrue(quickAccessGrid.contains("if isDataLoaded"))
        XCTAssertTrue(quickAccessGrid.contains("CompanionDashboardDataLoadingCard("))
        XCTAssertTrue(quickAccessGrid.contains(".frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)"))
        XCTAssertTrue(quickAccessGrid.contains(".accessibilityLabel(\"\\(category.title) \\(value)개 바로 보기\")"))
        XCTAssertTrue(quickAccessGrid.contains(".accessibilityHint(\"\\(category.title) 상세를 바로 아래에 표시합니다.\")"))
        XCTAssertFalse(quickAccessGrid.contains(".onTapGesture"))
        XCTAssertTrue(metricOverview.contains("if !isDataLoaded"))
        XCTAssertTrue(metricOverview.contains("if isDataLoaded && metricSnapshot.shouldShowAttentionMetricSection"))
        XCTAssertTrue(metricOverview.contains("if isDataLoaded && metricSnapshot.hasVisibleChangeSummary"))
        XCTAssertFalse(metricOverview.contains("if metricSnapshot.shouldShowAttentionMetricSection"))
        XCTAssertFalse(metricOverview.contains("if metricSnapshot.hasVisibleChangeSummary"))
        XCTAssertFalse(ios.contains("openDashboardCategoryFromOverview"))
        XCTAssertFalse(dashboardSyncCard.contains("RemoteAttentionStack(model: model)"))
        XCTAssertTrue(ios.contains("private struct RemoteAttentionSnapshot: Equatable"))
        XCTAssertTrue(ios.contains("private struct RemoteAttentionStackContent: View, Equatable"))
        XCTAssertTrue(ios.contains("private struct RemoteRunningStatusBanner"))
        XCTAssertLessThan(
            remoteAttentionStackContent.range(of: "ErrorBanner(message: snapshot.errorMessage)")!.lowerBound,
            remoteAttentionStackContent.range(of: "AuthSuccessBanner(message: message)")!.lowerBound
        )
        XCTAssertTrue(ios.contains("RemoteRunningStatusBanner(snapshot: snapshot, onCancel: onCancel)"))
        XCTAssertTrue(remoteRunningStatusBanner.contains("ProgressView()"))
        XCTAssertTrue(remoteRunningStatusBanner.contains("Image(systemName: \"stop.circle.fill\")"))
        XCTAssertTrue(remoteRunningStatusBanner.contains(".accessibilityHidden(true)"))
        XCTAssertTrue(remoteRunningStatusBanner.contains(".accessibilityLabel(\"\\(snapshot.runningTitle). \\(statusMessage)\")"))
        XCTAssertTrue(remoteRunningStatusBanner.contains(".accessibilityHint(cancelAlreadyRequested ? \"Mac이 실행 중단 요청을 확인하고 있습니다.\" : \"중요한 실행 상태입니다.\")"))
        XCTAssertTrue(remoteRunningStatusBanner.contains(".accessibilitySortPriority(90)"))
        XCTAssertTrue(authCodeHero.contains(".accessibilityLabel(\"KAIST 인증 번호 \\(digits). 휴대폰 인증 화면에서 같은 번호를 선택하세요.\")"))
        XCTAssertTrue(authCodeHero.contains(".accessibilitySortPriority(100)"))
        XCTAssertTrue(loginAttentionBanner.contains(".accessibilityLabel(\"로그인 필요. \\(message)\")"))
        XCTAssertTrue(authSuccessBanner.contains(".accessibilityLabel(\"인증 완료. \\(message)\")"))
        XCTAssertTrue(authSuccessBanner.contains(".frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)"))
        XCTAssertTrue(errorBanner.contains(".lineLimit(2)"))
        XCTAssertTrue(errorBanner.contains(".accessibilityLabel(\"오류. \\(message)\")"))
        XCTAssertTrue(errorBanner.contains(".accessibilityHint(\"전체 오류 내용은 로그 탭에서 확인할 수 있습니다.\")"))
        XCTAssertTrue(errorBanner.contains(".accessibilitySortPriority(95)"))
        XCTAssertTrue(errorBanner.contains(".frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)"))
        XCTAssertTrue(loginAttentionBanner.contains(".frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)"))
        XCTAssertFalse(ios.contains("private struct RemoteCancelControl"))
        XCTAssertTrue(ios.contains("var activeItemAction: ServerRelayItemAction?"))
        XCTAssertTrue(ios.contains("var activeSettingAction: ServerRelaySettingAction?"))
        XCTAssertTrue(ios.contains("recentItemActions.contains(where: \\.isActiveForCompanionDisplay)"))
        XCTAssertTrue(ios.contains("recentSettingActions.contains(where: \\.isActiveForCompanionDisplay)"))
        XCTAssertTrue(ios.contains("recentItemActions.first(where: \\.isActiveForCompanionDisplay)"))
        XCTAssertTrue(ios.contains("recentSettingActions.first(where: \\.isActiveForCompanionDisplay)"))
        XCTAssertTrue(ios.contains("normalizedMessage.localizedStandardContains(\"서버 화면에 바로 반영\")"))
        XCTAssertTrue(ios.contains("normalizedMessage.localizedStandardContains(\"서버 화면에는 바로 반영\")"))
        XCTAssertTrue(ios.contains("normalizedMessage.localizedStandardContains(\"서버 설정에 바로 반영\")"))
        XCTAssertFalse(ios.contains("status == .completed\n            && message.localizedStandardContains(\"서버 설정에 바로 반영\")"))
        XCTAssertTrue(ios.contains("serverRelayBootstrapTokenFingerprint(serverToken)"))
        XCTAssertTrue(ios.contains("private static func serverRelayBootstrapTokenFingerprint(_ token: String) -> String"))
        XCTAssertTrue(ios.contains("var hasActiveNonCommandWork: Bool"))
        XCTAssertTrue(ios.contains("var activeAttentionTitle: String"))
        XCTAssertTrue(ios.contains("return \"동기화 중단 중\""))
        XCTAssertTrue(ios.contains("shouldShowRunningStatus: model.hasActiveServerWork || model.status.phase == \"running\""))
        XCTAssertTrue(ios.contains("runningTitle: model.activeAttentionTitle"))
        XCTAssertTrue(ios.contains("파일 열기 요청을 서버에 올렸습니다. Mac 확인을 기다리는 중입니다."))
        XCTAssertTrue(ios.contains("파일 링크를 준비 중입니다."))
        XCTAssertTrue(ios.contains("설정 저장 요청이"))
        XCTAssertTrue(ios.contains("if !serverRelayConfigured {\n            return \"서버 연결 정보를 저장하면 상태를 불러옵니다.\""))
        XCTAssertTrue(ios.contains("if !hasLoadedServerSyncData {\n            return \"서버 요약을 불러오는 중입니다.\""))
        XCTAssertTrue(ios.contains("private func activeStatusText(_ status: ServerRelayItemActionStatus) -> String"))
        XCTAssertTrue(ios.contains("private func activeStatusText(_ status: ServerRelaySettingActionStatus) -> String"))
        XCTAssertTrue(ios.contains(".equatable()"))
        XCTAssertTrue(remoteRunningStatusBanner.contains("Text(snapshot.runningTitle)"))
        XCTAssertTrue(remoteRunningStatusBanner.contains("if snapshot.shouldShowCancelControl"))
        XCTAssertTrue(remoteRunningStatusBanner.contains("await onCancel()"))
        XCTAssertTrue(remoteRunningStatusBanner.contains("return \"요청 중\""))
        XCTAssertTrue(remoteRunningStatusBanner.contains("return \"중단\""))
        XCTAssertTrue(remoteRunningStatusBanner.contains("Label(cancelButtonTitle"))
        XCTAssertTrue(remoteRunningStatusBanner.contains(".frame(minHeight: 44)"))
        XCTAssertTrue(statusSummaryColumn.contains("RemoteDashboardMetricOverview"))
        XCTAssertTrue(statusSummaryColumn.contains("hasFileCleanupDetails: model.dashboardHasFileCleanupDetails,\n                showsLoadingPlaceholder: false"))
        XCTAssertLessThan(
            try XCTUnwrap(statusSummaryColumn.range(of: "RemoteDashboardMetricOverview(")).lowerBound,
            try XCTUnwrap(statusSummaryColumn.range(of: "compactDashboardDetail")).lowerBound
        )
        XCTAssertLessThan(
            try XCTUnwrap(statusSummaryColumn.range(of: "RemoteDashboardMetricOverview(")).lowerBound,
            try XCTUnwrap(statusSummaryColumn.range(of: "WorkstationDashboardEmptyGuidePanel()")).lowerBound
        )
        XCTAssertTrue(statusScreen.contains("@State private var displayedDashboardPreview: DashboardMetricCategory?"))
        XCTAssertFalse(statusScreen.contains("@State private var displayedChangeSummary: RemoteChangeSummaryKind?"))
        XCTAssertTrue(statusScreen.contains("displayedDashboardPreview = nil"))
        XCTAssertFalse(statusScreen.contains("displayedChangeSummary = nil"))
        XCTAssertFalse(statusScreen.contains("상세 준비 중"))
        XCTAssertFalse(statusScreen.contains("@State private var deferredStatusDetailTask"))
        XCTAssertFalse(statusScreen.contains("deferredStatusDetailTask = Task"))
        XCTAssertFalse(statusScreen.contains("try? await Task.sleep(nanoseconds: CompanionLargeList.detailRenderDelayNanoseconds)"))
        XCTAssertTrue(statusScreen.contains("statusDetailColumn"))
        XCTAssertTrue(statusScreen.contains("statusRegularWorkspace"))
        XCTAssertFalse(statusScreen.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(statusScreen.contains("VStack(alignment: .leading, spacing: 12)"))
        XCTAssertTrue(statusScreen.contains("DashboardCategoryInlineDetailPanel(category: category, model: model)"))
        XCTAssertTrue(statusScreen.contains("if model.hasLoadedServerSyncData"))
        XCTAssertTrue(statusScreen.contains("WorkstationDashboardRunSummaryCard(status: model.dashboardStatus)"))
        XCTAssertTrue(statusDetailColumn.contains("CompanionDashboardDataLoadingCard("))
        XCTAssertTrue(statusDetailColumn.contains("isLoading: model.isLoadingServerSyncData"))
        XCTAssertTrue(statusDetailColumn.contains("didFail: model.connectionSucceeded == false"))
        XCTAssertTrue(statusDetailColumn.contains("failureMessage: model.errorMessage"))
        XCTAssertTrue(statusDetailColumn.contains("WorkstationDashboardEmptyGuidePanel()"))
        XCTAssertLessThan(
            try XCTUnwrap(statusDetailColumn.range(of: "CompanionDashboardDataLoadingCard(")).lowerBound,
            try XCTUnwrap(statusDetailColumn.range(of: "WorkstationDashboardEmptyGuidePanel()")).lowerBound
        )
        XCTAssertTrue(categoryScreen.contains("CompanionCategoryDataLoadingState("))
        XCTAssertTrue(tasksScreen.contains("CompanionCategoryDataLoadingState("))
        XCTAssertTrue(categoryDetailPanel.contains("CompanionCategoryDataLoadingState("))
        XCTAssertTrue(categoryLoadingState.contains("CompanionDashboardDataLoadingCard("))
        XCTAssertTrue(categoryLoadingState.contains("isLoading: isLoading"))
        XCTAssertTrue(categoryLoadingState.contains("didFail: didFail"))
        XCTAssertTrue(categoryLoadingState.contains("failureMessage: failureMessage"))
        XCTAssertTrue(categoryLoadingState.contains("case .files:"))
        XCTAssertTrue(categoryLoadingState.contains("case .notices:"))
        XCTAssertTrue(categoryLoadingState.contains("case .calendar:"))
        XCTAssertTrue(categoryLoadingState.contains("서버 연결 정보를 저장하면 이 화면이 채워집니다."))
        XCTAssertTrue(categoryLoadingState.contains(".accessibilityLabel(\"\\(categoryLoadingTitle). \\(categoryLoadingSubtitle)\")"))
        XCTAssertTrue(metricOverview.contains("var showsLoadingPlaceholder = true"))
        XCTAssertTrue(metricOverview.contains("if showsLoadingPlaceholder {"))
        XCTAssertTrue(metricOverview.contains("isLoading: model.isLoadingServerSyncData"))
        XCTAssertTrue(metricOverview.contains("didFail: model.connectionSucceeded == false"))
        XCTAssertTrue(metricOverview.contains("failureMessage: model.errorMessage"))
        XCTAssertTrue(metricOverview.contains("isDataLoaded\n            && horizontalSizeClass != .regular"))
        let rebuildDashboardStatus = try sourceBody(
            after: "private func rebuildDashboardStatus()",
            in: ios,
            description: "iOS dashboard status rebuild"
        )
        XCTAssertTrue(rebuildDashboardStatus.contains("status.withAuthoritativeDashboardCounts("))
        XCTAssertTrue(rebuildDashboardStatus.contains("visibleCounts: dashboardVisibleCounts"))
        XCTAssertTrue(rebuildDashboardStatus.contains("calendarChanges: visibleCalendarChangesCache"))
        XCTAssertFalse(rebuildDashboardStatus.contains("next.applyMailDashboardItems"))
        let withoutDashboardCounts = try sourceBody(
            after: "func withoutDashboardCounts() -> SanitizedRemoteStatus",
            in: ios,
            description: "iOS dashboard status without loaded sync data"
        )
        XCTAssertFalse(withoutDashboardCounts.contains("assignments: assignments"))
        XCTAssertFalse(withoutDashboardCounts.contains("exams: exams"))
        XCTAssertFalse(withoutDashboardCounts.contains("notices: notices"))
        XCTAssertFalse(withoutDashboardCounts.contains("fileTotal: fileTotal"))
        XCTAssertTrue(withoutDashboardCounts.contains("phase: phase"))
        XCTAssertTrue(withoutDashboardCounts.contains("authDigits: authDigits"))
        XCTAssertTrue(ios.contains("var nextVisibleCounts = CompanionDashboardVisibleCounts()"))
        XCTAssertTrue(ios.contains("let defaultStatusFilter = CompanionItemStatusFilter.defaultFilter(for: category)"))
        XCTAssertTrue(ios.contains("if defaultStatusFilter.includes(item) {\n                    defaultVisibleCount += 1"))
        XCTAssertTrue(ios.contains("nextVisibleCounts[category] = defaultVisibleCount"))
        XCTAssertTrue(ios.contains("dashboardVisibleCounts = nextVisibleCounts"))
        XCTAssertTrue(ios.contains("func withAuthoritativeDashboardCounts("))
        XCTAssertTrue(ios.contains("visibleCounts: CompanionDashboardVisibleCounts"))
        XCTAssertTrue(ios.contains("next.assignments = visibleCounts.assignments"))
        XCTAssertTrue(ios.contains("next.fileTotal = visibleCounts.files"))
        XCTAssertFalse(ios.contains("itemsByCategoryID: [String: [ServerRelaySyncItem]]"))
        XCTAssertTrue(ios.contains("let calendarCounts = Self.calendarCounts(in: calendarChanges)"))
        XCTAssertTrue(ios.contains("next.calendarCreated = calendarCounts.created"))
        XCTAssertTrue(ios.contains("next.calendarUpdated = calendarCounts.updated"))
        XCTAssertTrue(ios.contains("next.calendarDeleted = calendarCounts.deleted"))
        XCTAssertFalse(ios.contains("Self.calendarCount(in: calendarChanges"))
        XCTAssertTrue(ios.contains("case \"created\", \"mail\":\n                counts.created += 1"))
        XCTAssertTrue(ios.contains("didSet { rebuildVisibleCalendarChanges(); rebuildDashboardDerivedState() }"))
        XCTAssertFalse(ios.contains("didSet { rebuildVisibleCalendarChanges(); rebuildDashboardDerivedState(); rebuildChangeSummaryItemLookup() }"))
        XCTAssertTrue(statusScreen.contains("WorkstationDashboardOverviewData(model: model)"))
        XCTAssertTrue(statusScreen.contains("showsMetrics: false"))
        XCTAssertTrue(statusScreen.contains("onOpenCategory: { category in"))
        XCTAssertTrue(statusScreen.contains("selectDashboardCategory(category)"))
        XCTAssertFalse(statusScreen.contains("title: \"항목 선택\""))
        XCTAssertFalse(statusScreen.contains("파일, 과제, 공지, 시험, 캘린더 중 하나를 선택하면"))
        XCTAssertFalse(statusScreen.contains("DashboardCategoryInlineDetailPanel(category: defaultWorkstationDetailCategory, model: model)"))
        XCTAssertFalse(statusScreen.contains("private var defaultWorkstationDetailCategory"))
        XCTAssertFalse(statusScreen.contains("DashboardMetricCategory.defaultWorkstationDetail(for: model.dashboardStatus)"))
        XCTAssertTrue(statusScreen.contains("private var effectiveDashboardSelection"))
        XCTAssertTrue(statusScreen.contains("return nil"))
        XCTAssertGreaterThanOrEqual(statusScreen.components(separatedBy: "effectiveSelectedCategory: effectiveDashboardSelection").count - 1, 2)
        XCTAssertFalse(statusScreen.contains("CompanionItemListPrewarmView(model: model, categories: dashboardPrewarmCategories)"))
        XCTAssertFalse(statusScreen.contains("private var dashboardPrewarmCategories"))
        XCTAssertFalse(statusScreen.contains("[.files, .assignments, .notices, .exams, .helpDesk]\n            .filter"))
        XCTAssertTrue(statusScreen.contains("WorkstationDashboardOverviewPanel("))
        XCTAssertTrue(statusScreen.contains("HStack(alignment: .top, spacing: CompanionWorkstationMetrics.columnSpacing)"))
        XCTAssertTrue(statusScreen.contains("statusMainColumn"))
        XCTAssertTrue(statusScreen.contains("statusCommandColumn"))
        XCTAssertTrue(statusScreen.contains("statusMetricColumn"))
        XCTAssertTrue(statusScreen.contains("minWidth: CompanionWorkstationMetrics.listColumnMinWidth"))
        XCTAssertTrue(statusScreen.contains("idealWidth: CompanionWorkstationMetrics.listColumnIdealWidth"))
        XCTAssertTrue(statusScreen.contains("maxWidth: CompanionWorkstationMetrics.listColumnMaxWidth"))
        XCTAssertTrue(statusScreen.contains("minWidth: CompanionWorkstationMetrics.detailColumnMinWidth"))
        XCTAssertTrue(statusScreen.contains("idealWidth: CompanionWorkstationMetrics.detailColumnIdealWidth"))
        XCTAssertFalse(statusScreen.contains("minWidth: CompanionWorkstationMetrics.commandColumnMinWidth"))
        XCTAssertFalse(statusScreen.contains("minWidth: CompanionWorkstationMetrics.metricColumnMinWidth"))
        XCTAssertFalse(statusScreen.contains("minWidth: CompanionWorkstationMetrics.compactCommandColumnMinWidth"))
        XCTAssertFalse(statusScreen.contains("idealWidth: CompanionWorkstationMetrics.compactCommandColumnIdealWidth"))
        XCTAssertFalse(statusScreen.contains("maxWidth: CompanionWorkstationMetrics.compactCommandColumnMaxWidth"))
        XCTAssertFalse(statusScreen.contains("minWidth: CompanionWorkstationMetrics.compactDetailColumnMinWidth"))
        XCTAssertFalse(statusScreen.contains("idealWidth: CompanionWorkstationMetrics.compactDetailColumnIdealWidth"))
        XCTAssertFalse(statusScreen.contains("WorkstationDashboardDetailPanel"))
        XCTAssertFalse(metricOverview.contains("CompactDashboardSelectionPanel(category: selectedCategory, model: model)"))
        XCTAssertFalse(metricOverview.contains("RemoteChangeSummaryDetailPanel(kind: selectedChangeSummary, model: model)"))
        XCTAssertTrue(metricOverview.contains("let model: CompanionModel"))
        XCTAssertTrue(metricOverview.contains("var status: SanitizedRemoteStatus"))
        XCTAssertTrue(metricOverview.contains("var hasFileCleanupDetails: Bool"))
        XCTAssertTrue(metricOverview.contains("var effectiveSelectedCategory: DashboardMetricCategory? = nil"))
        XCTAssertTrue(metricOverview.contains("isSelected: isSelected(category)"))
        XCTAssertTrue(metricOverview.contains("(effectiveSelectedCategory ?? selectedCategory) == category"))
        XCTAssertFalse(metricOverview.contains("@ObservedObject var model"))
        XCTAssertFalse(metricOverview.contains("model.dryRunReports.contains"))
        XCTAssertFalse(metricOverview.contains("var displayedCategory: DashboardMetricCategory?"))
        XCTAssertFalse(metricOverview.contains("var displayedChangeSummary: RemoteChangeSummaryKind?"))
        XCTAssertFalse(metricOverview.contains("displayedKind: displayedChangeSummary"))
        XCTAssertFalse(metricOverview.contains("if let selectedCategory, categories.contains(selectedCategory)"))
        XCTAssertFalse(metricOverview.contains("compactMetricDetail(for: selectedCategory)"))
        XCTAssertFalse(metricOverview.contains("DashboardCategoryInlineDetailPanel(category: category, model: model)"))
        XCTAssertTrue(statusScreen.contains("compactDashboardDetail"))
        XCTAssertTrue(statusScreen.contains("if let kind = selectedChangeSummary"))
        XCTAssertTrue(statusScreen.contains("let category = displayedDashboardPreview"))
        XCTAssertTrue(statusScreen.contains("DashboardCategoryInlineDetailPanel(category: category, model: model)"))
        XCTAssertFalse(metricOverview.contains("if displayedCategory == category"))
        XCTAssertTrue(metricOverview.contains("private func selectCategory(_ category: DashboardMetricCategory)"))
        XCTAssertTrue(metricOverview.contains("companionPerformWithoutAnimation {\n            selectedCategory = category\n            onCategoryTap(category)"))
        XCTAssertFalse(remoteChangeSummary.contains("var displayedKind: RemoteChangeSummaryKind?"))
        XCTAssertTrue(remoteChangeSummary.contains("let model: CompanionModel"))
        XCTAssertTrue(metricOverview.contains("var showsCompactChangeDetail = true"))
        XCTAssertTrue(metricOverview.contains("showsCompactDetail: showsCompactChangeDetail"))
        XCTAssertTrue(remoteChangeSummary.contains("var showsCompactDetail = true"))
        XCTAssertTrue(remoteChangeSummary.contains("compactChangeDetail(for: selectedKind)"))
        XCTAssertTrue(remoteChangeSummary.contains("if horizontalSizeClass != .regular"))
        XCTAssertTrue(remoteChangeSummary.contains("RemoteChangeSummaryDetailPanel("))
        XCTAssertTrue(remoteChangeSummary.contains("changedItems: model.cachedChangeSummaryItems(for: kind.rawValue)"))
        XCTAssertTrue(remoteChangeSummary.contains("changedCalendarItems: model.cachedChangeSummaryCalendarChanges(for: kind.rawValue)"))
        XCTAssertTrue(remoteChangeSummary.contains("fileCleanupReports: model.cachedFileCleanupReportsForDashboard()"))
        XCTAssertTrue(remoteChangeSummaryDetail.contains("var changedItems: [ServerRelaySyncItem]"))
        XCTAssertTrue(remoteChangeSummaryDetail.contains("var changedCalendarItems: [CalendarChange]"))
        XCTAssertTrue(remoteChangeSummaryDetail.contains("var fileCleanupReports: [DryRunReport]"))
        XCTAssertFalse(remoteChangeSummaryDetail.contains("@ObservedObject var model"))
        XCTAssertFalse(remoteChangeSummaryDetail.contains("model.syncItems"))
        XCTAssertFalse(remoteChangeSummaryDetail.contains("model.visibleCalendarChanges().filter"))
        XCTAssertTrue(remoteChangeSummaryDetail.contains("selectedChangedItemStillVisible"))
        XCTAssertTrue(remoteChangeSummaryDetail.contains("clearStaleSelectedItemIfNeeded()"))
        XCTAssertTrue(remoteChangeSummaryDetail.contains(".onChange(of: selectedChangedItemStillVisible)"))
        XCTAssertFalse(deferredInlineItemDetail.contains("onChange(of: item.id)"))
        XCTAssertFalse(remoteChangeSummaryDetail.contains("model.dryRunReports.filter"))
        XCTAssertFalse(ios.contains("CompanionDashboardDetailPreparingView"))
        XCTAssertFalse(statusScreen.contains("RemoteLogSummaryPanel"))
        XCTAssertFalse(statusScreen.contains("RemoteCommandPanel"))
        XCTAssertFalse(dashboardSyncCard.contains("RemoteCancelControl(model: model, compact: compact)"))
        XCTAssertTrue(ios.contains("await model.cancelRunningCommand()"))
        XCTAssertTrue(dashboardSyncCard.contains("MailPasteAnalyzerPanel(model: model)"))
        XCTAssertFalse(ios.contains("private struct RemoteCommandPanel"))
        XCTAssertFalse(ios.contains("private struct RemoteDashboardStatusStrip"))
        XCTAssertFalse(ios.contains("private struct RemoteStatusHeader"))
        XCTAssertFalse(statusScreen.contains("RecentRemoteCommandsView"))
        XCTAssertFalse(authCodeHero.contains("Color.klmsPrimaryCommandButtonBackground"))
        XCTAssertFalse(authCodeHero.contains("Color.klmsPrimaryCommandButtonForeground"))
        XCTAssertTrue(authCodeHero.contains("Color.klmsWarningBorder"))
        XCTAssertTrue(authCodeHero.contains("Color.klmsWarningBackground"))
        XCTAssertFalse(ios.contains(".buttonStyle(KLMSActionButtonStyle(tone: .primary))"))
        XCTAssertTrue(ios.contains("private func companionPerformWithoutAnimation"))
        XCTAssertGreaterThanOrEqual(ios.components(separatedBy: "companionPerformWithoutAnimation {").count - 1, 10)
        XCTAssertFalse(ios.contains(".transition(.opacity)"))
        XCTAssertTrue(compactSelectedRow.contains("companionPerformWithoutAnimation"))
        XCTAssertFalse(compactSelectedRow.contains(".transition(.opacity)"))
        XCTAssertTrue(compactSelectedRow.contains(".accessibilityLabel(\"\\(rowBadge) \\(item.title.nilIfEmpty ?? \"제목 없음\")\")"))
        XCTAssertTrue(compactSelectedRow.contains(".accessibilityValue(expanded ? \"펼쳐짐\" : \"접힘\")"))
        XCTAssertTrue(compactSelectedRow.contains(".accessibilityHint(\"항목 상세와 처리 버튼을 \\(expanded ? \"접습니다\" : \"펼칩니다\").\")"))
        XCTAssertTrue(mailAnalysisResult.contains("companionPerformWithoutAnimation"))
        XCTAssertFalse(mailAnalysisResult.contains(".transition(.opacity)"))
        XCTAssertTrue(mailAnalysisResult.contains(".accessibilityValue(selectedItemID == item.id ? \"펼쳐짐\" : \"접힘\")"))
        XCTAssertTrue(mailAnalysisResult.contains(".accessibilityHint(selectedItemID == item.id ? \"관련 KLMS 항목 상세와 처리 버튼을 접습니다.\" : \"관련 KLMS 항목 상세와 처리 버튼을 펼칩니다.\")"))
        XCTAssertTrue(mailAnalysisResult.contains("matchedSelectionStillVisible"))
        XCTAssertTrue(mailAnalysisResult.contains("clearStaleMatchedSelectionIfNeeded()"))
        XCTAssertTrue(mailAnalysisResult.contains(".onChange(of: matchedSelectionStillVisible)"))
        XCTAssertTrue(remoteChangeSummaryDetail.contains("companionPerformWithoutAnimation"))
        XCTAssertTrue(remoteChangeSummaryDetail.contains(".accessibilityValue(selectedItemID == item.id ? \"펼쳐짐\" : \"접힘\")"))
        XCTAssertTrue(remoteChangeSummaryDetail.contains(".accessibilityHint(selectedItemID == item.id ? \"변경 항목 상세와 처리 버튼을 접습니다.\" : \"변경 항목 상세와 처리 버튼을 펼칩니다.\")"))
        XCTAssertFalse(remoteChangeSummaryDetail.contains("ServerSyncItemInlineDetailPanel(item: item, model: model)\n                                .transition(.opacity)"))
        let inlineRows = try sourceStructBody(named: "CompanionInlineItemRowsView", in: ios)
        let selectableRows = try sourceStructBody(named: "CompanionSelectableItemListRows", in: ios)
        XCTAssertTrue(inlineRows.contains("inlineSelectionStillVisible"))
        XCTAssertTrue(inlineRows.contains("optimisticExternalSelectionStillVisible"))
        XCTAssertTrue(inlineRows.contains("clearStaleInlineSelectionIfNeeded()"))
        XCTAssertTrue(inlineRows.contains("clearStaleExternalSelectionIfNeeded()"))
        XCTAssertTrue(selectableRows.contains("selectedItemStillVisible"))
        XCTAssertTrue(selectableRows.contains("clearStaleSelectionIfNeeded()"))
        XCTAssertTrue(deferredInlineItemDetail.contains("ServerSyncItemInlineDetailPanel(item: item, model: model)"))
        XCTAssertTrue(deferredInlineItemDetail.contains("transaction.animation = nil"))
        XCTAssertFalse(deferredInlineItemDetail.contains("@State private var loadedItemID"))
        XCTAssertFalse(deferredInlineItemDetail.contains("@State private var shouldRender = false"))
        XCTAssertFalse(deferredInlineItemDetail.contains("@State private var renderedItemID: String?"))
        XCTAssertFalse(deferredInlineItemDetail.contains("if renderedItemID == item.id"))
        XCTAssertFalse(deferredInlineItemDetail.contains("await Task.yield()"))
        XCTAssertFalse(deferredInlineItemDetail.contains("try? await Task.sleep(nanoseconds: CompanionLargeList.detailRenderDelayNanoseconds)"))
        XCTAssertFalse(ios.contains("private struct DeferredServerSyncItemDetailPreparingPanel"))
        XCTAssertFalse(ios.contains("Text(\"상세를 준비하는 중입니다.\")"))
        XCTAssertFalse(deferredInlineItemDetail.contains(".task(id: item.id)"))
        XCTAssertFalse(deferredInlineItemDetail.contains(".onDisappear"))
        XCTAssertTrue(deferredInlineItemDetail.contains(".id(item.id)"))
        XCTAssertEqual(
            ios.components(separatedBy: "ServerSyncItemInlineDetailPanel(item: item, model: model)").count - 1,
            1,
            "Item detail rendering should be mounted once through the shared wrapper."
        )
        XCTAssertGreaterThanOrEqual(
            ios.components(separatedBy: "DeferredServerSyncItemDetailPanel(item: item, model: model)").count - 1,
            5,
            "Companion item selections should reuse the same immediate detail wrapper across dashboard, changes, and mail analysis lists."
        )
        XCTAssertTrue(sharedRunLogRow.contains("companionPerformWithoutAnimation"))
        XCTAssertTrue(serverRequestLogRow.contains("companionPerformWithoutAnimation"))
        XCTAssertTrue(remoteFileAccessRequestRow.contains("companionPerformWithoutAnimation"))
        XCTAssertTrue(remoteCommandRow.contains("companionPerformWithoutAnimation"))
        for row in [sharedRunLogRow, serverRequestLogRow, remoteFileAccessRequestRow, remoteCommandRow] {
            XCTAssertTrue(row.contains("Button {"))
            XCTAssertFalse(row.contains(".onTapGesture"))
            XCTAssertTrue(row.contains(".accessibilityLabel"))
            XCTAssertTrue(row.contains(".buttonStyle(KLMSCardButtonStyle"))
        }
        XCTAssertFalse(ios.contains(".frame(maxWidth: .infinity, minHeight: 38)"))
        XCTAssertFalse(ios.contains(".frame(width: 38, height: 38)"))
        XCTAssertTrue(ios.contains(".frame(width: 44, height: 44)"))
        XCTAssertFalse(ios.contains(".frame(maxWidth: .infinity, minHeight: 36)"))
        XCTAssertFalse(ios.contains(".frame(maxWidth: .infinity, minHeight: 34)"))
        XCTAssertFalse(ios.contains(".frame(minHeight: 32)"))
        XCTAssertTrue(inlineItemDetail.contains("Text(\"항목 처리\")"))
        XCTAssertTrue(inlineItemDetail.contains("Text(\"동기화\")"))
        XCTAssertTrue(inlineItemDetail.contains("Label(\"\\(relevantCommand.displayName) 다시 실행\""))
        XCTAssertTrue(inlineItemDetail.contains("model.hasInFlightRequest && !hasImmediateServerActions"))
        XCTAssertTrue(inlineItemDetail.contains("let requiresMac = !action.isServerDisplayOnlyAction"))
        XCTAssertTrue(inlineItemDetail.contains("(requiresMac && (model.isSubmitting || model.hasInFlightRequest))"))
        XCTAssertFalse(inlineItemDetail.contains("Text(\"수정/삭제 선택\")"))
        XCTAssertFalse(inlineItemDetail.contains("Text(\"반영\")"))
        XCTAssertFalse(ios.contains("private struct ServerSyncItemDetailView"))
        XCTAssertTrue(ios.contains("case .fileTrash:\n            \"삭제\""))
        XCTAssertTrue(ios.contains("case .examPromote:\n            \"시험으로 등록\""))
        XCTAssertFalse(ios.contains("\"삭제/휴지통\""))
        XCTAssertFalse(ios.contains("\"삭제/숨김\""))
        XCTAssertFalse(ios.contains("\"반영/시험 확정\""))

        XCTAssertTrue(settingsScreen.contains("ServerRelayConnectionPanel"))
        XCTAssertFalse(settingsScreen.contains("InfoBanner(message: model.remoteAvailabilityMessage)"))
        XCTAssertTrue(settingsScreen.contains("CompanionImmediateSettingsPanel"))
        XCTAssertFalse(settingsScreen.contains("CompanionAppearancePanel"))
        XCTAssertTrue(settingsScreen.contains("RemoteSettingsPanel"))
        XCTAssertTrue(settingsScreen.contains("RemoteDiagnosticPanel"))
        XCTAssertFalse(immediateSettingsPanel.contains("@ObservedObject var model"))
        XCTAssertTrue(immediateSettingsPanel.contains("var selectedAppearanceMode: KLMSAppearanceMode"))
        XCTAssertTrue(immediateSettingsPanel.contains("var noticeNotesEnabled: Bool"))
        XCTAssertFalse(immediateSettingsPanel.contains("var isSubmitting: Bool"))
        XCTAssertTrue(immediateSettingsPanel.contains("var updateAppearanceMode: (KLMSAppearanceMode) async -> Void"))
        XCTAssertTrue(immediateSettingsPanel.contains("var updateNoticeNotes: (Bool) async -> Void"))
        XCTAssertTrue(immediateSettingsPanel.contains("CompanionAppearanceModeSelector("))
        XCTAssertTrue(immediateSettingsPanel.contains("selectedMode: selectedAppearanceMode"))
        XCTAssertFalse(immediateSettingsPanel.contains(".disabled(isSubmitting)"))
        XCTAssertFalse(immediateSettingsPanel.contains("Picker(\"화면 모드\""))
        XCTAssertFalse(immediateSettingsPanel.contains(".pickerStyle(.segmented)"))
        let appearanceModeSelector = try sourceStructBody(named: "CompanionAppearanceModeSelector", in: ios)
        XCTAssertFalse(appearanceModeSelector.contains("@ObservedObject var model"))
        XCTAssertTrue(appearanceModeSelector.contains("var selectedMode: KLMSAppearanceMode"))
        XCTAssertFalse(appearanceModeSelector.contains("var isSubmitting: Bool"))
        XCTAssertTrue(appearanceModeSelector.contains("var updateAppearanceMode: (KLMSAppearanceMode) async -> Void"))
        XCTAssertTrue(appearanceModeSelector.contains("ForEach(KLMSAppearanceMode.allCases)"))
        XCTAssertTrue(appearanceModeSelector.contains(".frame(maxWidth: .infinity, minHeight: 44)"))
        XCTAssertTrue(appearanceModeSelector.contains(".accessibilityLabel(\"화면 모드 \\(mode.title)\")"))
        XCTAssertTrue(appearanceModeSelector.contains(".accessibilityValue(selectedMode == mode ? \"선택됨\" : \"선택 안 됨\")"))
        XCTAssertTrue(appearanceModeSelector.contains(".accessibilityHint(\"KLMS Sync 화면 모드를 \\(mode.title)으로 바꿉니다.\")"))
        XCTAssertTrue(appearanceModeSelector.contains(".buttonStyle(KLMSCardButtonStyle(cornerRadius: 12))"))
        XCTAssertFalse(appearanceModeSelector.contains(".disabled(isSubmitting)"))
        XCTAssertTrue(settingsScreen.contains("@Environment(\\.horizontalSizeClass)"))
        XCTAssertTrue(settingsScreen.contains("if horizontalSizeClass == .regular"))
        XCTAssertTrue(settingsScreen.contains("settingsPrimaryColumn"))
        XCTAssertTrue(settingsScreen.contains("settingsSupportColumn"))
        XCTAssertTrue(settingsScreen.contains("selectedAppearanceMode: KLMSAppearanceMode(rawValue: model.sharedAppearanceModeValue) ?? .system"))
        XCTAssertTrue(settingsScreen.contains("noticeNotesEnabled: model.sharedNoticeUpdateNotesEnabled"))
        XCTAssertTrue(settingsScreen.contains("await model.updateSharedAppearanceMode(mode.rawValue)"))
        XCTAssertTrue(settingsScreen.contains("await model.updateSharedNoticeNotes(enabled)"))
        XCTAssertTrue(settingsScreen.contains("RemoteSettingsPanel(model: model, usesWideGrid: horizontalSizeClass == .regular)"))
        XCTAssertTrue(settingsScreen.contains("HStack(alignment: .top, spacing: CompanionWorkstationMetrics.columnSpacing)"))
        XCTAssertTrue(settingsScreen.contains("settingsRegularWorkspace"))
        XCTAssertTrue(settingsScreen.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(settingsScreen.contains("settingsWideColumns"))
        XCTAssertTrue(settingsScreen.contains("settingsStackedColumns"))
        XCTAssertTrue(settingsScreen.contains("minWidth: CompanionWorkstationMetrics.listColumnMinWidth"))
        XCTAssertTrue(settingsScreen.contains("idealWidth: CompanionWorkstationMetrics.listColumnIdealWidth"))
        XCTAssertTrue(settingsScreen.contains("maxWidth: CompanionWorkstationMetrics.listColumnMaxWidth"))
        XCTAssertTrue(settingsScreen.contains("minWidth: CompanionWorkstationMetrics.detailColumnMinWidth"))
        XCTAssertTrue(settingsScreen.contains("idealWidth: CompanionWorkstationMetrics.detailColumnIdealWidth"))
        let settingsRelayIndex = try XCTUnwrap(settingsScreen.range(of: "ServerRelayConnectionPanel(")?.lowerBound)
        let settingsDiagnosticIndex = try XCTUnwrap(settingsScreen.range(of: "RemoteDiagnosticPanel(")?.lowerBound)
        let settingsPrivacyIndex = try XCTUnwrap(settingsScreen.range(of: "RemotePrivacyNote()")?.lowerBound)
        XCTAssertLessThan(
            settingsScreen.distance(from: settingsScreen.startIndex, to: settingsDiagnosticIndex),
            settingsScreen.distance(from: settingsScreen.startIndex, to: settingsPrivacyIndex),
            "iPad settings should show diagnostics before the privacy note."
        )
        XCTAssertLessThan(
            settingsScreen.distance(from: settingsScreen.startIndex, to: settingsPrivacyIndex),
            settingsScreen.distance(from: settingsScreen.startIndex, to: settingsRelayIndex),
            "Server relay setup should stay at the bottom because it is needed less often after pairing."
        )
        XCTAssertFalse(settingsScreen.contains("RemoteLogSummaryPanel"))
        XCTAssertFalse(settingsScreen.contains("RecentRemoteCommandsView"))
        XCTAssertTrue(immediateSettingsPanel.contains("저장하면 모든 기기에 바로 적용됩니다."))
        XCTAssertFalse(immediateSettingsPanel.contains("서버에 바로 저장되어 Mac, iPhone, iPad, Windows가 같은 값을 씁니다."))
        XCTAssertTrue(immediateSettingsPanel.contains("끄면 원격 동기화에서 Notes 공지 메모만 건너뜁니다."))
        XCTAssertFalse(immediateSettingsPanel.contains("끄면 iPhone/iPad/Windows에서 실행한 동기화는 Notes 공지 메모 쓰기만 건너뜁니다."))
        XCTAssertFalse(immediateSettingsPanel.contains("withAnimation(.easeInOut(duration: 0.08))"))
        XCTAssertFalse(immediateSettingsPanel.contains("@State private var isExpanded"))
        XCTAssertFalse(immediateSettingsPanel.contains("CompanionExpansionBadge(isExpanded: isExpanded)"))
        XCTAssertFalse(immediateSettingsPanel.contains(".buttonStyle(KLMSCardButtonStyle(cornerRadius: 12))"))
        XCTAssertTrue(remoteSettingsPanel.contains("RemoteSettingsPanelContent("))
        XCTAssertTrue(remoteSettingsPanel.contains("settingGroups: model.remoteSettingGroups"))
        XCTAssertTrue(remoteSettingsPanel.contains("settingCount: model.remoteSettings.count"))
        XCTAssertTrue(remoteSettingsPanel.contains(".equatable()"))
        XCTAssertTrue(remoteSettingsPanelContent.contains("Mac에서 실행할 동기화 방식을 정합니다."))
        XCTAssertTrue(remoteSettingsPanelContent.contains("변경한 값은 서버에 저장되고 Mac 앱이 받아 적용합니다."))
        XCTAssertTrue(remoteSettingsPanelContent.contains("var usesWideGrid = false"))
        XCTAssertTrue(remoteSettingsPanelContent.contains("} else if usesWideGrid {"))
        XCTAssertTrue(remoteSettingsPanelContent.contains("LazyVGrid("))
        XCTAssertTrue(remoteSettingsPanelContent.contains("GridItem(.adaptive(minimum: 260)"))
        XCTAssertTrue(ios.contains("fileprivate var remoteSettingGroups: [RemoteSettingGroup] = []"))
        XCTAssertTrue(ios.contains("@Published var remoteSettings: [ServerRelaySetting] = [] {\n        didSet { rebuildRemoteSettingGroups() }"))
        XCTAssertTrue(ios.contains("private func rebuildRemoteSettingGroups()"))
        XCTAssertTrue(remoteSettingsPanelContent.contains("ForEach(settingGroups)"))
        XCTAssertFalse(remoteSettingsPanelContent.contains("RemoteSettingGroup.grouped(settings: model.remoteSettings)"))
        XCTAssertTrue(remoteSettingsPanelContent.contains("nonisolated static func =="))
        XCTAssertTrue(remoteSettingsPanelContent.contains("lhs.settingGroups == rhs.settingGroups"))
        XCTAssertFalse(remoteSettingGroupSection.contains("@ObservedObject var model"))
        XCTAssertFalse(remoteSettingRow.contains("@ObservedObject var model"))
        XCTAssertTrue(remoteSettingGroupSection.contains("var createSettingAction: (ServerRelaySetting, String) async -> Void"))
        XCTAssertTrue(remoteSettingRow.contains("var createSettingAction: (ServerRelaySetting, String) async -> Void"))
        XCTAssertFalse(remoteSettingRow.contains("|| isSubmitting"))
        XCTAssertTrue(remoteSettingRow.contains("Button(settingChoiceTitle(option))"))
        XCTAssertTrue(remoteSettingRow.contains("Text(settingChoiceTitle(setting.value.nilIfEmpty ?? \"\"))"))
        XCTAssertTrue(remoteSettingRow.contains("case \"manual-digits\":"))
        XCTAssertTrue(remoteSettingRow.contains("return \"인증번호 직접 선택\""))
        XCTAssertTrue(remoteSettingRow.contains("case \"quick\":"))
        XCTAssertTrue(remoteSettingRow.contains("return \"빠른 모드\""))
        XCTAssertTrue(remoteSettingRow.contains("KLMS가 로그인을 요구하면 인증번호를 찾아 상단 알림으로 보여줍니다."))
        XCTAssertFalse(remoteSettingRow.contains("로컬에 같은 파일이 있어도 다시 받습니다."))
        XCTAssertTrue(remoteSettingRow.contains("공지 메모의 읽음/중요 체크 상태를 매번 확인합니다."))
        XCTAssertTrue(remoteSettingRow.contains("제목, 시간, 장소가 이미 맞는 일정은 다시 쓰지 않습니다."))
        XCTAssertFalse(remoteSettingsPanelContent.contains("실행 엔진이 쓰는 값을 Mac 설정 파일에 반영합니다."))
        XCTAssertFalse(remoteSettingsPanelContent.contains("Mac 앱이 받아 config.env에 저장합니다."))
        XCTAssertFalse(remoteSettingsPanelContent.contains("withAnimation(.easeInOut(duration: 0.08))"))
        XCTAssertFalse(remoteSettingsPanelContent.contains(".transition(.opacity)"))
        XCTAssertFalse(remoteSettingsPanelContent.contains(".buttonStyle(KLMSCardButtonStyle(cornerRadius: 12))"))
        XCTAssertFalse(remoteSettingsPanelContent.contains("CompanionExpansionBadge(isExpanded: isExpanded)"))
        XCTAssertFalse(remoteDiagnosticPanel.contains("@ObservedObject var model"))
        let serverRelayConnectionPanel = try sourceStructBody(named: "ServerRelayConnectionPanel", in: ios)
        XCTAssertFalse(serverRelayConnectionPanel.contains("@ObservedObject var model"))
        XCTAssertTrue(serverRelayConnectionPanel.contains("@Binding var serverURL: String"))
        XCTAssertTrue(serverRelayConnectionPanel.contains("@Binding var serverToken: String"))
        XCTAssertTrue(serverRelayConnectionPanel.contains("var checkConnection: () async -> Void"))
        XCTAssertTrue(serverRelayConnectionPanel.contains("var refreshSummary: () async -> Void"))
        XCTAssertTrue(settingsScreen.contains("isConfigured: model.serverRelayConfigured"))
        XCTAssertTrue(settingsScreen.contains("serverURL: serverURLBinding"))
        XCTAssertTrue(settingsScreen.contains("serverToken: serverTokenBinding"))
        XCTAssertTrue(settingsScreen.contains("private var serverURLBinding: Binding<String>"))
        XCTAssertTrue(settingsScreen.contains("private var serverTokenBinding: Binding<String>"))
        XCTAssertTrue(settingsScreen.contains("await model.checkServerRelayConnection()"))
        XCTAssertTrue(settingsScreen.contains("await model.createCommand(.report)"))
        XCTAssertTrue(remoteDiagnosticPanel.contains("var verifySummary: ServerRelayVerifySummary?"))
        XCTAssertTrue(remoteDiagnosticPanel.contains("var stageDurations: [KLMSStageDuration]"))
        XCTAssertTrue(remoteDiagnosticPanel.contains("var dryRunReports: [DryRunReport]"))
        XCTAssertTrue(remoteDiagnosticPanel.contains("var commandsDisabled: Bool"))
        XCTAssertTrue(remoteDiagnosticPanel.contains("var createCommand: (RemoteCommandKind, Bool) async -> Void"))
        XCTAssertTrue(settingsScreen.contains("verifySummary: model.verifySummary"))
        XCTAssertTrue(settingsScreen.contains("stageDurations: model.latestSharedRunLogStageDurations"))
        XCTAssertTrue(settingsScreen.contains("dryRunReports: model.dryRunReports"))
        XCTAssertTrue(settingsScreen.contains("commandsDisabled: !model.isRemoteAvailable || model.hasInFlightRequest"))
        XCTAssertTrue(settingsScreen.contains("await model.createCommand(kind, dryRun: dryRun)"))
        XCTAssertTrue(remoteDiagnosticPanel.contains("companionPerformWithoutAnimation {\n                    isPanelExpanded.toggle()"))
        XCTAssertFalse(remoteDiagnosticPanel.contains("Button {\n                isPanelExpanded.toggle()"))
        XCTAssertTrue(remoteSettingsPanelContent.contains("Color.klmsCardBackground, in: RoundedRectangle(cornerRadius: 14)"))
        XCTAssertTrue(ios.contains("동기화 범위를 정합니다."))
        XCTAssertTrue(ios.contains("파일 탐색, 주차별 폴더, 보존 방식을 정합니다."))
        XCTAssertTrue(ios.contains("공지 메모의 접기, 양식, 상태 반영 방식을 정합니다."))
        XCTAssertTrue(ios.contains("같은 일정은 건너뛰고 변경이 있을 때만 반영합니다."))
        XCTAssertTrue(ios.contains("Safari 창 동작처럼 자주 바꾸지 않는 설정입니다."))
        XCTAssertFalse(ios.contains("var expandedDetail: String"))
        XCTAssertFalse(ios.contains("var hasExpandedDetail: Bool"))
        XCTAssertFalse(ios.contains("동기화 범위와 캘린더 반영 기준을 정합니다."))
        XCTAssertFalse(ios.contains("동기화 범위와 Calendar 반영 방식을 정합니다."))
        XCTAssertFalse(ios.contains("파일 탐색, 다운로드 건너뛰기, 폴더 정리 방식을 정합니다."))
        XCTAssertFalse(ios.contains("Notes 메모에 숨긴 공지를 쓸지, 변경 없는 메모를 다시 쓸지 정합니다."))
        XCTAssertTrue(remoteSettingGroupSection.contains("RoundedRectangle(cornerRadius: 12)"))
        XCTAssertFalse(remoteSettingGroupSection.contains("@State private var showsDetail"))
        XCTAssertFalse(remoteSettingGroupSection.contains("showsDetail.toggle()"))
        XCTAssertFalse(ios.contains("private struct CompanionInlineDetailBadge"))
        XCTAssertFalse(remoteSettingGroupSection.contains("private var shouldShowExpandedDetail"))
        XCTAssertFalse(remoteSettingGroupSection.contains("group.hasExpandedDetail && group.isCollapsible && isExpanded"))
        XCTAssertFalse(remoteSettingGroupSection.contains("CompanionSettingHelpText(group.expandedDetail)"))
        XCTAssertTrue(remoteSettingGroupSection.contains("Text(group.detail)"))
        XCTAssertTrue(remoteSettingGroupSection.contains(".lineLimit(2)"))
        XCTAssertFalse(remoteSettingGroupSection.contains("CompanionInlineDetailBadge(isExpanded: showsDetail)"))
        XCTAssertFalse(remoteSettingGroupSection.contains(".accessibilityLabel(\"\\(group.title) 설정 \\(isExpanded ? \"펼쳐짐\" : \"접힘\")\")"))
        XCTAssertFalse(remoteSettingGroupSection.contains(".accessibilityLabel(\"\\(group.title) 설명"))
        XCTAssertTrue(remoteSettingGroupSection.contains(".accessibilityElement(children: .combine)"))
        XCTAssertFalse(ios.contains("var isCollapsible: Bool"))
        XCTAssertTrue(remoteSettingGroupSection.contains("if group.isCollapsible"))
        XCTAssertTrue(remoteSettingGroupSection.contains("DeferredInteractionExpansion(isExpanded: isExpanded)"))
        XCTAssertFalse(remoteSettingGroupSection.contains("if isExpanded {\n                    groupSettingsRows"))
        XCTAssertTrue(remoteSettingGroupSection.contains("private var groupSettingsRows: some View"))
        XCTAssertTrue(remoteSettingGroupSection.contains("(!group.isCollapsible || isExpanded) ? Color.klmsSelectedBorder.opacity(0.48) : Color.klmsBorder.opacity(0.86)"))
        XCTAssertTrue(remoteSettingGroupSection.contains("ForEach(group.settings)"))
        XCTAssertTrue(remoteSettingGroupSection.contains(".stroke((!group.isCollapsible || isExpanded) ? Color.klmsSelectedBorder.opacity(0.48) : Color.klmsBorder.opacity(0.86), lineWidth: 1)"))
        XCTAssertTrue(remoteDiagnosticPanel.contains("상태 검사와 권한 점검은 필요할 때만 펼치세요."))
        XCTAssertTrue(remoteDiagnosticPanel.contains("CompanionExpansionBadge(isExpanded: isPanelExpanded)"))
        XCTAssertTrue(remoteDiagnosticPanel.contains("DeferredInteractionExpansion(isExpanded: isPanelExpanded)"))
        XCTAssertTrue(remoteDiagnosticPanel.contains("RoundedRectangle(cornerRadius: 14)"))
        XCTAssertTrue(remoteDiagnosticPanel.contains(".accessibilityLabel(\"진단 \\(isPanelExpanded ? \"펼쳐짐\" : \"접힘\")\")"))
        XCTAssertTrue(remoteDiagnosticPanel.contains("CompanionSettingsSubsectionCard("))
        XCTAssertTrue(remoteDiagnosticPanel.contains("title: \"고급 도구\""))
        XCTAssertTrue(remoteDiagnosticPanel.contains("collapsible: true"))
        XCTAssertTrue(relayConnectionPanel.contains("@State private var isExpanded = false"))
        XCTAssertFalse(relayConnectionPanel.contains("isExpanded = true"))
        XCTAssertFalse(relayConnectionPanel.contains(".onAppear"))
        XCTAssertFalse(relayConnectionPanel.contains(".onChange(of: isConfigured)"))
        XCTAssertFalse(relayConnectionPanel.contains("withAnimation(.easeInOut(duration: 0.08))"))
        XCTAssertFalse(relayConnectionPanel.contains(".transition(.opacity)"))
        XCTAssertTrue(relayConnectionPanel.contains(".buttonStyle(KLMSCardButtonStyle(cornerRadius: 12))"))
        XCTAssertTrue(relayConnectionPanel.contains(".accessibilityLabel(\"서버 릴레이 \\(isConfigured ? \"저장됨\" : \"미설정\") \\(isExpanded ? \"펼쳐짐\" : \"접힘\")\")"))
        XCTAssertTrue(relayConnectionPanel.contains("CompanionSettingsSubsectionCard("))
        XCTAssertTrue(relayConnectionPanel.contains("title: \"서버 연결 정보\""))
        XCTAssertTrue(relayConnectionPanel.contains("title: \"연결 확인\""))
        XCTAssertTrue(relayConnectionPanel.contains("title: \"복사\""))
        XCTAssertTrue(relayConnectionPanel.contains("title: \"연결 초기화\""))
        XCTAssertTrue(relayConnectionPanel.contains("연결 정보가 저장되어 있습니다."))
        XCTAssertTrue(relayConnectionPanel.contains("연결 정보를 붙여넣어 주세요."))
        XCTAssertTrue(relayConnectionPanel.contains("공개 HTTPS 주소만 넣습니다. 로컬 주소는 저장하지 않습니다."))
        XCTAssertTrue(relayConnectionPanel.contains("이 기기용 토큰입니다. Mac 전용 토큰은 넣지 않습니다."))
        XCTAssertTrue(relayConnectionPanel.contains("실제 KLMS 수집은 Mac 앱이 처리합니다."))
        XCTAssertTrue(relayConnectionPanel.contains("연결 확인은 동기화 없이 서버 응답만 검사합니다."))
        XCTAssertFalse(relayConnectionPanel.contains("서버 연결 정보가 저장되어 있습니다."))
        XCTAssertFalse(relayConnectionPanel.contains("Cloudflare 릴레이 연결 정보를 붙여넣어 주세요."))
        XCTAssertFalse(relayConnectionPanel.contains("집 주소"))
        XCTAssertFalse(relayConnectionPanel.contains("iPhone/iPad/Windows용 토큰입니다."))
        XCTAssertFalse(relayConnectionPanel.contains("Mac 앱에는 같은 서버 URL과 별도의 Mac 전용 토큰이 저장되어 있어야 합니다."))
        XCTAssertFalse(relayConnectionPanel.contains("Label(\"서버 릴레이 정보\", systemImage: \"link\")"))
        XCTAssertFalse(remotePrivacyNote.contains("withAnimation(.easeInOut(duration: 0.08))"))
        XCTAssertFalse(remotePrivacyNote.contains(".transition(.opacity)"))
        XCTAssertFalse(remotePrivacyNote.contains("@State private var isExpanded"))
        XCTAssertFalse(remotePrivacyNote.contains("Button {"))
        XCTAssertFalse(remotePrivacyNote.contains("companionPerformWithoutAnimation"))
        XCTAssertFalse(remotePrivacyNote.contains(".buttonStyle(KLMSCardButtonStyle(cornerRadius: 12))"))
        XCTAssertFalse(remotePrivacyNote.contains("CompanionExpansionBadge"))
        XCTAssertFalse(remotePrivacyNote.contains("if isExpanded"))
        XCTAssertFalse(remotePrivacyNote.contains(".accessibilityHint(isExpanded ?"))
        XCTAssertTrue(remotePrivacyNote.contains(".accessibilityElement(children: .combine)"))
        XCTAssertTrue(remotePrivacyNote.contains(".accessibilityLabel(\"개인정보와 서버 보관. 서버에는 실행 요청과 요약 상태만 저장됩니다. 파일 열기 요청 때만 Mac이 임시 링크를 만듭니다.\")"))
        XCTAssertTrue(remotePrivacyNote.contains("서버에는 실행 요청과 요약 상태만 저장됩니다."))
        XCTAssertTrue(remotePrivacyNote.contains("파일 열기를 요청할 때만 Mac이 임시 링크를 만들고, 만료되면 정리합니다."))
        XCTAssertFalse(remotePrivacyNote.contains("파일은 사용자가 열기를 요청할 때만 Mac 앱에서 임시로 올리고"))
        XCTAssertTrue(remotePrivacyNote.contains("RoundedRectangle(cornerRadius: 14)"))
        XCTAssertTrue(dashboardSyncCard.contains("primaryCommandTitle(isRunning: isRunning, isDisabled: isDisabled)"))
        XCTAssertTrue(dashboardSyncCard.contains("primaryCommandSystemImage(isRunning: isRunning, isDisabled: isDisabled)"))
        XCTAssertTrue(dashboardSyncCard.contains("return \"전체 동기화\""))
        XCTAssertFalse(dashboardSyncCard.contains("return \"Mac 연결 필요\""))
        XCTAssertFalse(dashboardSyncCard.contains("return \"잠시 대기\""))
        XCTAssertTrue(dashboardSyncCard.contains("return isRemoteAvailable ? \"준비됨\" : \"설정 필요\""))
        XCTAssertFalse(dashboardSyncCard.contains("return model.isRemoteAvailable ? \"준비됨\" : \"연결 필요\""))
        XCTAssertTrue(dashboardSyncCard.contains("isDisabled ? Color.klmsSecondaryText.opacity(0.76) : Color.klmsPrimaryCommandButtonForeground"))
        XCTAssertTrue(dashboardSyncCard.contains("if isDisabled { return Color.klmsSubtleCardBackground.opacity(0.86) }"))
        XCTAssertTrue(dashboardSyncCard.contains("if isDisabled { return Color.klmsCommandButtonBorder.opacity(0.64) }"))
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
        XCTAssertTrue(dashboardSyncCard.contains("let isDisabled = commandDisabled(for: kind)"))
        XCTAssertTrue(dashboardSyncCard.contains("secondaryCommandSystemImage(isRunning: isRunning, isDisabled: isDisabled)"))
        XCTAssertTrue(dashboardSyncCard.contains("return \"lock.fill\""))
        XCTAssertTrue(dashboardSyncCard.contains(".buttonStyle(KLMSCardButtonStyle(disabledOpacity: 1.0))"))
        XCTAssertTrue(dashboardSyncCard.contains(".frame(maxWidth: .infinity, minHeight: compact ? 44 : 46, alignment: .center)"))
        XCTAssertFalse(dashboardSyncCard.contains("minHeight: compact ? 42"))
        XCTAssertFalse(dashboardSyncCard.contains(".opacity(commandDisabled(for: kind) ? 0.62"))
        XCTAssertFalse(dashboardSyncCard.contains("if compact {\n                LazyVGrid(columns: secondaryColumns"))
        XCTAssertTrue(designSpec.contains("바로 아래에 `파일`, `과제/시험`, `공지` 개별 실행 버튼을 3열로 둔다."))
        XCTAssertTrue(designSpec.contains("설정: 앱 안의 왼쪽 작업 공간에서 처리한다. 별도 macOS Settings 창을 띄우지 않는다."))
        XCTAssertTrue(dashboardSyncCard.contains(".padding(.horizontal, 5)"))
        XCTAssertTrue(metricOverview.contains("if horizontalSizeClass == .regular"))
        XCTAssertTrue(metricOverview.contains("Text(title)"))
        let iosYearFieldIndex = try XCTUnwrap(companionItemListControls.range(of: "companionPickerField(title: \"연도\"")?.lowerBound)
        let iosSemesterFieldIndex = try XCTUnwrap(companionItemListControls.range(of: "companionPickerField(title: \"학기\"")?.lowerBound)
        let iosCourseFieldIndex = try XCTUnwrap(companionItemListControls.range(of: "companionPickerField(title: \"과목\"")?.lowerBound)
        XCTAssertLessThan(companionItemListControls.distance(from: companionItemListControls.startIndex, to: iosYearFieldIndex), companionItemListControls.distance(from: companionItemListControls.startIndex, to: iosCourseFieldIndex))
        XCTAssertLessThan(companionItemListControls.distance(from: companionItemListControls.startIndex, to: iosSemesterFieldIndex), companionItemListControls.distance(from: companionItemListControls.startIndex, to: iosCourseFieldIndex))
        XCTAssertTrue(companionItemListControls.contains(".frame(minHeight: 44)"))
        XCTAssertTrue(companionItemListControls.contains(".frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)"))
        XCTAssertTrue(companionItemListControls.contains(".accessibilityLabel(title)"))
        XCTAssertTrue(companionItemListControls.contains(".accessibilityValue(isSelected ? \"선택됨\" : \"선택 안 됨\")"))
        XCTAssertTrue(metricTile.contains("Color.klmsCardBackground"))
        XCTAssertTrue(metricTile.contains(".font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())"))
        XCTAssertTrue(metricTile.contains(".font(.system(size: 11, weight: .bold, design: .rounded))"))
        XCTAssertTrue(metricTile.contains(".padding(11)"))
        XCTAssertFalse(metricTile.contains(".padding(.horizontal, 12)"))
        XCTAssertFalse(metricTile.contains(".padding(.vertical, 8)"))
        XCTAssertTrue(metricTile.contains("RoundedRectangle(cornerRadius: 14)"))
        XCTAssertTrue(compactSelectedRow.contains("RoundedRectangle(cornerRadius: 14)"))
        XCTAssertTrue(cardButtonStyle.contains("Color.klmsCommandButtonPressedOverlay"))
        XCTAssertTrue(cardButtonStyle.contains("var disabledOpacity: Double = 0.48"))
        XCTAssertTrue(cardButtonStyle.contains("@Environment(\\.isEnabled)"))
        XCTAssertTrue(cardButtonStyle.contains(".opacity(isEnabled ? 1.0 : disabledOpacity)"))
        XCTAssertFalse(cardButtonStyle.contains(".opacity(configuration.isPressed ? 0.96 : 1.0)"))
        XCTAssertTrue(actionButtonStyle.contains("RoundedRectangle(cornerRadius: 10)"))
        XCTAssertTrue(actionButtonStyle.contains(".font(.system(size: 12, weight: .semibold, design: .rounded))"))
        XCTAssertTrue(actionButtonStyle.contains(".padding(.horizontal, 8)"))
        XCTAssertTrue(actionButtonStyle.contains(".padding(.vertical, 10)"))
        XCTAssertTrue(actionButtonStyle.contains("background(isPressed: configuration.isPressed)"))
        XCTAssertTrue(actionButtonStyle.contains("return AnyShapeStyle(isPressed ? Color.klmsCommandButtonPressedBackground : Color.klmsCommandButtonBackground.opacity(0.90))"))
        XCTAssertTrue(actionButtonStyle.contains("return AnyShapeStyle(isPressed ? Color.klmsPrimaryCommandButtonPressedBackground : Color.klmsPrimaryCommandButtonBackground)"))
        XCTAssertTrue(actionButtonStyle.contains("LinearGradient("))
        XCTAssertTrue(actionButtonStyle.contains("Color.klmsDangerCommandButtonForeground"))
        XCTAssertTrue(ios.contains("static var klmsDangerCommandButtonForeground"))
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
        XCTAssertTrue(remoteSettingRow.contains("CompanionSettingsControlContainer {"))
        XCTAssertTrue(remoteSettingRow.contains("Text(settingChoiceTitle(setting.value.nilIfEmpty ?? \"\"))"))
        XCTAssertTrue(remoteSettingRow.contains("Label(setting.boolValue ? \"켜짐\" : \"꺼짐\""))
        XCTAssertTrue(remoteSettingRow.contains("Button(\"저장\")"))
        XCTAssertTrue(remoteSettingRow.contains(".frame(minHeight: 44)"))
        XCTAssertTrue(remoteSettingRow.contains(".buttonStyle(KLMSActionButtonStyle())"))
        XCTAssertTrue(remoteSettingRow.contains(".accessibilityLabel(\"\\(setting.title) 현재 값 \\(settingValueSummary)\")"))
        XCTAssertTrue(remoteSettingRow.contains("CompanionSettingsControlContainer {\n                control"))
        XCTAssertTrue(remoteSettingRow.contains(".lineLimit(2)"))
        XCTAssertFalse(remoteSettingRow.contains("@State private var isExpanded"))
        XCTAssertFalse(remoteSettingRow.contains("isExpanded.toggle()"))
        XCTAssertFalse(remoteSettingRow.contains("CompanionExpansionBadge"))
        XCTAssertFalse(remoteSettingRow.contains("if isExpanded"))
        XCTAssertFalse(remoteSettingRow.contains(".accessibilityHint(isExpanded ?"))
        XCTAssertTrue(remoteRunningStatusBanner.contains("\"stop.fill\""))
        XCTAssertTrue(remoteRunningStatusBanner.contains(".background(Color.klmsSubtleCardBackground"))
        XCTAssertTrue(remoteRunningStatusBanner.contains(".buttonStyle(KLMSActionButtonStyle(tone: .destructive))"))
        XCTAssertFalse(remoteRunningStatusBanner.contains(".background(Color.klmsDangerBackground"))
        XCTAssertTrue(remoteVerifyCheckRow.contains(".background(Color.klmsSubtleCardBackground"))
        XCTAssertTrue(remoteVerifyCheckRow.contains(".frame(width: 3)"))
        XCTAssertTrue(remoteVerifyCheckRow.contains("isIssue ? 0.34 : 0.18"))
        XCTAssertFalse(remoteVerifyCheckRow.contains("return Color.klmsDangerBackground"))
        XCTAssertTrue(remoteVerifyCheckRow.contains("@State private var showsGuidance = false"))
        XCTAssertTrue(remoteVerifyCheckRow.contains("CompanionDiagnosticDisclosure("))
        XCTAssertTrue(remoteVerifyCheckRow.contains("title: \"원인과 조치 보기\""))
        XCTAssertTrue(remoteVerifyCheckRow.contains("title: \"원본 보기\""))
        XCTAssertFalse(remoteVerifyCheckRow.contains("DisclosureGroup(isExpanded:"))
        XCTAssertTrue(remoteVerifyCheckRow.contains(".lineLimit(1)"))
        XCTAssertTrue(remoteVerifyCheckRow.contains(".lineLimit(2)"))
        XCTAssertTrue(remoteVerifySummaryPanel.contains("private let primaryVisibleIssueCount = 1"))
        XCTAssertTrue(remoteVerifySummaryPanel.contains("let checkSummary = RemoteVerifyCheckSummary("))
        XCTAssertTrue(remoteVerifySummaryPanel.contains("ForEach(checkSummary.primaryIssues, id: \\.id)"))
        XCTAssertTrue(remoteVerifySummaryPanel.contains("ForEach(checkSummary.remainingIssues, id: \\.id)"))
        XCTAssertTrue(remoteVerifySummaryPanel.contains("CompanionDiagnosticDisclosure("))
        XCTAssertFalse(remoteVerifySummaryPanel.contains("let primaryIssues = Array(issueChecks.prefix(primaryVisibleIssueCount))"))
        XCTAssertFalse(remoteVerifySummaryPanel.contains("let remainingIssues = Array(issueChecks.dropFirst(primaryVisibleIssueCount))"))
        XCTAssertFalse(remoteVerifySummaryPanel.contains("DisclosureGroup(isExpanded:"))
        XCTAssertTrue(remoteVerifySummaryPanel.contains("나머지 확인 항목"))
        XCTAssertTrue(companionDiagnosticDisclosure.contains("companionPerformWithoutAnimation"))
        XCTAssertTrue(companionDiagnosticDisclosure.contains(".frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)"))
        XCTAssertTrue(companionDiagnosticDisclosure.contains(".buttonStyle(KLMSCardButtonStyle(cornerRadius: 8))"))
        XCTAssertTrue(companionDiagnosticDisclosure.contains(".accessibilityLabel(\"\\(title) \\(isExpanded ? \"펼쳐짐\" : \"접힘\")\")"))
        XCTAssertTrue(companionDiagnosticDisclosure.contains(".accessibilityHint(isExpanded ? \"\\(title) 접기\" : \"\\(title) 펼치기\")"))
        XCTAssertTrue(companionDiagnosticDisclosure.contains("DeferredInteractionExpansion(isExpanded: isExpanded)"))
        XCTAssertTrue(errorBanner.contains(".background(Color.klmsSubtleCardBackground"))
        XCTAssertFalse(errorBanner.contains(".background(Color.klmsDangerBackground"))
        XCTAssertFalse(actionButtonStyle.contains(".padding(.horizontal, 10)"))
        XCTAssertFalse(actionButtonStyle.contains(".padding(.vertical, 8)"))
        XCTAssertTrue(relayConnectionPanel.contains("RoundedRectangle(cornerRadius: 14)"))
        XCTAssertTrue(relayConnectionPanel.contains("RoundedRectangle(cornerRadius: 12)"))
        XCTAssertTrue(immediateSettingsPanel.contains("RoundedRectangle(cornerRadius: 14)"))
        XCTAssertTrue(immediateSettingsPanel.contains("CompanionImmediateSettingRow("))
        XCTAssertTrue(immediateSettingRow.contains("CompanionSettingsControlContainer {"))
        XCTAssertTrue(immediateSettingRow.contains("var statusText: String"))
        XCTAssertFalse(immediateSettingRow.contains("@State private var isExpanded"))
        XCTAssertFalse(immediateSettingRow.contains("CompanionExpansionBadge"))
        XCTAssertFalse(immediateSettingRow.contains(".accessibilityHint(isExpanded"))
        XCTAssertFalse(immediateSettingRow.contains("if isExpanded"))
        XCTAssertFalse(immediateSettingRow.contains(".transition(.opacity)"))
        XCTAssertTrue(immediateSettingRow.contains("Text(statusText)"))
        XCTAssertTrue(immediateSettingRow.contains(".lineLimit(2)"))
        XCTAssertTrue(immediateSettingsPanel.contains("Text(\"바로 반영되는 설정\")"))
        XCTAssertTrue(immediateSettingsPanel.contains("Label(\n                                \"원격 실행에서 공지 메모도 갱신\""))
        XCTAssertTrue(immediateSettingsPanel.contains("systemImage: noticeNotesEnabled ? \"checkmark.circle.fill\" : \"circle\""))
        XCTAssertTrue(immediateSettingsPanel.contains(".frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)"))
        XCTAssertTrue(immediateSettingsPanel.contains(".buttonStyle(KLMSActionButtonStyle(tone: noticeNotesEnabled ? .success : .soft))"))
        XCTAssertTrue(immediateSettingsPanel.contains(".accessibilityLabel(\"공지 메모 갱신\")"))
        XCTAssertTrue(immediateSettingsPanel.contains(".accessibilityValue(noticeNotesEnabled ? \"켜짐\" : \"꺼짐\")"))
        XCTAssertTrue(immediateSettingsPanel.contains(".accessibilityHint(\"원격 동기화에서 Notes 공지 메모를 쓸지 정합니다.\")"))
        XCTAssertTrue(dashboardSyncCard.contains("return \"파일\""))
        XCTAssertTrue(dashboardSyncCard.contains("return \"과제/시험\""))
        XCTAssertTrue(dashboardSyncCard.contains("return \"공지\""))
        XCTAssertTrue(dashboardSyncCard.contains(".buttonStyle(KLMSCardButtonStyle(cornerRadius: 12, disabledOpacity: 0.78))"))
        XCTAssertFalse(dashboardSyncCard.contains("isRunning ? Color.klmsPrimaryCommandButtonBorder.opacity(0.58)"))
        XCTAssertTrue(dashboardSyncCard.contains("primaryCommandTitle(isRunning: isRunning, isDisabled: isDisabled)"))
        XCTAssertTrue(dashboardSyncCard.contains("primaryCommandSystemImage(isRunning: isRunning, isDisabled: isDisabled)"))
        XCTAssertTrue(dashboardSyncCard.contains("Color.klmsPrimaryCommandButtonForeground"))
        XCTAssertTrue(dashboardSyncCard.contains("return \"전체 동기화\""))
        XCTAssertFalse(dashboardSyncCard.contains("return \"Mac 연결 필요\""))
        XCTAssertFalse(dashboardSyncCard.contains("return \"잠시 대기\""))
        XCTAssertTrue(dashboardSyncCard.contains("isDisabled ? Color.klmsSecondaryText.opacity(0.76) : Color.klmsPrimaryCommandButtonForeground"))
        XCTAssertTrue(dashboardSyncCard.contains("if isDisabled { return Color.klmsSubtleCardBackground.opacity(0.86) }"))
        XCTAssertTrue(dashboardSyncCard.contains("if isDisabled { return Color.klmsCommandButtonBorder.opacity(0.64) }"))
        XCTAssertTrue(dashboardSyncCard.contains(".buttonStyle(KLMSCardButtonStyle(cornerRadius: 12, disabledOpacity: 0.78))\n        .disabled(isDisabled)"))
        XCTAssertTrue(dashboardSyncCard.contains("private func isCommandActive(_ kind: RemoteCommandKind) -> Bool"))
        XCTAssertTrue(dashboardSyncCard.contains("private func runOrCancel(_ kind: RemoteCommandKind)"))
        XCTAssertTrue(dashboardSyncCard.contains("model.latestDisplayStatus?.isInFlight == true && model.latestCommand?.kind == kind"))
        XCTAssertFalse(dashboardSyncCard.contains("Mac 앱에 실행 요청을 보냅니다."))
        XCTAssertTrue(dashboardSyncCard.contains(".font(.system(size: 11, weight: .bold, design: .rounded))"))
        XCTAssertTrue(dashboardSyncCard.contains(".font(.system(size: 19, weight: .heavy, design: .rounded))"))
        XCTAssertTrue(dashboardSyncCard.contains(".padding(.horizontal, 5)"))
        XCTAssertTrue(dashboardSyncCard.contains("let isDisabled = commandDisabled(for: kind)"))
        XCTAssertTrue(dashboardSyncCard.contains("secondaryCommandSystemImage(isRunning: isRunning, isDisabled: isDisabled)"))
        XCTAssertTrue(dashboardSyncCard.contains(".buttonStyle(KLMSCardButtonStyle(disabledOpacity: 1.0))"))
        XCTAssertFalse(dashboardSyncCard.contains(".opacity(commandDisabled(for: kind) ? 0.48"))
        XCTAssertFalse(dashboardSyncCard.contains("isRunning ? Color.klmsPrimaryCommandButtonBorder.opacity(0.58)"))
        XCTAssertTrue(ios.contains("private func companionItemKindTint(_ kind: String) -> Color"))
        XCTAssertTrue(dashboardMetricCategory.contains("Color.klmsWarningBorder"))
        XCTAssertTrue(dashboardMetricCategory.contains("Color.klmsSuccessBorder"))
        XCTAssertTrue(dashboardMetricCategory.contains("Color.klmsCommandAccent"))
        XCTAssertTrue(dashboardMetricCategory.contains("Color.klmsSecondaryText"))
        XCTAssertFalse(dashboardMetricCategory.contains("static func defaultWorkstationDetail(for status: SanitizedRemoteStatus) -> DashboardMetricCategory"))
        XCTAssertFalse(dashboardMetricCategory.contains("[.files, .assignments, .exams, .notices, .calendar, .quarantine, .helpDesk]"))
        XCTAssertFalse(dashboardMetricCategory.contains(".first { $0.value(from: status) > 0 } ?? .files"))
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
        XCTAssertFalse(remoteChangeSummary.contains("entries.filter { $0.kind != selectedKind }"))
        XCTAssertTrue(remoteChangeSummary.contains("if !entries.isEmpty"))
        XCTAssertTrue(remoteChangeSummary.contains("FlowChipLayout(entries: entries"))
        XCTAssertTrue(flowChipLayout.contains("Image(systemName: entry.kind.systemImage)"))
        XCTAssertTrue(flowChipLayout.contains("isSelected ? Color.klmsSelectedForeground : entry.kind.tint"))
        XCTAssertTrue(flowChipLayout.contains("isSelected ? Color.klmsSelectedForeground : Color.klmsPrimaryText"))
        XCTAssertTrue(flowChipLayout.contains("isSelected ? Color.klmsSelectedForeground.opacity(0.86) : Color.klmsSecondaryText"))
        XCTAssertTrue(flowChipLayout.contains("let isSelected = selectedKind == entry.kind"))
        XCTAssertTrue(flowChipLayout.contains("isSelected\n                            ? Color.klmsSelectedBackground.opacity(0.96)"))
        XCTAssertTrue(flowChipLayout.contains(": entry.kind.chipBackground"))
        XCTAssertTrue(flowChipLayout.contains(": entry.kind.chipBorder"))
        XCTAssertTrue(flowChipLayout.contains("GridItem(.adaptive(minimum: 128), spacing: 7)"))
        XCTAssertTrue(flowChipLayout.contains(".frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)"))
        XCTAssertTrue(flowChipLayout.contains(".accessibilityLabel(\"\\(entry.kind.title) \\(entry.value)개 \\(selectedKind == entry.kind ? \"펼쳐짐\" : \"접힘\")\")"))
        XCTAssertFalse(flowChipLayout.contains("entry.kind.tint.opacity(0.10)"))
        XCTAssertFalse(flowChipLayout.contains("entry.kind.tint.opacity(0.26)"))
        XCTAssertTrue(flowChipLayout.contains("Color.klmsSelectedBorder.opacity(0.92)"))
        XCTAssertTrue(flowChipLayout.contains(".buttonStyle(KLMSCardButtonStyle())"))
        XCTAssertTrue(remoteChangeSummaryDetail.contains("@Environment(\\.horizontalSizeClass) private var horizontalSizeClass"))
        XCTAssertTrue(remoteChangeSummaryDetail.contains("@State private var visibleItemLimit = CompanionLargeList.initialVisibleLimit"))
        XCTAssertTrue(remoteChangeSummaryDetail.contains("@State private var calendarVisibleLimit = CompanionLargeList.calendarVisibleLimit"))
        XCTAssertTrue(remoteChangeSummaryDetail.contains("@State private var cleanupVisibleLimit = CompanionLargeList.previewVisibleLimit"))
        XCTAssertTrue(remoteChangeSummaryDetail.contains("CompanionLargeList.initialVisibleLimit(horizontalSizeClass: horizontalSizeClass)"))
        XCTAssertTrue(remoteChangeSummaryDetail.contains("CompanionLargeList.calendarVisibleLimit(horizontalSizeClass: horizontalSizeClass)"))
        XCTAssertTrue(remoteChangeSummaryDetail.contains("CompanionLargeList.previewVisibleLimit(horizontalSizeClass: horizontalSizeClass)"))
        XCTAssertTrue(remoteChangeSummaryDetail.contains("private func resetVisibleLimits()"))
        XCTAssertTrue(remoteChangeSummaryDetail.contains("let visibleChangedItems = changedItems.prefix(visibleItemLimit)"))
        XCTAssertTrue(remoteChangeSummaryDetail.contains("ForEach(visibleChangedItems)"))
        XCTAssertTrue(remoteChangeSummaryDetail.contains("let visibleCalendarItems = changedCalendarItems.prefix(calendarVisibleLimit)"))
        XCTAssertTrue(remoteChangeSummaryDetail.contains("ForEach(visibleCalendarItems)"))
        XCTAssertTrue(remoteChangeSummaryDetail.contains("let visibleReports = fileCleanupReports.prefix(cleanupVisibleLimit)"))
        XCTAssertTrue(remoteChangeSummaryDetail.contains("ForEach(visibleReports, id: \\.scope)"))
        XCTAssertFalse(remoteChangeSummaryDetail.contains("ForEach(Array(visibleReports.enumerated()), id: \\.offset)"))
        XCTAssertTrue(remoteChangeSummaryDetail.contains("CompanionShowMoreRowsButton"))
        XCTAssertFalse(remoteChangeSummaryDetail.contains("ForEach(changedItems)"))
        XCTAssertFalse(remoteChangeSummaryDetail.contains("ForEach(changedCalendarItems)"))
        XCTAssertTrue(remoteChangeSummaryDetail.contains(".background(Color.klmsSubtleCardBackground)"))
        XCTAssertTrue(remoteChangeSummaryDetail.contains("Color.klmsBorder.opacity(0.95)"))
        XCTAssertTrue(inlineItemDetail.contains("companionItemKindTint(item.kind)"))
        XCTAssertTrue(serverSyncDataRow.contains("companionItemKindTint(snapshot.kind)"))
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

        XCTAssertTrue(ios.contains("@Published private(set) var dashboardHasFileCleanupDetails = false"))
        XCTAssertTrue(ios.contains("private func rebuildDashboardFileCleanupDetails()"))
        XCTAssertTrue(ios.contains("if isDataLoaded && metricSnapshot.hasVisibleChangeSummary"))
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
        let envDocumentRoot = packageRoot.appendingPathComponent("Sources/KLMSShared/EnvDocument.swift")
        let macSettings = try String(contentsOf: macSettingsRoot, encoding: .utf8)
        let macModel = try String(contentsOf: macModelRoot, encoding: .utf8)
        let ios = try String(contentsOf: iosRoot, encoding: .utf8)
        let envDocument = try String(contentsOf: envDocumentRoot, encoding: .utf8)
        let settingsForm = try sourceBody(
            after: "private func settingsForm",
            in: macSettings,
            description: "Mac settings form"
        )
        let settingsGroupBox = try sourceBody(
            after: "private struct SettingsGroupBox<Content: View>: View",
            in: macSettings,
            description: "Mac settings group box"
        )
        let settingsFieldRow = try sourceBody(
            after: "private struct SettingsFieldRow<Content: View>: View",
            in: macSettings,
            description: "Mac settings field row"
        )
        let settingsDisclosureCard = try sourceBody(
            after: "private struct SettingsDisclosureCard<Content: View, Label: View>: View",
            in: macSettings,
            description: "Mac settings disclosure card"
        )
        let settingsActionGroupBox = try sourceBody(
            after: "private struct SettingsActionGroupBox<Content: View>: View",
            in: macSettings,
            description: "Mac settings action group box"
        )
        let remoteSettingGroup = try sourceBody(
            after: "private struct RemoteSettingGroup: Identifiable",
            in: ios,
            description: "iPhone/iPad remote setting group"
        )
        let macRemoteSettingKeys = try macServerRelayEditableSettingKeys(
            macModel: macModel,
            envDocument: envDocument
        )
        let iosRemoteSettingKeys = try iosRemoteSettingKeys(
            from: remoteSettingGroup,
            knownKeys: macRemoteSettingKeys
        )
        let missingRemoteSettingKeys = macRemoteSettingKeys.subtracting(iosRemoteSettingKeys).sorted()

        XCTAssertTrue(
            missingRemoteSettingKeys.isEmpty,
            "iPhone/iPad remote setting groups are missing Mac server settings: \(missingRemoteSettingKeys.joined(separator: ", "))"
        )
        XCTAssertFalse(iosRemoteSettingKeys.contains("KLMS_SSO_LOGIN_ID"))

        XCTAssertFalse(macSettings.contains("TabView(selection:"))
        XCTAssertFalse(macSettings.contains(".tabItem"))
        XCTAssertFalse(macSettings.contains("settingsSidebar"))
        XCTAssertFalse(macSettings.contains("case relay"))
        XCTAssertTrue(macSettings.contains("settingsTabBar"))
        XCTAssertTrue(macSettings.contains("settingsContentPanel"))
        XCTAssertTrue(macSettings.contains("selectedSettingsContent"))
        XCTAssertTrue(macSettings.contains(".id(selectedTab.rawValue)"))
        XCTAssertTrue(macSettings.contains(".accessibilityAction"))
        XCTAssertTrue(macSettings.contains("selectSettingsTab(tab)"))
        XCTAssertTrue(macSettings.contains("var primarySectionTitle: String"))
        XCTAssertTrue(macSettings.contains("settingsHeaderBadge(selectedTab.primarySectionTitle, primary: true)"))
        XCTAssertTrue(macSettings.contains("settingsHeaderBadge(selectedTab.scopeLabel, primary: false)"))
        XCTAssertTrue(macSettings.contains("private func settingsHeaderBadge(_ text: String, primary: Bool) -> some View"))
        XCTAssertTrue(macSettings.contains("private let settingsTabColumns"))
        XCTAssertTrue(macSettings.contains("GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 7)"))
        XCTAssertTrue(macSettings.contains("LazyVGrid(columns: settingsTabColumns, alignment: .leading, spacing: 7)"))
        XCTAssertTrue(macSettings.contains("settingsTabButton"))
        XCTAssertTrue(macSettings.contains("KLMSMacSettingsTabButtonStyle"))
        XCTAssertTrue(macSettings.contains("@State private var hoveredTab: SettingsTab?"))
        XCTAssertTrue(macSettings.contains("let isHovered = hoveredTab == tab"))
        XCTAssertTrue(macSettings.contains("var transaction = Transaction()"))
        XCTAssertTrue(macSettings.contains("transaction.animation = nil"))
        XCTAssertTrue(macSettings.contains("withTransaction(transaction)"))
        XCTAssertTrue(macSettings.contains("private func settingsPerformWithoutAnimation"))
        XCTAssertEqual(macSettings.components(separatedBy: "Button {\n                isExpanded.toggle()\n            }").count - 1, 0)
        XCTAssertGreaterThanOrEqual(macSettings.components(separatedBy: "settingsPerformWithoutAnimation {\n                    isExpanded.toggle()\n                }").count - 1, 4)
        XCTAssertTrue(macSettings.contains(".onHover { hovering in"))
        XCTAssertTrue(macSettings.contains("hoveredTab = hovering ? tab : (hoveredTab == tab ? nil : hoveredTab)"))
        XCTAssertTrue(macSettings.contains(".accessibilityIdentifier(\"settings-\\(tab.rawValue)\")"))
        XCTAssertTrue(macSettings.contains("static var allCases: [SettingsTab] {\n        [.app, .login, .sync, .files, .notice]"))
        XCTAssertTrue(macSettings.contains("\"화면/앱\""))
        XCTAssertTrue(macSettings.contains("\"설정 파일 저장\""))
        XCTAssertFalse(macSettings.contains("\"Mac 설정 파일\""))
        XCTAssertTrue(macSettings.contains("Text(\"자주 쓰는 설정은 바로 보이고, 설치/백업 같은 부가 항목만 접어 둡니다.\")"))
        XCTAssertTrue(macSettings.contains("\"파일 확인\""))
        XCTAssertTrue(macSettings.contains("\"바로 반영되는 설정\""))
        XCTAssertTrue(macSettings.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(macSettings.contains("VStack(alignment: .trailing, spacing: 4)"))
        XCTAssertTrue(settingsForm.contains("VStack(alignment: .leading, spacing: 12)"))
        XCTAssertFalse(settingsForm.contains("ScrollView(.horizontal"))
        XCTAssertFalse(settingsForm.contains("HStack(alignment: .top"))
        XCTAssertTrue(macSettings.contains(".frame(width: 28, height: 28)"))
        XCTAssertTrue(macSettings.contains("Color.klmsMacSelectedBorder.opacity(0.18)"))
        XCTAssertTrue(macSettings.contains("Color.klmsMacSubtleCardBackground.opacity(isHovered ? 0.92 : 0.72)"))
        XCTAssertFalse(macSettings.contains("Image(systemName: \"chevron.right\")"))
        XCTAssertTrue(macSettings.contains("Color.klmsMacSubtleCardBackground.opacity(isHovered ? 0.58 : 0.34)"))
        XCTAssertTrue(macSettings.contains(".frame(maxWidth: .infinity, minHeight: 44, alignment: .center)"))
        XCTAssertFalse(macSettings.contains(".frame(maxWidth: .infinity, minHeight: 42, alignment: .center)"))
        XCTAssertTrue(macSettings.contains(".overlay(alignment: .bottom)"))
        XCTAssertTrue(macSettings.contains(".frame(height: 3)"))
        XCTAssertTrue(macSettings.contains("Color.klmsMacCommandBorder.opacity(isHovered ? 0.72 : 0.42)"))
        XCTAssertTrue(macSettings.contains("private struct SettingsGroupBox"))
        XCTAssertTrue(macSettings.contains("var badge: String?"))
        XCTAssertTrue(macSettings.contains("var collapsible: Bool"))
        XCTAssertTrue(macSettings.contains("badge: String? = nil"))
        XCTAssertTrue(macSettings.contains("collapsible: Bool = false"))
        XCTAssertTrue(macSettings.contains("badge: \"설정 파일 저장\""))
        XCTAssertTrue(macSettings.contains("badge: \"바로 반영\""))
        XCTAssertTrue(macSettings.contains("badge: \"필요할 때만\""))
        XCTAssertTrue(macSettings.contains("badge: \"서버\""))
        XCTAssertTrue(macSettings.contains("badge: \"필요할 때만\",\n                collapsible: true"))
        XCTAssertTrue(macSettings.contains("badge: \"서버\",\n            collapsible: true"))
        XCTAssertTrue(macSettings.contains("KLMSMacSettingsDisclosureButtonStyle"))
        XCTAssertFalse(macSettings.contains("withAnimation(.easeInOut(duration: 0.08))"))
        XCTAssertFalse(macSettings.contains(".transition(.opacity.combined(with: .move(edge: .top)))"))
        XCTAssertFalse(macSettings.contains(".transition(.opacity)"))
        XCTAssertTrue(macSettings.contains("SettingsExpansionBadge(isExpanded: isExpanded)"))
        XCTAssertTrue(macSettings.contains("private struct SettingsExpansionBadge"))
        XCTAssertTrue(macSettings.contains("Image(systemName: isExpanded ? \"chevron.up\" : \"chevron.down\")"))
        XCTAssertTrue(macSettings.contains("Text(isExpanded ? \"접기\" : \"펼치기\")"))
        XCTAssertTrue(settingsGroupBox.contains(".frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)"))
        XCTAssertTrue(settingsFieldRow.contains(".frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)"))
        XCTAssertTrue(settingsDisclosureCard.contains(".frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)"))
        XCTAssertTrue(settingsActionGroupBox.contains(".frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)"))
        XCTAssertTrue(macSettings.contains(".overlay(alignment: .leading)"))
        XCTAssertTrue(macSettings.contains("if !collapsible || isExpanded"))
        XCTAssertTrue(macSettings.contains("if collapsible {\n                SettingsExpansionBadge(isExpanded: isExpanded)"))
        XCTAssertTrue(macSettings.contains(".fill((!collapsible || isExpanded) ? Color.klmsMacSelectedBorder.opacity(0.86) : Color.clear)"))
        XCTAssertTrue(macSettings.contains(".fill((!collapsible || isExpanded) ? Color.klmsMacSelectedBorder.opacity(0.72) : Color.clear)"))
        XCTAssertTrue(macSettings.contains("isExpanded ? Color.klmsMacSelectedBackground.opacity(0.78) : Color.klmsMacSubtleCardBackground"))
        XCTAssertTrue(macSettings.contains("isExpanded ? Color.klmsMacSelectedBorder.opacity(0.58) : Color.klmsMacBorder.opacity(0.68)"))
        XCTAssertTrue(macSettings.contains("defaultExpanded: true"))
        XCTAssertFalse(macSettings.contains("if !isExpanded,\n                           let description"))
        XCTAssertTrue(macSettings.contains(".lineLimit(2)"))
        XCTAssertTrue(macSettings.contains("title: \"실행 방식\""))
        XCTAssertTrue(macSettings.contains("title: \"Safari 자동화\""))
        XCTAssertTrue(macSettings.contains("title: \"파일 확인\""))
        XCTAssertTrue(macSettings.contains("title: \"저장 위치\""))
        XCTAssertTrue(macSettings.contains("title: \"문제 분석용 보관\""))
        XCTAssertTrue(macSettings.contains("title: \"바로 반영되는 설정\""))
        XCTAssertTrue(macSettings.contains("title: \"설치와 백업\""))
        XCTAssertTrue(macSettings.contains("SettingsDisclosureLabel("))
        XCTAssertTrue(macSettings.contains("badge: badge"))
        XCTAssertTrue(macSettings.contains(".minimumScaleFactor(0.88)"))
        XCTAssertTrue(macSettings.contains("SettingsDisclosureCard {"))
        XCTAssertTrue(macSettings.contains("private struct SettingsActionGroupBox"))
        XCTAssertTrue(macSettings.contains("LazyVGrid(columns: settingsActionColumns, spacing: 8)"))
        XCTAssertTrue(macSettings.contains("Label(\"붙여넣기\", systemImage: \"doc.on.clipboard\")"))
        XCTAssertTrue(macSettings.contains("Label(\"연결 정보 복사\", systemImage: \"doc.on.doc\")"))
        XCTAssertFalse(macSettings.contains("Button(\"붙여넣기\")"))
        XCTAssertFalse(macSettings.contains("Button(\"URL 복사\")"))
        XCTAssertTrue(macSettings.contains("private struct SettingsFieldRow"))
        XCTAssertTrue(macSettings.contains("var summary: String?"))
        XCTAssertTrue(macSettings.contains("@State private var isExpanded: Bool"))
        XCTAssertTrue(macSettings.contains("SettingsFieldRow(\n            title: title,"))
        XCTAssertTrue(macSettings.contains("collapsible: collapsible"))
        XCTAssertTrue(macSettings.contains("SettingsCurrentValueBadge(value: summary)"))
        XCTAssertTrue(macSettings.contains("private struct SettingsCurrentValueBadge"))
        XCTAssertTrue(macSettings.contains("Text(\"현재\")"))
        XCTAssertTrue(macSettings.contains(".accessibilityLabel(\"현재 값 \\(value)\")"))
        XCTAssertTrue(macSettings.contains("SettingsExpansionBadge(isExpanded: isExpanded)"))
        XCTAssertTrue(macSettings.contains("private struct SettingsFieldDescriptionText"))
        XCTAssertTrue(macSettings.contains("SettingsFieldDescriptionText(description)"))
        XCTAssertTrue(macSettings.contains("Image(systemName: \"info.circle\")"))
        XCTAssertTrue(macSettings.contains("private func settingsTextInput("))
        XCTAssertTrue(macSettings.contains("private func settingsInlineSummary(_ value: String) -> String"))
        XCTAssertTrue(macSettings.contains("trimmed.contains(\"/\") || trimmed.contains(\"\\\\\") || trimmed.count > 18"))
        XCTAssertTrue(macSettings.contains("Text(title)\n                .font(.caption.weight(.semibold))"))
        XCTAssertTrue(macSettings.contains("settingsTextInput(title, text: binding(key))"))
        XCTAssertTrue(macSettings.contains("title: \"연결 정보\""))
        XCTAssertTrue(macSettings.contains("title: \"릴레이 동작\""))
        XCTAssertTrue(macSettings.contains("title: \"서버 확인\""))
        XCTAssertTrue(macSettings.contains("SettingsActionGroupBox(\n                    title: \"연결 정보\",\n                    detail: \"서버 주소와 기기별 토큰을 한곳에서 관리합니다.\",\n                    systemImage: \"link\""))
        XCTAssertTrue(macSettings.contains("Image(systemName: systemImage)"))
        XCTAssertTrue(macSettings.contains("Color.klmsMacSubtleCardBackground.opacity(0.50)"))
        XCTAssertTrue(macSettings.contains("defaultExpanded: Bool = false"))
        XCTAssertTrue(macSettings.contains("badge: \"바로 반영\",\n                defaultExpanded: true"))
        XCTAssertFalse(macSettings.contains("badge: \"설정 파일 저장\",\n                defaultExpanded: true"))
        XCTAssertFalse(macSettings.contains("Divider()"))
        XCTAssertFalse(macSettings.contains("Section(\""))
        XCTAssertFalse(macSettings.contains("백그라운드 실행 허용"))
        XCTAssertFalse(macSettings.contains("동기화 주기(초)"))
        XCTAssertFalse(macSettings.contains("빠르게"))

        XCTAssertTrue(macModel.contains("앱이 앞에 없어도 로그인 보조"))
        XCTAssertTrue(macModel.contains("로그인 보조 방식"))
        XCTAssertFalse(macModel.contains("파일 강제 다시 받기"))
        XCTAssertTrue(macModel.contains("공지 큰 섹션 접기"))
        XCTAssertTrue(macModel.contains("공지 과목명 접기"))
        XCTAssertTrue(macModel.contains("공지 항목 접기"))
        XCTAssertTrue(macModel.contains("공지 항목을 제목처럼 표시"))
        XCTAssertTrue(macModel.contains("공지 읽음/중요 상태 항상 확인"))
        XCTAssertTrue(macModel.contains("공지 내용이 같으면 메모 다시 쓰지 않기"))
        XCTAssertFalse(macModel.contains("공지 메모에 원문 양식으로 붙여넣기"))
        XCTAssertTrue(macModel.contains("\"NOTICE_NATIVE_PREFORMATTED_PASTE_ONLY\": \"0\""))
        XCTAssertTrue(macModel.contains("\"FILE_FORCE_DOWNLOAD\": \"0\""))

        XCTAssertTrue(ios.contains("private struct RemoteSettingGroup"))
        XCTAssertTrue(ios.contains("RemoteSettingGroupSection"))
        XCTAssertTrue(ios.contains("@Published private(set) var hasLoadedServerSyncData = false"))
        XCTAssertTrue(ios.contains("private var dashboardMailItems: [ServerRelaySyncItem]"))
        XCTAssertTrue(ios.contains("hasLoadedServerSyncData ? mailDashboardItems : []"))
        XCTAssertTrue(ios.contains("hasLoadedServerSyncData ? status.withAuthoritativeDashboardCounts("))
        XCTAssertTrue(ios.contains("(syncItems + dashboardMailItems).dedupedForServerRelay()"))
        XCTAssertFalse(ios.contains("(syncItems + mailDashboardItems).dedupedForServerRelay()"))
        XCTAssertTrue(ios.contains("rebuildDashboardDerivedState()"))
        XCTAssertTrue(ios.contains("private func dashboardActionHiddenItemIDs() -> Set<String>"))
        XCTAssertTrue(ios.contains("action.action.hidesDashboardItemAfterRequest"))
        XCTAssertTrue(ios.contains("!action.status.isFailedLike"))
        XCTAssertTrue(ios.contains("for item in categoryItems where !item.isHidden && !hiddenByActionItemIDs.contains(item.id)"))
        XCTAssertTrue(ios.contains("var hidesDashboardItemAfterRequest: Bool"))
        XCTAssertTrue(ios.contains("case .assignmentComplete,"))
        XCTAssertTrue(ios.contains("case .assignmentRestore,"))
        XCTAssertFalse(ios.contains("next.applyMailDashboardItems(dashboardMailItems, baseItems: syncItems)"))
        XCTAssertTrue(ios.contains("+ dashboardMailItems"))
        XCTAssertTrue(ios.contains("if !hasLoadedServerSyncData"))
        let companionDashboardCategoryScreen = try sourceStructBody(named: "CompanionDashboardCategoryScreen", in: ios)
        XCTAssertTrue(companionDashboardCategoryScreen.contains("if !model.hasLoadedServerSyncData"))
        XCTAssertTrue(companionDashboardCategoryScreen.contains("CompanionCategoryDataLoadingState("))
        let companionTasksScreen = try sourceStructBody(named: "CompanionTasksScreen", in: ios)
        XCTAssertTrue(companionTasksScreen.contains("if model.hasLoadedServerSyncData"))
        XCTAssertTrue(companionTasksScreen.contains("CompanionCategoryDataLoadingState("))
        let workstationTasksWorkspace = try sourceStructBody(named: "WorkstationTasksWorkspace", in: ios)
        XCTAssertTrue(workstationTasksWorkspace.contains("if model.hasLoadedServerSyncData"))
        XCTAssertTrue(workstationTasksWorkspace.contains("CompanionCategoryDataLoadingState("))
        let dashboardCategoryInlineDetailPanel = try sourceStructBody(named: "DashboardCategoryInlineDetailPanel", in: ios)
        XCTAssertTrue(dashboardCategoryInlineDetailPanel.contains("if model.hasLoadedServerSyncData"))
        XCTAssertTrue(dashboardCategoryInlineDetailPanel.contains("CompanionCategoryDataLoadingState("))
        XCTAssertTrue(ios.contains("\"KLMS_LOGIN_ASSIST_ENABLED\", \"KLMS_LOGIN_ASSIST_MODE\", \"KLMS_LOGIN_ASSIST_ALLOW_NONINTERACTIVE\""))
        XCTAssertFalse(ios.contains("\"FILE_FORCE_DOWNLOAD\""))
        XCTAssertFalse(ios.contains("로컬에 같은 파일이 있어도 다시 받습니다."))
        XCTAssertTrue(ios.contains("\"NOTICE_COLLAPSE_SECTIONS\""))
        XCTAssertTrue(ios.contains("\"NOTICE_COLLAPSE_COURSES\""))
        XCTAssertTrue(ios.contains("\"NOTICE_COLLAPSE_NOTICE_ITEMS\""))
        XCTAssertTrue(ios.contains("\"NOTICE_STYLE_NOTICE_ITEMS_AS_HEADINGS\""))
        XCTAssertTrue(ios.contains("\"NOTICE_NATIVE_ALWAYS_CAPTURE_STATE\""))
        XCTAssertTrue(ios.contains("\"NOTICE_NATIVE_VERIFY_STABLE_SKIP_FORMAT\""))
        XCTAssertFalse(ios.contains("\"NOTICE_NATIVE_PREFORMATTED_PASTE_ONLY\""))
        XCTAssertTrue(ios.contains("\"NOTICE_NATIVE_PLAIN_TEXT_PASTE\""))
        XCTAssertTrue(ios.contains("\"동기화\""))
        XCTAssertTrue(ios.contains("[\"SYNC_MODE\"]"))
        XCTAssertTrue(ios.contains("\"캘린더\""))
        XCTAssertTrue(ios.contains("[\"CALENDAR_SKIP_UNCHANGED_DESIRED\"]"))
        XCTAssertTrue(ios.contains("\"고급\""))
        XCTAssertTrue(ios.contains("\"KLMS_SAFARI_BACKGROUND_WINDOW_ENABLED\""))
        XCTAssertTrue(ios.contains("\"KLMS_SAFARI_BACKGROUND_WINDOW_MODE\""))
        XCTAssertTrue(ios.contains("\"KLMS_SAFARI_REUSE_EXISTING_WINDOW_ENABLED\""))
        XCTAssertTrue(ios.contains("KLMS를 읽을 때 전용 Safari 창을 백그라운드처럼 다룹니다."))
        XCTAssertTrue(ios.contains("KLMS Sync가 만든 Safari 창을 재사용해 새 창이 계속 늘어나는 일을 줄입니다."))
        XCTAssertTrue(ios.contains("groups.firstIndex(where: { $0.title == \"고급\" })"))
        XCTAssertTrue(ios.contains("groups[advancedIndex].settings.append(contentsOf: extras)"))
        XCTAssertTrue(remoteSettingGroup.contains("var isCollapsible = false"))
        XCTAssertTrue(remoteSettingGroup.contains("isCollapsible: spec.isCollapsible"))
        XCTAssertTrue(remoteSettingGroup.contains("\"공지 메모\",\n                \"checklist\",\n                \"공지 메모의 접기, 양식, 상태 반영 방식을 정합니다.\",\n                false"))
        XCTAssertTrue(remoteSettingGroup.contains("\"로그인\",\n                \"person.badge.key\",\n                \"인증번호 감지와 로그인 보조 방식을 정합니다.\",\n                false"))
        XCTAssertTrue(remoteSettingGroup.contains("\"동기화\",\n                \"arrow.triangle.2.circlepath\",\n                \"동기화 범위를 정합니다.\",\n                false"))
        XCTAssertTrue(remoteSettingGroup.contains("\"파일\",\n                \"folder\",\n                \"파일 탐색, 주차별 폴더, 보존 방식을 정합니다.\",\n                false"))
        XCTAssertTrue(remoteSettingGroup.contains("\"캘린더\",\n                \"calendar\",\n                \"같은 일정은 건너뛰고 변경이 있을 때만 반영합니다.\",\n                false"))
        XCTAssertTrue(remoteSettingGroup.contains("for index in groups.indices where groups[index].title == \"고급\""))
        XCTAssertTrue(remoteSettingGroup.contains("groups[index].isCollapsible = true"))
        XCTAssertEqual(remoteSettingGroup.components(separatedBy: ".isCollapsible = true").count - 1, 1)
        let remoteSettingGroupSection = try sourceStructBody(named: "RemoteSettingGroupSection", in: ios)
        XCTAssertTrue(remoteSettingGroupSection.contains("if group.isCollapsible"))
        XCTAssertTrue(remoteSettingGroupSection.contains("DeferredInteractionExpansion(isExpanded: isExpanded)"))
        XCTAssertFalse(remoteSettingGroupSection.contains("if isExpanded {\n                    groupSettingsRows"))
        XCTAssertTrue(remoteSettingGroupSection.contains("private var groupSettingsRows: some View"))
        XCTAssertTrue(remoteSettingGroupSection.contains("CompanionExpansionBadge(isExpanded: isExpanded, compact: true)"))
        XCTAssertTrue(remoteSettingGroupSection.contains(".frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)"))
        XCTAssertFalse(ios.contains("\"Safari\",\n                \"safari\""))
        XCTAssertTrue(ios.contains("private struct CompanionConnectionInput"))
        let companionConnectionInput = try sourceStructBody(named: "CompanionConnectionInput", in: ios)
        XCTAssertTrue(companionConnectionInput.contains(".frame(minHeight: 44)"))
        XCTAssertTrue(ios.contains("title: \"서버 URL\""))
        XCTAssertTrue(ios.contains("title: \"클라이언트 토큰\""))
        XCTAssertTrue(ios.contains("private struct CompanionImmediateSettingRow"))
        XCTAssertTrue(ios.contains("CompanionImmediateSettingRow("))
        XCTAssertTrue(ios.contains("private struct CompanionSettingsControlContainer"))
        XCTAssertTrue(ios.contains("private struct CompanionSettingsSubsectionCard"))
        let companionSettingsSubsectionCard = try sourceBody(
            after: "private struct CompanionSettingsSubsectionCard<Content: View>: View",
            in: ios,
            description: "iOS companion settings subsection card"
        )
        XCTAssertFalse(ios.contains("@State private var isExpanded = true"))
        XCTAssertTrue(ios.contains("@State private var isExpanded = false"))
        XCTAssertFalse(ios.contains("var isDefaultExpanded: Bool"))
        XCTAssertFalse(ios.contains("defaultExpanded:"))
        XCTAssertFalse(ios.contains("var isCollapsible: Bool"))
        XCTAssertTrue(ios.contains("private struct RemoteSettingsPanel: View"))
        XCTAssertFalse(ios.contains("_isExpanded = State(initialValue: group.isDefaultExpanded)"))
        XCTAssertFalse(ios.contains("title != \"Safari\" && title != \"고급\""))
        XCTAssertFalse(ios.contains("title == \"Safari\" || title == \"고급\""))
        XCTAssertTrue(ios.contains("group.countText"))
        XCTAssertTrue(ios.contains("CompanionSettingsSubsectionCard("))
        XCTAssertTrue(ios.contains("collapsible: true"))
        XCTAssertEqual(ios.components(separatedBy: "collapsible: true").count - 1, 1)
        XCTAssertTrue(companionSettingsSubsectionCard.contains(".accessibilityLabel(\"\\(title) \\(isExpanded ? \"펼쳐짐\" : \"접힘\")\")"))
        XCTAssertTrue(companionSettingsSubsectionCard.contains(".frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)"))
        XCTAssertTrue(companionSettingsSubsectionCard.contains("DeferredInteractionExpansion(isExpanded: isExpanded)"))
        XCTAssertFalse(companionSettingsSubsectionCard.contains("if isExpanded {\n                    VStack(alignment: .leading, spacing: 8)"))
        XCTAssertTrue(ios.contains("settingValueSummary"))
        XCTAssertTrue(ios.contains("private func compactSettingValueSummary(_ value: String) -> String"))
        XCTAssertTrue(ios.contains("trimmed.contains(\"/\") || trimmed.contains(\"\\\\\") || trimmed.count > 18"))
        XCTAssertTrue(ios.contains("Text(settingValueSummary)"))
        XCTAssertTrue(ios.contains("var statusText: String"))
        XCTAssertTrue(ios.contains("Text(statusText)"))
        XCTAssertTrue(ios.contains("@State private var isExpanded = false"))
        XCTAssertFalse(ios.contains("private struct CompanionDetailDisclosureBadge"))
        XCTAssertTrue(ios.contains("CompanionExpansionBadge(isExpanded: isExpanded, compact: true)"))
        XCTAssertFalse(ios.contains("Text(isExpanded ? \"설명 접기\" : \"설명 보기\")"))
        XCTAssertTrue(ios.contains("private struct CompanionExpansionBadge"))
        XCTAssertTrue(ios.contains("CompanionExpansionBadge(isExpanded: isExpanded)"))
        XCTAssertTrue(ios.contains("CompanionExpansionBadge(isExpanded: isPanelExpanded)"))
        XCTAssertTrue(ios.contains("CompanionExpansionBadge(isExpanded: isExpanded, compact: true)"))
        XCTAssertFalse(ios.contains(".onAppear {\n            if !isConfigured {\n                isExpanded = true\n            }\n        }"))
        XCTAssertFalse(ios.contains(".onChange(of: isConfigured) { _, configured in\n            if !configured {\n                isExpanded = true\n            }\n        }"))
        XCTAssertTrue(ios.contains("Image(systemName: isExpanded ? \"chevron.up\" : \"chevron.down\")"))
        XCTAssertTrue(ios.contains("Text(isExpanded ? \"접기\" : \"펼치기\")"))
        XCTAssertTrue(ios.contains("isExpanded ? Color.klmsSelectedBackground.opacity(0.92) : Color.klmsSubtleCardBackground"))
        XCTAssertTrue(ios.contains("isExpanded ? Color.klmsSelectedBorder.opacity(0.64) : Color.klmsBorder.opacity(0.72)"))
        XCTAssertTrue(ios.contains("\"공지 메모\""))
        XCTAssertFalse(ios.contains("Text(setting.key)"))
    }

    func testMacAndIOSUseDedicatedLogScreensForRequestHistory() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let macRoot = packageRoot.appendingPathComponent("Sources/KLMSMac/MenuBarRootView.swift")
        let macDetailRoot = packageRoot.appendingPathComponent("Sources/KLMSMac/DashboardDetailView.swift")
        let macModelRoot = packageRoot.appendingPathComponent("Sources/KLMSMac/KLMSMacModel.swift")
        let iosRoot = packageRoot.appendingPathComponent("Sources/KLMSiOS/KLMSiOSApp.swift")
        let designSpecRoot = packageRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/superpowers/specs/2026-06-14-klms-sync-app-visual-redesign.md")
        let mac = try String(contentsOf: macRoot, encoding: .utf8)
        let macDetail = try String(contentsOf: macDetailRoot, encoding: .utf8)
        let macModel = try String(contentsOf: macModelRoot, encoding: .utf8)
        let ios = try String(contentsOf: iosRoot, encoding: .utf8)
        let designSpec = try String(contentsOf: designSpecRoot, encoding: .utf8)
        let macRootBody = try sourceBody(after: "struct MenuBarRootView: View", in: mac, description: "Mac root view")
        let macSelectionMarker = try sourceStructBody(named: "MacWorkspaceSelectionAccessibilityMarker", in: mac)
        let macNavigationView = try sourceStructBody(named: "WorkspaceNavigationView", in: mac)
        let macNavigationSelectionMarker = try sourceStructBody(named: "WorkspaceNavigationSelectionMarker", in: mac)
        let macSidebarView = try sourceStructBody(named: "MacWorkspaceSidebarView", in: mac)
        let macRuntimePanel = try sourceStructBody(named: "DashboardRuntimePanelView", in: mac)
        let macMetricTile = try sourceStructBody(named: "MetricTile", in: mac)
        let hiddenItemsListView = try sourceStructBody(named: "HiddenItemsListView", in: macDetail)
        let dashboardTopBarView = try sourceStructBody(named: "DashboardTopBarView", in: mac)
        let dashboardTopBarStatusContent = try sourceStructBody(named: "DashboardTopBarStatusContent", in: mac)
        let macAlertBannerSnapshot = try sourceBody(
            after: "private struct MacAlertBannerSnapshot: Equatable",
            in: mac,
            description: "Mac alert banner snapshot"
        )
        let macAlertBannerView = try sourceStructBody(named: "MacAlertBannerView", in: mac)
        let macAlertBannerContent = try sourceStructBody(named: "MacAlertBannerContent", in: mac)
        let nextActionPanelView = try sourceStructBody(named: "NextActionPanelView", in: mac)
        let deferredMacWorkspacePanel = try sourceBody(
            after: "private struct DeferredMacWorkspacePanel<Content: View>: View",
            in: mac,
            description: "Mac deferred workspace panel"
        )
        let macWorkstationLayoutView = try sourceStructBody(named: "MacWorkstationLayoutView", in: mac)
        let taskAndExamWorkspaceView = try sourceStructBody(named: "TaskAndExamWorkspaceView", in: mac)
        let quickStatusStripView = try sourceStructBody(named: "QuickStatusStripView", in: mac)
        let externalIntegrationStatusView = try sourceStructBody(named: "ExternalIntegrationStatusView", in: mac)
        let importantLogPanelView = try sourceStructBody(named: "ImportantLogPanelView", in: mac)
        let logSummaryPanelView = try sourceStructBody(named: "LogSummaryPanelView", in: mac)
        let logSummaryDetailView = try sourceStructBody(named: "LogSummaryDetailView", in: mac)
        let logSummaryTile = try sourceStructBody(named: "LogSummaryTile", in: mac)
        let sectionBox = try sourceBody(
            after: "struct SectionBox<Content: View>: View",
            in: mac,
            description: "Mac section box"
        )
        let commandPanelView = try sourceStructBody(named: "CommandPanelView", in: mac)
        let iosHistoryScreen = try sourceStructBody(named: "CompanionHistoryScreen", in: ios)
        let iosHistoryRegularWorkspace = try sourceBody(
            after: "private var historyRegularWorkspace",
            in: iosHistoryScreen,
            description: "iPad log regular workspace"
        )
        let iosHistorySummaryColumn = try sourceBody(
            after: "private var historySummaryColumn",
            in: iosHistoryScreen,
            description: "iPad log summary column"
        )
        let iosHistoryStageColumn = try sourceBody(
            after: "private var historyStageColumn",
            in: iosHistoryScreen,
            description: "iPad log stage column"
        )
        let iosHistoryDetailColumn = try sourceBody(
            after: "private var historyDetailColumn",
            in: iosHistoryScreen,
            description: "iPad log detail column"
        )
        let iosSplitRoot = try sourceStructBody(named: "CompanionSplitRootView", in: ios)
        let iosSidebar = try sourceStructBody(named: "WorkstationSidebar", in: ios)
        let iosSidebarButton = try sourceStructBody(named: "CompanionSidebarButton", in: ios)
        let compactTabBar = try sourceStructBody(named: "CompanionCompactTabBar", in: ios)
        let iosScreenContainer = try sourceBody(
            after: "private struct CompanionScreenContainer<Content: View>: View",
            in: ios,
            description: "iOS companion screen container"
        )
        let iosHeader = try sourceStructBody(named: "CompanionScreenHeader", in: ios)
        let iosHeaderStatusPill = try sourceStructBody(named: "CompanionHeaderStatusPill", in: ios)
        let iosStatusScreen = try sourceStructBody(named: "CompanionStatusScreen", in: ios)
        let iosMetricOverview = try sourceStructBody(named: "RemoteDashboardMetricOverview", in: ios)
        let iosMetricTile = try sourceStructBody(named: "RemoteMetricTile", in: ios)
        let iosWorkstationMetricCard = try sourceStructBody(named: "WorkstationMetricCard", in: ios)
        let iosRemoteLogSummaryPanel = try sourceStructBody(named: "RemoteLogSummaryPanel", in: ios)
        let iosRemoteLogDetailPanel = try sourceStructBody(named: "RemoteLogDetailPanel", in: ios)
        let iosRemoteLogSummaryRow = try sourceStructBody(named: "RemoteLogSummaryRow", in: ios)
        let iosCompanionEmptyDetailPanel = try sourceStructBody(named: "CompanionEmptyDetailPanel", in: ios)
        let iosSharedRunLogsView = try sourceStructBody(named: "SharedRunLogsView", in: ios)
        let iosSharedRunLogRow = try sourceStructBody(named: "SharedRunLogRow", in: ios)
        let iosInlineLogBlock = try sourceStructBody(named: "CompanionInlineLogBlock", in: ios)
        let macRemoteActivityPanel = try sourceStructBody(named: "RemoteActivityPanelView", in: mac)
        let macSharedRunLogActivityRow = try sourceStructBody(named: "SharedRunLogActivityRow", in: mac)
        let macServerRequestLogActivityRow = try sourceStructBody(named: "ServerRequestLogActivityRow", in: mac)
        let macRemoteCommandActivityRow = try sourceStructBody(named: "RemoteCommandActivityRow", in: mac)
        let macFileAccessActivityRow = try sourceStructBody(named: "FileAccessActivityRow", in: mac)
        let macRunLogArchivePanel = try sourceStructBody(named: "RunLogArchivePanelView", in: mac)
        let macRunLogArchiveRow = try sourceStructBody(named: "RunLogArchiveRowView", in: mac)
        let topUtilityActions = try sourceStructBody(named: "TopUtilityActionsView", in: mac)
        let iosCardButtonStyle = try sourceBody(
            after: "private struct KLMSCardButtonStyle: ButtonStyle",
            in: ios,
            description: "iOS card button style"
        )
        let actionButtonStyle = try sourceBody(
            after: "private struct KLMSActionButtonStyle: ButtonStyle",
            in: ios,
            description: "iOS action button style"
        )
        let toolbarButtonStyle = try sourceBody(
            after: "private struct KLMSToolbarButtonStyle: ButtonStyle",
            in: ios,
            description: "iOS toolbar button style"
        )

        XCTAssertTrue(mac.contains("case activityLogs"))
        XCTAssertTrue(mac.contains("case diagnostics"))
        XCTAssertTrue(mac.contains("\"로그\""))
        XCTAssertTrue(macModel.contains("var hasClearableVisibleLogs: Bool"))
        XCTAssertTrue(macModel.contains("var hasClearableExecutionRunLogs: Bool"))
        XCTAssertTrue(macModel.contains("var hasClearableLocalRelayLogs: Bool"))
        XCTAssertTrue(macModel.contains("func clearExecutionRunLogs()"))
        XCTAssertTrue(macModel.contains("func clearLocalRelayLogs()"))
        XCTAssertTrue(mac.contains(".disabled(model.runningCommand != nil || !model.hasClearableVisibleLogs)"))
        XCTAssertTrue(macRunLogArchivePanel.contains("model.clearExecutionRunLogs()"))
        XCTAssertTrue(macRunLogArchivePanel.contains("model.clearLocalRelayLogs()"))
        XCTAssertTrue(mac.contains("private enum RunLogArchiveList"))
        XCTAssertTrue(mac.contains("static let initialVisibleLimit = 12"))
        XCTAssertTrue(mac.contains("static let increment = 18"))
        XCTAssertTrue(macRunLogArchivePanel.contains("@State private var visibleLimit = RunLogArchiveList.initialVisibleLimit"))
        XCTAssertTrue(macRunLogArchivePanel.contains("visibleLimit += RunLogArchiveList.increment"))
        XCTAssertTrue(macRunLogArchivePanel.contains("visibleLimit = RunLogArchiveList.initialVisibleLimit"))
        XCTAssertFalse(macRunLogArchivePanel.contains("visibleLimit = 30"))
        XCTAssertFalse(macRunLogArchivePanel.contains("visibleLimit += 30"))
        XCTAssertFalse(macRunLogArchiveRow.contains("DisclosureGroup"))
        XCTAssertTrue(macRunLogArchiveRow.contains(".accessibilityLabel(\"\\(record.command.displayName) 실행 로그 \\(isExpanded ? \"펼쳐짐\" : \"접힘\")\")"))
        XCTAssertTrue(macRunLogArchiveRow.contains(".contentShape(RoundedRectangle(cornerRadius: 8))"))
        XCTAssertFalse(macRunLogArchiveRow.contains("model.deleteCommandHistoryRecord"))
        XCTAssertFalse(macRunLogArchiveRow.contains("Image(systemName: \"trash\")"))
        XCTAssertTrue(mac.contains("LinearGradient("))
        XCTAssertTrue(mac.contains("Image(systemName: \"trash\")"))
        XCTAssertTrue(mac.contains(".accessibilityLabel(\"서버·파일 요청 기록 지우기\")"))
        XCTAssertTrue(macRemoteActivityPanel.contains(".buttonStyle(KLMSMacCompactDangerIconButtonStyle())"))
        XCTAssertTrue(macModel.contains("func clearServerRelayActivityLogs() async"))
        XCTAssertTrue(macModel.contains("var hasClearableServerActivityLogs: Bool"))
        XCTAssertFalse(mac.contains("Label(\"기록 지우기\", systemImage: \"trash\")"))
        XCTAssertTrue(mac.contains("CompactStageDurationRowsView(durations: record.visibleStageDurations)"))
        XCTAssertTrue(mac.contains("record.visibleStageDurations"))
        let compactStageRows = try sourceStructBody(named: "CompactStageDurationRowsView", in: mac)
        XCTAssertTrue(compactStageRows.contains("private static let visibleLimit = 4"))
        XCTAssertTrue(compactStageRows.contains("ForEach(visibleDurations)"))
        XCTAssertTrue(compactStageRows.contains("Text(\"+\\(remainingCount)단계\")"))
        XCTAssertTrue(mac.contains(".fixedSize(horizontal: true, vertical: false)"))
        XCTAssertTrue(mac.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        let sharedRunLogRow = try sourceStructBody(named: "SharedRunLogRow", in: ios)
        let serverRequestLogRow = try sourceStructBody(named: "ServerRequestLogRow", in: ios)
        let remoteFileAccessRequestRow = try sourceStructBody(named: "RemoteFileAccessRequestRow", in: ios)
        let remoteCommandRow = try sourceStructBody(named: "RemoteCommandRow", in: ios)
        XCTAssertTrue(iosInlineLogBlock.contains("private let highlightSourceText: String"))
        XCTAssertTrue(iosInlineLogBlock.contains("@State private var highlights: [KLMSLogHighlight]"))
        XCTAssertTrue(iosInlineLogBlock.contains("self.highlightSourceText = Self.boundedHighlightSourceText(boundedText)"))
        XCTAssertTrue(iosInlineLogBlock.contains("self._highlights = State(initialValue: [])"))
        XCTAssertTrue(iosInlineLogBlock.contains(".task(id: highlightSourceText)"))
        XCTAssertTrue(iosInlineLogBlock.contains("Task.detached(priority: .utility)"))
        XCTAssertTrue(iosInlineLogBlock.contains("private static func boundedHighlightSourceText"))
        XCTAssertTrue(iosInlineLogBlock.contains("let maxCharacters = 3_000"))
        XCTAssertTrue(iosInlineLogBlock.contains("let text = highlightSourceText"))
        XCTAssertFalse(iosInlineLogBlock.contains("self.highlights = KLMSReadableLogParser.highlights(from: boundedText)"))
        XCTAssertTrue(iosInlineLogBlock.contains("CompanionReadableLogHighlightsView(highlights: highlights)"))
        XCTAssertFalse(iosInlineLogBlock.contains("CompanionReadableLogHighlightsView(highlights: KLMSReadableLogParser.highlights"))
        XCTAssertTrue(sharedRunLogRow.contains(".accessibilityLabel(\"\\(log.commandTitle.nilIfEmpty ?? \"동기화\") 로그 \\(isExpanded ? \"펼쳐짐\" : \"접힘\")\")"))
        XCTAssertTrue(sharedRunLogRow.contains(".accessibilityHint(isExpanded ? \"단계별 소요 시간과 마지막 로그를 접습니다.\" : \"단계별 소요 시간과 마지막 로그를 펼칩니다.\")"))
        XCTAssertFalse(sharedRunLogRow.contains("로그 \\(isExpanded ? \"접기\" : \"펼치기\")"))
        XCTAssertTrue(serverRequestLogRow.contains(".accessibilityLabel(\"\\(entry.action.nilIfEmpty ?? entry.path.nilIfEmpty ?? \"서버 요청\") 기록 \\(isExpanded ? \"펼쳐짐\" : \"접힘\")\")"))
        XCTAssertTrue(serverRequestLogRow.contains(".accessibilityHint(isExpanded ? \"요청 출처와 상세 로그를 접습니다.\" : \"요청 출처와 상세 로그를 펼칩니다.\")"))
        XCTAssertFalse(serverRequestLogRow.contains("기록 \\(isExpanded ? \"접기\" : \"펼치기\")"))
        XCTAssertTrue(remoteFileAccessRequestRow.contains(".accessibilityLabel(\"\\(request.itemTitle.nilIfEmpty ?? \"파일\") 요청 기록 \\(isExpanded ? \"펼쳐짐\" : \"접힘\")\")"))
        XCTAssertTrue(remoteFileAccessRequestRow.contains(".accessibilityHint(isExpanded ? \"파일 요청 상태와 상세 로그를 접습니다.\" : \"파일 요청 상태와 상세 로그를 펼칩니다.\")"))
        XCTAssertFalse(remoteFileAccessRequestRow.contains("요청 기록 \\(isExpanded ? \"접기\" : \"펼치기\")"))
        XCTAssertTrue(remoteCommandRow.contains(".accessibilityLabel(\"\\(command.kind.displayName) 원격 실행 기록 \\(isExpanded ? \"펼쳐짐\" : \"접힘\")\")"))
        XCTAssertTrue(remoteCommandRow.contains(".accessibilityHint(isExpanded ? \"실행 상태와 상세 로그를 접습니다.\" : \"실행 상태와 상세 로그를 펼칩니다.\")"))
        XCTAssertFalse(remoteCommandRow.contains("원격 실행 기록 \\(isExpanded ? \"접기\" : \"펼치기\")"))
        XCTAssertFalse(mac.contains("case runLogs"))
        XCTAssertTrue(macRootBody.contains("DashboardTopBarView(model: model, selectedSection: $selectedSection)"))
        XCTAssertTrue(macRootBody.contains("MacAlertBannerView("))
        XCTAssertFalse(macRootBody.contains("CommandPanelView(model: model)"))
        XCTAssertTrue(macRootBody.contains("MacWorkspaceSidebarView("))
        XCTAssertTrue(macRootBody.contains("resetCurrentSectionScroll: resetCurrentSectionScroll"))
        XCTAssertTrue(macRootBody.contains(".frame(width: 264, alignment: .topLeading)"))
        XCTAssertTrue(mac.contains("Rectangle()\n                    .fill(Color.klmsMacBorder.opacity(0.76))"))
        XCTAssertTrue(macRootBody.contains("ZStack(alignment: .topLeading)"))
        XCTAssertTrue(macRootBody.contains("MacWorkspaceSelectionAccessibilityMarker(section: selectedSection)"))
        XCTAssertTrue(macRootBody.contains("MacWorkspaceRenderedAccessibilityMarker(section: selectedSection)"))
        XCTAssertTrue(macRootBody.contains(".frame(maxWidth: .infinity, alignment: .topLeading)"))
        XCTAssertTrue(macRootBody.contains("MacWorkstationLayoutView("))
        XCTAssertTrue(macRootBody.contains(".accessibilityIdentifier(\"workspace-scroll-\\(selectedSection.rawValue)\")"))
        XCTAssertTrue(macSelectionMarker.contains(".accessibilityIdentifier(\"workspace-content-\\(section.rawValue)\")"))
        XCTAssertTrue(macSelectionMarker.contains(".accessibilityLabel(section.accessibilitySummary)"))
        XCTAssertTrue(macSelectionMarker.contains(".frame(width: 1, height: 1)"))
        XCTAssertTrue(macModel.contains("@Published private(set) var cachedIssues: [EngineIssue] = []"))
        XCTAssertTrue(macModel.contains("var needsAttention: Bool"))
        XCTAssertTrue(macModel.contains("var attentionSummary: String"))
        XCTAssertTrue(macModel.contains("let nextIssues = nextSnapshot.issues"))
        XCTAssertTrue(macModel.contains("private(set) var dashboardSummaryPresentation = DashboardSummaryPresentation"))
        XCTAssertTrue(macModel.contains("dashboardSummaryPresentation = DashboardSummaryPresentation(snapshot: snapshot, summary: dashboardSummaryCache)"))
        XCTAssertTrue(macModel.contains("private(set) var dashboardRenderSignature = DashboardRenderSignature"))
        XCTAssertTrue(macModel.contains("private(set) var dashboardFileRenderSignature = DashboardFileRenderSignature(snapshot: EngineSnapshot())"))
        XCTAssertTrue(macModel.contains("dashboardRenderSignature = DashboardRenderSignature(snapshot: snapshot, summary: dashboardSummaryCache)"))
        XCTAssertTrue(macModel.contains("dashboardFileRenderSignature = DashboardFileRenderSignature(snapshot: snapshot)"))
        XCTAssertTrue(mac.contains("IssueSummaryView(issues: model.cachedIssues)"))
        XCTAssertFalse(mac.contains("IssueSummaryView(issues: snapshot.issues)"))
        XCTAssertTrue(mac.contains("renderSignature: model.dashboardRenderSignature"))
        XCTAssertTrue(mac.contains("presentation: model.dashboardSummaryPresentation"))
        XCTAssertTrue(mac.contains("fileRenderSignature: model.dashboardFileRenderSignature"))
        XCTAssertFalse(mac.contains("renderSignature: DashboardRenderSignature(snapshot: model.snapshot, summary: model.dashboardSummaryCache)"))
        XCTAssertTrue(macWorkstationLayoutView.contains("let model: KLMSMacModel"))
        XCTAssertFalse(mac.contains("@State private var renderedSection"))
        XCTAssertFalse(mac.contains("@State private var renderSectionTask"))
        XCTAssertFalse(mac.contains("workspaceRenderDelayNanoseconds"))
        XCTAssertFalse(mac.contains("scheduleRenderedSection"))
        XCTAssertFalse(mac.contains("try? await Task.sleep(nanoseconds: workspaceRenderDelayNanoseconds)"))
        XCTAssertFalse(mac.contains("selectedSection: $renderedSection"))
        XCTAssertFalse(mac.contains(".task(id: selectedSection)"))
        XCTAssertFalse(mac.contains("let target = selectedSection"))
        XCTAssertFalse(mac.contains(".onChange(of: selectedSection) { _, nextSection in"))
        XCTAssertFalse(mac.contains("queueRenderedSection(nextSection)"))
        XCTAssertFalse(mac.contains("private func queueRenderedSection(_ section: KLMSMacSection)"))
        XCTAssertFalse(mac.contains("@State private var workspaceRenderTask: Task<Void, Never>?"))
        XCTAssertFalse(mac.contains("workspaceRenderTask?.cancel()"))
        XCTAssertFalse(mac.contains("workspaceRenderTask = Task { @MainActor in"))
        XCTAssertFalse(mac.contains("withTransaction(transaction) {\n            renderedSection = section"))
        XCTAssertTrue(macRootBody.contains("selectedSection: selectedSection"))
        XCTAssertTrue(mac.contains("selectedSection: $selectedSection"))
        XCTAssertFalse(deferredMacWorkspacePanel.contains("@State private var loadedID"))
        XCTAssertTrue(deferredMacWorkspacePanel.contains("var contentIdentifier: String?"))
        XCTAssertTrue(deferredMacWorkspacePanel.contains("var deferContent: Bool"))
        XCTAssertTrue(deferredMacWorkspacePanel.contains("@State private var isContentReady = false"))
        XCTAssertTrue(deferredMacWorkspacePanel.contains("@State private var contentTask: Task<Void, Never>?"))
        XCTAssertFalse(deferredMacWorkspacePanel.contains("if loadedID == id"))
        XCTAssertFalse(deferredMacWorkspacePanel.contains(".accessibilityIdentifier(\"workspace-loading-\\(id)\")"))
        XCTAssertTrue(mac.contains("MacWorkspacePanelPreparingView()"))
        XCTAssertTrue(mac.contains("ProgressView()"))
        XCTAssertTrue(mac.contains("private enum MacWorkspacePanelTiming"))
        XCTAssertTrue(mac.contains("static let deferredContentDelayNanoseconds: UInt64 = 90_000_000"))
        XCTAssertTrue(mac.contains("static let heavyListContentDelayNanoseconds: UInt64 = 260_000_000"))
        XCTAssertFalse(deferredMacWorkspacePanel.contains("loadingText"))
        XCTAssertTrue(deferredMacWorkspacePanel.contains("ZStack(alignment: .topLeading)"))
        XCTAssertTrue(deferredMacWorkspacePanel.contains("workspaceContentAccessibilityMarker"))
        XCTAssertTrue(deferredMacWorkspacePanel.contains("Text(\"작업공간 내용\")"))
        XCTAssertTrue(deferredMacWorkspacePanel.contains(".accessibilityElement(children: .ignore)"))
        XCTAssertTrue(deferredMacWorkspacePanel.contains(".accessibilityLabel(\"작업공간 내용\")"))
        XCTAssertTrue(deferredMacWorkspacePanel.contains("guard deferContent else"))
        XCTAssertTrue(deferredMacWorkspacePanel.contains(".accessibilityIdentifier(\"workspace-panel-\\(id)\")"))
        XCTAssertFalse(deferredMacWorkspacePanel.contains(".task(id: id)"))
        XCTAssertTrue(deferredMacWorkspacePanel.contains("await Task.yield()"))
        XCTAssertTrue(deferredMacWorkspacePanel.contains("var contentDelayNanoseconds: UInt64"))
        XCTAssertTrue(deferredMacWorkspacePanel.contains("contentDelayNanoseconds: UInt64 = MacWorkspacePanelTiming.deferredContentDelayNanoseconds"))
        XCTAssertTrue(deferredMacWorkspacePanel.contains("try? await Task.sleep(nanoseconds: contentDelayNanoseconds)"))
        XCTAssertFalse(deferredMacWorkspacePanel.contains("renderDelayNanoseconds"))
        XCTAssertFalse(deferredMacWorkspacePanel.contains("loadedID = id"))
        XCTAssertTrue(macWorkstationLayoutView.contains("DeferredMacWorkspacePanel(id: \"workspace-dashboard\", contentIdentifier: \"workspace-content-dashboard\", deferContent: false)"))
        XCTAssertTrue(macWorkstationLayoutView.contains("DashboardSummaryView(model: model)"))
        XCTAssertFalse(macWorkstationLayoutView.contains("DeferredDashboardSummaryView"))
        XCTAssertFalse(macWorkstationLayoutView.contains("loadsImmediately: true"))
        let filesPanelIndex = try XCTUnwrap(macWorkstationLayoutView.range(of: "id: \"workspace-files\"")?.lowerBound)
        let filesPanelTail = macWorkstationLayoutView[filesPanelIndex...]
        let filesPanelEnd = try XCTUnwrap(filesPanelTail.range(of: "cachedDashboardDetailPanel(kind: .files)")?.upperBound)
        let filesPanelBlock = String(filesPanelTail[..<filesPanelEnd])
        XCTAssertTrue(filesPanelBlock.contains("contentIdentifier: \"workspace-content-files\""))
        XCTAssertTrue(filesPanelBlock.contains("contentDelayNanoseconds: MacWorkspacePanelTiming.heavyListContentDelayNanoseconds"))
        XCTAssertTrue(macWorkstationLayoutView.contains("id: \"workspace-tasks\""))
        XCTAssertTrue(macWorkstationLayoutView.contains("contentDelayNanoseconds: MacWorkspacePanelTiming.heavyListContentDelayNanoseconds"))
        XCTAssertTrue(macWorkstationLayoutView.contains("DeferredMacWorkspacePanel(id: \"workspace-notices\", contentIdentifier: \"workspace-content-notices\""))
        XCTAssertTrue(macWorkstationLayoutView.contains("DeferredMacWorkspacePanel(id: \"workspace-calendar\", contentIdentifier: \"workspace-content-calendar\""))
        XCTAssertTrue(macWorkstationLayoutView.contains("id: \"workspace-activityLogs\""))
        XCTAssertTrue(macWorkstationLayoutView.contains("contentIdentifier: \"workspace-content-activityLogs\""))
        XCTAssertTrue(macWorkstationLayoutView.contains("id: \"workspace-diagnostics\""))
        XCTAssertTrue(macWorkstationLayoutView.contains("contentIdentifier: \"workspace-content-diagnostics\""))
        XCTAssertTrue(macWorkstationLayoutView.contains("id: \"workspace-settings\""))
        XCTAssertTrue(macWorkstationLayoutView.contains("contentIdentifier: \"workspace-content-settings\""))
        XCTAssertTrue(macWorkstationLayoutView.contains("cachedDashboardDetailPanel(kind: .files)"))
        XCTAssertTrue(macWorkstationLayoutView.contains("cachedDashboardDetailPanel(kind: .notices)"))
        XCTAssertTrue(macWorkstationLayoutView.contains("cachedDashboardDetailPanel(kind: .calendar)"))
        XCTAssertTrue(macWorkstationLayoutView.contains(".accessibilityIdentifier(\"workspace-container-\\(selectedSection.rawValue)\")"))
        XCTAssertFalse(macWorkstationLayoutView.contains(".accessibilityIdentifier(\"workspace-marker-\\(selectedSection.rawValue)\")"))
        XCTAssertTrue(macWorkstationLayoutView.contains(".accessibilityIdentifier(\"workspace-rendered-content-\\(selectedSection.rawValue)\")"))
        XCTAssertTrue(macWorkstationLayoutView.contains(".accessibilityElement(children: .ignore)"))
        XCTAssertTrue(taskAndExamWorkspaceView.contains("@State private var selectedKind: DashboardDetailKind = .assignments"))
        XCTAssertTrue(taskAndExamWorkspaceView.contains("taskKindSelector"))
        XCTAssertTrue(taskAndExamWorkspaceView.contains("LazyVGrid(columns: taskKindColumns, spacing: 8)"))
        XCTAssertTrue(taskAndExamWorkspaceView.contains("private var taskKindColumns: [GridItem]"))
        XCTAssertTrue(taskAndExamWorkspaceView.contains(".frame(maxWidth: .infinity, minHeight: 44)"))
        XCTAssertTrue(taskAndExamWorkspaceView.contains("cachedDashboardDetailPanel(kind: activeKind)"))
        XCTAssertTrue(taskAndExamWorkspaceView.contains("availableKinds.contains(selectedKind) ? selectedKind : .assignments"))
        XCTAssertTrue(taskAndExamWorkspaceView.contains("model.snapshot.visibleCounts.helpDesk > 0"))
        XCTAssertTrue(taskAndExamWorkspaceView.contains("renderSignature: model.dashboardRenderSignature"))
        XCTAssertTrue(macSidebarView.contains("let model: KLMSMacModel"))
        XCTAssertTrue(dashboardTopBarView.contains("let model: KLMSMacModel"))
        XCTAssertTrue(macAlertBannerView.contains("let model: KLMSMacModel"))
        XCTAssertTrue(commandPanelView.contains("let model: KLMSMacModel"))
        XCTAssertTrue(taskAndExamWorkspaceView.contains("let model: KLMSMacModel"))
        XCTAssertTrue(quickStatusStripView.contains("let model: KLMSMacModel"))
        XCTAssertTrue(externalIntegrationStatusView.contains("let model: KLMSMacModel"))
        XCTAssertTrue(importantLogPanelView.contains("let model: KLMSMacModel"))
        XCTAssertTrue(logSummaryPanelView.contains("let model: KLMSMacModel"))
        XCTAssertTrue(logSummaryDetailView.contains("let model: KLMSMacModel"))
        XCTAssertFalse(macWorkstationLayoutView.contains("@ObservedObject var model"))
        XCTAssertFalse(macSidebarView.contains("@ObservedObject var model"))
        XCTAssertFalse(dashboardTopBarView.contains("@ObservedObject var model"))
        XCTAssertFalse(macAlertBannerView.contains("@ObservedObject var model"))
        XCTAssertFalse(commandPanelView.contains("@ObservedObject var model"))
        XCTAssertFalse(taskAndExamWorkspaceView.contains("@ObservedObject var model"))
        XCTAssertFalse(quickStatusStripView.contains("@ObservedObject var model"))
        XCTAssertFalse(externalIntegrationStatusView.contains("@ObservedObject var model"))
        XCTAssertFalse(importantLogPanelView.contains("@ObservedObject var model"))
        XCTAssertFalse(logSummaryPanelView.contains("@ObservedObject var model"))
        XCTAssertFalse(logSummaryDetailView.contains("@ObservedObject var model"))
        XCTAssertEqual(mac.components(separatedBy: "@ObservedObject var model: KLMSMacModel").count - 1, 1)
        let alertRange = try XCTUnwrap(macRootBody.range(of: "MacAlertBannerView("))
        let workstationRange = try XCTUnwrap(macRootBody.range(of: "MacWorkstationLayoutView("))
        let sidebarRange = try XCTUnwrap(macRootBody.range(of: "MacWorkspaceSidebarView("))
        let scrollRange = try XCTUnwrap(macRootBody.range(of: "WholeScreenVerticalScrollView"))
        XCTAssertLessThan(sidebarRange.lowerBound, scrollRange.lowerBound)
        XCTAssertLessThan(alertRange.lowerBound, scrollRange.lowerBound)
        XCTAssertLessThan(alertRange.lowerBound, workstationRange.lowerBound)
        XCTAssertFalse(mac.contains("struct MacDesignWindowRootView"))
        XCTAssertTrue(macSidebarView.contains("Text(\"KLMS Sync\")"))
        XCTAssertTrue(macSidebarView.contains("Text(\"작업 공간\")"))
        XCTAssertTrue(macSidebarView.contains("ScrollView(.vertical, showsIndicators: true)"))
        XCTAssertFalse(macSidebarView.contains("CommandPanelView(model: model)"))
        XCTAssertTrue(macSidebarView.contains("WorkspaceNavigationView(selection: $selectedSection, resetCurrentSectionScroll: resetCurrentSectionScroll)"))
        XCTAssertFalse(macSidebarView.contains("Spacer(minLength: 10)"))
        let sidebarNavigationRange = try XCTUnwrap(macSidebarView.range(of: "WorkspaceNavigationView(selection: $selectedSection"))
        let sidebarRuntimeRange = try XCTUnwrap(macSidebarView.range(of: "DashboardRuntimePanelView(model: model)"))
        XCTAssertLessThan(sidebarNavigationRange.lowerBound, sidebarRuntimeRange.lowerBound)
        XCTAssertTrue(macSidebarView.contains("DashboardRuntimePanelView(model: model)"))
        XCTAssertTrue(macSidebarView.contains("Color.klmsMacSidebarBackground"))
        XCTAssertTrue(macRuntimePanel.contains("@State private var isExpanded = false"))
        XCTAssertFalse(macRuntimePanel.contains("@AppStorage(\"KLMSMacRuntimePanelExpanded\")"))
        XCTAssertTrue(externalIntegrationStatusView.contains("@State private var isExpanded = false"))
        XCTAssertFalse(externalIntegrationStatusView.contains("@AppStorage(\"KLMSMacIntegrationStatusExpanded\")"))
        XCTAssertTrue(macRuntimePanel.contains("if isExpanded {"))
        XCTAssertTrue(macRuntimePanel.contains("runtimeSummaryBadgeText"))
        XCTAssertTrue(macRuntimePanel.contains("runtimeSummaryBadgeColor"))
        XCTAssertTrue(macRuntimePanel.contains("isExpanded ? \"chevron.down\" : \"chevron.right\""))
        XCTAssertTrue(macRuntimePanel.contains(".help(isExpanded ? \"연동 상태 접기\" : \"연동 상태 펼치기\")"))
        XCTAssertTrue(macNavigationView.contains("section.systemImage"))
        XCTAssertTrue(macNavigationView.contains("@State private var hoveredSection"))
        XCTAssertTrue(macNavigationView.contains("let isHovered = hoveredSection == section"))
        XCTAssertTrue(macNavigationView.contains("var transaction = Transaction()"))
        XCTAssertTrue(macNavigationView.contains("transaction.animation = nil"))
        XCTAssertTrue(macNavigationView.contains("withTransaction(transaction)"))
        XCTAssertTrue(macNavigationView.contains(".frame(width: 30, height: 30)"))
        XCTAssertTrue(macNavigationView.contains("iconBackground(isSelected: isSelected, isHovered: isHovered)"))
        XCTAssertTrue(macNavigationView.contains("Color.klmsMacSelectedBorder.opacity(0.24)"))
        XCTAssertTrue(macNavigationView.contains("Color.klmsMacSubtleCardBackground.opacity(0.72)"))
        XCTAssertTrue(macNavigationView.contains("Image(systemName: \"chevron.right\")"))
        XCTAssertTrue(macNavigationView.contains("rowBackground(isSelected: isSelected, isHovered: isHovered)"))
        XCTAssertTrue(macNavigationView.contains("Color.klmsMacSubtleCardBackground.opacity(0.62)"))
        XCTAssertTrue(macNavigationView.contains("Color.klmsMacSubtleCardBackground.opacity(0.28)"))
        XCTAssertTrue(macNavigationView.contains(".overlay(alignment: .leading)"))
        XCTAssertTrue(macNavigationView.contains(".frame(width: isSelected ? 4 : 0)"))
        XCTAssertTrue(macNavigationView.contains("rowBorder(isSelected: isSelected, isHovered: isHovered)"))
        XCTAssertTrue(macNavigationView.contains("Color.klmsMacCommandBorder.opacity(0.74)"))
        XCTAssertTrue(macNavigationView.contains("Color.klmsMacCommandBorder.opacity(0.36)"))
        XCTAssertTrue(macNavigationView.contains(".onHover { hovering in"))
        XCTAssertTrue(mac.contains("light: NSColor(red: 0.894, green: 0.878, blue: 0.827, alpha: 1.0)"))
        XCTAssertTrue(mac.contains("dark: NSColor(red: 0.224, green: 0.212, blue: 0.184, alpha: 1.0)"))
        XCTAssertTrue(mac.contains("light: NSColor(red: 0.165, green: 0.165, blue: 0.153, alpha: 0.56)"))
        XCTAssertTrue(mac.contains("dark: NSColor(red: 0.941, green: 0.875, blue: 0.722, alpha: 0.48)"))
        XCTAssertTrue(macNavigationView.contains(".frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)"))
        XCTAssertTrue(macNavigationView.contains("WorkspaceNavigationSelectionMarker(section: selection)"))
        XCTAssertTrue(macNavigationSelectionMarker.contains(".accessibilityIdentifier(\"workspace-navigation-selection-\\(section.rawValue)\")"))
        XCTAssertTrue(macNavigationView.contains("guard selection != section else {"))
        XCTAssertTrue(macNavigationView.contains("resetCurrentSectionScroll()"))
        XCTAssertTrue(macMetricTile.contains("Image(systemName: isSelected ? \"checkmark.circle.fill\" : \"chevron.right\")"))
        XCTAssertTrue(macMetricTile.contains("var isHovered: Bool"))
        XCTAssertTrue(macMetricTile.contains(".background(metricBackground, in: RoundedRectangle(cornerRadius: 13))"))
        XCTAssertTrue(macMetricTile.contains("return isHovered ? Color.klmsMacSubtleCardBackground.opacity(0.64) : Color.klmsMacCardBackground"))
        XCTAssertTrue(macMetricTile.contains("isSelected ? Color.klmsMacSelectedForeground : Color.klmsMacPrimaryText"))
        XCTAssertTrue(macMetricTile.contains(".stroke(metricBorder, lineWidth: isSelected ? 1.4 : 1)"))
        XCTAssertTrue(macMetricTile.contains("return isHovered ? Color.klmsMacCommandBorder.opacity(0.78) : Color.klmsMacBorder"))
        XCTAssertTrue(macMetricTile.contains("isHovered ? Color.klmsMacPrimaryText : Color.klmsMacSecondaryText.opacity(0.70)"))
        XCTAssertFalse(macMetricTile.contains(".shadow(color: isSelected ? tint.opacity(0.12) : Color.clear"))
        XCTAssertTrue(macMetricTile.contains(".font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())"))
        XCTAssertTrue(macMetricTile.contains(".frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)"))
        XCTAssertFalse(macMetricTile.contains("minHeight: 82"))
        XCTAssertTrue(dashboardTopBarView.contains("DashboardTopBarStatusContent(snapshot: snapshot)"))
        XCTAssertTrue(dashboardTopBarView.contains(".equatable()"))
        XCTAssertTrue(dashboardTopBarStatusContent.contains("Text(snapshot.title)"))
        XCTAssertFalse(dashboardTopBarView.contains("Text(\"대시보드\")"))
        XCTAssertTrue(dashboardTopBarStatusContent.contains(".font(.system(size: 26, weight: .bold, design: .rounded))"))
        XCTAssertTrue(dashboardTopBarView.contains(".accessibilityIdentifier(\"workspace-title-\\(selectedSection.rawValue)\")"))
        XCTAssertFalse(dashboardTopBarView.contains(".accessibilityIdentifier(\"workspace-content-\\(selectedSection.rawValue)\")"))
        XCTAssertTrue(dashboardTopBarView.contains(".accessibilityLabel(\"\\(selectedSection.title) 화면\")"))
        XCTAssertTrue(dashboardTopBarStatusContent.contains("Label(runningPhaseLabel, systemImage: \"arrow.triangle.2.circlepath\")"))
        XCTAssertTrue(dashboardTopBarView.contains("runningPhaseLabel: \"진행 중\""))
        XCTAssertTrue(macAlertBannerView.contains("MacAlertBannerContent(snapshot: snapshot)"))
        XCTAssertTrue(macAlertBannerView.contains(".equatable()"))
        XCTAssertTrue(macAlertBannerContent.contains("nonisolated static func =="))
        XCTAssertTrue(macAlertBannerContent.contains(".accessibilitySortPriority(100)"))
        XCTAssertTrue(macAlertBannerContent.contains(".zIndex(1)"))
        XCTAssertTrue(macAlertBannerContent.contains(".lineLimit(1)"))
        XCTAssertTrue(macAlertBannerContent.contains(".minimumScaleFactor(snapshot.authDigits == nil ? 0.72 : 0.86)"))
        XCTAssertTrue(macAlertBannerContent.contains(".frame(maxWidth: snapshot.authDigits == nil ? 92 : nil)"))
        XCTAssertTrue(macAlertBannerSnapshot.contains("var shouldShow: Bool"))
        XCTAssertTrue(macAlertBannerSnapshot.contains("|| !hasSyncReport"))
        XCTAssertFalse(macAlertBannerSnapshot.contains("selectedSection == .dashboard"))
        XCTAssertTrue(macAlertBannerSnapshot.contains("if authDigits != nil"))
        XCTAssertTrue(macAlertBannerSnapshot.contains("if authStatusMessage != nil"))
        XCTAssertTrue(macAlertBannerSnapshot.contains("if needsAttention"))
        XCTAssertTrue(macAlertBannerSnapshot.contains("return currentPhaseText ?? \"LOG\""))
        XCTAssertFalse(mac.contains("private struct CommandOutputPanelView"))
        XCTAssertTrue(mac.contains("Label(\"\\(command.displayName) 변경량 계산\", systemImage: \"magnifyingglass\")"))
        XCTAssertTrue(mac.contains(".frame(maxWidth: .infinity, minHeight: 44)"))
        XCTAssertFalse(mac.contains(".frame(maxWidth: .infinity, minHeight: 34)"))
        XCTAssertFalse(mac.contains(".frame(maxWidth: .infinity, minHeight: 40)"))
        XCTAssertTrue(macDetail.contains("Label(\"더 보기 \\(remainingCount)개 남음\", systemImage: \"chevron.down\")"))
        XCTAssertTrue(macDetail.contains(".frame(minHeight: 44)"))
        XCTAssertTrue(macDetail.contains(".accessibilityLabel(title)"))
        XCTAssertFalse(macDetail.contains(".frame(minHeight: 40)"))
        XCTAssertFalse(macDetail.contains(".frame(minHeight: 30)"))
        XCTAssertFalse(ios.contains("private struct RemoteStatusHeader"))
        XCTAssertFalse(ios.contains("private struct RemoteDashboardStatusStrip"))
        let workstationBody = try sourceStructBody(named: "MacWorkstationLayoutView", in: mac)
        XCTAssertFalse(workstationBody.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertFalse(workstationBody.contains("HStack(alignment: .top, spacing: 14)"))
        XCTAssertFalse(workstationBody.contains(".frame(minWidth: 220, idealWidth: 260, maxWidth: 300, alignment: .topLeading)"))
        XCTAssertTrue(workstationBody.contains(".layoutPriority(1)"))
        XCTAssertFalse(workstationBody.contains(".accessibilityIdentifier(workspaceContainerAccessibilityIdentifier)"))
        XCTAssertTrue(workstationBody.contains("private var workspaceContentMarker: some View"))
        XCTAssertTrue(workstationBody.contains(".accessibilityIdentifier(\"workspace-container-\\(selectedSection.rawValue)\")"))
        XCTAssertFalse(workstationBody.contains(".accessibilityIdentifier(\"workspace-marker-\\(selectedSection.rawValue)\")"))
        XCTAssertTrue(workstationBody.contains(".accessibilityIdentifier(\"workspace-rendered-content-\\(selectedSection.rawValue)\")"))
        XCTAssertFalse(workstationBody.contains("workspace-host-\\(selectedSection.rawValue)"))
        XCTAssertFalse(workstationBody.contains(".frame(width: 280, alignment: .topLeading)"))
        XCTAssertTrue(workstationBody.contains("DeferredMacWorkspacePanel(id: \"workspace-dashboard\", contentIdentifier: \"workspace-content-dashboard\""))
        XCTAssertTrue(workstationBody.contains("CommandPanelView(model: model)"))
        XCTAssertTrue(workstationBody.contains("DashboardSummaryView(model: model)"))
        XCTAssertFalse(workstationBody.contains("WorkspaceNavigationView(selection: $selectedSection)"))
        XCTAssertFalse(workstationBody.contains("DashboardRuntimePanelView(model: model)"))
        XCTAssertTrue(workstationBody.contains("case .files:"))
        XCTAssertTrue(workstationBody.contains("case .tasks:"))
        XCTAssertTrue(workstationBody.contains("case .notices:"))
        XCTAssertTrue(workstationBody.contains("case .calendar:"))
        XCTAssertTrue(workstationBody.contains("TaskAndExamWorkspaceView(model: model)"))
        XCTAssertTrue(workstationBody.contains("DeferredMacWorkspacePanel(id: \"workspace-dashboard\""))
        XCTAssertTrue(workstationBody.contains("id: \"workspace-files\""))
        XCTAssertTrue(workstationBody.contains("id: \"workspace-tasks\""))
        XCTAssertTrue(workstationBody.contains("contentDelayNanoseconds: MacWorkspacePanelTiming.heavyListContentDelayNanoseconds"))
        XCTAssertTrue(workstationBody.contains("DeferredMacWorkspacePanel(id: \"workspace-notices\""))
        XCTAssertTrue(workstationBody.contains("DeferredMacWorkspacePanel(id: \"workspace-calendar\""))
        XCTAssertTrue(workstationBody.contains("id: \"workspace-activityLogs\""))
        XCTAssertTrue(workstationBody.contains("id: \"workspace-diagnostics\""))
        XCTAssertTrue(workstationBody.contains("id: \"workspace-settings\""))
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
        XCTAssertTrue(workstationBody.contains("DiagnosticStageDurationPanelView"))
        XCTAssertTrue(workstationBody.contains("RemoteActivityPanelView"))
        XCTAssertTrue(workstationBody.contains("RunLogArchivePanelView"))
        XCTAssertFalse(workstationBody.contains("DeferredMacWorkspacePanel(id: \"activity-run-log-archive\""))
        XCTAssertFalse(workstationBody.contains("DeferredMacWorkspacePanel(id: \"diagnostics-secondary-panels\""))
        XCTAssertTrue(macRemoteActivityPanel.contains("Text(\"동기화 단계\")"))
        XCTAssertTrue(macRemoteActivityPanel.contains("Mac 앱에서 실행한 단계별 소요 시간과 마지막 로그입니다."))
        XCTAssertTrue(macRemoteActivityPanel.contains("stageDurations: model.sharedRunLogStageDurationsByID[log.id] ?? []"))
        XCTAssertTrue(macModel.contains("@Published private(set) var sharedRunLogStageDurationsByID"))
        XCTAssertTrue(macModel.contains("rebuildSharedRunLogStageDurationCache()"))
        XCTAssertTrue(macSharedRunLogActivityRow.contains("CompactStageDurationRowsView(durations: stageDurations)"))
        XCTAssertTrue(macSharedRunLogActivityRow.contains("var stageDurations: [KLMSStageDuration]"))
        XCTAssertFalse(macSharedRunLogActivityRow.contains("KLMSStageDurationParser.parse(from: log.outputTail)"))
        XCTAssertFalse(topUtilityActions.contains("selectedSection = .settings"))
        XCTAssertFalse(topUtilityActions.contains("utilityLabel(\"설정\""))
        XCTAssertTrue(topUtilityActions.contains("utilityLabel(\"바로가기\", systemImage: \"square.grid.2x2\")"))
        XCTAssertTrue(topUtilityActions.contains("Color.klmsMacSubtleCardBackground"))
        XCTAssertTrue(topUtilityActions.contains("Color.klmsMacCommandBorder"))
        XCTAssertTrue(dashboardTopBarView.contains("첫 실행 전 · 전체 동기화나 진단을 실행하세요."))
        XCTAssertTrue(dashboardTopBarView.contains("statusBadgeText: \"준비 필요\""))
        XCTAssertTrue(macAlertBannerSnapshot.contains("처음 실행 준비"))
        XCTAssertTrue(macAlertBannerSnapshot.contains("메모/캘린더/미리 알림"))
        XCTAssertTrue(macAlertBannerSnapshot.contains("return \"확인\""))
        XCTAssertTrue(nextActionPanelView.contains("환경 진단으로 권한과 엔진 상태를 먼저 확인합니다."))
        XCTAssertFalse(macAlertBannerView.contains("Notes/Calendar/Reminders"))
        XCTAssertFalse(macAlertBannerView.contains("자연어"))
        XCTAssertTrue(workstationBody.contains("case .diagnostics:"))
        XCTAssertTrue(workstationBody.contains("VerifyPanelView"))
        let taskWorkspaceBody = try sourceStructBody(named: "TaskAndExamWorkspaceView", in: mac)
        XCTAssertTrue(taskWorkspaceBody.contains("taskKindButton(kind)"))
        XCTAssertTrue(taskWorkspaceBody.contains(".frame(maxWidth: .infinity, minHeight: 44)"))
        XCTAssertTrue(taskWorkspaceBody.contains(".accessibilityLabel(\"\\(kind.title) 목록\")"))
        XCTAssertTrue(taskWorkspaceBody.contains("ForEach(availableKinds)"))
        XCTAssertFalse(taskWorkspaceBody.contains("GridItem(.flexible(minimum: 280), spacing: 12, alignment: .top)"))
        XCTAssertFalse(taskWorkspaceBody.contains(".gridCellColumns(2)"))
        XCTAssertFalse(taskWorkspaceBody.contains("LazyVGrid(columns: columns, alignment: .leading, spacing: 12)"))
        XCTAssertFalse(taskWorkspaceBody.contains("cachedDashboardDetailPanel(kind: .assignments)"))
        XCTAssertFalse(taskWorkspaceBody.contains("cachedDashboardDetailPanel(kind: .exams)"))
        XCTAssertFalse(taskWorkspaceBody.contains("HStack(alignment: .top, spacing: 12)"))
        XCTAssertFalse(taskWorkspaceBody.contains(".frame(minWidth: 280, maxWidth: .infinity"))

        let dashboardBody = try sectionBody(in: workstationBody, from: "case .dashboard:", to: "case .activityLogs:")
        XCTAssertTrue(dashboardBody.contains("DashboardSummaryView"))
        XCTAssertFalse(dashboardBody.contains("CommandOutputPanelView"))
        XCTAssertFalse(dashboardBody.contains("LogSummaryPanelView"))
        XCTAssertFalse(dashboardBody.contains("RemoteActivityPanelView"))
        let dashboardSummaryContent = try sourceStructBody(named: "DashboardSummaryContentView", in: mac)
        XCTAssertFalse(mac.contains("DashboardLogSummaryPanelView(model: model)"))
        XCTAssertFalse(dashboardSummaryContent.contains("DashboardLogSummaryPanelView(model: model)"))
        XCTAssertFalse(dashboardSummaryContent.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(dashboardSummaryContent.contains("var presentation: DashboardSummaryPresentation"))
        XCTAssertTrue(dashboardSummaryContent.contains("self.presentation = presentation"))
        XCTAssertFalse(dashboardSummaryContent.contains("self.presentation = DashboardSummaryPresentation(snapshot: snapshot, summary: summary)"))
        XCTAssertFalse(dashboardSummaryContent.contains("var summary: KLMSMacDashboardSummaryCache"))
        XCTAssertTrue(mac.contains("struct DashboardSummaryPresentation"))
        XCTAssertTrue(mac.contains("func visibleMetrics(archiveExpanded: Bool) -> [Metric]"))
        XCTAssertFalse(dashboardSummaryContent.contains("let primaryMetrics = ["))
        XCTAssertFalse(dashboardSummaryContent.contains("let attentionMetrics = ["))
        XCTAssertFalse(dashboardSummaryContent.contains("let archiveMetrics = ["))
        let logsBody = try sectionBody(in: workstationBody, from: "case .activityLogs:", to: "case .diagnostics:")
        XCTAssertTrue(logsBody.contains("id: \"workspace-activityLogs\""))
        XCTAssertTrue(logsBody.contains("contentIdentifier: \"workspace-content-activityLogs\""))
        XCTAssertTrue(logsBody.contains("contentDelayNanoseconds: MacWorkspacePanelTiming.heavyListContentDelayNanoseconds"))
        XCTAssertTrue(logsBody.contains("VStack(alignment: .leading, spacing: 16)"))
        XCTAssertTrue(logsBody.contains(".frame(maxWidth: .infinity, alignment: .topLeading)"))
        XCTAssertFalse(logsBody.contains("loadingText:"))
        XCTAssertTrue(logsBody.contains("LogSummaryPanelView(model: model"))
        XCTAssertTrue(logsBody.contains("DiagnosticStageDurationPanelView(model: model)"))
        XCTAssertTrue(logsBody.contains("RemoteActivityPanelView(model: model)"))
        XCTAssertTrue(logsBody.contains("RunLogArchivePanelView(model: model)"))
        XCTAssertLessThan(
            try XCTUnwrap(logsBody.range(of: "id: \"workspace-activityLogs\"")).lowerBound,
            try XCTUnwrap(logsBody.range(of: "LogSummaryPanelView(model: model")).lowerBound
        )
        XCTAssertLessThan(
            try XCTUnwrap(logsBody.range(of: "LogSummaryPanelView(model: model")).lowerBound,
            try XCTUnwrap(logsBody.range(of: "DiagnosticStageDurationPanelView(model: model)")).lowerBound
        )
        XCTAssertLessThan(
            try XCTUnwrap(logsBody.range(of: "DiagnosticStageDurationPanelView(model: model)")).lowerBound,
            try XCTUnwrap(logsBody.range(of: "RemoteActivityPanelView(model: model)")).lowerBound
        )
        XCTAssertLessThan(
            try XCTUnwrap(logsBody.range(of: "RemoteActivityPanelView(model: model)")).lowerBound,
            try XCTUnwrap(logsBody.range(of: "RunLogArchivePanelView(model: model)")).lowerBound
        )
        XCTAssertTrue(macRemoteActivityPanel.contains("SectionBox(title: \"서버·파일 요청 기록\")"))
        XCTAssertTrue(logSummaryTile.contains("로그 요약 \\(isExpanded ? \"펼쳐짐\" : \"접힘\")"))
        XCTAssertTrue(logSummaryTile.contains(".accessibilityHint(isExpanded ? \"관련 로그 접기\" : \"관련 로그 펼치기\")"))
        XCTAssertFalse(logSummaryTile.contains("로그 요약 \\(isExpanded ? \"접기\" : \"펼치기\")"))
        XCTAssertTrue(logSummaryTile.contains("로그 요약"))
        XCTAssertTrue(logSummaryPanelView.contains("private let tileColumns = [GridItem(.adaptive(minimum: 176), spacing: 8)]"))
        XCTAssertTrue(logSummaryPanelView.contains("private let renderReferenceDate = Date()"))
        XCTAssertTrue(logSummaryPanelView.contains("renderReferenceDate.timeIntervalSince($0.updatedAt) <= Self.terminalSummaryDisplayInterval"))
        XCTAssertTrue(logSummaryPanelView.contains("renderReferenceDate.timeIntervalSince(command.updatedAt) <= Self.terminalSummaryDisplayInterval"))
        XCTAssertFalse(logSummaryPanelView.contains("Date().timeIntervalSince"))
        XCTAssertTrue(hiddenItemsListView.contains("private let renderReferenceDate = Date()"))
        XCTAssertTrue(hiddenItemsListView.contains("isPastDashboardExamForApp(referenceDate: renderReferenceDate)"))
        XCTAssertFalse(macDetail.contains("return due < Date()"))
        XCTAssertTrue(macDetail.contains("return due < referenceDate"))
        XCTAssertTrue(logSummaryPanelView.contains("LazyVGrid(columns: tileColumns, alignment: .leading, spacing: 8)"))
        XCTAssertFalse(logSummaryPanelView.contains("HStack(alignment: .top, spacing: 8)"))
        XCTAssertTrue(logSummaryPanelView.contains(".background(Color.klmsMacCardBackground, in: RoundedRectangle(cornerRadius: 14))"))
        XCTAssertTrue(logSummaryPanelView.contains(".stroke(Color.klmsMacBorder.opacity(0.72), lineWidth: 1)"))
        XCTAssertTrue(logSummaryDetailView.contains("Text(\"파일 요청 기록\")"))
        XCTAssertFalse(logSummaryDetailView.contains("await model.clearServerRelayLogs(scope: .fileAccess)"))
        XCTAssertFalse(logSummaryDetailView.contains(".accessibilityLabel(\"파일 요청 기록 지우기\")"))
        XCTAssertTrue(sectionBox.contains("VStack(alignment: .leading, spacing: 9)"))
        XCTAssertTrue(sectionBox.contains(".stroke(borderColor.opacity(0.78), lineWidth: 1)"))
        XCTAssertNotNil(macSharedRunLogActivityRow.range(of: #"macPerformWithoutAnimation\s*\{\s*isExpanded\.toggle\(\)"#, options: .regularExpression))
        XCTAssertTrue(macSharedRunLogActivityRow.contains("실행 로그 \\(isExpanded ? \"펼쳐짐\" : \"접힘\")"))
        XCTAssertTrue(macSharedRunLogActivityRow.contains(".accessibilityHint(isExpanded ? \"실행 로그 접기\" : \"실행 로그 펼치기\")"))
        XCTAssertFalse(macSharedRunLogActivityRow.contains("실행 로그 \\(isExpanded ? \"접기\" : \"펼치기\")"))
        XCTAssertNotNil(macServerRequestLogActivityRow.range(of: #"macPerformWithoutAnimation\s*\{\s*isExpanded\.toggle\(\)"#, options: .regularExpression))
        XCTAssertTrue(macServerRequestLogActivityRow.contains(".padding(8)"))
        XCTAssertTrue(macServerRequestLogActivityRow.contains(".background(statusColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))"))
        XCTAssertTrue(macServerRequestLogActivityRow.contains(".contentShape(RoundedRectangle(cornerRadius: 8))"))
        XCTAssertTrue(macServerRequestLogActivityRow.contains("기록 \\(isExpanded ? \"펼쳐짐\" : \"접힘\")"))
        XCTAssertTrue(macServerRequestLogActivityRow.contains(".accessibilityHint(isExpanded ? \"서버 요청 기록 접기\" : \"서버 요청 기록 펼치기\")"))
        XCTAssertFalse(macServerRequestLogActivityRow.contains("기록 \\(isExpanded ? \"접기\" : \"펼치기\")"))
        XCTAssertNotNil(macRemoteCommandActivityRow.range(of: #"macPerformWithoutAnimation\s*\{\s*isExpanded\.toggle\(\)"#, options: .regularExpression))
        XCTAssertTrue(macRemoteCommandActivityRow.contains(".padding(8)"))
        XCTAssertTrue(macRemoteCommandActivityRow.contains(".background(statusColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))"))
        XCTAssertTrue(macRemoteCommandActivityRow.contains(".contentShape(RoundedRectangle(cornerRadius: 8))"))
        XCTAssertTrue(macRemoteCommandActivityRow.contains("원격 실행 기록 \\(isExpanded ? \"펼쳐짐\" : \"접힘\")"))
        XCTAssertTrue(macRemoteCommandActivityRow.contains(".accessibilityHint(isExpanded ? \"원격 실행 기록 접기\" : \"원격 실행 기록 펼치기\")"))
        XCTAssertFalse(macRemoteCommandActivityRow.contains("원격 실행 기록 \\(isExpanded ? \"접기\" : \"펼치기\")"))
        XCTAssertNotNil(macFileAccessActivityRow.range(of: #"macPerformWithoutAnimation\s*\{\s*isExpanded\.toggle\(\)"#, options: .regularExpression))
        XCTAssertTrue(macFileAccessActivityRow.contains("파일 요청 기록 \\(isExpanded ? \"펼쳐짐\" : \"접힘\")"))
        XCTAssertTrue(macFileAccessActivityRow.contains(".accessibilityHint(isExpanded ? \"파일 요청 기록 접기\" : \"파일 요청 기록 펼치기\")"))
        XCTAssertFalse(macFileAccessActivityRow.contains("파일 요청 기록 \\(isExpanded ? \"접기\" : \"펼치기\")"))
        let issueSummaryView = try sourceStructBody(named: "IssueSummaryView", in: mac)
        let issueRowView = try sourceStructBody(named: "IssueRowView", in: mac)
        let diagnosticToolsPanel = try sourceStructBody(named: "DiagnosticToolsPanelView", in: mac)
        let diagnosticStageDurationPanel = try sourceStructBody(named: "DiagnosticStageDurationPanelView", in: mac)
        let appDiagnosticsPanel = try sourceStructBody(named: "AppDiagnosticsPanelView", in: mac)
        let runLogArchivePanel = try sourceStructBody(named: "RunLogArchivePanelView", in: mac)
        XCTAssertTrue(issueSummaryView.contains("@State private var isExpanded = false"))
        XCTAssertTrue(issueSummaryView.contains("@State private var isRemainingIssuesExpanded = false"))
        XCTAssertTrue(issueSummaryView.contains("private let primaryVisibleIssueCount = 1"))
        XCTAssertTrue(issueSummaryView.contains("private let remainingVisibleLimit = 3"))
        XCTAssertTrue(issueSummaryView.contains("let primaryIssues = Array(issues.prefix(primaryVisibleIssueCount))"))
        XCTAssertTrue(issueSummaryView.contains("let remainingIssues = Array(issues.dropFirst(primaryVisibleIssueCount))"))
        XCTAssertNotNil(issueSummaryView.range(of: #"macPerformWithoutAnimation\s*\{\s*isExpanded\.toggle\(\)"#, options: .regularExpression))
        XCTAssertNotNil(issueSummaryView.range(of: #"macPerformWithoutAnimation\s*\{\s*isRemainingIssuesExpanded\.toggle\(\)"#, options: .regularExpression))
        XCTAssertTrue(issueSummaryView.contains("if isExpanded"))
        XCTAssertTrue(issueSummaryView.contains("ForEach(primaryIssues)"))
        XCTAssertTrue(issueSummaryView.contains("if isRemainingIssuesExpanded"))
        XCTAssertTrue(issueSummaryView.contains("ForEach(remainingIssues.prefix(remainingVisibleLimit))"))
        XCTAssertTrue(issueSummaryView.contains("Text(compactTitle)"))
        XCTAssertTrue(issueSummaryView.contains(".accessibilityLabel(\"\\(compactTitle) \\(issues.count)개 \\(isExpanded ? \"펼쳐짐\" : \"접힘\")\")"))
        XCTAssertTrue(issueSummaryView.contains(".accessibilityHint(isExpanded ? \"확인 항목 접기\" : \"확인 항목 펼치기\")"))
        XCTAssertTrue(issueSummaryView.contains(".accessibilityLabel(\"나머지 확인 항목 \\(remainingIssues.count)개 \\(isRemainingIssuesExpanded ? \"펼쳐짐\" : \"접힘\")\")"))
        XCTAssertTrue(issueSummaryView.contains("return \"상태 검사 실패\""))
        XCTAssertTrue(issueSummaryView.contains("return \"권한 확인 필요\""))
        XCTAssertTrue(issueRowView.contains("var compact = false"))
        XCTAssertTrue(issueRowView.contains(".lineLimit(compact ? 1 : 2)"))
        XCTAssertFalse(issueSummaryView.contains("ForEach(issues.prefix(3))"))
        XCTAssertFalse(issueSummaryView.contains("ForEach(issues.prefix(5))"))
        XCTAssertTrue(diagnosticToolsPanel.contains("title: \"고급 도구\""))
        XCTAssertTrue(diagnosticToolsPanel.contains("DiagnosticChecksDisclosure("))
        XCTAssertFalse(diagnosticToolsPanel.contains("DisclosureGroup(isExpanded: $isAdvancedExpanded)"))
        XCTAssertTrue(diagnosticStageDurationPanel.contains("@State private var isDetailExpanded = false"))
        XCTAssertTrue(diagnosticStageDurationPanel.contains("title: \"자세히 보기\""))
        XCTAssertTrue(diagnosticStageDurationPanel.contains("DiagnosticChecksDisclosure("))
        XCTAssertFalse(diagnosticStageDurationPanel.contains("DisclosureGroup"))
        let verifyPanelView = try sourceStructBody(named: "VerifyPanelView", in: mac)
        let verifyCheckRowView = try sourceStructBody(named: "VerifyCheckExplanationRowView", in: mac)
        let doctorPanelView = try sourceStructBody(named: "DoctorPanelView", in: mac)
        let diagnosticChecksDisclosure = try sourceBody(
            after: "private struct DiagnosticChecksDisclosure<Content: View>: View",
            in: mac,
            description: "Mac diagnostic checks disclosure"
        )
        XCTAssertTrue(mac.contains("private struct DiagnosticChecksDisclosure"))
        XCTAssertTrue(mac.contains("private func macPerformWithoutAnimation"))
        XCTAssertTrue(diagnosticChecksDisclosure.contains("macPerformWithoutAnimation {\n                    isExpanded.toggle()"))
        XCTAssertTrue(runLogArchivePanel.contains("macPerformWithoutAnimation {\n                            isHistoryExpanded.toggle()"))
        XCTAssertTrue(runLogArchivePanel.contains("macPerformWithoutAnimation {\n                                showingSystemLogs.toggle()"))
        XCTAssertTrue(verifyPanelView.contains("SectionBox(title: \"상태 검사\")"))
        XCTAssertTrue(verifyPanelView.contains("상태 검사에서 설명이 필요한 실패 항목이 없습니다."))
        XCTAssertTrue(verifyPanelView.contains("@State private var isAllChecksExpanded = false"))
        XCTAssertTrue(verifyPanelView.contains("DiagnosticChecksDisclosure("))
        XCTAssertTrue(verifyPanelView.contains("title: \"나머지 확인 항목 \\(checkSummary.remainingIssues.count)개\""))
        XCTAssertFalse(verifyPanelView.contains("DisclosureGroup {\n                        VStack(alignment: .leading, spacing: 6)"))
        XCTAssertFalse(verifyPanelView.contains("DisclosureGroup(isExpanded: $isRemainingIssuesExpanded)"))
        XCTAssertTrue(verifyCheckRowView.contains("title: \"원본 보기\""))
        XCTAssertTrue(verifyCheckRowView.contains("title: \"원인과 조치 보기\""))
        XCTAssertTrue(verifyCheckRowView.contains("@State private var isGuidanceExpanded = false"))
        XCTAssertTrue(verifyCheckRowView.contains(".lineLimit(1)"))
        XCTAssertTrue(verifyCheckRowView.contains(".lineLimit(2)"))
        XCTAssertTrue(doctorPanelView.contains("SectionBox(title: \"권한/환경 진단\")"))
        XCTAssertTrue(doctorPanelView.contains("summaryText(for: doctor, checkSummary: checkSummary)"))
        XCTAssertTrue(doctorPanelView.contains("권한과 실행 환경에서 설명이 필요한 실패 항목이 없습니다."))
        XCTAssertTrue(doctorPanelView.contains("return \"상태: \\(doctor.status.klmsLocalizedStatus) · 확인 필요 \\(checkSummary.issueCount)개 · 정상 \\(checkSummary.okCount)개\""))
        XCTAssertTrue(doctorPanelView.contains("@State private var isAllChecksExpanded = false"))
        XCTAssertTrue(doctorPanelView.contains("DiagnosticChecksDisclosure("))
        XCTAssertTrue(doctorPanelView.contains("title: \"나머지 진단 항목 \\(checkSummary.remainingIssues.count)개\""))
        XCTAssertFalse(doctorPanelView.contains("DisclosureGroup(isExpanded: $isRemainingIssuesExpanded)"))
        XCTAssertTrue(diagnosticChecksDisclosure.contains(".accessibilityLabel(\"\\(title) \\(isExpanded ? \"펼쳐짐\" : \"접힘\")\")"))
        XCTAssertTrue(diagnosticChecksDisclosure.contains(".accessibilityHint(isExpanded ? \"\\(title) 접기\" : \"\\(title) 펼치기\")"))
        XCTAssertTrue(diagnosticChecksDisclosure.contains(".frame(maxWidth: .infinity, minHeight: compact ? 36 : 44, alignment: .leading)"))
        XCTAssertTrue(diagnosticChecksDisclosure.contains(".contentShape(RoundedRectangle(cornerRadius: 7))"))
        XCTAssertTrue(diagnosticChecksDisclosure.contains("Color.klmsMacSubtleCardBackground.opacity(0.34)"))
        XCTAssertFalse(diagnosticChecksDisclosure.contains(".stroke(Color.klmsMacBorder.opacity(0.54)"))
        let collapsibleSectionBox = try sourceBody(
            after: "struct CollapsibleSectionBox<Content: View>: View",
            in: mac,
            description: "Mac collapsible section box"
        )
        XCTAssertTrue(collapsibleSectionBox.contains(".accessibilityLabel(\"\\(title) \\(isExpanded ? \"펼쳐짐\" : \"접힘\")\")"))
        XCTAssertTrue(collapsibleSectionBox.contains(".accessibilityHint(isExpanded ? \"\\(title) 접기\" : \"\\(title) 펼치기\")"))
        XCTAssertTrue(collapsibleSectionBox.contains(".frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)"))
        XCTAssertTrue(collapsibleSectionBox.contains(".contentShape(RoundedRectangle(cornerRadius: 10))"))
        let doctorCheckRowView = try sourceStructBody(named: "DoctorCheckRowView", in: mac)
        XCTAssertTrue(doctorCheckRowView.contains(".lineLimit(compact ? 2 : 1)"))
        XCTAssertTrue(appDiagnosticsPanel.contains("private let permissionActionColumns = [GridItem(.adaptive(minimum: 136), spacing: 8)]"))
        XCTAssertTrue(appDiagnosticsPanel.contains("LazyVGrid(columns: permissionActionColumns, alignment: .leading, spacing: 8)"))
        XCTAssertTrue(appDiagnosticsPanel.contains("title: \"설치·권한 세부 정보\""))
        XCTAssertTrue(appDiagnosticsPanel.contains("title: \"필요 권한 범위\""))
        XCTAssertFalse(appDiagnosticsPanel.contains("DisclosureGroup"))
        XCTAssertFalse(appDiagnosticsPanel.contains("HStack {\n                        Button"))

        let diagnosticsBody = try sectionBody(in: workstationBody, from: "case .diagnostics:", to: ".padding(.vertical, 4)")
        XCTAssertTrue(diagnosticsBody.contains("id: \"workspace-diagnostics\""))
        XCTAssertTrue(diagnosticsBody.contains("contentIdentifier: \"workspace-content-diagnostics\""))
        XCTAssertTrue(diagnosticsBody.contains("contentDelayNanoseconds: MacWorkspacePanelTiming.heavyListContentDelayNanoseconds"))
        XCTAssertTrue(diagnosticsBody.contains("VStack(alignment: .leading, spacing: 16)"))
        XCTAssertTrue(diagnosticsBody.contains(".frame(maxWidth: .infinity, alignment: .topLeading)"))
        XCTAssertFalse(diagnosticsBody.contains("loadingText:"))
        XCTAssertLessThan(
            try XCTUnwrap(diagnosticsBody.range(of: "id: \"workspace-diagnostics\"")).lowerBound,
            try XCTUnwrap(diagnosticsBody.range(of: "VerifyPanelView")).lowerBound
        )
        XCTAssertLessThan(
            try XCTUnwrap(diagnosticsBody.range(of: "VerifyPanelView")).lowerBound,
            try XCTUnwrap(diagnosticsBody.range(of: "DiagnosticToolsPanelView")).lowerBound
        )
        XCTAssertTrue(diagnosticsBody.contains("DiagnosticToolsPanelView"))
        XCTAssertFalse(diagnosticsBody.contains("DiagnosticStageDurationPanelView"))
        XCTAssertTrue(diagnosticsBody.contains("DoctorPanelView(snapshot: model.snapshot)"))
        XCTAssertTrue(diagnosticsBody.contains("AppDiagnosticsPanelView(model: model)"))
        XCTAssertTrue(diagnosticsBody.contains("LoginPanelView(model: model)"))
        XCTAssertFalse(diagnosticsBody.contains("DiagnosticCommandLogPanelView"))
        XCTAssertFalse(diagnosticsBody.contains("RemoteActivityPanelView"))
        XCTAssertFalse(diagnosticsBody.contains("LogPanelView"))

        XCTAssertTrue(ios.contains("return \"로그\""))
        XCTAssertTrue(iosHistoryScreen.contains("CompanionScreenContainer(title: \"로그\""))
        XCTAssertTrue(iosStatusScreen.contains("RemoteDashboardSyncCard(model: model, compact: horizontalSizeClass != .regular)"))
        XCTAssertTrue(iosStatusScreen.contains("RemoteDashboardMetricOverview("))
        XCTAssertTrue(iosHistoryScreen.contains("RemoteLogSummaryPanel"))
        XCTAssertTrue(iosHistoryScreen.contains("SharedRunLogsView"))
        XCTAssertTrue(iosHistoryScreen.contains("RecentServerRequestLogView"))
        XCTAssertTrue(iosHistoryScreen.contains("RecentFileAccessRequestsView"))
        XCTAssertTrue(iosHistoryScreen.contains("RecentRemoteCommandsView"))
        XCTAssertTrue(iosHistoryScreen.contains("@Environment(\\.horizontalSizeClass)"))
        XCTAssertTrue(iosHistoryScreen.contains("if horizontalSizeClass == .regular"))
        XCTAssertTrue(iosHistoryScreen.contains("historyRegularWorkspace"))
        XCTAssertTrue(iosHistoryScreen.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(iosHistoryScreen.contains("historyWideColumns"))
        XCTAssertTrue(iosHistoryScreen.contains("historyTwoColumnFallback"))
        XCTAssertTrue(iosHistoryScreen.contains("historyStackFallback"))
        XCTAssertTrue(iosHistoryScreen.contains("VStack(alignment: .leading, spacing: 12)"))
        XCTAssertTrue(iosHistoryScreen.contains("HStack(alignment: .top, spacing: CompanionWorkstationMetrics.columnSpacing)"))
        XCTAssertTrue(iosHistoryScreen.contains("historySummaryColumn"))
        XCTAssertTrue(iosHistoryScreen.contains("historyStageColumn"))
        XCTAssertTrue(iosHistoryScreen.contains("historyDetailColumn"))
        XCTAssertTrue(iosHistoryScreen.contains("historyRequestColumn"))
        XCTAssertTrue(iosHistoryScreen.contains("minWidth: CompanionWorkstationMetrics.commandColumnMinWidth"))
        XCTAssertTrue(iosHistoryScreen.contains("idealWidth: CompanionWorkstationMetrics.commandColumnIdealWidth"))
        XCTAssertTrue(iosHistoryScreen.contains("maxWidth: CompanionWorkstationMetrics.commandColumnMaxWidth"))
        XCTAssertTrue(iosHistoryScreen.contains("minWidth: CompanionWorkstationMetrics.metricColumnMinWidth"))
        XCTAssertTrue(iosHistoryScreen.contains("idealWidth: CompanionWorkstationMetrics.metricColumnIdealWidth"))
        XCTAssertTrue(iosHistoryScreen.contains("maxWidth: CompanionWorkstationMetrics.metricColumnMaxWidth"))
        XCTAssertTrue(iosHistoryScreen.contains("minWidth: CompanionWorkstationMetrics.detailColumnMinWidth"))
        XCTAssertTrue(iosHistoryScreen.contains("idealWidth: CompanionWorkstationMetrics.detailColumnIdealWidth"))
        XCTAssertLessThan(
            try XCTUnwrap(iosHistoryRegularWorkspace.range(of: "historyWideColumns")).lowerBound,
            try XCTUnwrap(iosHistoryRegularWorkspace.range(of: "historyTwoColumnFallback")).lowerBound
        )
        XCTAssertTrue(iosHistoryScreen.contains("selectedHistoryDetailPanel"))
        XCTAssertTrue(iosHistoryScreen.contains("historyRequestColumn"))
        XCTAssertTrue(iosHistoryScreen.contains("@State private var selectedLogSummaryKind: RemoteLogSummaryKind? = .status"))
        XCTAssertTrue(iosHistoryScreen.contains("showsInlineDetail: horizontalSizeClass != .regular"))
        XCTAssertTrue(iosHistoryScreen.contains("selectedKind: horizontalSizeClass == .regular ? $selectedLogSummaryKind : nil"))
        XCTAssertFalse(iosHistorySummaryColumn.contains("SharedRunLogsView"))
        XCTAssertTrue(iosHistoryStageColumn.contains("SharedRunLogsView"))
        XCTAssertTrue(iosHistoryDetailColumn.contains("selectedHistoryDetailPanel"))
        XCTAssertTrue(iosHistoryDetailColumn.contains("historyStageColumn"))
        XCTAssertTrue(iosHistoryScreen.contains("RemoteLogDetailPanel("))
        XCTAssertTrue(iosHistoryScreen.contains("snapshot: remoteLogDetailSnapshot"))
        XCTAssertTrue(iosHistoryScreen.contains("recentCommands: model.recentCommands"))
        XCTAssertTrue(iosHistoryScreen.contains("recentFileAccessRequests: model.recentFileAccessRequests"))
        XCTAssertTrue(iosHistoryScreen.contains("CompanionEmptyDetailPanel("))
        XCTAssertFalse(ios.contains("private struct RemoteRunRequestHistoryPanel"))
        XCTAssertTrue(iosRemoteLogSummaryPanel.contains("var showsInlineDetail = true"))
        XCTAssertTrue(iosRemoteLogSummaryPanel.contains("var selectedKind: Binding<RemoteLogSummaryKind?>? = nil"))
        XCTAssertTrue(iosRemoteLogSummaryPanel.contains("var snapshot: RemoteLogSummarySnapshot"))
        XCTAssertTrue(iosRemoteLogSummaryPanel.contains("var inlineDetail: (RemoteLogSummaryKind) -> AnyView"))
        XCTAssertFalse(iosRemoteLogSummaryPanel.contains("@ObservedObject var model"))
        XCTAssertTrue(iosRemoteLogSummaryPanel.contains("@State private var localExpandedKind"))
        XCTAssertTrue(iosRemoteLogSummaryPanel.contains("selectedKind?.wrappedValue ?? localExpandedKind"))
        XCTAssertTrue(iosRemoteLogSummaryPanel.contains("selectedKind.wrappedValue = expandedKind == kind ? nil : kind"))
        XCTAssertTrue(iosRemoteLogSummaryPanel.contains("Color.klmsCardBackground, in: RoundedRectangle(cornerRadius: 14)"))
        XCTAssertTrue(iosRemoteLogSummaryPanel.contains(".stroke(Color.klmsBorder, lineWidth: 1)"))
        XCTAssertTrue(iosRemoteLogSummaryPanel.contains("실행하면 서버에 요청이 올라갑니다."))
        XCTAssertTrue(iosRemoteLogSummaryPanel.contains("지난 기록은 펼쳐서 봅니다."))
        XCTAssertFalse(iosRemoteLogSummaryPanel.contains("상세는 옆 패널에 표시됩니다."))
        XCTAssertTrue(iosRemoteLogSummaryPanel.contains("행을 누르면 펼쳐집니다."))
        XCTAssertFalse(iosRemoteLogSummaryPanel.contains("실행 버튼을 누르면 Mac 앱에 요청이 올라갑니다."))
        XCTAssertFalse(iosRemoteLogSummaryPanel.contains("지난 완료/실패 기록은 이 행을 펼쳐서 확인할 수 있습니다."))
        XCTAssertFalse(iosRemoteLogSummaryPanel.contains("선택한 기록의 상세는 오른쪽 패널에서 확인합니다."))
        XCTAssertFalse(iosRemoteLogSummaryPanel.contains("요약 행을 누르면 관련 기록을 바로 펼칩니다."))
        XCTAssertFalse(iosRemoteLogSummaryPanel.contains(".clipShape(RoundedRectangle(cornerRadius: 8))"))
        XCTAssertTrue(iosRemoteLogSummaryPanel.contains(".frame(width: 44, height: 44)"))
        XCTAssertTrue(iosRemoteLogDetailPanel.contains("RoundedRectangle(cornerRadius: 12)"))
        XCTAssertFalse(iosRemoteLogDetailPanel.contains("clearRemoteLogs(scope: .command)"))
        XCTAssertFalse(iosRemoteLogDetailPanel.contains("clearRemoteLogs(scope: .fileAccess)"))
        XCTAssertFalse(iosRemoteLogDetailPanel.contains(".accessibilityLabel(\"최근 요청 기록 지우기\")"))
        XCTAssertFalse(iosRemoteLogDetailPanel.contains(".accessibilityLabel(\"파일 요청 기록 지우기\")"))
        XCTAssertTrue(iosCompanionEmptyDetailPanel.contains("minHeight: 180"))
        XCTAssertTrue(iosCompanionEmptyDetailPanel.contains("Color.klmsCardBackground, in: RoundedRectangle(cornerRadius: 14)"))
        XCTAssertTrue(iosRemoteLogSummaryRow.contains("isExpanded ? Color.klmsSelectedBackground.opacity(0.96) : Color.klmsSubtleCardBackground.opacity(0.62)"))
        XCTAssertTrue(iosRemoteLogSummaryRow.contains(".frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)"))
        XCTAssertTrue(iosRemoteLogSummaryRow.contains("KLMSCardButtonStyle(cornerRadius: 12)"))
        XCTAssertTrue(iosRemoteLogSummaryRow.contains(".accessibilityLabel(accessibilitySummary)"))
        XCTAssertTrue(iosRemoteLogSummaryRow.contains("private var accessibilitySummary: String"))
        XCTAssertTrue(iosRemoteLogSummaryRow.contains("accessibilitySentence(title)"))
        XCTAssertTrue(iosRemoteLogSummaryRow.contains("accessibilitySentence(value)"))
        XCTAssertTrue(iosRemoteLogSummaryRow.contains("accessibilitySentence(detail)"))
        XCTAssertTrue(iosRemoteLogSummaryRow.contains("if let last = trimmed.last, \".!?。！？\".contains(last)"))
        XCTAssertTrue(ios.contains("private struct RemoteLogDetailSnapshot: Equatable"))
        XCTAssertFalse(iosRemoteLogDetailPanel.contains("@ObservedObject var model"))
        XCTAssertTrue(iosRemoteLogDetailPanel.contains("var snapshot: RemoteLogDetailSnapshot"))
        XCTAssertTrue(iosRemoteLogDetailPanel.contains("var recentCommands: [RemoteRunCommand]"))
        XCTAssertTrue(iosRemoteLogDetailPanel.contains("var recentFileAccessRequests: [ServerRelayFileAccessRequest]"))
        XCTAssertFalse(iosRemoteLogSummaryRow.contains(".accessibilityLabel(\"\\(title) \\(value). \\(detail). \\(isExpanded ? \"펼쳐짐\" : \"접힘\")\")"))
        XCTAssertFalse(iosRemoteLogSummaryRow.contains("KLMSCardButtonStyle(cornerRadius: 8)"))
        XCTAssertTrue(iosSharedRunLogsView.contains("Text(\"동기화 단계\")"))
        XCTAssertTrue(iosSharedRunLogsView.contains("단계별 시간과 마지막 로그를 보여줍니다."))
        XCTAssertFalse(iosSharedRunLogsView.contains("지우면 모든 기기에서 사라집니다."))
        XCTAssertFalse(iosSharedRunLogsView.contains("Mac 앱에서 실행한 단계별 소요 시간과 마지막 로그입니다."))
        XCTAssertTrue(iosSharedRunLogsView.contains(".accessibilityLabel(\"동기화 단계 기록 지우기\")"))
        XCTAssertTrue(iosSharedRunLogsView.contains(".frame(width: 44, height: 44)"))
        XCTAssertTrue(iosSharedRunLogsView.contains("var stageDurationsByID: [String: [KLMSStageDuration]] = [:]"))
        XCTAssertTrue(iosSharedRunLogsView.contains("stageDurations: stageDurationsByID[log.id] ?? []"))
        XCTAssertTrue(iosSharedRunLogsView.contains("@State private var visibleLimit = CompanionLargeList.logVisibleLimit"))
        XCTAssertTrue(iosSharedRunLogsView.contains("ForEach(visibleLogs)"))
        XCTAssertTrue(iosSharedRunLogsView.contains("remainingCount: logs.count - visibleLogs.count"))
        XCTAssertTrue(iosSharedRunLogsView.contains("context: \"동기화 단계 기록\""))
        XCTAssertFalse(iosSharedRunLogsView.contains("Text(\"공유 실행 로그\")"))
        XCTAssertTrue(ios.contains("@Published private(set) var sharedRunLogStageDurationsByID"))
        XCTAssertTrue(ios.contains("@Published private(set) var latestSharedRunLogStageDurations"))
        XCTAssertTrue(ios.contains("private func rebuildSharedRunLogStageDurationCache()"))
        XCTAssertTrue(ios.contains("RemoteStageDurationSummaryView(durations: stageDurations)"))
        XCTAssertTrue(iosSharedRunLogRow.contains("isExpanded ? Color.klmsSelectedBackground.opacity(0.96) : Color.klmsCardBackground"))
        XCTAssertTrue(iosSharedRunLogRow.contains("Color.klmsSelectedBorder.opacity(0.82)"))
        XCTAssertTrue(iosSharedRunLogRow.contains("var stageDurations: [KLMSStageDuration]"))
        XCTAssertFalse(iosSharedRunLogRow.contains("KLMSStageDurationParser.parse(from: log.outputTail)"))
        XCTAssertTrue(ios.contains("var hasClearableRemoteLogs: Bool"))
        XCTAssertTrue(iosRemoteLogSummaryPanel.contains(".disabled(snapshot.clearDisabled)"))
        XCTAssertTrue(iosHistoryScreen.contains("!model.hasClearableRemoteLogs"))
        XCTAssertTrue(ios.contains("LinearGradient("))
        XCTAssertTrue(ios.contains("Image(systemName: \"trash\")"))
        XCTAssertTrue(ios.contains(".accessibilityLabel(\"파일 요청 기록 지우기\")"))
        XCTAssertFalse(ios.contains("Label(\"기록 지우기\", systemImage: \"trash\")"))
        XCTAssertTrue(ios.contains("private enum CompanionWorkstationMetrics"))
        XCTAssertTrue(ios.contains("static let sidebarWidth: CGFloat = 224"))
        XCTAssertTrue(ios.contains("static let horizontalPadding: CGFloat = 22"))
        XCTAssertTrue(ios.contains("static let commandColumnMinWidth: CGFloat = 312"))
        XCTAssertFalse(ios.contains("static let compactCommandColumnMinWidth"))
        XCTAssertFalse(ios.contains("static let compactDetailColumnMinWidth"))
        XCTAssertTrue(ios.contains("static let metricColumnIdealWidth: CGFloat = 448"))
        XCTAssertTrue(ios.contains("static let detailColumnIdealWidth: CGFloat = 700"))
        XCTAssertTrue(ios.contains("static let listColumnIdealWidth: CGFloat = 560"))
        XCTAssertTrue(ios.contains("settingsWideColumns"))
        XCTAssertTrue(ios.contains("settingsStackedColumns"))
        XCTAssertTrue(ios.contains("static var workstationSections"))
        XCTAssertTrue(iosSplitRoot.contains("WorkstationSidebar(selectedSection: $selectedSection)"))
        XCTAssertTrue(iosSplitRoot.contains("minWidth: CompanionWorkstationMetrics.sidebarWidth"))
        XCTAssertTrue(iosSplitRoot.contains("idealWidth: CompanionWorkstationMetrics.sidebarWidth"))
        XCTAssertTrue(iosSplitRoot.contains("maxWidth: CompanionWorkstationMetrics.sidebarWidth"))
        XCTAssertTrue(iosSplitRoot.contains(".fixedSize(horizontal: true, vertical: false)"))
        XCTAssertTrue(iosSplitRoot.contains(".layoutPriority(2)"))
        XCTAssertFalse(iosSplitRoot.contains(".frame(width: 154)"))
        XCTAssertTrue(iosSplitRoot.contains("HStack(spacing: 0)"))
        XCTAssertTrue(iosSidebar.contains("CompanionAppSection.workstationSections"))
        XCTAssertTrue(designSpec.contains("사이드바: 대시보드, 파일, 공지, 과제/시험, 캘린더, 로그, 설정"))
        XCTAssertTrue(designSpec.contains("파일, 과제/시험, 공지, 캘린더는 iPad에서 1급 작업 공간으로 바로 열 수 있어야 한다."))
        XCTAssertFalse(designSpec.contains("사이드바: 대시보드, 로그, 설정"))
        XCTAssertTrue(iosSidebar.contains("VStack(alignment: .leading, spacing: 8)"))
        XCTAssertTrue(iosSidebar.contains("Text(\"작업 공간\")"))
        XCTAssertFalse(iosSidebar.contains("@ObservedObject var model: CompanionModel"))
        XCTAssertFalse(iosSidebar.contains("badgeText: badgeText(for: section)"))
        XCTAssertFalse(iosSidebar.contains("private func badgeText(for section: CompanionAppSection) -> String?"))
        XCTAssertFalse(iosSidebar.contains("value = status.fileTotal"))
        XCTAssertFalse(iosSidebar.contains("value = status.notices"))
        XCTAssertFalse(iosSidebar.contains("value = status.assignments + status.exams"))
        XCTAssertFalse(iosSidebar.contains("value = status.calendarChangeTotal"))
        XCTAssertTrue(iosSidebar.contains(".font(.title3.weight(.bold))"))
        XCTAssertTrue(iosSidebar.contains(".padding(.horizontal, 14)"))
        XCTAssertTrue(iosSidebar.contains(".padding(.top, 18)"))
        XCTAssertTrue(iosSidebar.contains("showsIcon: true"))
        XCTAssertTrue(iosSidebar.contains("showsArrow: true"))
        XCTAssertTrue(iosSidebar.contains("isCompact: false"))
        XCTAssertFalse(iosSidebar.contains("isCompact: true"))
        XCTAssertTrue(iosSidebarButton.contains("var isCompact = false"))
        XCTAssertFalse(iosSidebarButton.contains("var badgeText: String?"))
        XCTAssertTrue(iosSidebarButton.contains("HStack(spacing: isCompact ? 7 : 10)"))
        XCTAssertFalse(iosSidebarButton.contains("if let badgeText"))
        XCTAssertFalse(iosSidebarButton.contains(".accessibilityHidden(true)"))
        XCTAssertTrue(iosSidebarButton.contains(".accessibilityValue(accessibilityValue)"))
        XCTAssertTrue(iosSidebarButton.contains(".accessibilityHint(\"\\(section.title) 작업 공간으로 이동합니다.\")"))
        XCTAssertTrue(compactTabBar.contains(".accessibilityValue(selectedSection == section ? \"선택됨\" : \"선택 안 됨\")"))
        XCTAssertTrue(iosSidebarButton.contains("isSelected ? \"선택됨\" : \"선택 안 됨\""))
        XCTAssertFalse(iosSidebarButton.contains("badgeText.map { \"\\($0)개\" }"))
        XCTAssertTrue(iosSidebarButton.contains(".frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)"))
        XCTAssertTrue(iosSidebarButton.contains("ZStack"))
        XCTAssertTrue(iosSidebarButton.contains("Color.klmsSelectedBorder.opacity(0.24)"))
        XCTAssertTrue(iosSidebarButton.contains("Color.klmsSubtleCardBackground.opacity(0.72)"))
        XCTAssertTrue(iosSidebarButton.contains(".frame(width: isCompact ? 28 : 30, height: isCompact ? 28 : 30)"))
        XCTAssertTrue(iosSidebarButton.contains("Image(systemName: \"chevron.right\")"))
        XCTAssertTrue(iosSidebarButton.contains(".font(.system(size: isCompact ? 12 : 13, weight: isSelected ? .bold : .semibold, design: .rounded))"))
        XCTAssertTrue(iosSidebarButton.contains(".padding(.leading, isCompact ? 7 : 8)"))
        XCTAssertTrue(iosSidebarButton.contains(".padding(.trailing, isCompact ? 8 : 9)"))
        XCTAssertTrue(iosSidebarButton.contains(".padding(.vertical, isCompact ? 8 : 9)"))
        XCTAssertFalse(iosSidebarButton.contains("minHeight: isCompact ? 40 : 36"))
        XCTAssertTrue(iosSidebarButton.contains("Color.klmsSelectedBackground"))
        XCTAssertTrue(iosSidebarButton.contains(": Color.klmsSubtleCardBackground.opacity(0.30)"))
        XCTAssertTrue(iosSidebarButton.contains(".overlay(alignment: .leading)"))
        XCTAssertTrue(iosSidebarButton.contains(".frame(width: isSelected ? 4 : 0)"))
        XCTAssertTrue(iosSidebarButton.contains("RoundedRectangle(cornerRadius: 12)"))
        XCTAssertTrue(iosSidebarButton.contains("isSelected ? Color.klmsSelectedBorder : Color.klmsBorder.opacity(0.40)"))
        XCTAssertTrue(ios.contains("light: UIColor(red: 0.894, green: 0.878, blue: 0.827, alpha: 1.0)"))
        XCTAssertTrue(ios.contains("dark: UIColor(red: 0.224, green: 0.212, blue: 0.184, alpha: 1.0)"))
        XCTAssertTrue(ios.contains("light: UIColor(red: 0.165, green: 0.165, blue: 0.153, alpha: 0.56)"))
        XCTAssertTrue(ios.contains("dark: UIColor(red: 0.941, green: 0.875, blue: 0.722, alpha: 0.48)"))
        XCTAssertFalse(iosSidebarButton.contains(".shadow(color: isSelected ? Color.klmsSelectedBorder.opacity(0.10) : Color.clear"))
        XCTAssertTrue(iosSidebarButton.contains(".buttonStyle(KLMSCardButtonStyle())"))
        XCTAssertTrue(iosSidebarButton.contains(".contentShape(RoundedRectangle(cornerRadius: 12))"))
        XCTAssertTrue(iosCardButtonStyle.contains("var cornerRadius: CGFloat = 10"))
        XCTAssertTrue(iosCardButtonStyle.contains("RoundedRectangle(cornerRadius: cornerRadius)"))
        XCTAssertTrue(iosCardButtonStyle.contains(".frame(minWidth: 44, minHeight: 44)"))
        XCTAssertTrue(iosCardButtonStyle.contains(".contentShape(RoundedRectangle(cornerRadius: cornerRadius))"))
        XCTAssertTrue(actionButtonStyle.contains(".frame(minWidth: 44, minHeight: 44)"))
        XCTAssertTrue(toolbarButtonStyle.contains(".frame(minWidth: 44, minHeight: 44)"))
        XCTAssertFalse(ios.contains(".frame(minHeight: 36)"))
        XCTAssertFalse(ios.contains(".frame(height: 36)"))
        XCTAssertFalse(ios.contains(".frame(maxWidth: .infinity, minHeight: 36)"))
        XCTAssertTrue(iosCardButtonStyle.contains("Color.klmsCommandButtonPressedOverlay.opacity(configuration.isPressed ? 1.0 : 0.0)"))
        XCTAssertFalse(iosCardButtonStyle.contains("Color.klmsPrimaryCommandButtonBorder.opacity(configuration.isPressed ? 0.52 : 0.0)"))
        XCTAssertFalse(iosSidebarButton.contains(".animation(.easeOut(duration: 0.10), value: isSelected)"))
        XCTAssertTrue(iosSplitRoot.contains("currentSection"))
        XCTAssertFalse(iosSplitRoot.contains("deferDisplayedSection(newSection ?? .status)"))
        XCTAssertTrue(ios.contains("private struct CompanionSelectableItemListRows"))
        XCTAssertTrue(ios.contains("private struct CompanionInlineItemRowsView"))
        XCTAssertFalse(iosSplitRoot.contains("await Task.yield()"))
        XCTAssertFalse(iosSplitRoot.contains("CompanionInlineDetailPreparingView"))
        XCTAssertTrue(iosScreenContainer.contains("let model: CompanionModel"))
        XCTAssertFalse(iosScreenContainer.contains("showsAttentionStack"))
        XCTAssertTrue(iosScreenContainer.contains("RemoteAttentionStack("))
        XCTAssertTrue(iosScreenContainer.contains("snapshot: attentionSnapshot"))
        XCTAssertTrue(iosScreenContainer.contains("await model.cancelRunningCommand()"))
        XCTAssertTrue(iosScreenContainer.contains("private var attentionSnapshot: RemoteAttentionSnapshot"))
        XCTAssertTrue(iosScreenContainer.contains(".accessibilitySortPriority(100)"))
        XCTAssertTrue(iosScreenContainer.contains(".zIndex(1)"))
        XCTAssertLessThan(
            try XCTUnwrap(iosScreenContainer.range(of: "RemoteAttentionStack(")).lowerBound,
            try XCTUnwrap(iosScreenContainer.range(of: "WholeScreenVerticalScrollView")).lowerBound
        )
        XCTAssertTrue(iosScreenContainer.contains("Color.klmsScreenBackground"))
        XCTAssertFalse(iosScreenContainer.contains("Color.klmsScreenBackground.ignoresSafeArea()"))
        XCTAssertFalse(iosScreenContainer.contains("@ObservedObject var model"))
        XCTAssertTrue(ios.contains("private struct RemoteAttentionStack: View"))
        let remoteAttentionStack = try sourceStructBody(named: "RemoteAttentionStack", in: ios)
        XCTAssertFalse(remoteAttentionStack.contains("@ObservedObject var model"))
        XCTAssertTrue(remoteAttentionStack.contains("var snapshot: RemoteAttentionSnapshot"))
        XCTAssertTrue(remoteAttentionStack.contains("var onCancel: () async -> Void"))
        XCTAssertTrue(iosHeader.contains("@Environment(\\.horizontalSizeClass)"))
        XCTAssertTrue(iosHeader.contains("compactHeader"))
        XCTAssertTrue(iosHeader.contains("regularHeader"))
        XCTAssertTrue(iosHeader.contains("Text(\"KLMS Sync\")"))
        XCTAssertTrue(iosHeader.contains("CompanionHeaderStatusPill(snapshot: headerStatusSnapshot)"))
        XCTAssertTrue(iosHeader.contains("private var headerStatusSnapshot: CompanionHeaderStatusSnapshot"))
        XCTAssertFalse(iosHeader.contains("@ObservedObject var model"))
        XCTAssertFalse(iosHeader.contains("private var headerStatusText"))
        XCTAssertFalse(iosHeaderStatusPill.contains("@ObservedObject var model"))
        XCTAssertTrue(iosHeaderStatusPill.contains("var snapshot: CompanionHeaderStatusSnapshot"))
        XCTAssertTrue(ios.contains("private struct CompanionHeaderStatusSnapshot: Equatable"))
        XCTAssertTrue(ios.contains("return \"갱신 전\""))
        XCTAssertFalse(ios.contains("return \"방금 갱신\""))
        XCTAssertTrue(ios.contains("private struct CompanionHeaderStatusPillContent: View, Equatable"))
        XCTAssertTrue(iosHeaderStatusPill.contains("CompanionHeaderStatusPillContent(snapshot: snapshot)"))
        XCTAssertTrue(iosHeaderStatusPill.contains(".equatable()"))
        XCTAssertFalse(iosHeader.contains("Text(model.statusLine)"))
        XCTAssertTrue(iosStatusScreen.contains("statusDetailColumn"))
        XCTAssertTrue(iosStatusScreen.contains("statusRegularWorkspace"))
        XCTAssertFalse(iosStatusScreen.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(iosStatusScreen.contains("VStack(alignment: .leading, spacing: 12)"))
        XCTAssertTrue(iosStatusScreen.contains("DashboardCategoryInlineDetailPanel(category: category, model: model)"))
        XCTAssertTrue(iosStatusScreen.contains("if model.hasLoadedServerSyncData"))
        XCTAssertTrue(iosStatusScreen.contains("WorkstationDashboardRunSummaryCard(status: model.dashboardStatus)"))
        XCTAssertTrue(iosStatusScreen.contains("CompanionDashboardDataLoadingCard("))
        XCTAssertTrue(iosStatusScreen.contains("isLoading: model.isLoadingServerSyncData"))
        XCTAssertTrue(iosStatusScreen.contains("didFail: model.connectionSucceeded == false"))
        XCTAssertTrue(iosStatusScreen.contains("failureMessage: model.errorMessage"))
        XCTAssertTrue(iosStatusScreen.contains("WorkstationDashboardEmptyGuidePanel()"))
        XCTAssertTrue(iosStatusScreen.contains("WorkstationDashboardOverviewData(model: model)"))
        XCTAssertTrue(iosStatusScreen.contains("showsMetrics: false"))
        XCTAssertFalse(iosStatusScreen.contains("title: \"항목 선택\""))
        XCTAssertFalse(iosStatusScreen.contains("DashboardCategoryInlineDetailPanel(category: defaultWorkstationDetailCategory, model: model)"))
        XCTAssertFalse(iosStatusScreen.contains("private var defaultWorkstationDetailCategory"))
        XCTAssertFalse(iosStatusScreen.contains("DashboardMetricCategory.defaultWorkstationDetail(for: model.dashboardStatus)"))
        XCTAssertTrue(iosStatusScreen.contains("HStack(alignment: .top, spacing: CompanionWorkstationMetrics.columnSpacing)"))
        XCTAssertTrue(iosStatusScreen.contains("statusMainColumn"))
        XCTAssertTrue(iosStatusScreen.contains("statusCommandColumn"))
        XCTAssertTrue(iosStatusScreen.contains("statusMetricColumn"))
        XCTAssertTrue(iosStatusScreen.contains("minWidth: CompanionWorkstationMetrics.listColumnMinWidth"))
        XCTAssertTrue(iosStatusScreen.contains("idealWidth: CompanionWorkstationMetrics.listColumnIdealWidth"))
        XCTAssertTrue(iosStatusScreen.contains("maxWidth: CompanionWorkstationMetrics.listColumnMaxWidth"))
        XCTAssertTrue(iosStatusScreen.contains("minWidth: CompanionWorkstationMetrics.detailColumnMinWidth"))
        XCTAssertFalse(iosStatusScreen.contains("minWidth: CompanionWorkstationMetrics.commandColumnMinWidth"))
        XCTAssertFalse(iosStatusScreen.contains("minWidth: CompanionWorkstationMetrics.metricColumnMinWidth"))
        XCTAssertFalse(iosStatusScreen.contains("minWidth: CompanionWorkstationMetrics.compactCommandColumnMinWidth"))
        XCTAssertFalse(iosStatusScreen.contains("idealWidth: CompanionWorkstationMetrics.compactCommandColumnIdealWidth"))
        XCTAssertFalse(iosStatusScreen.contains("maxWidth: CompanionWorkstationMetrics.compactCommandColumnMaxWidth"))
        XCTAssertFalse(iosStatusScreen.contains("minWidth: CompanionWorkstationMetrics.compactDetailColumnMinWidth"))
        XCTAssertFalse(iosStatusScreen.contains("idealWidth: CompanionWorkstationMetrics.compactDetailColumnIdealWidth"))
        XCTAssertFalse(iosStatusScreen.contains("WorkstationDashboardDetailPanel"))
        XCTAssertTrue(iosStatusScreen.contains("WorkstationDashboardOverviewPanel("))
        XCTAssertTrue(iosStatusScreen.contains("data: WorkstationDashboardOverviewData(model: model)"))
        XCTAssertTrue(iosStatusScreen.contains("showsMetrics: false"))
        XCTAssertFalse(iosStatusScreen.contains("onOpenCategory: openDashboardCategoryFromOverview"))
        XCTAssertTrue(ios.contains("private struct WorkstationDashboardOverviewData: Equatable"))
        XCTAssertTrue(ios.contains("private struct WorkstationDashboardOverviewPanel: View, Equatable"))
        XCTAssertTrue(ios.contains("private struct RemoteDashboardMetricSnapshot: Equatable"))
        XCTAssertFalse(iosStatusScreen.contains("WorkstationDashboardOverviewPanel(model: model)"))
        XCTAssertFalse(iosMetricOverview.contains("CompactDashboardSelectionPanel(category: selectedCategory, model: model)"))
        XCTAssertTrue(iosMetricOverview.contains("let model: CompanionModel"))
        XCTAssertTrue(iosMetricOverview.contains("var status: SanitizedRemoteStatus"))
        XCTAssertTrue(iosMetricOverview.contains("var hasFileCleanupDetails: Bool"))
        XCTAssertTrue(iosMetricOverview.contains("private let metricSnapshot: RemoteDashboardMetricSnapshot"))
        XCTAssertTrue(iosMetricOverview.contains("metricSnapshot = RemoteDashboardMetricSnapshot("))
        XCTAssertFalse(iosMetricOverview.contains("@ObservedObject var model"))
        XCTAssertFalse(iosMetricOverview.contains("model.dryRunReports.contains"))
        XCTAssertFalse(iosStatusScreen.contains("?? .files"))
        XCTAssertTrue(iosMetricOverview.contains("@Environment(\\.horizontalSizeClass)"))
        XCTAssertTrue(iosMetricOverview.contains("private let compactColumns"))
        XCTAssertTrue(iosMetricOverview.contains("private let workstationColumns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: 8), count: 2)"))
        XCTAssertTrue(iosMetricOverview.contains("LazyVGrid(columns: workstationColumns, alignment: .leading, spacing: 8)"))
        XCTAssertTrue(iosMetricOverview.contains("LazyVGrid(columns: compactColumns, alignment: .leading, spacing: 8)"))
        XCTAssertFalse(iosMetricOverview.contains("if horizontalSizeClass == .regular {\n                    VStack(spacing: 8)"))
        XCTAssertFalse(iosMetricOverview.contains("horizontalSizeClass == .regular && !primaryMetricCategories.isEmpty"))
        XCTAssertTrue(iosMetricOverview.contains("WorkstationMetricCard"))
        XCTAssertTrue(iosMetricOverview.contains("if metricSnapshot.shouldShowPrimaryMetricSection {"))
        XCTAssertTrue(iosMetricOverview.contains("if isDataLoaded && metricSnapshot.shouldShowAttentionMetricSection {"))
        XCTAssertTrue(iosMetricOverview.contains("metricSection(\"주요 항목\", categories: metricSnapshot.primaryMetricCategories)"))
        XCTAssertTrue(iosMetricOverview.contains("metricSection(\"확인 필요\", categories: metricSnapshot.attentionMetricCategories)"))
        XCTAssertTrue(iosMetricOverview.contains("표시할 대시보드 항목이 없습니다."))
        XCTAssertTrue(iosMetricOverview.contains("shouldShowInlineEmptyDashboardMessage"))
        XCTAssertTrue(iosMetricOverview.contains("horizontalSizeClass != .regular"))
        XCTAssertTrue(iosMetricOverview.contains("metricSnapshot.primaryMetricCategories.isEmpty"))
        XCTAssertTrue(iosMetricOverview.contains("metricSnapshot.attentionMetricCategories.isEmpty"))
        XCTAssertTrue(iosMetricOverview.contains("&& !metricSnapshot.hasVisibleChangeSummary"))
        XCTAssertFalse(iosMetricOverview.contains(".filter { $0.value(from: displayStatus) > 0 }"))
        XCTAssertFalse(iosMetricOverview.contains("let categories: [DashboardMetricCategory] = [.quarantine, .calendar]"))
        XCTAssertTrue(ios.contains("let attentionCategories: [DashboardMetricCategory] = [.quarantine, .calendar]"))
        XCTAssertFalse(iosMetricOverview.contains("horizontalSizeClass == .regular ? [.quarantine, .calendar] : [.quarantine]"))
        XCTAssertFalse(iosMetricOverview.contains("private var hasVisibleMetrics: Bool"))
        XCTAssertFalse(iosMetricOverview.contains("private var shouldShowPrimaryMetricSection"))
        XCTAssertFalse(iosMetricOverview.contains("private var shouldShowAttentionMetricSection"))
        XCTAssertTrue(ios.contains("var shouldShowPrimaryMetricSection: Bool"))
        XCTAssertTrue(ios.contains("var shouldShowAttentionMetricSection: Bool"))
        XCTAssertTrue(iosMetricOverview.contains("Text(title)"))
        XCTAssertTrue(iosMetricTile.contains("Image(systemName: systemImage)"))
        XCTAssertTrue(iosMetricTile.contains(".frame(width: 26, height: 26)"))
        XCTAssertTrue(iosMetricTile.contains(".font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())"))
        XCTAssertTrue(iosMetricTile.contains("Color.klmsSelectedBackground.opacity(0.96)"))
        XCTAssertTrue(iosMetricTile.contains("Color.klmsSelectedForeground"))
        XCTAssertTrue(iosMetricTile.contains("isSelected ? Color.klmsSelectedForeground.opacity(0.82) : Color.klmsSecondaryText"))
        XCTAssertTrue(iosMetricTile.contains("Color.klmsSelectedBorder.opacity(0.92)"))
        XCTAssertFalse(iosMetricTile.contains(".shadow(color: isSelected ? Color.klmsSelectedBorder.opacity(0.10) : Color.clear"))
        XCTAssertTrue(iosMetricTile.contains(".buttonStyle(KLMSCardButtonStyle(cornerRadius: 14))"))
        XCTAssertTrue(iosMetricTile.contains(".accessibilityValue(isSelected ? \"선택됨\" : \"선택 안 됨\")"))
        XCTAssertTrue(iosMetricTile.contains(".accessibilityHint(\"\\(label) 상세를 아래에 엽니다.\")"))
        XCTAssertTrue(iosWorkstationMetricCard.contains(".padding(11)"))
        XCTAssertTrue(iosWorkstationMetricCard.contains("Image(systemName: category.systemImage)"))
        XCTAssertTrue(iosWorkstationMetricCard.contains(".frame(width: 26, height: 26)"))
        XCTAssertTrue(iosWorkstationMetricCard.contains("Text(\"\\(category.title) \\(value)개\")"))
        XCTAssertTrue(iosWorkstationMetricCard.contains(".font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())"))
        XCTAssertTrue(iosWorkstationMetricCard.contains(".font(.system(size: 11, weight: .regular, design: .rounded))"))
        XCTAssertTrue(iosWorkstationMetricCard.contains("isSelected ? Color.klmsSelectedForeground.opacity(0.78) : Color.klmsSecondaryText"))
        XCTAssertFalse(iosWorkstationMetricCard.contains(".font(.headline.weight(.semibold))"))
        XCTAssertTrue(iosWorkstationMetricCard.contains("RoundedRectangle(cornerRadius: 13)"))
        XCTAssertTrue(iosWorkstationMetricCard.contains("Color.klmsSelectedBackground.opacity(0.96)"))
        XCTAssertTrue(iosWorkstationMetricCard.contains("Color.klmsSelectedBorder.opacity(0.92)"))
        XCTAssertTrue(iosWorkstationMetricCard.contains(".buttonStyle(KLMSCardButtonStyle(cornerRadius: 13))"))
        XCTAssertTrue(iosWorkstationMetricCard.contains(".accessibilityValue(isSelected ? \"선택됨\" : \"선택 안 됨\")"))
        XCTAssertTrue(iosWorkstationMetricCard.contains(".accessibilityHint(\"\\(category.title) 상세와 처리 버튼을 오른쪽 패널에 표시합니다.\")"))
        XCTAssertTrue(ios.contains("private struct WorkstationDashboardOverviewPanel"))
        let iosWorkstationOverviewPanel = try sourceBody(
            after: "private struct WorkstationDashboardOverviewPanel: View, Equatable",
            in: ios,
            description: "WorkstationDashboardOverviewPanel"
        )
        XCTAssertFalse(iosWorkstationOverviewPanel.contains("let model: CompanionModel"))
        XCTAssertFalse(iosWorkstationOverviewPanel.contains("model.cachedVisibleDashboardItems"))
        XCTAssertTrue(iosWorkstationOverviewPanel.contains("Text(\"대시보드\")"))
        XCTAssertTrue(iosWorkstationOverviewPanel.contains("최신 항목을 먼저 보고, 목록 카드에서 바로 처리합니다."))
        XCTAssertFalse(iosWorkstationOverviewPanel.contains("WorkstationDashboardSelectionGuide()"))
        XCTAssertTrue(iosWorkstationOverviewPanel.contains(".background(Color.klmsCardBackground, in: RoundedRectangle(cornerRadius: 14))"))
        XCTAssertTrue(iosWorkstationOverviewPanel.contains("Image(systemName: metric.systemImage)"))
        XCTAssertTrue(iosWorkstationOverviewPanel.contains(".frame(width: 26, height: 26)"))
        XCTAssertTrue(iosWorkstationOverviewPanel.contains(".background(metric.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))"))
        XCTAssertTrue(iosWorkstationOverviewPanel.contains(".accessibilityLabel(\"\\(metric.title) \\(metric.value)개\")"))
        XCTAssertTrue(iosWorkstationOverviewPanel.contains(".accessibilityHint(\"\\(metric.title) 목록을 가운데 작업 영역에 표시합니다.\")"))
        XCTAssertTrue(iosWorkstationOverviewPanel.contains("MetricSummary(category: .files, title: \"파일\", value: status.fileTotal, systemImage: \"folder\", tint: Color.klmsCommandAccent)"))
        XCTAssertTrue(iosWorkstationOverviewPanel.contains("MetricSummary(category: .notices, title: \"공지\", value: status.notices, systemImage: \"note.text\", tint: Color.klmsCommandAccent)"))
        XCTAssertTrue(iosWorkstationOverviewPanel.contains("MetricSummary(category: .exams, title: \"시험\", value: status.exams, systemImage: \"calendar.badge.clock\", tint: Color.klmsWarningBorder)"))
        XCTAssertTrue(iosWorkstationOverviewPanel.contains("if overviewMetrics.isEmpty"))
        XCTAssertTrue(iosWorkstationOverviewPanel.contains("표시할 대시보드 항목이 없습니다."))
        XCTAssertTrue(iosWorkstationOverviewPanel.contains("].filter { $0.value > 0 }"))
        XCTAssertTrue(iosWorkstationOverviewPanel.contains("WorkstationDashboardPreviewSection("))
        XCTAssertTrue(iosWorkstationOverviewPanel.contains("title: \"파일\""))
        XCTAssertTrue(iosWorkstationOverviewPanel.contains("title: \"과제/시험\""))
        XCTAssertTrue(iosWorkstationOverviewPanel.contains("title: \"공지\""))
        XCTAssertTrue(iosWorkstationOverviewPanel.contains("private var filePreviewItems: [ServerRelaySyncItem]"))
        XCTAssertTrue(iosWorkstationOverviewPanel.contains("private var noticePreviewItems: [ServerRelaySyncItem]"))
        XCTAssertTrue(iosWorkstationOverviewPanel.contains("if !data.hasLoadedServerSyncData"))
        XCTAssertTrue(iosWorkstationOverviewPanel.contains("CompanionDashboardDataLoadingCard("))
        XCTAssertTrue(iosWorkstationOverviewPanel.contains("isLoading: data.isLoadingServerSyncData"))
        XCTAssertTrue(iosWorkstationOverviewPanel.contains("didFail: data.didFailServerSyncDataLoad"))
        XCTAssertTrue(iosWorkstationOverviewPanel.contains("failureMessage: data.serverSyncDataFailureMessage"))
        XCTAssertTrue(iosWorkstationOverviewPanel.contains("if data.hasLoadedServerSyncData, !filePreviewItems.isEmpty"))
        XCTAssertTrue(iosWorkstationOverviewPanel.contains("if data.hasLoadedServerSyncData, !previewTaskItems.isEmpty"))
        XCTAssertTrue(iosWorkstationOverviewPanel.contains("if data.hasLoadedServerSyncData, !noticePreviewItems.isEmpty"))
        XCTAssertTrue(iosWorkstationOverviewPanel.contains("if data.hasLoadedServerSyncData, shouldShowWorkstationEmptyGuide"))
        XCTAssertTrue(iosWorkstationOverviewPanel.contains("if data.hasLoadedServerSyncData {\n                WorkstationChangeSummaryCard(status: data.status)\n            }"))
        XCTAssertFalse(iosWorkstationOverviewPanel.contains("\n            WorkstationChangeSummaryCard(status: data.status)\n"))
        XCTAssertTrue(iosWorkstationOverviewPanel.contains("overviewMetrics.isEmpty"))
        XCTAssertTrue(iosWorkstationOverviewPanel.contains("filePreviewItems.isEmpty"))
        XCTAssertTrue(iosWorkstationOverviewPanel.contains("previewTaskItems.isEmpty"))
        XCTAssertTrue(iosWorkstationOverviewPanel.contains("noticePreviewItems.isEmpty"))
        XCTAssertTrue(ios.contains("private struct WorkstationDashboardEmptyGuidePanel"))
        XCTAssertTrue(ios.contains("대시보드 준비 중"))
        XCTAssertTrue(ios.contains("서버 데이터가 아직 없어서 표시할 항목이 없습니다."))
        XCTAssertTrue(ios.contains("서버 연결"))
        XCTAssertTrue(ios.contains("요약 갱신"))
        XCTAssertTrue(ios.contains("바로 처리"))
        XCTAssertFalse(iosWorkstationOverviewPanel.contains("items: previewItems(for: .files)"))
        XCTAssertFalse(iosWorkstationOverviewPanel.contains("items: previewItems(for: .notices)"))
        XCTAssertTrue(ios.contains("private struct WorkstationDashboardOverviewData: Equatable"))
        XCTAssertTrue(ios.contains(".companionSorted(by: .recent)"))
        XCTAssertTrue(iosWorkstationOverviewPanel.contains("WorkstationChangeSummaryCard(status: data.status)"))
        XCTAssertTrue(ios.contains("private struct WorkstationDashboardPreviewSection"))
        XCTAssertFalse(ios.contains("private struct WorkstationDashboardSelectionGuide"))
        XCTAssertFalse(ios.contains("Text(\"선택하면 할 수 있는 일\")"))
        XCTAssertFalse(ios.contains("\"강의자료와 공지 첨부 파일을 같은 목록에서 확인합니다.\""))
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
        let tabRoot = try sourceStructBody(named: "CompanionTabRootView", in: ios)
        let splitRoot = try sourceStructBody(named: "CompanionSplitRootView", in: ios)
        let sectionContent = try sourceStructBody(named: "CompanionSectionContent", in: ios)
        let statusScreen = try sourceStructBody(named: "CompanionStatusScreen", in: ios)
        let categoryScreen = try sourceStructBody(named: "CompanionDashboardCategoryScreen", in: ios)
        let tasksScreen = try sourceStructBody(named: "CompanionTasksScreen", in: ios)
        let settingsScreen = try sourceStructBody(named: "CompanionSettingsScreen", in: ios)
        let syncDataPanel = try sourceStructBody(named: "ServerSyncDataPanel", in: ios)
        let inlineDetail = try sourceStructBody(named: "DashboardCategoryInlineDetailPanel", in: ios)
        let searchFilterPanel = try sourceBody(
            after: "private struct CompanionSearchFilterPanel<Controls: View>: View",
            in: ios,
            description: "CompanionSearchFilterPanel"
        )
        let iosHistoryScreen = try sourceStructBody(named: "CompanionHistoryScreen", in: ios)
        let iosRemoteLogSummaryPanel = try sourceStructBody(named: "RemoteLogSummaryPanel", in: ios)
        let controlsPlaceholder = try sourceStructBody(named: "CompanionItemListControlsPlaceholder", in: ios)
        let deferredControls = try sourceStructBody(named: "DeferredCompanionItemListControls", in: ios)
        let selectableRows = try sourceStructBody(named: "CompanionSelectableItemListRows", in: ios)
        let inlineRows = try sourceStructBody(named: "CompanionInlineItemRowsView", in: ios)
        let listData = try sourceBody(
            after: "private struct CompanionItemListData: Sendable",
            in: ios,
            description: "CompanionItemListData"
        )
        let companionItemListFilter = try sourceBody(
            after: "private enum CompanionItemListFilter",
            in: ios,
            description: "CompanionItemListFilter"
        )
        let companionItemFilterOptions = try sourceBody(
            after: "private struct CompanionItemFilterOptions",
            in: ios,
            description: "CompanionItemFilterOptions"
        )
        let companionItemStatusFilter = try sourceBody(
            after: "private enum CompanionItemStatusFilter: String, CaseIterable, Identifiable, Sendable",
            in: ios,
            description: "CompanionItemStatusFilter"
        )
        let deferredInlineItemDetail = try sourceStructBody(named: "DeferredServerSyncItemDetailPanel", in: ios)
        let inlineItemDetail = try sourceStructBody(named: "ServerSyncItemInlineDetailPanel", in: ios)
        let serverSyncDataRow = try sourceStructBody(named: "ServerSyncDataRow", in: ios)
        let workstationExternalDetail = try sourceStructBody(named: "WorkstationExternalDetailPanel", in: ios)
        let remoteItemToggleButton = try sourceStructBody(named: "RemoteItemToggleButton", in: ios)
        let workstationOverview = try sourceBody(
            after: "private struct WorkstationDashboardOverviewPanel: View, Equatable",
            in: ios,
            description: "WorkstationDashboardOverviewPanel"
        )
        let workstationPreviewSection = try sourceStructBody(named: "WorkstationDashboardPreviewSection", in: ios)
        let workstationChangeSummary = try sourceStructBody(named: "WorkstationChangeSummaryCard", in: ios)
        let workstationCategory = try sourceStructBody(named: "WorkstationDashboardCategoryWorkspace", in: ios)
        let workstationTasks = try sourceStructBody(named: "WorkstationTasksWorkspace", in: ios)
        let workstationCalendar = try sourceStructBody(named: "WorkstationCalendarWorkspace", in: ios)
        let workstationCategoryRegularWorkspace = try sourceBody(
            after: "private var categoryRegularWorkspace: some View",
            in: workstationCategory,
            description: "category regular workspace"
        )
        let workstationTasksRegularWorkspace = try sourceBody(
            after: "private var tasksRegularWorkspace: some View",
            in: workstationTasks,
            description: "tasks regular workspace"
        )
        let workstationTaskCategorySelector = try sourceStructBody(named: "WorkstationTaskCategorySelector", in: ios)
        let workstationCalendarRegularWorkspace = try sourceBody(
            after: "private var calendarRegularWorkspace: some View",
            in: workstationCalendar,
            description: "calendar regular workspace"
        )
        let compactSelectedRow = try sourceStructBody(named: "CompactDashboardSelectedRow", in: ios)
        let recentFileRequests = try sourceStructBody(named: "RecentFileAccessRequestsView", in: ios)
        let recentServerRequests = try sourceStructBody(named: "RecentServerRequestLogView", in: ios)
        let recentRemoteCommands = try sourceStructBody(named: "RecentRemoteCommandsView", in: ios)
        let companionModel = try sourceBody(
            after: "final class CompanionModel: ObservableObject",
            in: ios,
            description: "CompanionModel"
        )
        let longDetailFieldRow = try sourceStructBody(named: "LongDetailFieldRow", in: ios)

        XCTAssertTrue(ios.contains("private struct CompanionItemListData"))
        XCTAssertTrue(listData.contains("var filteredItemIDs: Set<String>"))
        XCTAssertTrue(listData.contains("Set(sortedFiltered.map(\\.id))"))
        XCTAssertTrue(ios.contains("private struct CompanionItemFilterOptions: Equatable, Sendable"))
        XCTAssertTrue(companionItemListFilter.contains("static func options(for items: [ServerRelaySyncItem])"))
        XCTAssertTrue(companionItemListFilter.contains("for item in items"))
        XCTAssertTrue(companionItemListFilter.contains("courses.insert(course)"))
        XCTAssertTrue(companionItemListFilter.contains("years.insert(year)"))
        XCTAssertTrue(companionItemListFilter.contains("semesters.insert(semester)"))
        XCTAssertTrue(companionItemFilterOptions.contains("let listOptions = CompanionItemListFilter.options(for: items)"))
        XCTAssertTrue(companionItemFilterOptions.contains("courseOptions = listOptions.courses"))
        XCTAssertTrue(companionItemFilterOptions.contains("yearOptions = listOptions.years"))
        XCTAssertTrue(companionItemFilterOptions.contains("semesterOptions = listOptions.semesters"))
        XCTAssertFalse(companionItemFilterOptions.contains("CompanionItemListFilter.courseOptions(for: items)"))
        XCTAssertFalse(companionItemFilterOptions.contains("CompanionItemListFilter.yearOptions(for: items)"))
        XCTAssertFalse(companionItemFilterOptions.contains("CompanionItemListFilter.semesterOptions(for: items)"))
        XCTAssertTrue(ios.contains("private struct CompanionItemStatusFilterAvailability: Sendable"))
        XCTAssertTrue(companionItemStatusFilter.contains("let availability = CompanionItemStatusFilterAvailability(items: items)"))
        XCTAssertTrue(companionItemStatusFilter.contains("return candidates.filter { availability.contains($0) }"))
        XCTAssertFalse(companionItemStatusFilter.contains("items.contains { filter.includes($0) }"))
        XCTAssertTrue(ios.contains("private struct DeferredCompanionItemListControls: View"))
        XCTAssertTrue(ios.contains("filterOptions: CompanionItemFilterOptions? = nil"))
        XCTAssertTrue(ios.contains("let resolvedFilterOptions = filterOptions ?? CompanionItemFilterOptions(items: base, category: category)"))
        XCTAssertTrue(ios.contains("private enum CompanionItemListPreloadStore"))
        XCTAssertTrue(ios.contains("private static let maxCachedLists = 20"))
        XCTAssertFalse(ios.contains("private static let maxCachedLists = 8"))
        XCTAssertTrue(ios.contains("CompanionItemListPreloadStore.cachedData(for: currentKey)"))
        XCTAssertTrue(ios.contains("CompanionItemListPreloadStore.store(listData, for: inputKey)"))
        XCTAssertFalse(ios.contains("private struct CompanionItemListPrewarmView: View"))
        XCTAssertFalse(ios.contains("static func defaultCategoryKey(itemsRevision: Int, category: DashboardMetricCategory) -> CompanionItemListInputKey"))
        XCTAssertFalse(listData.contains("Task.detached(priority: .utility)"))
        XCTAssertFalse(selectableRows.contains("Task.detached(priority: .utility)"))
        XCTAssertFalse(inlineRows.contains("Task.detached(priority: .utility)"))
        XCTAssertFalse(ios.contains("prewarmDelayNanoseconds"))
        XCTAssertFalse(ios.contains("try? await Task.sleep(nanoseconds: CompanionLargeList.prewarmDelayNanoseconds)"))
        XCTAssertTrue(inlineRows.contains("return isSelected ? \"checkmark.circle.fill\" : \"chevron.right\""))
        XCTAssertTrue(inlineRows.contains(".accessibilityValue(presentation == .inlineDetail ? (isSelected ? \"펼쳐짐\" : \"접힘\") : (isSelected ? \"선택됨\" : \"선택 안 됨\"))"))
        XCTAssertTrue(selectableRows.contains(".accessibilityValue(selectedItemID == item.id ? \"선택됨\" : \"선택 안 됨\")"))
        XCTAssertTrue(serverSyncDataRow.contains("var snapshot: ServerSyncRowSnapshot"))
        XCTAssertTrue(serverSyncDataRow.contains("self.snapshot = ServerSyncRowSnapshot(item: item)"))
        XCTAssertTrue(serverSyncDataRow.contains("&& lhs.snapshot == rhs.snapshot"))
        XCTAssertTrue(serverSyncDataRow.contains(".frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)"))
        XCTAssertTrue(serverSyncDataRow.contains(".overlay(alignment: .leading)"))
        XCTAssertTrue(serverSyncDataRow.contains(".accessibilityLabel(snapshot.accessibilityLabel)"))
        XCTAssertTrue(ios.contains("private struct ServerSyncRowSnapshot: Equatable"))
        XCTAssertFalse(ios.contains("private struct ServerSyncRowSummary: Equatable"))
        XCTAssertFalse(serverSyncDataRow.contains("let summary = rowSummary"))
        XCTAssertFalse(serverSyncDataRow.contains(".accessibilityLabel(accessibilityLabelText)"))
        XCTAssertTrue(inlineItemDetail.contains("LongDetailFieldRow(title: \"세부 내용\", value: item.detail)"))
        XCTAssertFalse(inlineItemDetail.contains("\n            DetailFieldRow(title: \"세부 내용\", value: item.detail)"))
        XCTAssertTrue(inlineItemDetail.contains("Text(itemActionHelpMessage)"))
        XCTAssertTrue(inlineItemDetail.contains("숨김은 모든 기기 화면에 바로 반영됩니다. 삭제와 파일 링크 준비는 Mac 앱이 로컬 파일을 확인한 뒤 처리합니다."))
        XCTAssertTrue(inlineItemDetail.contains("이 버튼들은 서버 상태를 즉시 바꿉니다. Mac이 꺼져 있어도 다른 기기 화면에는 바로 반영됩니다."))
        XCTAssertTrue(inlineItemDetail.contains("숨김 처리는 서버 화면에 바로 반영됩니다. 파일 열기와 삭제처럼 로컬 파일이 필요한 작업은 Mac 앱이 처리합니다."))
        XCTAssertTrue(inlineItemDetail.contains("읽음, 중요, 숨김, 완료 같은 화면 상태는 서버에 바로 반영됩니다. Notes, Calendar, Reminders 실제 반영은 다음 Mac 동기화에서 맞춰집니다."))
        XCTAssertFalse(inlineItemDetail.contains("항목 처리 요청은 서버에 대기 상태로 올라가고, Mac 앱이 확인한 뒤 기존 상태 파일에 반영합니다."))
        XCTAssertTrue(longDetailFieldRow.contains("private static let collapsedCharacterLimit = 520"))
        XCTAssertTrue(longDetailFieldRow.contains("Text(collapsedText(displayValue))"))
        XCTAssertTrue(longDetailFieldRow.contains("Label(isExpanded ? \"접기\" : \"전체 보기\""))
        XCTAssertTrue(longDetailFieldRow.contains(".lineLimit(6)"))
        XCTAssertTrue(longDetailFieldRow.contains("companionPerformWithoutAnimation"))
        XCTAssertTrue(longDetailFieldRow.contains(".frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)"))
        XCTAssertTrue(longDetailFieldRow.contains(".contentShape(RoundedRectangle(cornerRadius: 10))"))
        XCTAssertTrue(longDetailFieldRow.contains(".buttonStyle(KLMSCardButtonStyle(cornerRadius: 10))"))
        XCTAssertTrue(longDetailFieldRow.contains(".accessibilityLabel(\"\\(title) \\(isExpanded ? \"펼쳐짐\" : \"접힘\")\")"))
        XCTAssertFalse(longDetailFieldRow.contains(".frame(minHeight: 36)"))
        XCTAssertTrue(recentFileRequests.contains(".frame(width: 44, height: 44)"))
        XCTAssertTrue(recentServerRequests.contains(".frame(width: 44, height: 44)"))
        XCTAssertTrue(recentRemoteCommands.contains(".frame(width: 44, height: 44)"))
        XCTAssertTrue(ios.contains("private struct KLMSCardButtonStyle: ButtonStyle"))
        XCTAssertTrue(ios.contains(".frame(minWidth: 44, minHeight: 44)"))
        XCTAssertTrue(ios.contains(".frame(minWidth: 44, minHeight: 44)"))
        XCTAssertFalse(ios.contains("private let klmsInteractionDetailDelayNanoseconds"))
        XCTAssertTrue(ios.contains(".onChange(of: appearanceMode)"))
        XCTAssertTrue(ios.contains("Self.schedulePlatformAppearance(newValue)"))
        XCTAssertTrue(ios.contains("window.overrideUserInterfaceStyle = style"))
        XCTAssertTrue(ios.contains("style = .unspecified"))
        XCTAssertTrue(ios.contains("style = .light"))
        XCTAssertTrue(ios.contains("style = .dark"))
        XCTAssertTrue(ios.contains("@Published private(set) var dashboardSyncItems: [ServerRelaySyncItem] = []"))
        XCTAssertTrue(ios.contains("@Published private(set) var dashboardSyncItemsRevision = 0"))
        XCTAssertTrue(ios.contains("@Published private(set) var dashboardHasFileCleanupDetails = false"))
        XCTAssertTrue(ios.contains("@Published private(set) var visibleCalendarChangesCache: [CalendarChange] = []"))
        XCTAssertTrue(ios.contains("@Published private(set) var changeSummaryItemsByKindID: [String: [ServerRelaySyncItem]] = [:]"))
        XCTAssertTrue(ios.contains("@Published private(set) var changeSummaryCalendarChangesByKindID: [String: [CalendarChange]] = [:]"))
        XCTAssertTrue(ios.contains("@Published private(set) var fileCleanupReportsForDashboard: [DryRunReport] = []"))
        XCTAssertTrue(ios.contains("private func rebuildDashboardDerivedState()"))
        XCTAssertTrue(companionModel.contains("didSet { rebuildDashboardFileCleanupDetails(); rebuildFileCleanupReportCache() }"))
        XCTAssertTrue(companionModel.contains("latestFileAccessRequestByItemID"))
        XCTAssertTrue(companionModel.contains("activeItemActionByItemID"))
        XCTAssertTrue(companionModel.contains("activeCalendarActionByID"))
        XCTAssertTrue(companionModel.contains("action.isActiveForCompanionDisplay"))
        XCTAssertTrue(companionModel.contains("recentItemActions = recentItemActions.filter(\\.isActiveForCompanionDisplay)"))
        XCTAssertTrue(companionModel.contains("recentSettingActions = recentSettingActions.filter(\\.isActiveForCompanionDisplay)"))
        XCTAssertTrue(companionModel.contains("dashboardItemsByCategoryID"))
        XCTAssertTrue(companionModel.contains("visibleDashboardItemsByCategoryID"))
        XCTAssertTrue(companionModel.contains("visibleDashboardItemLookupByCategoryID"))
        XCTAssertTrue(companionModel.contains("visibleCalendarChangeByID"))
        XCTAssertTrue(companionModel.contains("dashboardFilterOptionsByCategoryID"))
        XCTAssertTrue(companionModel.contains("defaultDashboardListDataByCategoryID"))
        XCTAssertTrue(companionModel.contains("dashboardSortedSyncItems"))
        XCTAssertTrue(companionModel.contains("dashboardActionHiddenItemIDsCache"))
        XCTAssertTrue(companionModel.contains("let nextHiddenByActionItemIDs = dashboardActionHiddenItemIDs()"))
        XCTAssertTrue(companionModel.contains("let hiddenActionsChanged = dashboardActionHiddenItemIDsCache != nextHiddenByActionItemIDs"))
        XCTAssertTrue(companionModel.contains("dashboardSortedSyncItems = nextItems.companionSorted(by: .recent)"))
        XCTAssertTrue(companionModel.contains("if itemsChanged || hiddenActionsChanged"))
        XCTAssertTrue(companionModel.contains("rebuildDashboardItemLookup(\n                sortedDashboardItems: dashboardSortedSyncItems,\n                hiddenByActionItemIDs: nextHiddenByActionItemIDs\n            )"))
        XCTAssertFalse(companionModel.contains("let sortedDashboardItems = dashboardSyncItems.companionSorted(by: .recent)"))
        XCTAssertTrue(companionModel.contains("DashboardMetricCategory.itemCategory(for: item)"))
        XCTAssertTrue(companionModel.contains("visibleDashboardTaskItems = nextVisibleTaskItems"))
        XCTAssertFalse(companionModel.contains(".filter { category.includes($0) }\n                .companionSorted(by: .recent)"))
        XCTAssertTrue(companionModel.contains("nextVisibleLookup[category.rawValue] = Dictionary(visibleItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })"))
        XCTAssertTrue(companionModel.contains("visibleCalendarChangeByID = Dictionary(next.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })"))
        XCTAssertTrue(companionModel.contains("let filterOptions = CompanionItemFilterOptions(items: categoryItems, category: category)"))
        XCTAssertTrue(companionModel.contains("nextFilterOptions[category.rawValue] = filterOptions"))
        XCTAssertTrue(companionModel.contains("nextDefaultListData[category.rawValue] = CompanionItemListData("))
        XCTAssertTrue(companionModel.contains("func cachedVisibleDashboardItem(for itemID: String, categoryID: String) -> ServerRelaySyncItem?"))
        XCTAssertTrue(companionModel.contains("func visibleCalendarChange(for id: String) -> CalendarChange?"))
        XCTAssertTrue(companionModel.contains("fileprivate func cachedDefaultDashboardListData(for categoryID: String) -> CompanionItemListData?"))
        XCTAssertTrue(companionModel.contains("visibleDashboardTaskItems"))
        XCTAssertTrue(companionModel.contains("@Published private(set) var currentRemoteLogCommand: RemoteRunCommand?"))
        XCTAssertTrue(companionModel.contains("@Published private(set) var latestRemoteLogFileRequest: ServerRelayFileAccessRequest?"))
        XCTAssertTrue(companionModel.contains("@Published private(set) var activeRemoteLogFileRequest: ServerRelayFileAccessRequest?"))
        XCTAssertTrue(companionModel.contains("private func rebuildRemoteLogDerivedState()"))
        XCTAssertTrue(companionModel.contains("var hasClearableRemoteLogs: Bool {\n        hasClearableRemoteLogsCache"))
        XCTAssertTrue(companionModel.contains("var hasInFlightRequest: Bool {\n        latestDisplayStatus?.isInFlight == true\n            || activeRemoteLogFileRequest != nil"))
        XCTAssertTrue(companionModel.contains("private func rebuildFileAccessLookup()"))
        XCTAssertTrue(companionModel.contains("private func rebuildItemActionLookups()"))
        XCTAssertTrue(companionModel.contains("private func rebuildDashboardFileCleanupDetails()"))
        XCTAssertTrue(companionModel.contains("private func rebuildChangeSummaryItemLookup(sortedItems: [ServerRelaySyncItem]? = nil)"))
        XCTAssertTrue(companionModel.contains("RemoteChangeSummaryKind.itemChangeKinds.map"))
        XCTAssertTrue(companionModel.contains("for item in sortedItems ?? dashboardSyncItems.companionSorted(by: .recent)"))
        XCTAssertTrue(companionModel.contains("rebuildChangeSummaryItemLookup(sortedItems: dashboardSortedSyncItems)"))
        XCTAssertFalse(companionModel.contains("for item in syncItems.companionSorted(by: .recent)"))
        XCTAssertTrue(companionModel.contains("for kind in RemoteChangeSummaryKind.itemChangeKinds(for: item)"))
        XCTAssertFalse(companionModel.contains(".filter { kind.includes($0) }\n                .companionSorted(by: .recent)"))
        XCTAssertTrue(companionModel.contains("private func rebuildChangeSummaryCalendarLookup"))
        XCTAssertTrue(companionModel.contains("RemoteChangeSummaryKind.calendarChangeKinds.map"))
        XCTAssertTrue(companionModel.contains("RemoteChangeSummaryKind.calendarChangeKind(for: change)"))
        XCTAssertFalse(companionModel.contains("next[kind.rawValue] = source.filter { kind.includes($0) }"))
        XCTAssertTrue(ios.contains("case \"created\", \"mail\":\n            return .calendarCreated"))
        XCTAssertTrue(companionModel.contains("private func rebuildFileCleanupReportCache()"))
        XCTAssertTrue(companionModel.contains("private func rebuildVisibleCalendarChanges()"))
        XCTAssertTrue(companionModel.contains("func cachedDashboardItems(for categoryID: String)"))
        XCTAssertTrue(companionModel.contains("func cachedVisibleDashboardItems(for categoryID: String)"))
        XCTAssertTrue(companionModel.contains("func cachedDashboardFilterOptions(for categoryID: String) -> CompanionItemFilterOptions?"))
        XCTAssertTrue(companionModel.contains("func cachedVisibleDashboardTaskItems() -> [ServerRelaySyncItem]"))
        XCTAssertTrue(companionModel.contains("func cachedChangeSummaryItems(for kindID: String)"))
        XCTAssertTrue(companionModel.contains("func cachedChangeSummaryCalendarChanges(for kindID: String)"))
        XCTAssertTrue(companionModel.contains("func cachedFileCleanupReportsForDashboard()"))
        XCTAssertTrue(companionModel.contains("func visibleCalendarChanges() -> [CalendarChange] {\n        visibleCalendarChangesCache"))
        XCTAssertFalse(companionModel.contains(".filter { $0.itemID == item.id }"))
        XCTAssertFalse(workstationTasks.contains("].flatMap { $0 }"))
        XCTAssertFalse(workstationTasks.contains("model.cachedVisibleDashboardTaskItems()"))
        XCTAssertTrue(tasksScreen.contains("@State private var selectedCompactTaskCategory = DashboardMetricCategory.assignments"))
        XCTAssertTrue(tasksScreen.contains("private var compactTasksWorkspace: some View"))
        XCTAssertTrue(tasksScreen.contains("WorkstationTaskCategorySelector("))
        XCTAssertTrue(tasksScreen.contains("DashboardCategoryInlineDetailPanel(category: selectedCompactTaskCategory, model: model)"))
        XCTAssertTrue(tasksScreen.contains(".id(selectedCompactTaskCategory.rawValue)"))
        XCTAssertFalse(tasksScreen.contains("DashboardCategoryInlineDetailPanel(category: .assignments, model: model)\n                DashboardCategoryInlineDetailPanel(category: .exams, model: model)"))
        XCTAssertFalse(workstationTaskCategorySelector.contains("가운데 작업 영역"))
        XCTAssertTrue(workstationTasks.contains("@State private var selectedTaskCategory = DashboardMetricCategory.assignments"))
        XCTAssertTrue(workstationTasks.contains("private var taskCategories: [DashboardMetricCategory]"))
        XCTAssertTrue(workstationTasks.contains("var categories: [DashboardMetricCategory] = [.assignments, .exams]"))
        XCTAssertTrue(workstationTasks.contains("categories.append(.helpDesk)"))
        XCTAssertTrue(workstationTasks.contains("private var selectedCategoryItems: [ServerRelaySyncItem]"))
        XCTAssertTrue(workstationTasks.contains("model.cachedVisibleDashboardItems(for: selectedTaskCategory.rawValue)"))
        XCTAssertTrue(ios.contains("private struct WorkstationTaskCategorySelector"))
        XCTAssertFalse(ios.contains("private func companionItemsFingerprint"))
        XCTAssertFalse(ios.contains("private struct WorkstationDashboardDetailPanel"))
        XCTAssertFalse(ios.contains("private struct DashboardCategoryDetailScreen"))
        XCTAssertFalse(ios.contains("private struct DashboardCategorySummaryRow"))
        XCTAssertFalse(ios.contains("private struct DashboardCalendarChangeRow"))
        XCTAssertFalse(inlineDetail.contains("companionItemsFingerprint(items)"))
        XCTAssertFalse(inlineDetail.contains("Section(\"검색과 필터\")"))
        XCTAssertFalse(inlineDetail.contains("TextField(\"\\(category.title) 검색\", text: $query)"))
        XCTAssertFalse(inlineDetail.contains("Section(\"검색\")"))
        XCTAssertFalse(inlineDetail.contains("Section(\"보기\")"))
        XCTAssertTrue(inlineDetail.contains("CompanionSearchFilterPanel(title: \"검색과 필터\", fieldPrompt: \"\\(category.title) 검색\", query: $query)"))
        XCTAssertTrue(inlineDetail.contains("CompanionItemListControlsPlaceholder()"))
        XCTAssertTrue(inlineDetail.contains("let filterOptions = model.cachedDashboardFilterOptions(for: category.rawValue)"))
        XCTAssertTrue(inlineDetail.contains("filterOptions: filterOptions"))
        XCTAssertFalse(inlineDetail.contains("DisclosureGroup(isExpanded:"))
        XCTAssertFalse(inlineDetail.contains("@State private var isExpanded"))
        XCTAssertTrue(searchFilterPanel.contains("TextField(fieldPrompt, text: $query)"))
        XCTAssertTrue(searchFilterPanel.contains(".frame(minHeight: 44)"))
        XCTAssertFalse(searchFilterPanel.contains("DisclosureGroup"))
        XCTAssertFalse(searchFilterPanel.contains("isExpanded"))
        XCTAssertFalse(iosRemoteLogSummaryPanel.contains("Date().timeIntervalSince"))
        XCTAssertFalse(iosRemoteLogSummaryPanel.contains("recentFileAccessRequests.first(where:"))
        XCTAssertFalse(iosRemoteLogSummaryPanel.contains("model.currentRemoteLogCommand"))
        XCTAssertFalse(iosRemoteLogSummaryPanel.contains("model.latestRemoteLogFileRequest"))
        XCTAssertTrue(iosRemoteLogSummaryPanel.contains("snapshot.currentCommand"))
        XCTAssertTrue(iosRemoteLogSummaryPanel.contains("snapshot.latestFileRequest"))
        XCTAssertTrue(iosHistoryScreen.contains("!model.hasClearableRequestLogs"))
        XCTAssertTrue(iosHistoryScreen.contains("!model.hasClearableFileAccessLogs"))
        XCTAssertTrue(iosHistoryScreen.contains("!model.hasClearableCommandLogs"))
        XCTAssertTrue(controlsPlaceholder.contains("목록 기준을 준비하고 있습니다"))
        XCTAssertTrue(controlsPlaceholder.contains("(\"정렬\", \"arrow.up.arrow.down\", \"최신순으로 준비 중\")"))
        XCTAssertTrue(controlsPlaceholder.contains("(\"범위\", \"line.3.horizontal.decrease.circle\", \"연도 · 학기 · 과목\")"))
        XCTAssertTrue(deferredControls.contains("CompanionItemListControls("))
        XCTAssertFalse(deferredControls.contains("@State private var displayedOptionsKey"))
        XCTAssertFalse(deferredControls.contains("if displayedOptionsKey == optionsKey"))
        XCTAssertFalse(deferredControls.contains("CompanionItemListControlsPlaceholder()"))
        XCTAssertFalse(deferredControls.contains(".task(id: optionsKey)"))
        XCTAssertFalse(deferredControls.contains("await Task.yield()"))
        XCTAssertFalse(inlineDetail.contains(".searchable(text: $query"))
        XCTAssertFalse(syncDataPanel.contains("TextField(\"동기화 데이터 검색\", text: $query)"))
        XCTAssertTrue(syncDataPanel.contains("CompanionSearchFilterPanel(title: \"검색과 필터\", fieldPrompt: \"동기화 데이터 검색\", query: $query)"))
        XCTAssertTrue(syncDataPanel.contains("DeferredCompanionItemListControls("))
        XCTAssertTrue(syncDataPanel.contains("CompanionItemListControlsPlaceholder()"))
        XCTAssertFalse(syncDataPanel.contains("DisclosureGroup(isExpanded: $isExpanded)"))
        XCTAssertFalse(syncDataPanel.contains("DisclosureGroup(isExpanded:"))
        XCTAssertFalse(syncDataPanel.contains("@State private var isExpanded"))
        XCTAssertTrue(selectableRows.contains("@State private var visibleLimit = CompanionLargeList.initialVisibleLimit"))
        XCTAssertTrue(ios.contains("static let initialVisibleLimit = 4"))
        XCTAssertTrue(ios.contains("static let regularInitialVisibleLimit = 12"))
        XCTAssertTrue(ios.contains("static func initialVisibleLimit(horizontalSizeClass: UserInterfaceSizeClass?) -> Int"))
        XCTAssertTrue(ios.contains("horizontalSizeClass == .regular ? regularInitialVisibleLimit : initialVisibleLimit"))
        XCTAssertTrue(ios.contains("static let previewVisibleLimit = 5"))
        XCTAssertTrue(ios.contains("static let regularPreviewVisibleLimit = 8"))
        XCTAssertTrue(ios.contains("static let calendarVisibleLimit = 6"))
        XCTAssertTrue(ios.contains("static let regularCalendarVisibleLimit = 10"))
        XCTAssertTrue(ios.contains("static func previewVisibleLimit(horizontalSizeClass: UserInterfaceSizeClass?) -> Int"))
        XCTAssertTrue(ios.contains("static func calendarVisibleLimit(horizontalSizeClass: UserInterfaceSizeClass?) -> Int"))
        XCTAssertTrue(ios.contains("static let filterRebuildDelayNanoseconds: UInt64 = 8_000_000"))
        XCTAssertFalse(ios.contains("static let detailRenderDelayNanoseconds"))
        XCTAssertFalse(deferredInlineItemDetail.contains("try? await Task.sleep(nanoseconds: CompanionLargeList.detailRenderDelayNanoseconds)"))
        XCTAssertFalse(ios.contains("static let prewarmDelayNanoseconds"))
        XCTAssertTrue(ios.contains("func shouldDebounceComparedTo(_ previous: CompanionItemListInputKey?) -> Bool"))
        XCTAssertTrue(ios.contains("previous.query = query"))
        XCTAssertTrue(ios.contains("transaction.animation = nil"))
        XCTAssertTrue(ios.contains("withTransaction(transaction)"))
        XCTAssertTrue(tabRoot.contains("let model: CompanionModel"))
        XCTAssertTrue(splitRoot.contains("let model: CompanionModel"))
        XCTAssertTrue(sectionContent.contains("let model: CompanionModel"))
        XCTAssertTrue(statusScreen.contains("let model: CompanionModel"))
        XCTAssertTrue(categoryScreen.contains("let model: CompanionModel"))
        XCTAssertTrue(tasksScreen.contains("let model: CompanionModel"))
        XCTAssertTrue(settingsScreen.contains("let model: CompanionModel"))
        XCTAssertTrue(iosHistoryScreen.contains("let model: CompanionModel"))
        XCTAssertFalse(tabRoot.contains("@ObservedObject var model"))
        XCTAssertFalse(splitRoot.contains("@ObservedObject var model"))
        XCTAssertFalse(sectionContent.contains("@ObservedObject var model"))
        XCTAssertFalse(statusScreen.contains("@ObservedObject var model"))
        XCTAssertFalse(categoryScreen.contains("@ObservedObject var model"))
        XCTAssertFalse(tasksScreen.contains("@ObservedObject var model"))
        XCTAssertFalse(settingsScreen.contains("@ObservedObject var model"))
        XCTAssertFalse(iosHistoryScreen.contains("@ObservedObject var model"))
        XCTAssertTrue(selectableRows.contains("@State private var selectedItemID"))
        XCTAssertTrue(selectableRows.contains("@Environment(\\.horizontalSizeClass) private var horizontalSizeClass"))
        XCTAssertTrue(selectableRows.contains("visibleLimit = currentInitialVisibleLimit"))
        XCTAssertFalse(selectableRows.contains("@State private var deferredSelectionTask: Task<Void, Never>?"))
        XCTAssertFalse(selectableRows.contains("deferredSelectionTask?.cancel()"))
        XCTAssertTrue(selectableRows.contains("LazyVStack(alignment: .leading, spacing: 8)"))
        XCTAssertTrue(selectableRows.contains("let visibleItems = items.prefix(visibleLimit)"))
        XCTAssertTrue(selectableRows.contains("ForEach(visibleItems)"))
        XCTAssertTrue(selectableRows.contains("CompanionShowMoreRowsButton("))
        XCTAssertTrue(ios.contains("private struct CompanionShowMoreRowsButton"))
        XCTAssertTrue(ios.contains("var context: String = \"항목\""))
        XCTAssertTrue(ios.contains("Text(\"더 보기\")"))
        XCTAssertTrue(ios.contains(".frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)"))
        XCTAssertTrue(ios.contains(".accessibilityLabel(\"\\(context) 더 보기\")"))
        XCTAssertTrue(ios.contains(".accessibilityHint(\"\\(context) 목록을 \\(remainingCount)개 더 펼칩니다.\")"))
        XCTAssertTrue(ios.contains("context: category.title"))
        XCTAssertTrue(ios.contains("context: \"파일 요청 기록\""))
        XCTAssertTrue(ios.contains("context: \"서버 요청 기록\""))
        XCTAssertTrue(selectableRows.contains("ServerSyncDataRow(item: item, isSelected: selectedItemID == item.id)"))
        XCTAssertTrue(selectableRows.contains(".buttonStyle(KLMSCardButtonStyle())"))
        XCTAssertTrue(selectableRows.contains("companionPerformWithoutAnimation {\n            selectedItemID = itemID\n            onSelect(item)\n        }"))
        XCTAssertFalse(selectableRows.contains("Task.sleep"))
        XCTAssertFalse(selectableRows.contains("guard !Task.isCancelled, selectedItemID == itemID else { return }"))
        XCTAssertFalse(selectableRows.contains("await Task.yield()"))
        XCTAssertTrue(selectableRows.contains("onSelect(item)"))
        XCTAssertFalse(selectableRows.contains("guard klmsInteractionDetailDelayNanoseconds > 0 else"))
        XCTAssertFalse(selectableRows.contains("try? await Task.sleep(nanoseconds: klmsInteractionDetailDelayNanoseconds)"))
        XCTAssertFalse(inlineDetail.contains("ForEach(filtered)"))
        XCTAssertFalse(inlineDetail.contains("private var baseItems"))
        XCTAssertFalse(inlineDetail.contains("private var filteredItems"))
        XCTAssertTrue(inlineDetail.contains("let items = model.cachedDashboardItems(for: category.rawValue)"))
        XCTAssertFalse(inlineDetail.contains("let items = model.dashboardSyncItems"))
        XCTAssertTrue(inlineDetail.contains("isCategoryPrefiltered: true"))
        XCTAssertFalse(inlineDetail.contains("initialVisibleLimit(for: category)"))
        XCTAssertFalse(inlineDetail.contains("incrementVisibleLimit(for: category)"))
        XCTAssertTrue(syncDataPanel.contains("@State private var cachedListData"))
        XCTAssertTrue(syncDataPanel.contains("@State private var cachedListInputKey: CompanionItemListInputKey?"))
        XCTAssertTrue(syncDataPanel.contains("var itemsRevision: Int"))
        XCTAssertTrue(syncDataPanel.contains("itemsRevision: itemsRevision"))
        XCTAssertFalse(syncDataPanel.contains("companionItemsFingerprint(items)"))
        XCTAssertTrue(syncDataPanel.contains(".task(id: listInputKey)"))
        XCTAssertTrue(syncDataPanel.contains("await rebuildCachedListDataAfterInputSettles()"))
        XCTAssertTrue(syncDataPanel.contains("cachedListInputKey == currentKey, cachedListData != nil"))
        XCTAssertTrue(syncDataPanel.contains("CompanionItemListPreloadStore.cachedData(for: currentKey)"))
        XCTAssertTrue(syncDataPanel.contains("CompanionItemListPreloadStore.store(listData, for: inputKey)"))
        XCTAssertTrue(syncDataPanel.contains("currentKey.shouldDebounceComparedTo(cachedListInputKey)"))
        XCTAssertTrue(syncDataPanel.contains("try? await Task.sleep(nanoseconds: CompanionLargeList.filterRebuildDelayNanoseconds)"))
        XCTAssertTrue(syncDataPanel.contains("guard !Task.isCancelled, currentKey == listInputKey else { return }"))
        XCTAssertTrue(syncDataPanel.contains("guard !Task.isCancelled, inputKey == listInputKey else { return }"))
        XCTAssertTrue(syncDataPanel.contains("cachedListInputKey = inputKey"))
        XCTAssertTrue(syncDataPanel.contains("Task.detached(priority: .userInitiated)"))
        XCTAssertFalse(syncDataPanel.contains("await Task.yield()"))
        XCTAssertTrue(syncDataPanel.contains("CompanionSelectableItemListRows("))
        XCTAssertTrue(syncDataPanel.contains("itemIDs: listData.filteredItemIDs"))
        XCTAssertFalse(syncDataPanel.contains("@State private var selectedItemID"))
        XCTAssertFalse(syncDataPanel.contains("private var filteredItems"))
        XCTAssertTrue(inlineDetail.contains("let listData = await Task.detached(priority: .userInitiated)"))
        XCTAssertTrue(inlineDetail.contains("@State private var cachedListData"))
        XCTAssertTrue(inlineDetail.contains("@State private var cachedListInputKey: CompanionItemListInputKey?"))
        XCTAssertTrue(inlineDetail.contains("private var defaultListInputKey: CompanionItemListInputKey"))
        XCTAssertTrue(inlineDetail.contains("seedDefaultListDataIfAvailable()"))
        XCTAssertTrue(inlineDetail.contains("seedDefaultListDataIfAvailable(for: currentKey)"))
        XCTAssertTrue(inlineDetail.contains("model.cachedDefaultDashboardListData(for: category.rawValue)"))
        XCTAssertTrue(inlineDetail.contains(".task(id: listInputKey)"))
        XCTAssertTrue(inlineDetail.contains("await rebuildCachedListDataAfterInputSettles()"))
        XCTAssertTrue(inlineDetail.contains("cachedListInputKey == currentKey, cachedListData != nil"))
        XCTAssertTrue(inlineDetail.contains("currentKey.shouldDebounceComparedTo(cachedListInputKey)"))
        XCTAssertTrue(inlineDetail.contains("try? await Task.sleep(nanoseconds: CompanionLargeList.filterRebuildDelayNanoseconds)"))
        XCTAssertTrue(inlineDetail.contains("guard !Task.isCancelled, inputKey == listInputKey else { return }"))
        XCTAssertTrue(inlineDetail.contains("cachedListInputKey = inputKey"))
        XCTAssertFalse(inlineDetail.contains("await Task.yield()"))
        XCTAssertTrue(inlineDetail.contains("CompanionInlineItemRowsView("))
        XCTAssertTrue(inlineDetail.contains("itemIDs: listData.filteredItemIDs"))
        XCTAssertTrue(inlineDetail.contains("DeferredCompanionItemListControls("))
        XCTAssertTrue(inlineDetail.contains("presentation: itemPresentation"))
        XCTAssertTrue(inlineDetail.contains("externalSelectedItemID: externallySelectedItemID"))
        XCTAssertTrue(inlineDetail.contains("onSelectItem: onSelectItem"))
        XCTAssertTrue(inlineDetail.contains("let model: CompanionModel"))
        XCTAssertFalse(inlineDetail.contains("@ObservedObject var model"))
        XCTAssertTrue(inlineRows.contains("presentation == .externalDetail"))
        XCTAssertTrue(inlineRows.contains("@State private var optimisticExternalSelectedItemID: String?"))
        XCTAssertFalse(inlineRows.contains("@State private var deferredExternalSelectionTask: Task<Void, Never>?"))
        XCTAssertTrue(inlineRows.contains("optimisticExternalSelectedItemID ?? externalSelectedItemID"))
        XCTAssertTrue(inlineRows.contains("companionPerformWithoutAnimation {\n                optimisticExternalSelectedItemID = itemID\n                onSelectItem(item)\n            }"))
        XCTAssertFalse(inlineRows.contains("deferredExternalSelectionTask?.cancel()"))
        XCTAssertFalse(inlineRows.contains("Task.sleep"))
        XCTAssertFalse(inlineRows.contains("await Task.yield()"))
        XCTAssertFalse(inlineRows.contains("guard !Task.isCancelled, optimisticExternalSelectedItemID == itemID else { return }"))
        XCTAssertTrue(inlineRows.contains("onSelectItem(item)"))
        XCTAssertTrue(inlineRows.contains("accessorySystemImage(isSelected: isSelected)"))
        XCTAssertTrue(inlineRows.contains(".buttonStyle(KLMSCardButtonStyle())"))
        XCTAssertFalse(inlineRows.contains("@State private var detailItemID"))
        XCTAssertTrue(inlineRows.contains("@State private var visibleLimit = CompanionLargeList.initialVisibleLimit"))
        XCTAssertTrue(inlineRows.contains("@Environment(\\.horizontalSizeClass) private var horizontalSizeClass"))
        XCTAssertTrue(inlineRows.contains("CompanionLargeList.initialVisibleLimit(horizontalSizeClass: horizontalSizeClass)"))
        XCTAssertTrue(inlineRows.contains("LazyVStack(alignment: .leading, spacing: 8)"))
        XCTAssertTrue(inlineRows.contains("ForEach(visibleItems)"))
        XCTAssertTrue(inlineRows.contains("CompanionShowMoreRowsButton("))
        XCTAssertFalse(inlineRows.contains("var itemIDs: Set<String>? = nil"))
        XCTAssertTrue(inlineRows.contains("var itemIDs: Set<String>"))
        XCTAssertTrue(inlineRows.contains("private func containsItemID(_ itemID: String) -> Bool"))
        XCTAssertFalse(inlineRows.contains("return items.contains { $0.id == itemID }"))
        XCTAssertTrue(inlineRows.contains("return itemIDs.contains(itemID)"))
        XCTAssertFalse(selectableRows.contains("var itemIDs: Set<String>? = nil"))
        XCTAssertTrue(selectableRows.contains("var itemIDs: Set<String>"))
        XCTAssertTrue(selectableRows.contains("private func containsItemID(_ itemID: String) -> Bool"))
        XCTAssertFalse(selectableRows.contains("return items.contains { $0.id == itemID }"))
        XCTAssertTrue(selectableRows.contains("return itemIDs.contains(itemID)"))
        XCTAssertFalse(inlineRows.contains("Self.initialVisibleLimit(for: category)"))
        XCTAssertFalse(ios.contains("private struct DashboardMetricDetailPanel"))
        XCTAssertFalse(ios.contains("let filtered = filteredItems"))
        XCTAssertFalse(ios.contains("let visibleItems = filtered.prefix(visibleLimit)"))
        XCTAssertTrue(inlineDetail.contains("@State private var calendarVisibleLimit = CompanionLargeList.calendarVisibleLimit"))
        XCTAssertTrue(inlineDetail.contains("@Environment(\\.horizontalSizeClass) private var horizontalSizeClass"))
        XCTAssertTrue(inlineDetail.contains("CompanionLargeList.calendarVisibleLimit(horizontalSizeClass: horizontalSizeClass)"))
        XCTAssertTrue(inlineDetail.contains("let visibleChanges = calendarChanges.prefix(calendarVisibleLimit)"))
        XCTAssertTrue(inlineDetail.contains("ForEach(visibleChanges)"))
        XCTAssertFalse(inlineDetail.contains("ForEach(calendarChanges)"))
        XCTAssertFalse(inlineRows.contains("@State private var displayedInlineItemID"))
        XCTAssertFalse(inlineRows.contains("@State private var inlineDetailTask"))
        XCTAssertTrue(inlineRows.contains("presentation == .inlineDetail && selectedItemID == item.id"))
        XCTAssertFalse(ios.contains("private struct CompanionInlineDetailPreparingView"))
        XCTAssertFalse(deferredInlineItemDetail.contains("@State private var isReady = false"))
        XCTAssertFalse(deferredInlineItemDetail.contains("@State private var detailTask: Task<Void, Never>?"))
        XCTAssertFalse(deferredInlineItemDetail.contains("CompanionInlineDetailPreparingView()"))
        XCTAssertTrue(deferredInlineItemDetail.contains("ServerSyncItemInlineDetailPanel(item: item, model: model)"))
        XCTAssertFalse(deferredInlineItemDetail.contains("await Task.yield()"))
        XCTAssertFalse(deferredInlineItemDetail.contains("try? await Task.sleep(nanoseconds: CompanionLargeList.detailRenderDelayNanoseconds)"))
        XCTAssertFalse(deferredInlineItemDetail.contains("guard !Task.isCancelled else { return }"))
        XCTAssertFalse(deferredInlineItemDetail.contains(".onDisappear"))
        XCTAssertTrue(deferredInlineItemDetail.contains(".id(item.id)"))
        XCTAssertFalse(inlineRows.contains("deferInlineDetail"))
        XCTAssertTrue(inlineRows.contains("clearStaleInlineSelectionIfNeeded()"))
        XCTAssertTrue(inlineRows.contains("clearStaleExternalSelectionIfNeeded()"))
        XCTAssertFalse(inlineRows.contains("deferredExternalSelectionTask?.cancel()"))
        XCTAssertFalse(inlineRows.contains("guard klmsInteractionDetailDelayNanoseconds > 0 else"))
        XCTAssertFalse(inlineRows.contains("try? await Task.sleep(nanoseconds: klmsInteractionDetailDelayNanoseconds)"))
        XCTAssertTrue(serverSyncDataRow.contains(".accessibilityElement(children: .ignore)"))
        XCTAssertTrue(serverSyncDataRow.contains(".accessibilityLabel(snapshot.accessibilityLabel)"))
        XCTAssertTrue(serverSyncDataRow.contains(".accessibilityValue(isSelected ? \"선택됨\" : \"선택 안 됨\")"))
        XCTAssertTrue(serverSyncDataRow.contains("var snapshot: ServerSyncRowSnapshot"))
        XCTAssertTrue(serverSyncDataRow.contains("Text(snapshot.kindName)"))
        XCTAssertTrue(serverSyncDataRow.contains("Text(snapshot.metadata)"))
        XCTAssertFalse(serverSyncDataRow.contains("private var rowSummary"))
        XCTAssertFalse(inlineRows.contains("private func increaseVisibleLimit()"))
        XCTAssertFalse(selectableRows.contains("private func increaseVisibleLimit()"))
        XCTAssertFalse(inlineRows.contains("@ObservedObject var model"))
        XCTAssertTrue(inlineItemDetail.contains("let model: CompanionModel"))
        XCTAssertFalse(inlineItemDetail.contains("@ObservedObject var model"))
        XCTAssertTrue(workstationExternalDetail.contains("let model: CompanionModel"))
        XCTAssertFalse(workstationExternalDetail.contains("@ObservedObject var model"))
        XCTAssertTrue(remoteItemToggleButton.contains("let model: CompanionModel"))
        XCTAssertFalse(remoteItemToggleButton.contains("@ObservedObject var model"))
        XCTAssertFalse(compactSelectedRow.contains("@ObservedObject var model"))
        XCTAssertFalse(inlineDetail.contains("private var filteredItems"))
        XCTAssertTrue(workstationCategory.contains("itemPresentation: .externalDetail"))
        XCTAssertTrue(workstationCategory.contains("let model: CompanionModel"))
        XCTAssertFalse(workstationCategory.contains("@ObservedObject var model"))
        XCTAssertTrue(workstationCategory.contains("categoryRegularWorkspace"))
        XCTAssertTrue(workstationCategory.contains("categoryListPanel"))
        XCTAssertTrue(workstationCategory.contains("categoryDetailPanel"))
        XCTAssertFalse(workstationCategory.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertFalse(workstationCategoryRegularWorkspace.contains("VStack(alignment: .leading, spacing: 12)"))
        XCTAssertTrue(workstationCategory.contains("externallySelectedItemID: activeSelectedItemID"))
        XCTAssertTrue(workstationCategory.contains("private var activeSelectedItemID: String? {\n        selectedItemID\n    }"))
        XCTAssertFalse(workstationCategory.contains("selectedItemID ?? items.first?.id"))
        XCTAssertTrue(workstationCategory.contains("return model.cachedVisibleDashboardItem(for: selectedItemID, categoryID: category.rawValue)"))
        XCTAssertTrue(workstationCategory.contains(".onAppear {"))
        XCTAssertTrue(workstationCategory.contains(".onChange(of: itemsResetKey)"))
        XCTAssertTrue(workstationCategory.contains("private func clearStaleExternalSelectionIfNeeded()"))
        XCTAssertTrue(workstationCategory.contains("model.cachedVisibleDashboardItem(for: selectedItemID, categoryID: category.rawValue) != nil"))
        XCTAssertFalse(workstationCategory.contains("guard let first = items.first else"))
        XCTAssertFalse(workstationCategory.contains("selectedItemID = first.id"))
        XCTAssertTrue(workstationCategory.contains("companionPerformWithoutAnimation {\n            selectedItemID = nil\n        }"))
        XCTAssertFalse(workstationCategory.contains("displayedSelectedItem = first"))
        XCTAssertFalse(workstationCategory.contains("displayedSelectedItem = refreshed"))
        XCTAssertTrue(workstationCategory.contains("emptyMessage: \"목록에서 항목을 선택해 주세요.\""))
        XCTAssertFalse(workstationCategory.contains("@State private var displayedSelectedItem: ServerRelaySyncItem?"))
        XCTAssertFalse(workstationCategory.contains("@State private var deferredDetailSelectionTask"))
        XCTAssertFalse(workstationCategory.contains("@State private var displayedSelectedItemID"))
        XCTAssertFalse(workstationCategory.contains("@State private var externalDetailTask"))
        XCTAssertFalse(workstationCategory.contains("WorkstationExternalDetailPreparingPanel"))
        XCTAssertTrue(workstationCategory.contains("if activeSelectedItemID == item.id {\n            return\n        }"))
        XCTAssertFalse(workstationCategory.contains("activeSelectedItemID == item.id && displayedSelectedItemID == item.id"))
        XCTAssertFalse(workstationCategory.contains("deferExternalDetail(item)"))
        XCTAssertFalse(workstationCategory.contains("deferredDetailSelectionTask"))
        XCTAssertFalse(workstationCategory.contains("Task.sleep"))
        XCTAssertFalse(workstationCategory.contains("refreshExternalSelection()"))
        XCTAssertTrue(workstationCategory.contains("WorkstationExternalDetailPanel"))
        XCTAssertTrue(workstationCategory.contains("minWidth: CompanionWorkstationMetrics.detailColumnMinWidth"))
        XCTAssertTrue(workstationCategory.contains("idealWidth: CompanionWorkstationMetrics.detailColumnIdealWidth"))
        XCTAssertFalse(workstationCategory.contains("minWidth: CompanionWorkstationMetrics.compactListColumnMinWidth"))
        XCTAssertFalse(workstationCategory.contains("idealWidth: CompanionWorkstationMetrics.compactListColumnIdealWidth"))
        XCTAssertFalse(workstationCategory.contains("maxWidth: CompanionWorkstationMetrics.compactListColumnMaxWidth"))
        XCTAssertFalse(workstationCategory.contains("minWidth: CompanionWorkstationMetrics.compactDetailColumnMinWidth"))
        XCTAssertFalse(workstationCategory.contains("idealWidth: CompanionWorkstationMetrics.compactDetailColumnIdealWidth"))
        XCTAssertTrue(workstationCategory.contains("selectedItemID = item.id"))
        XCTAssertFalse(workstationCategory.contains("displayedSelectedItem = item"))
        XCTAssertFalse(workstationCategory.contains("let item = items.first(where: { $0.id == displayedSelectedItemID })"))
        XCTAssertFalse(workstationTasks.contains("taskPanel(.assignments)"))
        XCTAssertTrue(workstationTasks.contains("let model: CompanionModel"))
        XCTAssertFalse(workstationTasks.contains("@ObservedObject var model"))
        XCTAssertTrue(workstationTasks.contains("tasksRegularWorkspace"))
        XCTAssertTrue(workstationTasks.contains("tasksListPanel"))
        XCTAssertTrue(workstationTasks.contains("tasksDetailPanel"))
        XCTAssertFalse(workstationTasks.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertFalse(workstationTasksRegularWorkspace.contains("VStack(alignment: .leading, spacing: 12)"))
        XCTAssertFalse(workstationTasks.contains("taskPanel(.exams)"))
        XCTAssertTrue(workstationTasks.contains("WorkstationTaskCategorySelector("))
        XCTAssertTrue(workstationTasks.contains("taskPanel(selectedTaskCategory)"))
        XCTAssertTrue(workstationTasks.contains(".id(selectedTaskCategory.rawValue)"))
        XCTAssertTrue(workstationTasks.contains("private var activeSelectedItemID: String? {\n        selectedItemID\n    }"))
        XCTAssertFalse(workstationTasks.contains("selectedItemID ?? combinedItems.first?.id"))
        XCTAssertTrue(workstationTasks.contains("return model.cachedVisibleDashboardItem(for: selectedItemID, categoryID: selectedTaskCategory.rawValue)"))
        XCTAssertTrue(workstationTasks.contains(".onAppear {"))
        XCTAssertTrue(workstationTasks.contains("normalizeSelectedTaskCategory()"))
        XCTAssertTrue(workstationTasks.contains(".onChange(of: categoryAvailabilityKey)"))
        XCTAssertTrue(workstationTasks.contains(".onChange(of: selectedTaskCategory)"))
        XCTAssertTrue(workstationTasks.contains(".onChange(of: itemsResetKey)"))
        XCTAssertTrue(workstationTasks.contains("private func clearStaleExternalSelectionIfNeeded()"))
        XCTAssertFalse(workstationTasks.contains("guard let first = combinedItems.first else"))
        XCTAssertTrue(workstationTasks.contains("model.cachedVisibleDashboardItem(for: selectedItemID, categoryID: selectedTaskCategory.rawValue) != nil"))
        XCTAssertFalse(workstationTasks.contains("guard let first = selectedCategoryItems.first else"))
        XCTAssertFalse(workstationTasks.contains("selectedItemID = first.id"))
        XCTAssertTrue(workstationTasks.contains("companionPerformWithoutAnimation {\n            selectedItemID = nil\n        }"))
        XCTAssertFalse(workstationTasks.contains("displayedSelectedItem = first"))
        XCTAssertFalse(workstationTasks.contains("displayedSelectedItem = refreshed"))
        XCTAssertTrue(workstationTasks.contains("emptyMessage: \"목록에서 과제나 시험을 선택해 주세요.\""))
        XCTAssertFalse(workstationTasks.contains("@State private var displayedSelectedItem: ServerRelaySyncItem?"))
        XCTAssertFalse(workstationTasks.contains("@State private var deferredDetailSelectionTask"))
        XCTAssertFalse(workstationTasks.contains("@State private var displayedSelectedItemID"))
        XCTAssertFalse(workstationTasks.contains("@State private var externalDetailTask"))
        XCTAssertFalse(workstationTasks.contains("WorkstationExternalDetailPreparingPanel"))
        XCTAssertTrue(workstationTasks.contains("if activeSelectedItemID == item.id {\n            return\n        }"))
        XCTAssertFalse(workstationTasks.contains("activeSelectedItemID == item.id && displayedSelectedItemID == item.id"))
        XCTAssertFalse(workstationTasks.contains("deferExternalDetail(item)"))
        XCTAssertFalse(workstationTasks.contains("deferredDetailSelectionTask"))
        XCTAssertFalse(workstationTasks.contains("Task.sleep"))
        XCTAssertFalse(workstationTasks.contains("refreshExternalSelection()"))
        XCTAssertTrue(workstationTasks.contains("WorkstationExternalDetailPanel"))
        XCTAssertTrue(workstationTasks.contains("minWidth: CompanionWorkstationMetrics.detailColumnMinWidth"))
        XCTAssertTrue(workstationTasks.contains("idealWidth: CompanionWorkstationMetrics.detailColumnIdealWidth"))
        XCTAssertFalse(workstationTasks.contains("minWidth: CompanionWorkstationMetrics.compactListColumnMinWidth"))
        XCTAssertFalse(workstationTasks.contains("idealWidth: CompanionWorkstationMetrics.compactListColumnIdealWidth"))
        XCTAssertFalse(workstationTasks.contains("maxWidth: CompanionWorkstationMetrics.compactListColumnMaxWidth"))
        XCTAssertFalse(workstationTasks.contains("minWidth: CompanionWorkstationMetrics.compactDetailColumnMinWidth"))
        XCTAssertFalse(workstationTasks.contains("idealWidth: CompanionWorkstationMetrics.compactDetailColumnIdealWidth"))
        XCTAssertTrue(workstationTasks.contains("selectedItemID = item.id"))
        XCTAssertFalse(workstationTasks.contains("displayedSelectedItem = item"))
        XCTAssertFalse(workstationTasks.contains("let item = combinedItems.first(where: { $0.id == displayedSelectedItemID })"))
        XCTAssertFalse(workstationTasks.contains("combinedItems"))
        XCTAssertTrue(categoryScreen.contains("if horizontalSizeClass == .regular && category == .calendar"))
        XCTAssertTrue(categoryScreen.contains("WorkstationCalendarWorkspace(model: model)"))
        XCTAssertTrue(workstationCalendar.contains("let model: CompanionModel"))
        XCTAssertFalse(workstationCalendar.contains("@ObservedObject var model"))
        XCTAssertTrue(workstationCalendar.contains("calendarRegularWorkspace"))
        XCTAssertFalse(workstationCalendar.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertFalse(workstationCalendarRegularWorkspace.contains("VStack(alignment: .leading, spacing: 12)"))
        XCTAssertTrue(workstationCalendar.contains("model.visibleCalendarChanges()"))
        XCTAssertTrue(workstationCalendar.contains("HStack(alignment: .top, spacing: CompanionWorkstationMetrics.columnSpacing)"))
        XCTAssertTrue(workstationCalendar.contains("calendarListPanel"))
        XCTAssertTrue(workstationCalendar.contains("calendarDetailPanel"))
        XCTAssertTrue(workstationCalendar.contains("minWidth: CompanionWorkstationMetrics.listColumnMinWidth"))
        XCTAssertTrue(workstationCalendar.contains("idealWidth: CompanionWorkstationMetrics.listColumnIdealWidth"))
        XCTAssertTrue(workstationCalendar.contains("maxWidth: CompanionWorkstationMetrics.listColumnMaxWidth"))
        XCTAssertTrue(workstationCalendar.contains("minWidth: CompanionWorkstationMetrics.detailColumnMinWidth"))
        XCTAssertTrue(workstationCalendar.contains("idealWidth: CompanionWorkstationMetrics.detailColumnIdealWidth"))
        XCTAssertFalse(workstationCalendar.contains("minWidth: CompanionWorkstationMetrics.compactListColumnMinWidth"))
        XCTAssertFalse(workstationCalendar.contains("idealWidth: CompanionWorkstationMetrics.compactListColumnIdealWidth"))
        XCTAssertFalse(workstationCalendar.contains("maxWidth: CompanionWorkstationMetrics.compactListColumnMaxWidth"))
        XCTAssertFalse(workstationCalendar.contains("minWidth: CompanionWorkstationMetrics.compactDetailColumnMinWidth"))
        XCTAssertFalse(workstationCalendar.contains("idealWidth: CompanionWorkstationMetrics.compactDetailColumnIdealWidth"))
        XCTAssertTrue(workstationCalendar.contains("RemoteCalendarActionPanel()"))
        XCTAssertTrue(workstationCalendar.contains("DashboardCalendarChangeDetailRow("))
        XCTAssertTrue(workstationCalendar.contains("activeAction: model.activeCalendarAction(for: selectedChange)"))
        XCTAssertTrue(workstationCalendar.contains("await model.createCalendarAction(action, change: selectedChange, edit: edit)"))
        XCTAssertFalse(workstationCalendar.contains("@State private var displayedSelectedChangeID"))
        XCTAssertFalse(workstationCalendar.contains("@State private var deferredDetailSelectionTask"))
        XCTAssertTrue(workstationCalendar.contains("@State private var calendarVisibleLimit = CompanionLargeList.regularCalendarVisibleLimit"))
        XCTAssertTrue(workstationCalendar.contains("calendarVisibleLimit = CompanionLargeList.regularCalendarVisibleLimit"))
        XCTAssertFalse(workstationCalendar.contains("@State private var externalDetailTask"))
        XCTAssertFalse(workstationCalendar.contains("WorkstationExternalDetailPreparingPanel"))
        XCTAssertFalse(workstationCalendar.contains("deferExternalDetail(change)"))
        XCTAssertFalse(workstationCalendar.contains("deferredDetailSelectionTask"))
        XCTAssertFalse(workstationCalendar.contains("Task.sleep"))
        XCTAssertTrue(workstationCalendar.contains("return model.visibleCalendarChange(for: selectedChangeID)"))
        XCTAssertTrue(workstationCalendar.contains("model.visibleCalendarChange(for: selectedChangeID) != nil"))
        XCTAssertTrue(workstationCalendar.contains("selectedChangeID = change.id"))
        XCTAssertFalse(workstationCalendar.contains("displayedSelectedChange = change"))
        XCTAssertFalse(workstationCalendar.contains("selectedChangeID = first.id"))
        XCTAssertFalse(workstationCalendar.contains("displayedSelectedChange = first"))
        XCTAssertFalse(workstationCalendar.contains("displayedSelectedChange = refreshed"))
        XCTAssertTrue(workstationCalendar.contains("companionPerformWithoutAnimation {\n            selectedChangeID = nil\n        }"))
        XCTAssertTrue(workstationCalendar.contains("remainingCount: changes.count - calendarVisibleLimit"))
        XCTAssertTrue(workstationCalendar.contains("context: \"캘린더 변경\""))
        XCTAssertTrue(workstationCalendar.contains(".frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)"))
        XCTAssertTrue(workstationCalendar.contains(".accessibilityHint(\"상세 패널에 일정 상세와 처리 버튼을 표시합니다.\")"))
        XCTAssertTrue(workstationCalendar.contains("case \"created\", \"mail\":"))
        XCTAssertTrue(workstationOverview.contains("var data: WorkstationDashboardOverviewData"))
        XCTAssertTrue(workstationOverview.contains("var showsMetrics = true"))
        XCTAssertTrue(workstationOverview.contains("var onOpenCategory: (DashboardMetricCategory) -> Void"))
        XCTAssertTrue(workstationOverview.contains("nonisolated static func == (lhs: WorkstationDashboardOverviewPanel, rhs: WorkstationDashboardOverviewPanel) -> Bool"))
        XCTAssertTrue(workstationOverview.contains("onOpenCategory(metric.category)"))
        XCTAssertTrue(workstationOverview.contains("WorkstationDashboardPreviewSection("))
        XCTAssertTrue(workstationOverview.contains("onOpenCategory: onOpenCategory"))
        XCTAssertTrue(workstationOverview.contains("MetricSummary(category: .files"))
        XCTAssertTrue(workstationOverview.contains("MetricSummary(category: .assignments"))
        XCTAssertTrue(workstationOverview.contains("MetricSummary(category: .notices"))
        XCTAssertTrue(workstationOverview.contains("MetricSummary(category: .exams"))
        XCTAssertFalse(workstationOverview.contains("@ObservedObject var model"))
        XCTAssertFalse(workstationOverview.contains("let model: CompanionModel"))
        XCTAssertTrue(workstationPreviewSection.contains("var category: DashboardMetricCategory"))
        XCTAssertTrue(workstationPreviewSection.contains("var onOpenCategory: (DashboardMetricCategory) -> Void"))
        XCTAssertTrue(workstationPreviewSection.contains("Button {\n                        onOpenCategory(category)"))
        XCTAssertTrue(workstationPreviewSection.contains(".buttonStyle(KLMSCardButtonStyle())"))
        XCTAssertTrue(workstationPreviewSection.contains(".accessibilityLabel(\"\\(title) \\(item.title.nilIfEmpty ?? \"항목\") 상세 열기\")"))
        XCTAssertTrue(workstationChangeSummary.contains("var status: SanitizedRemoteStatus"))
        XCTAssertFalse(workstationChangeSummary.contains("@ObservedObject var model"))
        XCTAssertFalse(workstationChangeSummary.contains("let model: CompanionModel"))
        XCTAssertFalse(ios.contains("private struct WorkstationExternalDetailPreparingPanel"))
        XCTAssertTrue(ios.contains("static let logVisibleLimit = 10"))
        XCTAssertTrue(recentFileRequests.contains("LazyVStack(spacing: 8)"))
        XCTAssertTrue(recentFileRequests.contains("ForEach(visibleRequests)"))
        XCTAssertTrue(recentFileRequests.contains("remainingCount: requests.count - visibleRequests.count"))
        XCTAssertTrue(recentFileRequests.contains("context: \"파일 요청 기록\""))
        XCTAssertTrue(recentFileRequests.contains("visibleLimit = CompanionLargeList.logVisibleLimit"))
        XCTAssertFalse(recentFileRequests.contains("ForEach(requests.prefix(30))"))
        XCTAssertTrue(recentServerRequests.contains("ForEach(visibleEntries)"))
        XCTAssertTrue(recentServerRequests.contains("remainingCount: entries.count - visibleEntries.count"))
        XCTAssertTrue(recentServerRequests.contains("context: \"서버 요청 기록\""))
        XCTAssertTrue(recentRemoteCommands.contains("LazyVStack(spacing: 8)"))
        XCTAssertTrue(recentRemoteCommands.contains("ForEach(visibleCommands)"))
        XCTAssertTrue(recentRemoteCommands.contains("remainingCount: commands.count - visibleCommands.count"))
        XCTAssertTrue(recentRemoteCommands.contains("context: \"최근 요청 기록\""))
        XCTAssertFalse(recentRemoteCommands.contains("ForEach(commands.prefix(30))"))
        XCTAssertFalse(recentRemoteCommands.contains("최근 30개만 표시합니다."))
    }

    func testIOSCalendarDetailHasMailPasteAnalyzerAndSharedCalendarActionLabels() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let iosRoot = packageRoot.appendingPathComponent("Sources/KLMSiOS/KLMSiOSApp.swift")
        let ios = try String(contentsOf: iosRoot, encoding: .utf8)
        let statusScreen = try sourceStructBody(named: "CompanionStatusScreen", in: ios)
        let dashboardInlineDetail = try sourceStructBody(named: "DashboardCategoryInlineDetailPanel", in: ios)
        let remoteChangeSummary = try sourceStructBody(named: "RemoteDashboardChangeSummary", in: ios)
        let mailPastePanel = try sourceStructBody(named: "MailPasteAnalyzerPanel", in: ios)
        let mailPasteResult = try sourceStructBodies(
            named: ["MailPasteAnalysisResultView", "MailPasteAnalysisResultContent"],
            in: ios
        )
        let mailPasteResultContent = try sourceStructBody(named: "MailPasteAnalysisResultContent", in: ios)
        let mailAnalysisProcess = try sourceStructBody(named: "MailAnalysisProcessView", in: ios)
        let mailPasteStartAnalysis = try sourceBody(
            after: "private func startAnalysis(debounceNanos: UInt64? = nil, force: Bool = false)",
            in: mailPastePanel,
            description: "iOS mail paste startAnalysis"
        )
        let mailPasteAnalyzer = try sourceBody(
            after: "private enum MailPasteAnalyzer",
            in: ios,
            description: "iOS mail paste analyzer"
        )
        let companionDateParsingCache = try sourceBody(
            after: "private enum CompanionDateParsingCache",
            in: ios,
            description: "iOS companion date parsing cache"
        )
        let remoteCalendarPanel = try sourceStructBody(named: "RemoteCalendarActionPanel", in: ios)

        XCTAssertTrue(mailPastePanel.contains(".accessibilityLabel(\"메일·캘린더 분석 \\(analysis.isEmpty ? \"입력 대기\" : analysis.kind.title) \\(isExpanded ? \"펼쳐짐\" : \"접힘\")\")"))
        XCTAssertTrue(mailPastePanel.contains(".frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)"))
        XCTAssertTrue(statusScreen.contains("selectedChangeSummary"))
        XCTAssertTrue(statusScreen.contains("@State private var displayedDashboardPreview"))
        XCTAssertFalse(statusScreen.contains("@State private var displayedChangeSummary"))
        XCTAssertFalse(statusScreen.contains("@State private var deferredStatusDetailTask"))
        XCTAssertFalse(statusScreen.contains("@State private var dashboardDetailTask"))
        XCTAssertFalse(statusScreen.contains("if horizontalSizeClass != .regular, selectedChangeSummary != nil || displayedChangeSummary != nil"))
        XCTAssertFalse(statusScreen.contains("if horizontalSizeClass != .regular {\n                statusDetailColumn"))
        XCTAssertFalse(statusScreen.contains("displayedChangeSummary: displayedChangeSummary"))
        XCTAssertFalse(statusScreen.contains("displayedChangeSummary = nil"))
        XCTAssertFalse(statusScreen.contains("상세 준비 중"))
        XCTAssertFalse(remoteChangeSummary.contains("CompanionDashboardDetailPreparingView"))
        XCTAssertTrue(remoteChangeSummary.contains("RemoteChangeSummaryDetailPanel("))
        XCTAssertTrue(remoteChangeSummary.contains("changedItems: model.cachedChangeSummaryItems(for: kind.rawValue)"))
        XCTAssertTrue(remoteChangeSummary.contains("changedCalendarItems: model.cachedChangeSummaryCalendarChanges(for: kind.rawValue)"))
        XCTAssertTrue(remoteChangeSummary.contains("fileCleanupReports: model.cachedFileCleanupReportsForDashboard()"))
        XCTAssertFalse(statusScreen.contains("CompanionDashboardDetailPreparingView"))
        XCTAssertFalse(statusScreen.contains("try? await Task.sleep(nanoseconds: CompanionLargeList.detailRenderDelayNanoseconds)"))
        XCTAssertTrue(statusScreen.contains("await Task.yield()"))
        XCTAssertFalse(statusScreen.contains("dashboardDetailTask?.cancel()"))
        XCTAssertFalse(statusScreen.contains("deferredStatusDetailTask?.cancel()"))
        XCTAssertTrue(statusScreen.contains("RemoteChangeSummaryDetailPanel"))
        let dashboardSyncCard = try sourceStructBodies(
            named: ["RemoteDashboardSyncCard", "RemoteDashboardSyncSnapshot", "RemoteDashboardSyncCardContent"],
            in: ios
        )

        XCTAssertTrue(dashboardSyncCard.contains("MailPasteAnalyzerPanel"))
        XCTAssertFalse(ios.contains("private struct RemoteCommandPanel"))
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
        XCTAssertTrue(ios.contains("private enum CompanionDateParsingCache"))
        XCTAssertTrue(mailPasteAnalyzer.contains("CompanionDateParsingCache.mailCalendarInputFormatter()"))
        XCTAssertTrue(mailPasteAnalyzer.contains("CompanionDateParsingCache.mailParseFormatter()"))
        XCTAssertFalse(mailPasteAnalyzer.contains("let formatter = DateFormatter()"))
        XCTAssertTrue(ios.contains("CompanionDateParsingCache.isoFormatter(fractionalSeconds: true)"))
        XCTAssertTrue(companionDateParsingCache.contains("Thread.current.threadDictionary"))
        XCTAssertTrue(mailPastePanel.contains("@State private var deferredAnalysisTask"))
        XCTAssertTrue(mailPastePanel.contains("@State private var latestAnalysisInputKey"))
        XCTAssertTrue(mailPastePanel.contains("scheduleAnalysis()"))
        XCTAssertTrue(mailPastePanel.contains("guard !mailText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else"))
        XCTAssertTrue(mailPastePanel.contains("latestAnalysisInputKey = \"\""))
        XCTAssertTrue(mailPastePanel.contains("private func startAnalysis(debounceNanos: UInt64? = nil, force: Bool = false)"))
        XCTAssertTrue(mailPastePanel.contains("startAnalysis(force: true)"))
        XCTAssertTrue(mailPastePanel.contains("let inputKey = \"\\(revision):\\(text.count):\\(text.hashValue)\""))
        XCTAssertTrue(mailPastePanel.contains("if !force && inputKey == latestAnalysisInputKey"))
        let duplicateGuardIndex = try XCTUnwrap(mailPasteStartAnalysis.range(of: "if !force && inputKey == latestAnalysisInputKey")?.lowerBound)
        let startCancelIndex = try XCTUnwrap(mailPasteStartAnalysis.range(of: "deferredAnalysisTask?.cancel()")?.lowerBound)
        XCTAssertLessThan(duplicateGuardIndex, startCancelIndex)
        XCTAssertTrue(mailPastePanel.contains("let nextAnalysis = await Task.detached(priority: .userInitiated)"))
        XCTAssertFalse(mailPastePanel.contains("analysis = MailPasteAnalyzer.analyze(mailText, syncItems: model.dashboardSyncItems)"))
        XCTAssertFalse(mailPastePanel.contains("analysis = MailPasteAnalyzer.analyze(text, syncItems: items)"))
        XCTAssertTrue(mailPastePanel.contains(".buttonStyle(KLMSCardButtonStyle())"))
        XCTAssertTrue(mailPastePanel.contains("LazyVGrid(columns: [GridItem(.adaptive(minimum: 132)"))
        XCTAssertFalse(mailPastePanel.contains("HStack(spacing: 8) {\n                        Button {\n                            pasteFromClipboard()"))
        XCTAssertTrue(mailPastePanel.contains("Label(\"입력 비우기\", systemImage: \"xmark.circle\")"))
        XCTAssertGreaterThanOrEqual(mailPastePanel.components(separatedBy: ".frame(maxWidth: .infinity)").count - 1, 3)
        XCTAssertFalse(mailPastePanel.contains("Label(\"입력 비우기\", systemImage: \"trash\")"))
        XCTAssertTrue(mailPastePanel.contains(".onChange(of: model.dashboardSyncItemsRevision)"))
        XCTAssertFalse(mailPastePanel.contains(".onChange(of: model.syncItems)"))
        XCTAssertFalse(mailPasteResultContent.contains("@ObservedObject var model"))
        XCTAssertTrue(mailPasteResult.contains(".equatable()"))
        XCTAssertTrue(mailPasteResult.contains("registeredDashboardItem: registeredDashboardItem"))
        XCTAssertFalse(mailPasteResult.contains("isSubmitting: model.isSubmitting"))
        XCTAssertFalse(mailPasteResultContent.contains("var isSubmitting: Bool"))
        XCTAssertFalse(mailPasteResultContent.contains(".disabled(isSubmitting)"))
        XCTAssertTrue(mailPasteResult.contains(".buttonStyle(KLMSCardButtonStyle())"))
        XCTAssertFalse(mailAnalysisProcess.contains("DisclosureGroup"))
        XCTAssertFalse(mailAnalysisProcess.contains("@State private var isExpanded"))
        XCTAssertFalse(mailAnalysisProcess.contains(".buttonStyle(KLMSCardButtonStyle())"))
        XCTAssertTrue(mailAnalysisProcess.contains("Text(\"\\(steps.count)단계\")"))
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
        XCTAssertTrue(ios.contains("private enum MailAnalysisStepTone: String, Equatable, Sendable"))
        XCTAssertTrue(ios.contains("private struct MailAnalysisStep: Identifiable, Equatable, Sendable"))
        XCTAssertTrue(ios.contains("private enum MailPasteDetectedKind: String, Sendable"))
        XCTAssertTrue(ios.contains("private struct MailPasteAnalysis: Equatable, Sendable"))
        XCTAssertTrue(ios.contains("isMailGreetingOrSignature"))
        XCTAssertTrue(ios.contains("exam schedule"))
        XCTAssertTrue(ios.contains("yyyy MMMM d h:mm a"))
        XCTAssertTrue(ios.contains("월요일|화요일|수요일"))
        XCTAssertTrue(ios.contains("normalizeMailText(item.searchText).contains(normalizedDue)"))
        XCTAssertTrue(ios.contains("Mac 캘린더에 등록"))
        XCTAssertTrue(ios.contains("MailDashboardItemEditForm"))
        XCTAssertTrue(ios.contains("submitRemoveMailDashboardItem"))
        XCTAssertTrue(ios.contains("action: .mailDashboardRemove"))
        XCTAssertTrue(ios.contains("let previousMailDashboardItems = mailDashboardItems"))
        XCTAssertTrue(ios.contains("mailDashboardItems = previousMailDashboardItems"))
        XCTAssertTrue(ios.contains("Label(\"등록\", systemImage: \"plus.circle\")"))
        XCTAssertTrue(ios.contains("Label(\"제거\", systemImage: \"minus.circle\")"))
        XCTAssertTrue(ios.contains("createManualCalendarAction"))
        XCTAssertTrue(ios.contains("action: .calendarCreate"))
        XCTAssertTrue(ios.contains("activeCalendarAction(for change: CalendarChange)"))
        XCTAssertTrue(ios.contains("visibleCalendarChanges()"))
        XCTAssertTrue(ios.contains(".unmatchedMailDashboardItems(comparedTo: syncItems)"))
        XCTAssertTrue(ios.contains("resolvedCalendarChangeIDs"))
        XCTAssertTrue(ios.contains("calendarChangeResolvedIDs(for change: CalendarChange)"))
        XCTAssertTrue(ios.contains("serverRelayCalendarChange(_ change: CalendarChange)"))
        XCTAssertTrue(ios.contains("let publicChangeID = serverRelayCalendarChange(change).id"))
        XCTAssertTrue(ios.contains("ids.contains(action.itemID)"))
        XCTAssertTrue(ios.contains("let actionItemID = serverRelayCalendarChange(change).id"))
        XCTAssertTrue(ios.contains("let previousResolvedCalendarChangeIDs = resolvedCalendarChangeIDs"))
        XCTAssertTrue(ios.contains("markCalendarChangeResolvedLocally(change)"))
        XCTAssertTrue(ios.contains("private func markCalendarChangeResolvedLocally(_ change: CalendarChange)"))
        XCTAssertTrue(ios.contains("resolvedCalendarChangeIDs = previousResolvedCalendarChangeIDs"))
        XCTAssertTrue(ios.contains("recentItemActions.removeAll { candidateIDs.contains($0.itemID) }"))
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
        let macMailPanel = try sourceBody(
            after: "struct MacMailPasteAnalyzerPanel: View",
            in: detail,
            description: "Mac mail paste analyzer panel"
        )
        let macMailAnalyzer = try sourceBody(
            after: "private enum MacMailPasteAnalyzer",
            in: detail,
            description: "Mac mail paste analyzer"
        )
        let macDateParsingCache = try sourceBody(
            after: "private enum KLMSMacDateParsingCache",
            in: detail,
            description: "Mac date parsing cache"
        )
        let macMailHeader = try sourceStructBody(named: "MacMailPasteHeaderButtonContent", in: detail)
        let macMailAnalysisProcess = try sourceStructBody(named: "MacMailAnalysisProcessView", in: detail)

        XCTAssertFalse(calendarDetail.contains("MacMailPasteAnalyzerPanel"))
        XCTAssertFalse(calendarGuide.contains("model.run(.verify)"))
        XCTAssertTrue(calendarGuide.contains("model.run(.coreSync)"))
        XCTAssertFalse(calendarGuide.contains("model.run(.doctor)"))
        XCTAssertFalse(calendarGuide.contains("캘린더 확인"))
        XCTAssertTrue(calendarGuide.contains("KLMS 기준 반영"))
        XCTAssertTrue(calendarGuide.contains("캘린더에서 열기"))
        XCTAssertTrue(calendarRow.contains("editStatusText = ok ? nil : \"캘린더 일정 등록 실패\""))
        XCTAssertTrue(calendarRow.contains("editStatusText = ok ? nil : \"변경 항목 제거 실패\""))
        XCTAssertTrue(calendarRow.contains("editStatusText = ok ? nil : \"캘린더 일정 삭제 실패\""))
        XCTAssertFalse(calendarRow.contains("editStatusText = ok ? \"캘린더 일정 등록 완료\""))
        XCTAssertFalse(calendarRow.contains("editStatusText = ok ? \"캘린더 일정 삭제 완료\""))
        XCTAssertTrue(calendarActionButton.contains("Color.klmsMacCommandButtonBackground.opacity(0.92)"))
        XCTAssertTrue(calendarActionButton.contains("Color.klmsMacCommandButtonBorder.opacity(0.95)"))
        XCTAssertFalse(calendarActionButton.contains("tint.opacity(0.10)"))
        XCTAssertFalse(calendarActionButton.contains("tint.opacity(0.24)"))
        XCTAssertFalse(dashboardSummary.contains("MacMailPasteAnalyzerPanel"))
        XCTAssertFalse(dashboardSummary.contains("@State private var displayedDetail"))
        XCTAssertFalse(dashboardSummary.contains("@State private var detailDisplayTask"))
        XCTAssertTrue(dashboardSummary.contains("@State private var renderedDetail: DashboardDetailKind?"))
        XCTAssertTrue(dashboardSummary.contains("@State private var detailRenderTask: Task<Void, Never>?"))
        XCTAssertTrue(mac.contains("private struct DashboardSummaryContentView: View, @preconcurrency Equatable"))
        XCTAssertFalse(mac.contains("Metric(\"완료 기록\", summary.completedAssignmentCount, detail: .assignmentRecords)"))
        XCTAssertFalse(detail.contains("case assignmentRecords"))
        XCTAssertFalse(detail.contains("\"완료 기록\""))
        XCTAssertFalse(mac.contains(".assignmentRecords"))
        XCTAssertFalse(detail.contains("hasher.combine(summary.completedAssignmentCount)"))
        XCTAssertTrue(dashboardSummary.contains("private func metricColumn("))
        XCTAssertTrue(dashboardSummary.contains("private func dashboardDetailColumn(kind: DashboardDetailKind)"))
        XCTAssertTrue(dashboardSummary.contains("DashboardDetailPanelView("))
        XCTAssertTrue(dashboardSummary.contains("renderSignature: renderSignature"))
        XCTAssertTrue(dashboardSummary.contains("fileRenderSignature: model.dashboardFileRenderSignature"))
        XCTAssertTrue(mac.contains("filterOptions: model.dashboardFilterOptions(for: kind)"))
        XCTAssertFalse(dashboardSummary.contains(".frame(minWidth: 340, idealWidth: 420, maxWidth: 500"))
        XCTAssertTrue(dashboardSummary.contains("VStack(alignment: .leading, spacing: 12)"))
        XCTAssertTrue(dashboardSummary.contains("await Task.yield()"))
        XCTAssertTrue(dashboardSummary.contains("guard selectedDetail != detail || renderedDetail != detail else"))
        XCTAssertTrue(dashboardSummary.contains("private func selectDashboardDetail"))
        XCTAssertTrue(dashboardSummary.contains("selectedDetail = detail"))
        XCTAssertTrue(dashboardSummary.contains("guard !Task.isCancelled, selectedDetail == detail else { return }"))
        XCTAssertTrue(dashboardSummary.contains("renderedDetail = detail"))
        XCTAssertFalse(dashboardSummary.contains("""
        if displayedDetail == detail {
            detailDisplayTask = nil
            return
        }
        displayedDetail = nil
        """))
        XCTAssertFalse(dashboardSummary.contains("DashboardDetailPreparingHint()"))
        XCTAssertTrue(commandPanel.contains("MacMailPasteAnalyzerPanel"))
        let macMailPanelIndex = try XCTUnwrap(commandPanel.range(of: "MacMailPasteAnalyzerPanel")?.lowerBound)
        let macFullSyncIndex = try XCTUnwrap(commandPanel.range(of: "primaryCommandActionCard(primaryCommand)")?.lowerBound)
        XCTAssertTrue(macMailPanelIndex < macFullSyncIndex)
        XCTAssertTrue(detail.contains("메일·캘린더 분석"))
        XCTAssertTrue(detail.contains("메일 본문을 붙여넣어 판독"))
        XCTAssertTrue(detail.contains("메일 원문 붙여넣기"))
        XCTAssertTrue(detail.contains("원문은 서버로 보내지 않음"))
        XCTAssertTrue(detail.contains("판독 결과"))
        XCTAssertTrue(detail.contains("캘린더에 등록"))
        XCTAssertTrue(macMailPanel.contains("@State private var deferredAnalysisTask"))
        XCTAssertTrue(macMailPanel.contains("scheduleAnalysis()"))
        XCTAssertTrue(macMailPanel.contains("Task.sleep(nanoseconds: 280_000_000)"))
        XCTAssertTrue(macMailPanel.contains(".onDisappear"))
        XCTAssertTrue(macMailHeader.contains("Image(systemName: \"envelope.open\")"))
        XCTAssertTrue(macMailHeader.contains("Image(systemName: isExpanded ? \"chevron.up\" : \"chevron.down\")"))
        XCTAssertTrue(detail.contains("MacMailAnalysisProcessView"))
        XCTAssertTrue(detail.contains("분석 과정"))
        XCTAssertTrue(macMailAnalysisProcess.contains("@State private var isExpanded = false"))
        XCTAssertFalse(macMailAnalysisProcess.contains("@State private var isExpanded = true"))
        XCTAssertFalse(macMailAnalysisProcess.contains("DisclosureGroup("))
        XCTAssertTrue(macMailAnalysisProcess.contains("Button {"))
        XCTAssertTrue(macMailAnalysisProcess.contains(".contentShape(RoundedRectangle(cornerRadius: 7))"))
        XCTAssertTrue(macMailAnalysisProcess.contains(".accessibilityLabel(\"분석 과정 \\(steps.count)단계 \\(isExpanded ? \"펼쳐짐\" : \"접힘\")\")"))
        XCTAssertTrue(macMailAnalysisProcess.contains(".accessibilityHint(isExpanded ? \"분석 과정 접기\" : \"분석 과정 펼치기\")"))
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
        XCTAssertTrue(detail.contains("private enum KLMSMacDateParsingCache"))
        XCTAssertTrue(macMailAnalyzer.contains("KLMSMacDateParsingCache.mailCalendarInputFormatter()"))
        XCTAssertTrue(macMailAnalyzer.contains("KLMSMacDateParsingCache.mailParseFormatter()"))
        XCTAssertFalse(macMailAnalyzer.contains("let formatter = DateFormatter()"))
        XCTAssertTrue(detail.contains("KLMSMacDateParsingCache.calendarDisplayFormatter()"))
        XCTAssertTrue(detail.contains("KLMSMacDateParsingCache.isoFormatter(fractionalSeconds: true)"))
        XCTAssertTrue(macDateParsingCache.contains("Thread.current.threadDictionary"))
        XCTAssertTrue(model.contains("func createManualCalendarEvent"))
        XCTAssertTrue(model.contains("EKEvent(eventStore: store)"))
        XCTAssertTrue(model.contains("applyServerRelayCalendarCreateAction"))
        XCTAssertTrue(model.contains("if let change = try? serverRelayCalendarChange(for: action)"))
        XCTAssertTrue(model.contains("applyServerRelayMailDashboardRemoveAction"))
        XCTAssertTrue(model.contains("case .mailDashboardRemove"))
        XCTAssertTrue(model.contains("runningAction.action == .calendarCreate"))
        XCTAssertTrue(model.contains("mailCalendarChanges()"))
        XCTAssertTrue(model.contains("visibleCalendarChanges(from: snapshot).map(serverRelayCalendarChange)"))
        XCTAssertTrue(model.contains("let changes = (snapshot.calendarSyncResult?.changes ?? []) + mailCalendarChanges()"))
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
        XCTAssertTrue(model.contains("cachedDashboardStateItemsByKind"))
        XCTAssertTrue(model.contains("cachedDashboardStateItemSignaturesByKind"))
        XCTAssertTrue(model.contains("func dashboardStateItems(for kind: DashboardDetailKind)"))
        XCTAssertTrue(model.contains("func dashboardStateItemsSignature(for kind: DashboardDetailKind)"))
        XCTAssertTrue(model.contains("private static func dashboardStateItemListSignature("))
        XCTAssertTrue(model.contains("cachedDashboardStateItemsByKind[.assignments] = Self.dedupedStateItems"))
        XCTAssertTrue(model.contains("cachedDashboardStateItemsByKind[.exams] = Self.dedupedStateItems"))
        XCTAssertTrue(detail.contains("model.dashboardStateItems(for: .assignments)"))
        XCTAssertTrue(detail.contains("itemsSignature: model.dashboardStateItemsSignature(for: .assignments)"))
        XCTAssertTrue(detail.contains("model.dashboardStateItems(for: .exams)"))
        XCTAssertTrue(detail.contains("itemsSignature: model.dashboardStateItemsSignature(for: .exams)"))
        XCTAssertFalse(detail.contains("model.mailDashboardStateItems(kind: \"assignment\")"))
        XCTAssertFalse(detail.contains("model.mailDashboardStateItems(kind: \"exam\")"))
        XCTAssertTrue(detail.contains("!model.isCalendarChangeResolved(change)"))
        XCTAssertTrue(detail.contains("isUserVisibleCalendarChange"))
        XCTAssertTrue(detail.contains("let allCalendarChanges = calendarChanges"))
        XCTAssertTrue(detail.contains("let hasReportedCalendarChanges = hasReportedCalendarChanges("))
        XCTAssertTrue(detail.contains("allChanges: allCalendarChanges"))
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
        XCTAssertTrue(ios.contains("let previousStatus = status"))
        XCTAssertTrue(ios.contains("shouldNotifyAuthSuccess(from: previousStatus, to: response.status)"))
        XCTAssertTrue(ios.contains("previousStatus.authDigits != nil"))
        XCTAssertTrue(ios.contains("return !Self.isAlreadyLoggedInMessage(message)"))
        XCTAssertTrue(ios.contains("var shouldShowAuthCompletion: Bool"))
        XCTAssertTrue(ios.contains("&& errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty"))
        XCTAssertTrue(ios.contains("private static func authSuccessDeduplicationKey(_ message: String) -> String"))
        XCTAssertTrue(ios.contains("return \"already-logged-in\""))
        XCTAssertTrue(ios.contains("return \"auth-completed\""))
        XCTAssertTrue(ios.contains("let deduplicationKey = Self.authSuccessDeduplicationKey(normalized)"))
        XCTAssertFalse(ios.contains("lastAuthSuccessAlertMessage = normalized"))
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
        let mailStateItems = try sourceBody(
            after: "func mailDashboardStateItems(kind: String)",
            in: model,
            description: "Mac mail dashboard state item accessor"
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
        XCTAssertTrue(model.contains("cachedMailDashboardStateItemsByKind"))
        XCTAssertTrue(mailStateItems.contains("cachedMailDashboardStateItemsByKind[kind] ?? []"))
        XCTAssertFalse(mailStateItems.contains("compactMap(\\.mailStateItem)"))
        XCTAssertTrue(mailCalendar.contains("cachedMailCalendarChanges"))
        XCTAssertFalse(mailCalendar.contains("currentServerRelayBaseSyncItems()"))
        XCTAssertTrue(rebuildCache.contains("unmatchedMailDashboardItems(comparedTo: currentServerRelayBaseSyncItems())"))
        XCTAssertTrue(rebuildCache.contains("cachedMailDashboardStateItemsByKind = cachedMailDashboardItemsByKind"))
        XCTAssertTrue(rebuildCache.contains("items.compactMap(\\.mailStateItem)"))
        XCTAssertTrue(rebuildCache.contains("rebuildDashboardSummaryCache()"))
        XCTAssertTrue(addMailItem.contains("rebuildMailDashboardCaches()"))
        XCTAssertTrue(removeMailItem.contains("rebuildMailDashboardCaches()"))
        XCTAssertTrue(applySnapshot.contains("replaceSnapshot(nextSnapshot)"))
        XCTAssertTrue(applySnapshot.contains("if runningCommand != nil"))
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
        let workstationCategory = try sourceStructBody(named: "WorkstationDashboardCategoryWorkspace", in: ios)
        let workstationTasks = try sourceStructBody(named: "WorkstationTasksWorkspace", in: ios)
        let workstationCalendar = try sourceStructBody(named: "WorkstationCalendarWorkspace", in: ios)

        XCTAssertTrue(project.contains("TARGETED_DEVICE_FAMILY = \"1,2\";"))
        XCTAssertTrue(project.contains("INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad"))
        XCTAssertTrue(ios.contains("@Environment(\\.horizontalSizeClass)"))
        XCTAssertTrue(ios.contains("private struct CompanionSplitRootView"))
        XCTAssertTrue(ios.contains("private struct WorkstationSidebar"))
        XCTAssertTrue(ios.contains("private struct CompanionDeferredSectionContent"))
        XCTAssertFalse(ios.contains("sectionRenderDelayNanoseconds"))
        XCTAssertFalse(ios.contains("try? await Task.sleep(nanoseconds: sectionRenderDelayNanoseconds)"))
        XCTAssertFalse(ios.contains("renderedSection"))
        XCTAssertFalse(ios.contains("sectionRenderTask"))
        XCTAssertTrue(ios.contains("guard selectedSection != section else { return }"))
        XCTAssertFalse(ios.contains("guard displayedSection != section else"))
        XCTAssertFalse(ios.contains("guard displayedDashboardPreview != category || displayedChangeSummary != nil else"))
        XCTAssertTrue(ios.contains("HStack(spacing: 0)"))
        XCTAssertTrue(ios.contains("WorkstationSidebar(selectedSection: $selectedSection)"))
        XCTAssertTrue(ios.contains("minWidth: CompanionWorkstationMetrics.sidebarWidth"))
        XCTAssertTrue(ios.contains("idealWidth: CompanionWorkstationMetrics.sidebarWidth"))
        XCTAssertTrue(ios.contains("maxWidth: CompanionWorkstationMetrics.sidebarWidth"))
        XCTAssertTrue(ios.contains(".fixedSize(horizontal: true, vertical: false)"))
        XCTAssertFalse(ios.contains(".frame(width: 154)"))
        XCTAssertTrue(ios.contains("private struct CompanionTabRootView"))
        XCTAssertTrue(ios.contains("private struct CompanionSectionContent"))
        XCTAssertTrue(ios.contains("CompanionSplitRootView(model: model, selectedSection: $selectedSection)"))
        XCTAssertTrue(ios.contains("CompanionTabRootView(model: model)"))
        XCTAssertTrue(ios.contains("CompanionDeferredSectionContent(section: selectedSection, model: model)"))
        XCTAssertTrue(ios.contains("CompanionDeferredSectionContent(section: currentSection, model: model)"))
        XCTAssertTrue(ios.contains("private struct WorkstationDashboardCategoryWorkspace"))
        XCTAssertTrue(ios.contains("private struct WorkstationTasksWorkspace"))
        XCTAssertTrue(ios.contains("private struct WorkstationCalendarWorkspace"))
        XCTAssertTrue(ios.contains("private struct WorkstationExternalDetailPanel"))
        XCTAssertTrue(workstationCategory.contains("model.cachedVisibleDashboardItem(for: selectedItemID, categoryID: category.rawValue)"))
        XCTAssertTrue(workstationTasks.contains("model.cachedVisibleDashboardItem(for: selectedItemID, categoryID: selectedTaskCategory.rawValue)"))
        XCTAssertTrue(workstationCalendar.contains("model.visibleCalendarChange(for: selectedChangeID)"))
        XCTAssertFalse(workstationCategory.contains("items.first { $0.id == selectedItemID }"))
        XCTAssertFalse(workstationTasks.contains("selectedCategoryItems.first { $0.id == selectedItemID }"))
        XCTAssertFalse(workstationCalendar.contains("changes.first { $0.id == selectedChangeID }"))
        XCTAssertTrue(ios.contains("WorkstationCalendarWorkspace(model: model)"))
        XCTAssertTrue(ios.contains("category.supportsWorkstationSelectionWorkspace"))
        XCTAssertTrue(ios.contains("horizontalSizeClass == .regular"))
        XCTAssertTrue(ios.contains(".frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)"))
        XCTAssertFalse(ios.contains(".frame(maxWidth: .infinity, minHeight: isCompact ? 40 : 36, alignment: .leading)"))
        XCTAssertFalse(ios.contains(".frame(maxWidth: .infinity, minHeight: 40)"))
        XCTAssertTrue(ios.contains("private var screenContent: some View"))
        XCTAssertTrue(ios.contains("NavigationStack {\n                    screenContent"))
        XCTAssertTrue(ios.contains(".background(Color.klmsScreenBackground.ignoresSafeArea())"))
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
        XCTAssertTrue(ios.contains("await model.bootstrapServerRelayFromLaunch()"))
        XCTAssertTrue(ios.contains("await startServerRelayRealtime(silentInitialErrors: silentInitialErrors)"))
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
        let iosEventStream = try sourceBody(
            after: "private func runServerRelayEventStream",
            in: ios,
            description: "iOS server relay event stream"
        )
        XCTAssertFalse(iosEventStream.contains("await refreshRecent(silentErrors: true, includeSyncData: false, showsActivity: false)"))
        XCTAssertTrue(ios.contains("await refreshRecent(silentErrors: true, includeSyncData: true, showsActivity: false)"))

        XCTAssertFalse(macModel.contains("serverRelayPollingTask"))
        XCTAssertFalse(macModel.contains("configureServerRelayPolling"))
        XCTAssertFalse(macModel.contains("serverRelayIdlePollingIntervalNanoseconds"))
        XCTAssertFalse(macModel.contains("serverRelayActivePollingIntervalNanoseconds"))
        XCTAssertTrue(macModel.contains("private static func serverRelayEventNeedsWorkerRefresh"))
        XCTAssertTrue(macModel.contains("private static func serverRelayEventShouldRefreshSyncData"))
        XCTAssertTrue(macModel.contains("serverRelayLastSyncDataFetchAt = nil"))
        XCTAssertTrue(macModel.contains("reason == \"commands:pending\""))
        XCTAssertTrue(macModel.contains("if reason == \"sync-data\" || reason.hasPrefix(\"sync-data:\")"))
        XCTAssertTrue(macModel.contains("reason.hasPrefix(\"item-actions:\")"))
        XCTAssertTrue(macModel.contains("reason.hasPrefix(\"setting-actions:\")"))
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

    func testMacRuntimeUsesServerSyncSettingsBeforeConfigEnv() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let macModelRoot = packageRoot.appendingPathComponent("Sources/KLMSMac/KLMSMacModel.swift")
        let macModel = try String(contentsOf: macModelRoot, encoding: .utf8)

        let applySyncData = try sourceBody(
            after: "private func applyServerRelaySyncData",
            in: macModel,
            description: "Mac apply server sync data"
        )
        let configValue = try sourceBody(
            after: "func configValue(_ key: EnvKnownKey)",
            in: macModel,
            description: "Mac config value"
        )
        let boolConfigValue = try sourceBody(
            after: "func boolConfigValue(_ key: EnvKnownKey",
            in: macModel,
            description: "Mac bool config value"
        )
        let runtimeConfigValue = try sourceBody(
            after: "private func runtimeConfigValue",
            in: macModel,
            description: "Mac runtime config value"
        )
        let runtimeBoolConfigValue = try sourceBody(
            after: "private func runtimeBoolConfigValue",
            in: macModel,
            description: "Mac runtime bool config value"
        )
        let setConfigValue = try sourceBody(
            after: "func setConfigValue(_ value: String, for key: EnvKnownKey)",
            in: macModel,
            description: "Mac set config value"
        )

        XCTAssertTrue(applySyncData.contains("syncData.settings + syncData.sharedSettings, merge: false"))
        XCTAssertTrue(configValue.contains("serverRelayRuntimeSettingValue(key)"))
        XCTAssertTrue(boolConfigValue.contains("serverRelayRuntimeSettingValue(key)"))
        XCTAssertTrue(runtimeConfigValue.contains("serverRelayRuntimeSettingValue(key)"))
        XCTAssertTrue(runtimeBoolConfigValue.contains("serverRelayRuntimeSettingValue(key)"))
        XCTAssertTrue(setConfigValue.contains("serverRelaySetting(for: key, value: value)"))
        XCTAssertTrue(setConfigValue.contains("applyServerRelaySharedSettings([setting])"))
        XCTAssertTrue(macModel.contains("private func applyServerRelaySharedSettings(_ settings: [ServerRelaySetting], merge: Bool = true) -> Bool"))
        XCTAssertTrue(macModel.contains("applyServerRelaySharedSettings(inbox.sharedSettings, merge: false)"))
        XCTAssertTrue(macModel.contains("private func serverRelayRuntimeSettingValue(_ key: EnvKnownKey) -> String?"))
        XCTAssertTrue(macModel.contains("private static func parseConfigBool(_ value: String) -> Bool?"))
        XCTAssertTrue(macModel.contains("\"NOTICE_COLLAPSE_COURSES\": runtimeBoolConfigValue(.noticeCollapseCourses"))
        XCTAssertTrue(macModel.contains("\"NOTICE_COLLAPSE_NOTICE_ITEMS\": runtimeBoolConfigValue(.noticeCollapseItems"))
    }

    func testIOSSettingActionsUpdateRemoteSettingsImmediately() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let iosRoot = packageRoot.appendingPathComponent("Sources/KLMSiOS/KLMSiOSApp.swift")
        let ios = try String(contentsOf: iosRoot, encoding: .utf8)
        let createSettingAction = try sourceBody(
            after: "func createSettingAction(setting: ServerRelaySetting, value: String) async",
            in: ios,
            description: "iOS create setting action"
        )
        let localApply = try sourceBody(
            after: "private func applyRemoteSettingActionLocally",
            in: ios,
            description: "iOS local setting action apply"
        )

        XCTAssertTrue(createSettingAction.contains("applyRemoteSettingActionLocally(savedAction, fallbackSetting: setting)"))
        XCTAssertTrue(createSettingAction.contains("let optimisticAction = ServerRelaySettingAction("))
        XCTAssertTrue(createSettingAction.contains("status: .running"))
        XCTAssertTrue(createSettingAction.contains("applyRemoteSettingActionLocally(optimisticAction, fallbackSetting: setting)"))
        XCTAssertTrue(createSettingAction.contains("let rollbackAction = ServerRelaySettingAction("))
        XCTAssertTrue(createSettingAction.contains("value: setting.value"))
        XCTAssertTrue(createSettingAction.contains("applyRemoteSettingActionLocally(rollbackAction, fallbackSetting: setting)"))
        XCTAssertTrue(createSettingAction.contains("if savedAction.status != .completed"))
        XCTAssertFalse(createSettingAction.contains("await refreshRecent(includeSyncData: false, showsActivity: false, scope: .settingActions)"))
        let optimisticApplyIndex = try XCTUnwrap(createSettingAction.range(of: "applyRemoteSettingActionLocally(optimisticAction, fallbackSetting: setting)")?.lowerBound)
        let serverRequestIndex = try XCTUnwrap(createSettingAction.range(of: "serverRelayStore.createSettingAction(action)")?.lowerBound)
        XCTAssertLessThan(optimisticApplyIndex, serverRequestIndex)
        XCTAssertTrue(localApply.contains("var settings = remoteSettings"))
        XCTAssertTrue(localApply.contains("ServerRelaySetting("))
        XCTAssertTrue(localApply.contains("value: action.value"))
        XCTAssertTrue(localApply.contains("remoteSettings = settings.sorted { $0.key < $1.key }"))
        let settingActionDisplay = try sourceBody(
            after: "private extension ServerRelaySettingAction",
            in: ios,
            description: "iOS setting action display state"
        )
        XCTAssertTrue(settingActionDisplay.contains("localizedStandardContains(\"서버 화면에는 바로 반영\")"))
        XCTAssertTrue(settingActionDisplay.contains("localizedStandardContains(\"서버 설정에 바로 반영\")"))
    }

    func testIOSServerDisplayItemActionsUpdateDashboardImmediately() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let iosRoot = packageRoot.appendingPathComponent("Sources/KLMSiOS/KLMSiOSApp.swift")
        let ios = try String(contentsOf: iosRoot, encoding: .utf8)
        let createItemAction = try sourceBody(
            after: "func createItemAction(_ actionKind: ServerRelayItemActionKind, item: ServerRelaySyncItem) async",
            in: ios,
            description: "iOS create item action"
        )
        let localApply = try sourceBody(
            after: "private func applyServerVisibleItemActionLocally",
            in: ios,
            description: "iOS local display item action apply"
        )

        XCTAssertTrue(createItemAction.contains("let updatesServerVisibleState = actionKind.isCompanionImmediateDisplayAction"))
        XCTAssertTrue(createItemAction.contains("applyServerVisibleItemActionLocally(actionKind, itemID: item.id)"))
        XCTAssertTrue(createItemAction.contains("let localAction = action.optimisticCompanionDisplayAction"))
        XCTAssertTrue(createItemAction.contains("recentItemActions.insert(localAction, at: 0)"))
        XCTAssertTrue(createItemAction.contains("serverRelayStore.createItemAction(action)"))
        XCTAssertTrue(createItemAction.contains("applyServerVisibleItemActionLocally(savedAction.action, itemID: savedAction.itemID)"))
        XCTAssertTrue(createItemAction.contains("let requiresMac = !actionKind.isServerDisplayOnlyAction"))
        XCTAssertTrue(createItemAction.contains("if requiresMac {\n            isSubmitting = true\n        }"))
        XCTAssertFalse(createItemAction.contains("isSubmitting = true\n        defer {\n            isSubmitting = false\n        }"))
        let inlineItemDetail = try sourceStructBody(named: "ServerSyncItemInlineDetailPanel", in: ios)
        let remoteItemToggleButton = try sourceStructBody(named: "RemoteItemToggleButton", in: ios)
        XCTAssertTrue(inlineItemDetail.contains(".disabled(!model.serverRelayConfigured || (requiresMac && (model.isSubmitting || model.hasInFlightRequest)))"))
        XCTAssertFalse(inlineItemDetail.contains(".disabled(!model.serverRelayConfigured || model.isSubmitting || (model.hasInFlightRequest && requiresMac))"))
        XCTAssertTrue(remoteItemToggleButton.contains(".disabled(!model.serverRelayConfigured || (!action.isServerDisplayOnlyAction && (model.isSubmitting || model.hasInFlightRequest)))"))
        XCTAssertFalse(remoteItemToggleButton.contains(".disabled(!model.serverRelayConfigured || model.isSubmitting)"))
        XCTAssertTrue(createItemAction.contains("if !savedAction.action.isServerDisplayOnlyAction"))
        XCTAssertFalse(createItemAction.contains("includeSyncData: !savedAction.action.isServerDisplayOnlyAction"))
        XCTAssertTrue(createItemAction.contains("schedulePostActionRefresh(scope: .itemActions)"))
        XCTAssertFalse(createItemAction.contains("await refreshRecent(includeSyncData: true, showsActivity: false, scope: .itemActions)"))
        XCTAssertTrue(createItemAction.contains("let previousSyncItems = syncItems"))
        XCTAssertTrue(createItemAction.contains("let previousSyncItemsSignature = syncItemsSignature"))
        XCTAssertTrue(createItemAction.contains("let previousMailDashboardItems = mailDashboardItems"))
        XCTAssertTrue(createItemAction.contains("restoreServerDisplayItemActionState("))
        let localApplyIndex = try XCTUnwrap(createItemAction.range(of: "applyServerVisibleItemActionLocally(actionKind, itemID: item.id)")?.lowerBound)
        let serverRequestIndex = try XCTUnwrap(createItemAction.range(of: "serverRelayStore.createItemAction(action)")?.lowerBound)
        XCTAssertLessThan(localApplyIndex, serverRequestIndex)
        XCTAssertTrue(ios.contains("private func restoreServerDisplayItemActionState("))
        XCTAssertTrue(ios.contains("syncItems = previousSyncItems"))
        XCTAssertTrue(ios.contains("syncItemsSignature = previousSyncItemsSignature"))
        XCTAssertTrue(ios.contains("mailDashboardItems = previousMailDashboardItems"))
        XCTAssertTrue(localApply.contains("rebuildDashboardDerivedState()"))
        XCTAssertTrue(ios.contains("restoreServerDisplayItemActionState("))
        XCTAssertTrue(ios.contains("rebuildDashboardDerivedState()\n        persistCachedServerSyncData(ServerRelaySyncData("))
        XCTAssertTrue(ios.contains("var optimisticCompanionDisplayAction: ServerRelayItemAction"))
        XCTAssertTrue(ios.contains("next.status = .completed"))
        XCTAssertTrue(ios.contains("next.message = \"서버 화면에 바로 반영했습니다. 모든 기기가 최신 상태를 받아옵니다.\""))
        XCTAssertTrue(ios.contains("var isCompanionImmediateDisplayAction: Bool"))
        XCTAssertTrue(ios.contains("isServerDisplayOnlyAction || self == .fileTrash"))
        XCTAssertTrue(localApply.contains("guard actionKind.isCompanionImmediateDisplayAction"))
        XCTAssertTrue(ios.contains("localizedStandardContains(\"서버 화면에는 바로 반영\")"))
        XCTAssertTrue(localApply.contains("case .assignmentComplete:"))
        XCTAssertTrue(localApply.contains("item.kind = \"completedAssignment\""))
        XCTAssertTrue(localApply.contains("case .examPromote:"))
        XCTAssertTrue(localApply.contains("item.kind = \"exam\""))
        XCTAssertTrue(localApply.contains("case .noticeRead:"))
        XCTAssertTrue(localApply.contains("item.isRead = true"))
        XCTAssertTrue(localApply.contains("case .noticeImportant:"))
        XCTAssertTrue(localApply.contains("item.isImportant = true"))
        XCTAssertTrue(localApply.contains("case .noticeHide, .fileHide:"))
        XCTAssertTrue(localApply.contains("item.isHidden = true"))
        XCTAssertTrue(localApply.contains("case .fileTrash,"))
        XCTAssertTrue(localApply.contains("item.status = \"삭제 요청\""))
        XCTAssertTrue(localApply.contains("syncItems = nextSyncItems.companionSorted(by: .recent)"))
        XCTAssertTrue(localApply.contains("persistCachedServerSyncData(ServerRelaySyncData("))
        XCTAssertTrue(ios.contains("private var cachedSyncDataPersistTask: Task<Void, Never>?"))
        XCTAssertTrue(ios.contains("cachedSyncDataPersistTask?.cancel()"))
        XCTAssertTrue(ios.contains("Task.detached(priority: .utility)"))
    }

    func testIOSServerActionRefreshesUseNarrowScopes() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let iosRoot = packageRoot.appendingPathComponent("Sources/KLMSiOS/KLMSiOSApp.swift")
        let ios = try String(contentsOf: iosRoot, encoding: .utf8)
        let submitMail = try sourceBody(
            after: "func submitMailDashboardItem",
            in: ios,
            description: "iOS submit mail dashboard item"
        )
        let removeMail = try sourceBody(
            after: "func submitRemoveMailDashboardItem",
            in: ios,
            description: "iOS remove mail dashboard item"
        )
        let updateSharedSetting = try sourceBody(
            after: "private func updateSharedSetting(",
            in: ios,
            description: "iOS shared setting update"
        )
        let createSettingAction = try sourceBody(
            after: "func createSettingAction(setting: ServerRelaySetting, value: String) async",
            in: ios,
            description: "iOS create setting action"
        )
        let createManualCalendarAction = try sourceBody(
            after: "func createManualCalendarAction(",
            in: ios,
            description: "iOS manual calendar action"
        )
        let createCalendarAction = try sourceBody(
            after: "func createCalendarAction(",
            in: ios,
            description: "iOS create calendar action"
        )
        let createCommand = try sourceBody(
            after: "func createCommand(_ kind: RemoteCommandKind",
            in: ios,
            description: "iOS create remote command"
        )
        let cancelCommand = try sourceBody(
            after: "func cancelRunningCommand() async",
            in: ios,
            description: "iOS cancel remote command"
        )
        let createFileAccess = try sourceBody(
            after: "func createFileAccessRequest(item: ServerRelaySyncItem) async",
            in: ios,
            description: "iOS file access request"
        )

        XCTAssertFalse(submitMail.contains("await refreshRecent(includeSyncData: false, showsActivity: false, scope: .itemActions)"))
        XCTAssertFalse(removeMail.contains("await refreshRecent(includeSyncData: false, showsActivity: false, scope: .itemActions)"))
        XCTAssertFalse(updateSharedSetting.contains("await refreshRecent(silentErrors: true, includeSyncData: false, showsActivity: false, scope: .settings)"))
        XCTAssertFalse(updateSharedSetting.contains("isSubmitting = true"))
        XCTAssertFalse(createSettingAction.contains("isSubmitting = true"))
        XCTAssertTrue(updateSharedSetting.contains("let previousSharedSettings = sharedSettings"))
        XCTAssertTrue(updateSharedSetting.contains("sharedSettings = previousSharedSettings"))
        XCTAssertFalse(createManualCalendarAction.contains("isSubmitting = true"))
        XCTAssertTrue(createManualCalendarAction.contains("let requestItemID = \"mail-calendar-\\(UUID().uuidString)\""))
        XCTAssertTrue(createManualCalendarAction.contains("rebuildItemActionLookups()"))
        XCTAssertTrue(createManualCalendarAction.contains("recentItemActions.removeAll { $0.itemID == requestItemID && $0.status == .pending }"))
        XCTAssertTrue(createCalendarAction.contains("markCalendarChangeResolvedLocally(change)"))
        XCTAssertTrue(createCalendarAction.contains("rebuildItemActionLookups()"))
        XCTAssertFalse(createCalendarAction.contains("isSubmitting = true"))
        XCTAssertFalse(createCalendarAction.contains("await refreshRecent("))
        XCTAssertTrue(createCommand.contains("recentCommands.insert(command, at: 0)"))
        XCTAssertTrue(createCommand.contains("rebuildRemoteLogDerivedState()"))
        XCTAssertTrue(createCommand.contains("요청을 대기열에 올렸습니다. 서버 확인을 기다리는 중입니다."))
        XCTAssertTrue(createCommand.contains("요청이 서버에 전달됐습니다."))
        XCTAssertFalse(createCommand.contains("isSubmitting = true"))
        XCTAssertFalse(createCommand.contains("await refreshRecent("))
        XCTAssertFalse(cancelCommand.contains("await refreshRecent("))
        XCTAssertTrue(cancelCommand.contains("let previousCommands = recentCommands"))
        XCTAssertTrue(cancelCommand.contains("중단 요청을 대기열에 올렸습니다. 서버 확인을 기다리는 중입니다."))
        XCTAssertTrue(cancelCommand.contains("중단 요청 전송 실패"))
        XCTAssertFalse(cancelCommand.contains("isSubmitting = true"))
        XCTAssertTrue(createFileAccess.contains("recentFileAccessRequests.insert(request, at: 0)"))
        XCTAssertTrue(createFileAccess.contains("rebuildFileAccessLookup()"))
        XCTAssertTrue(createFileAccess.contains("rebuildRemoteLogDerivedState()"))
        XCTAssertTrue(createFileAccess.contains("파일 링크 요청을 대기열에 올렸습니다. 서버 확인을 기다리는 중입니다."))
        XCTAssertFalse(createFileAccess.contains("isSubmitting = true"))
        XCTAssertFalse(createFileAccess.contains("await refreshRecent("))
    }

    func testIOSServerConnectionPasteImmediatelyRefreshesSummary() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let iosRoot = packageRoot.appendingPathComponent("Sources/KLMSiOS/KLMSiOSApp.swift")
        let ios = try String(contentsOf: iosRoot, encoding: .utf8)
        let pasteMethod = try sourceBody(
            after: "func pasteServerRelayConnectionInfo()",
            in: ios,
            description: "iOS server relay paste"
        )
        let refreshMethod = try sourceBody(
            after: "private func refreshAfterServerRelayConnectionChange()",
            in: ios,
            description: "iOS server relay paste refresh"
        )
        let loadingCard = try sourceStructBody(named: "CompanionDashboardDataLoadingCard", in: ios)

        XCTAssertTrue(pasteMethod.contains("refreshAfterServerRelayConnectionChange()"))
        XCTAssertTrue(pasteMethod.contains("let nextServerURL = connectionInfo.baseURL.absoluteString"))
        XCTAssertTrue(pasteMethod.contains("if nextServerURL != serverURL || nextServerToken != serverToken"))
        XCTAssertTrue(pasteMethod.contains("clearLoadedServerSyncData()"))
        XCTAssertTrue(pasteMethod.contains("UserDefaults.standard.removeObject(forKey: Self.cachedServerSyncDataKey)"))
        XCTAssertTrue(pasteMethod.contains("serverURL = nextServerURL"))
        XCTAssertTrue(pasteMethod.contains("serverToken = nextServerToken"))
        XCTAssertFalse(pasteMethod.contains("이제 서버 연결 확인을 눌러 주세요."))
        XCTAssertTrue(refreshMethod.contains("configureServerRelayEventStream()"))
        XCTAssertTrue(refreshMethod.contains("await self?.refreshRecent(includeSyncData: true, showsActivity: true)"))
        XCTAssertTrue(loadingCard.contains("서버 URL과 클라이언트 토큰을 넣으면 최신 요약을 바로 불러옵니다."))
        XCTAssertFalse(loadingCard.contains("연결 확인을 눌러 주세요."))
    }

    func testIOSCachesServerSummaryForFirstLaunchDashboard() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let iosRoot = packageRoot.appendingPathComponent("Sources/KLMSiOS/KLMSiOSApp.swift")
        let ios = try String(contentsOf: iosRoot, encoding: .utf8)
        let initBody = try sourceBody(
            after: "init()",
            in: ios,
            description: "iOS companion model init"
        )
        let applyBody = try sourceBody(
            after: "private func apply(_ syncData: ServerRelaySyncData",
            in: ios,
            description: "iOS sync-data apply"
        )
        let clearConnection = try sourceBody(
            after: "func clearServerRelayConnectionInfo()",
            in: ios,
            description: "iOS clear server relay connection"
        )
        let clearLoadedServerSyncData = try sourceBody(
            after: "private func clearLoadedServerSyncData()",
            in: ios,
            description: "iOS clear loaded server sync data"
        )

        XCTAssertTrue(ios.contains("private static let cachedServerSyncDataKey = \"KLMSCompanionCachedServerSyncData\""))
        XCTAssertTrue(ios.contains("private struct CachedServerSyncData: Codable, @unchecked Sendable"))
        XCTAssertTrue(ios.contains("var tokenFingerprint: String?"))
        XCTAssertTrue(ios.contains("private static let cachedServerSyncDataMaxAge: TimeInterval = 10 * 60"))
        XCTAssertTrue(initBody.contains("Self.loadCachedServerSyncData(for: serverURL, tokenFingerprint: Self.serverRelayBootstrapTokenFingerprint(serverToken))"))
        XCTAssertTrue(initBody.contains("apply(cachedSyncData, persistCache: false, markLoaded: true)"))
        XCTAssertTrue(initBody.contains("syncDataNeedsRefresh = true"))
        XCTAssertTrue(initBody.contains("저장된 서버 요약을 먼저 보여주고, 최신 상태를 다시 불러옵니다."))
        XCTAssertTrue(ios.contains("markLoaded: Bool = true"))
        XCTAssertTrue(applyBody.contains("if markLoaded, persistCache"))
        XCTAssertTrue(applyBody.contains("if markLoaded, !hasLoadedServerSyncData"))
        XCTAssertTrue(applyBody.contains("if markLoaded {\n            lastSyncDataRefreshAt = Date()"))
        XCTAssertTrue(applyBody.contains("persistCachedServerSyncData(syncData)"))
        let persistCacheBody = try sourceBody(
            after: "private func persistCachedServerSyncData(_ syncData: ServerRelaySyncData)",
            in: ios,
            description: "iOS cached sync-data persistence"
        )
        XCTAssertTrue(persistCacheBody.contains("cachedSyncDataPersistTask?.cancel()"))
        XCTAssertTrue(persistCacheBody.contains("try? await Task.sleep(nanoseconds: 350_000_000)"))
        XCTAssertTrue(persistCacheBody.contains("Task.detached(priority: .utility)"))
        XCTAssertTrue(persistCacheBody.contains("JSONEncoder().encode(cached)"))
        XCTAssertTrue(persistCacheBody.contains("UserDefaults.standard.set(data, forKey: Self.cachedServerSyncDataKey)"))
        XCTAssertTrue(applyBody.contains("applySharedSettings(syncData.sharedSettings, merge: false)"))
        XCTAssertTrue(ios.contains("private func applySharedSettings(_ incomingSettings: [ServerRelaySetting], merge: Bool) -> Bool"))
        XCTAssertTrue(ios.contains("applySharedSettings([setting], merge: true)"))
        XCTAssertTrue(ios.contains("applySharedSettings([saved], merge: true)"))
        XCTAssertTrue(ios.contains("private static func loadCachedServerSyncData(for serverURL: String, tokenFingerprint: String) -> ServerRelaySyncData?"))
        XCTAssertTrue(ios.contains("cached.serverURL == normalizedURL"))
        XCTAssertTrue(ios.contains("cached.tokenFingerprint == tokenFingerprint"))
        XCTAssertTrue(ios.contains("Date().timeIntervalSince(cached.storedAt) <= cachedServerSyncDataMaxAge"))
        XCTAssertTrue(ios.contains("UserDefaults.standard.removeObject(forKey: cachedServerSyncDataKey)"))
        XCTAssertTrue(ios.contains("private func persistCachedServerSyncData(_ syncData: ServerRelaySyncData)"))
        XCTAssertTrue(ios.contains("tokenFingerprint: Self.serverRelayBootstrapTokenFingerprint(serverToken)"))
        XCTAssertTrue(ios.contains("private func clearLoadedServerSyncData()"))
        XCTAssertTrue(clearLoadedServerSyncData.contains("cachedSyncDataPersistTask?.cancel()"))
        XCTAssertTrue(clearLoadedServerSyncData.contains("sharedSettings = []"))
        XCTAssertTrue(clearLoadedServerSyncData.contains("sharedSettingsSignature = nil"))
        XCTAssertTrue(clearConnection.contains("clearLoadedServerSyncData()"))
        XCTAssertTrue(clearConnection.contains("UserDefaults.standard.removeObject(forKey: Self.cachedServerSyncDataKey)"))
    }

    func testIOSRefreshesServerSummaryWhenAppBecomesActive() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let iosRoot = packageRoot.appendingPathComponent("Sources/KLMSiOS/KLMSiOSApp.swift")
        let ios = try String(contentsOf: iosRoot, encoding: .utf8)
        let rootView = try sourceBody(
            after: "struct CompanionRootView: View",
            in: ios,
            description: "iOS companion root view"
        )
        let bootstrap = try sourceBody(
            after: "func bootstrapServerRelayFromLaunch(silentInitialErrors: Bool = false) async",
            in: ios,
            description: "iOS server relay bootstrap"
        )
        let retryInitialLoad = try sourceBody(
            after: "private func retryInitialServerSyncDataIfNeeded",
            in: ios,
            description: "iOS initial sync-data retry"
        )
        let refreshRecent = try sourceBody(
            after: "func refreshRecent(",
            in: ios,
            description: "iOS refresh recent"
        )
        let applyResponse = try sourceBody(
            after: "private func apply(_ response: LocalRemoteResponse",
            in: ios,
            description: "iOS status apply"
        )
        let tokenFingerprint = try sourceBody(
            after: "private static func serverRelayBootstrapTokenFingerprint",
            in: ios,
            description: "iOS server relay token fingerprint"
        )

        XCTAssertTrue(rootView.contains("@Environment(\\.scenePhase) private var scenePhase"))
        XCTAssertTrue(rootView.contains(".task(id: model.serverRelayBootstrapKey)"))
        XCTAssertTrue(rootView.contains(".onChange(of: scenePhase)"))
        XCTAssertTrue(rootView.contains("guard newPhase == .active else { return }"))
        XCTAssertTrue(rootView.contains("await model.bootstrapServerRelayFromLaunch()"))
        XCTAssertTrue(rootView.contains("await model.bootstrapServerRelayFromLaunch(silentInitialErrors: true)"))
        XCTAssertTrue(ios.contains("var serverRelayBootstrapKey: String"))
        XCTAssertTrue(ios.contains("func bootstrapServerRelayFromLaunch(silentInitialErrors: Bool = false) async"))
        XCTAssertTrue(ios.contains("syncDataNeedsRefresh = true"))
        XCTAssertTrue(ios.contains("private static let initialSyncDataRetryDelayNanoseconds"))
        XCTAssertTrue(ios.contains("private static let initialSyncDataRetryLimit = 3"))
        XCTAssertTrue(bootstrap.contains("await startServerRelayRealtime(silentInitialErrors: silentInitialErrors)"))
        XCTAssertTrue(bootstrap.contains("await retryInitialServerSyncDataIfNeeded(silentInitialErrors: silentInitialErrors)"))
        XCTAssertTrue(retryInitialLoad.contains("for _ in 0..<Self.initialSyncDataRetryLimit"))
        XCTAssertTrue(retryInitialLoad.contains("guard shouldRetryInitialServerSyncData"))
        XCTAssertTrue(retryInitialLoad.contains("try? await Task.sleep(nanoseconds: Self.initialSyncDataRetryDelayNanoseconds)"))
        XCTAssertTrue(retryInitialLoad.contains("guard !Task.isCancelled, shouldRetryInitialServerSyncData"))
        XCTAssertTrue(retryInitialLoad.contains("await refreshRecent(silentErrors: silentInitialErrors, includeSyncData: true, showsActivity: false)"))
        let syncDataApplyIndex = try XCTUnwrap(refreshRecent.range(of: "switch await syncDataTask")?.lowerBound)
        let responseApplyIndex = try XCTUnwrap(refreshRecent.range(of: "switch await responseTask")?.lowerBound)
        XCTAssertLessThan(
            refreshRecent.distance(from: refreshRecent.startIndex, to: syncDataApplyIndex),
            refreshRecent.distance(from: refreshRecent.startIndex, to: responseApplyIndex)
        )
        XCTAssertTrue(applyResponse.contains("rebuildDashboardStatus()"))
        XCTAssertTrue(ios.contains("private var shouldRetryInitialServerSyncData: Bool"))
        XCTAssertTrue(ios.contains("serverRelayConfigured && (syncDataNeedsRefresh || !hasLoadedServerSyncData)"))
        XCTAssertTrue(ios.contains("serverRelayBootstrapTokenFingerprint(serverToken)"))
        XCTAssertFalse(tokenFingerprint.contains("var hasher = Hasher()"))
        XCTAssertTrue(tokenFingerprint.contains("var hash: UInt64 = 1_469_598_103_934_665_603"))
        XCTAssertTrue(tokenFingerprint.contains("hash &*= 1_099_511_628_211"))
        XCTAssertTrue(tokenFingerprint.contains("return \"token-\\(trimmed.count)-\\(String(hash, radix: 16))\""))
    }

    func testIOSDeferredExpansionRendersImmediatelyAfterToggle() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let iosRoot = packageRoot.appendingPathComponent("Sources/KLMSiOS/KLMSiOSApp.swift")
        let ios = try String(contentsOf: iosRoot, encoding: .utf8)
        let expansion = try sourceBody(
            after: "private struct DeferredInteractionExpansion<Content: View>: View",
            in: ios,
            description: "iOS deferred interaction expansion"
        )

        XCTAssertFalse(expansion.contains("@State private var renderTask: Task<Void, Never>?"))
        XCTAssertTrue(expansion.contains("scheduleRender(isExpanded)"))
        XCTAssertTrue(expansion.contains("shouldRender = expanded"))
        XCTAssertFalse(expansion.contains("await Task.yield()"))
        XCTAssertFalse(expansion.contains("guard !Task.isCancelled, isExpanded else { return }"))
        XCTAssertFalse(expansion.contains(".onDisappear"))
        XCTAssertFalse(expansion.contains("renderTask?.cancel()"))
    }

    func testIOSServerTokenPersistenceDoesNotBlockTyping() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let iosRoot = packageRoot.appendingPathComponent("Sources/KLMSiOS/KLMSiOSApp.swift")
        let ios = try String(contentsOf: iosRoot, encoding: .utf8)
        let companionModel = try sourceBody(
            after: "final class CompanionModel: ObservableObject",
            in: ios,
            description: "CompanionModel"
        )
        let schedulePersist = try sourceBody(
            after: "private func schedulePersistServerToken(_ token: String)",
            in: ios,
            description: "iOS server token persistence debounce"
        )

        XCTAssertTrue(companionModel.contains("didSet { schedulePersistServerToken(serverToken) }"))
        XCTAssertFalse(companionModel.contains("didSet { Self.persistServerToken(serverToken) }"))
        XCTAssertTrue(companionModel.contains("private var serverTokenPersistTask: Task<Void, Never>?"))
        XCTAssertTrue(schedulePersist.contains("try? await Task.sleep(nanoseconds: 350_000_000)"))
        XCTAssertTrue(schedulePersist.contains("Task.detached(priority: .utility)"))
        XCTAssertTrue(ios.contains("nonisolated private static func persistServerToken(_ token: String)"))
    }

    func testIOSServerTokenUserDefaultsPathIsMigrationOnly() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let iosRoot = packageRoot.appendingPathComponent("Sources/KLMSiOS/KLMSiOSApp.swift")
        let ios = try String(contentsOf: iosRoot, encoding: .utf8)
        let companionModel = try sourceBody(
            after: "final class CompanionModel: ObservableObject",
            in: ios,
            description: "CompanionModel"
        )
        let initializer = try sourceBody(after: "init()", in: companionModel, description: "CompanionModel init")
        let persistToken = try sourceBody(
            after: "nonisolated private static func persistServerToken(_ token: String)",
            in: companionModel,
            description: "iOS server token persistence"
        )
        let loadMigratingToken = try sourceBody(
            after: "nonisolated private static func loadServerRelayTokenMigratingUserDefaults() -> String",
            in: companionModel,
            description: "iOS server token migration"
        )

        XCTAssertTrue(initializer.contains("Self.loadServerRelayTokenMigratingUserDefaults()"))
        XCTAssertFalse(initializer.contains("UserDefaults.standard.string(forKey: Self.serverTokenKey)"))
        XCTAssertFalse(initializer.contains("Self.persistServerToken(storedServerToken)"))
        XCTAssertTrue(loadMigratingToken.contains("LocalRemoteTokenStore.load(account: \"server-relay-ios\")"))
        XCTAssertTrue(loadMigratingToken.contains("UserDefaults.standard.string(forKey: serverTokenKey)"))
        XCTAssertTrue(loadMigratingToken.contains("persistServerToken(legacyToken)"))
        XCTAssertGreaterThanOrEqual(
            loadMigratingToken.components(separatedBy: "UserDefaults.standard.removeObject(forKey: serverTokenKey)").count - 1,
            1
        )
        XCTAssertTrue(persistToken.contains("LocalRemoteTokenStore.save(trimmedToken, account: \"server-relay-ios\")"))
        XCTAssertTrue(persistToken.contains("UserDefaults.standard.removeObject(forKey: serverTokenKey)"))
        XCTAssertFalse(persistToken.contains("UserDefaults.standard.set"))
        XCTAssertFalse(companionModel.contains("UserDefaults.standard.set(serverToken"))
        XCTAssertFalse(companionModel.contains("UserDefaults.standard.set(trimmedToken"))
        XCTAssertFalse(companionModel.contains("UserDefaults.standard.set(token"))
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
        XCTAssertTrue(ios.contains("connectionMessage = \"최신 상태를 불러왔습니다.\""))
        XCTAssertTrue(ios.contains("connectionMessage = refreshFailureMessage(reason: message)"))
        XCTAssertTrue(ios.contains("private func refreshFailureMessage(reason: String) -> String"))
        XCTAssertTrue(ios.contains("설정에서 서버 URL과 클라이언트 토큰을 먼저 저장해 주세요."))
        XCTAssertTrue(ios.contains("요청을 완료하지 못했습니다. 서버 연결 설정과 네트워크 상태를 확인해 주세요."))
        XCTAssertFalse(ios.contains("connectionMessage = \"새로고침 실패\""))
        XCTAssertFalse(ios.contains("서버 연결 정보가 없어 새로 고칠 수 없습니다."))
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

        XCTAssertTrue(refreshBody.contains("async let responseTask = Self.fetchStatusResponseResult(store: serverRelayStore)"))
        XCTAssertTrue(refreshBody.contains("async let commandsTask = Self.fetchRecentCommandsIfNeeded(scope.fetchesCommands"))
        XCTAssertTrue(refreshBody.contains("async let syncDataTask"))
        XCTAssertTrue(refreshBody.contains("async let fileRequestsTask = Self.fetchRecentFileAccessRequestsIfNeeded(scope.fetchesFileRequests"))
        XCTAssertTrue(refreshBody.contains("async let itemActionsTask = Self.fetchRecentItemActionsIfNeeded(scope.fetchesItemActions"))
        XCTAssertTrue(refreshBody.contains("async let requestLogTask = Self.fetchRecentRequestLogIfNeeded(scope.fetchesRequestLog"))
        XCTAssertTrue(refreshBody.contains("async let settingActionsTask = Self.fetchRecentSettingActionsIfNeeded(scope.fetchesSettingActions"))
        XCTAssertTrue(refreshBody.contains("isLoadingServerSyncData = true"))
        XCTAssertTrue(refreshBody.contains("isLoadingServerSyncData = false"))
        XCTAssertTrue(refreshBody.contains("switch await syncDataTask"))
        XCTAssertTrue(refreshBody.contains("var statusRefreshError: Error?"))
        XCTAssertTrue(refreshBody.contains("var loadedSyncData = false"))
        XCTAssertTrue(refreshBody.contains("loadedSyncData = true"))
        XCTAssertTrue(refreshBody.contains("대시보드는 불러왔지만 현재 실행 상태 갱신은 실패했습니다."))
        XCTAssertTrue(refreshBody.contains("didChange = markInitialSyncDataLoadFailure(silentErrors: silentErrors) || didChange"))
        XCTAssertTrue(refreshBody.contains("didChange = markSyncDataLoadFailure(error, silentErrors: silentErrors) || didChange"))
        XCTAssertTrue(ios.contains("private static func fetchSyncDataResultIfNeeded"))
        XCTAssertTrue(ios.contains("return .failure(error)"))
        XCTAssertTrue(ios.contains("private func markInitialSyncDataLoadFailure(silentErrors: Bool) -> Bool"))
        XCTAssertTrue(ios.contains("private func markSyncDataLoadFailure(_ error: Error, silentErrors: Bool) -> Bool"))
        XCTAssertTrue(ios.contains("syncDataNeedsRefresh = true"))
        XCTAssertTrue(ios.contains("서버 요약을 불러오지 못했습니다. 연결을 확인한 뒤 새로고침해 주세요."))
        XCTAssertTrue(ios.contains("userAlert = UserAlert(title: alertTitle, message: message)"))
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
        syncStart: String = "",
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
          "sync_start": "\(syncStart)",
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

    private func sourceStructBodies(named names: [String], in source: String) throws -> String {
        try names
            .map { try sourceAnyStructBody(named: $0, in: source) }
            .joined(separator: "\n")
    }

    private func sourceAnyStructBody(named name: String, in source: String) throws -> String {
        if source.contains("private struct \(name): View") {
            return try sourceStructBody(named: name, in: source)
        }
        return try sourceBody(after: "private struct \(name)", in: source, description: "Swift struct \(name)")
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

    private func macServerRelayEditableSettingKeys(macModel: String, envDocument: String) throws -> Set<String> {
        let envRawValuesByCase = try envKnownKeyRawValuesByCaseName(from: envDocument)
        let settingsBlock = try sourceBody(
            after: "private static let serverRelayEditableSettings: [ServerRelaySettingDefinition]",
            in: macModel,
            description: "Mac server relay editable settings"
        )
        let caseNames = try regexCaptureGroups(
            pattern: #"ServerRelaySettingDefinition\(\.([A-Za-z0-9_]+)"#,
            in: settingsBlock
        ).compactMap(\.first)
        let keys = try caseNames.map { caseName -> String in
            guard let rawValue = envRawValuesByCase[caseName] else {
                throw NSError(domain: "DashboardDataModelTests", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "Missing EnvKnownKey raw value for \(caseName)",
                ])
            }
            return rawValue
        }
        return Set(keys)
    }

    private func iosRemoteSettingKeys(from remoteSettingGroup: String, knownKeys: Set<String>) throws -> Set<String> {
        let quotedValues = try regexCaptureGroups(
            pattern: #""([A-Z0-9_]+)""#,
            in: remoteSettingGroup
        ).compactMap(\.first)
        return Set(quotedValues.filter { knownKeys.contains($0) })
    }

    private func envKnownKeyRawValuesByCaseName(from envDocument: String) throws -> [String: String] {
        let matches = try regexCaptureGroups(
            pattern: #"case\s+([A-Za-z0-9_]+)\s*=\s*"([^"]+)""#,
            in: envDocument
        )
        return Dictionary(uniqueKeysWithValues: matches.compactMap { captures in
            guard captures.count == 2 else { return nil }
            return (captures[0], captures[1])
        })
    }

    private func regexCaptureGroups(pattern: String, in source: String) throws -> [[String]] {
        let regex = try NSRegularExpression(pattern: pattern)
        let nsSource = source as NSString
        return regex.matches(
            in: source,
            range: NSRange(location: 0, length: nsSource.length)
        ).map { match in
            (1..<match.numberOfRanges).compactMap { index in
                let range = match.range(at: index)
                guard range.location != NSNotFound else { return nil }
                return nsSource.substring(with: range)
            }
        }
    }
}
