import KLMSShared
import XCTest

final class StatusModelTests: XCTestCase {
    func testParsesSyncReportAndAttentionState() throws {
        let json = """
        {
          "status": "ok",
          "runs": {"files": {"scope": "files", "status": "ok", "completed_at": "now", "elapsed_ms": 1500}},
          "state": {"assignments": 2, "exams": 1, "past_exams": 3, "exam_records": 4, "helpdesk": 1},
          "notices": {"total": 9, "new": 2, "updated": 1, "ignored": 0},
          "files": {"total": 12, "new_files": 3, "quarantine": 1, "pruned": 4, "archive_pruned": 5},
          "calendar": {"created": 1, "updated": 2, "deleted": 3},
          "slowest": [{"name": "files", "duration_ms": 500, "status": "ok"}]
        }
        """

        let report = try JSONDecoder().decode(SyncReport.self, from: Data(json.utf8))

        XCTAssertEqual(report.state.assignments, 2)
        XCTAssertEqual(report.state.pastExams, 3)
        XCTAssertEqual(report.state.examRecords, 4)
        XCTAssertEqual(report.files.newFiles, 3)
        XCTAssertEqual(report.files.quarantine, 1)
        XCTAssertEqual(report.runs["files"]?.elapsedSecondsText, "1.50s")
        XCTAssertEqual(report.slowest.first?.durationSecondsText, "0.50s")
        XCTAssertTrue(report.needsAttention)
    }

    func testParsesCalendarSyncResultDetails() throws {
        let json = """
        {
          "backend": "swift",
          "generated_at": "2026-05-18T01:56:08.495Z",
          "summaries": [
            {"raw": "calendar=시험 bucket=exam created=1 updated=2 deleted=0 total=4", "calendar": "시험", "bucket": "exam", "created": 1, "updated": 2, "deleted": 0, "total": 4}
          ],
          "changes": [
            {
              "action": "updated",
              "calendar": "시험",
              "bucket": "exam",
              "identifier": "exam:123",
              "title": "[KLMS 시험] CS - Midterm",
              "course": "CS",
              "url": "https://klms.kaist.ac.kr/mod/quiz/view.php?id=123",
              "start_at": "2026-05-20T00:45:00.000Z",
              "due_at": "2026-05-20T01:00:00.000Z",
              "location": "E11",
              "changes": ["제목", "종료"]
            }
          ]
        }
        """

        let result = try JSONDecoder().decode(CalendarSyncResult.self, from: Data(json.utf8))

        XCTAssertEqual(result.backend, "swift")
        XCTAssertEqual(result.summaries.first?.calendar, "시험")
        XCTAssertEqual(result.summaries.first?.updated, 2)
        XCTAssertEqual(result.changes.first?.actionDisplayName, "수정")
        XCTAssertEqual(result.changes.first?.course, "CS")
        XCTAssertEqual(result.changes.first?.changes, ["제목", "종료"])
    }

    func testCalendarChangeHidesMemoOnlyUpdatesFromActionLists() throws {
        let memoOnly = CalendarChange(action: "updated", changes: ["메모"])
        let noteOnly = CalendarChange(action: "updated", changes: [" notes "])
        let titleUpdate = CalendarChange(action: "updated", changes: ["제목"])
        let created = CalendarChange(action: "created", changes: ["메모"])

        XCTAssertFalse(memoOnly.isUserVisibleCalendarChange)
        XCTAssertFalse(noteOnly.isUserVisibleCalendarChange)
        XCTAssertTrue(titleUpdate.isUserVisibleCalendarChange)
        XCTAssertTrue(created.isUserVisibleCalendarChange)
    }

    func testLegacyMailCalendarChangeDisplaysAsCreated() throws {
        let change = CalendarChange(action: "mail", title: "기말고사")

        XCTAssertEqual(change.actionDisplayName, "생성")
        XCTAssertTrue(change.isUserVisibleCalendarChange)
        XCTAssertTrue(change.explanationText.contains("새로 만든 항목"))
    }

    func testDeletedCalendarChangeIsConfirmationOnly() throws {
        let change = CalendarChange(action: "deleted", title: "지난 일정")

        XCTAssertTrue(change.isDeletedAction)
        XCTAssertEqual(change.actionDisplayName, "삭제됨")
        XCTAssertTrue(change.explanationText.contains("Apple Calendar에서 삭제"))
        XCTAssertTrue(change.nextActionText.contains("목록에서 바로 없앱니다"))
    }

    func testCalendarEventEditMessageRoundTripUsesServerKeys() throws {
        let edit = CalendarEventEdit(
            title: "기말고사 장소 변경",
            startAt: "2026-06-17 13:00",
            dueAt: "2026-06-17 16:00",
            location: "E11"
        )

        let message = try edit.encodedMessage()
        let decoded = try CalendarEventEdit.decodeMessage(message)

        XCTAssertTrue(message.contains("\"start_at\""))
        XCTAssertTrue(message.contains("\"due_at\""))
        XCTAssertEqual(decoded, edit)
    }

    func testCalendarChangeEditDefaultsPreserveVisibleCalendarContent() throws {
        let change = CalendarChange(
            title: "영미 단편소설 기말고사",
            startAt: "2026-06-04T05:30:00.000Z",
            dueAt: "2026-06-04T06:30:00.000Z",
            location: "N4 1432호"
        )

        let defaults = change.editDefaults

        XCTAssertEqual(defaults.title, "영미 단편소설 기말고사")
        XCTAssertEqual(defaults.startAt, "2026-06-04 14:30")
        XCTAssertEqual(defaults.dueAt, "2026-06-04 15:30")
        XCTAssertEqual(defaults.location, "N4 1432호")
    }

    func testParsesNoticeStageTimingRenderMode() throws {
        let json = """
        {
          "status": "ok",
          "completed_at": "2026-05-21T00:00:00Z",
          "elapsed_ms": 4900,
          "notice_render_results": [
            {"target": "capture", "status": "ok", "output": "Captured native notice checklist state"},
            {"target": "primary", "status": "ok", "output": "Updated native notice notes"}
          ],
          "slowest_events": [
            {"group": "native-notice-note", "name": "primary", "stage": "notice-summary", "duration_ms": 3000, "status": "ok"}
          ]
        }
        """

        let timing = try JSONDecoder().decode(StageTimingReport.self, from: Data(json.utf8))

        XCTAssertEqual(timing.elapsedSecondsText, "4.90s")
        XCTAssertEqual(timing.noticeRenderResults.first?.target, "capture")
        XCTAssertEqual(timing.slowestEvents.first?.durationSecondsText, "3s")
    }

    func testNoticeRenderResultsDisplayPrimaryBeforeArchiveAndCapture() throws {
        let timing = StageTimingReport(
            noticeRenderResults: [
                NoticeRenderResult(target: "capture", status: "ok", output: ""),
                NoticeRenderResult(target: "archive", status: "ok", output: ""),
                NoticeRenderResult(target: "primary", status: "ok", output: ""),
            ]
        )

        XCTAssertEqual(
            timing.noticeRenderResultsForDisplay.map(\.target),
            ["primary", "archive", "capture"]
        )
    }

    func testNoticeRenderResultsDisplayPrimaryStableNoopBeforeArchive() throws {
        let timing = StageTimingReport(
            noticeRenderResults: [
                NoticeRenderResult(target: "archive", status: "ok", output: ""),
                NoticeRenderResult(target: "primary-stable-noop", status: "skipped", output: ""),
                NoticeRenderResult(target: "capture-state-preserved", status: "ok", output: ""),
            ]
        )

        XCTAssertEqual(
            timing.noticeRenderResultsForDisplay.map(\.target),
            ["primary-stable-noop", "archive", "capture-state-preserved"]
        )
        XCTAssertEqual(timing.noticeRenderResultsForDisplay[0].displayTargetTitle, "KLMS 공지")
        XCTAssertEqual(timing.noticeRenderResultsForDisplay[1].displayTargetTitle, "확인한 공지")
        XCTAssertEqual(timing.noticeRenderResultsForDisplay[2].displayTargetTitle, "체크 표시 보존")
    }

    func testStaleRunningNoticeStageTimingIsMarkedInterrupted() throws {
        let timing = StageTimingReport(
            status: "running",
            runStartedAt: "2026-05-29T00:00:00.000Z",
            completedAt: "",
            elapsedMS: 14825
        )

        let stale = timing.markingStaleRunningIfNeeded(
            now: ISO8601DateFormatter().date(from: "2026-05-29T00:31:00Z")!
        )
        let fresh = timing.markingStaleRunningIfNeeded(
            now: ISO8601DateFormatter().date(from: "2026-05-29T00:10:00Z")!
        )

        XCTAssertEqual(stale.status, "interrupted")
        XCTAssertEqual(stale.status.klmsLocalizedStatus, "중단됨")
        XCTAssertEqual(fresh.status, "running")
    }

    func testParsesFilePreviewAndQuarantineReport() throws {
        let previewJSON = """
        {
          "manifest_count": 10,
          "actual_file_count": 9,
          "new_url_count": 1,
          "moved_count": 2,
          "local_missing_count": 6,
          "recoverable_missing_count": 2,
          "fresh_download_candidate_count": 3,
          "prune_candidate_count": 4,
          "type_mismatch_candidate_count": 5,
          "new_url_entries": [{"course": "CS", "filename": "a.pdf", "effective_relative_path": "CS/a.pdf", "url": "u"}],
          "moved_entries": [],
          "local_missing_entries": [{"course": "CS", "filename": "b.pdf", "effective_relative_path": "CS/b.pdf", "expected_path": "/tmp/CS/b.pdf", "recovery_source_path": "/archive/CS/b.pdf", "url": "u2"}],
          "recoverable_missing_entries": [],
          "fresh_download_candidates": [],
          "prune_candidates": ["old.pdf"],
          "type_mismatch_candidates": []
        }
        """
        let quarantineJSON = """
        {
          "quarantineRoot": "/tmp/q",
          "quarantineCount": 1,
          "records": [{"url": "u", "quarantine_path": "/tmp/q/a", "quarantine_relative_path": "a", "bytes": 10}]
        }
        """

        let preview = try JSONDecoder().decode(FileSyncPreview.self, from: Data(previewJSON.utf8))
        let quarantine = try JSONDecoder().decode(QuarantineReport.self, from: Data(quarantineJSON.utf8))

        XCTAssertEqual(preview.freshDownloadCandidateCount, 3)
        XCTAssertEqual(preview.localMissingCount, 6)
        XCTAssertEqual(preview.recoverableMissingCount, 2)
        XCTAssertEqual(preview.localMissingEntries.first?.expectedPath, "/tmp/CS/b.pdf")
        XCTAssertEqual(preview.localMissingEntries.first?.recoverySourcePath, "/archive/CS/b.pdf")
        XCTAssertEqual(preview.pruneCandidates, ["old.pdf"])
        XCTAssertEqual(quarantine.quarantineCount, 1)
        XCTAssertEqual(quarantine.records.first?.bytes, 10)
    }

    func testParsesFileDryRunBackupManifests() throws {
        let json = """
        {
          "dry_run": true,
          "scope": "files",
          "would_create": 0,
          "would_update": 2,
          "would_delete": 5,
          "would_download": 3,
          "would_prune": 5,
          "would_prune_course_files": 4,
          "would_prune_archive": 1,
          "skipped_side_effects": ["download", "prune-delete"],
          "prune_backup_manifest": "/tmp/course_files.json",
          "archive_prune_backup_manifest": "/tmp/archive.json"
        }
        """

        let report = try JSONDecoder().decode(DryRunReport.self, from: Data(json.utf8))

        XCTAssertEqual(report.wouldPruneCourseFiles, 4)
        XCTAssertEqual(report.wouldPruneArchive, 1)
        XCTAssertEqual(report.pruneBackupManifest, "/tmp/course_files.json")
        XCTAssertEqual(report.archivePruneBackupManifest, "/tmp/archive.json")
    }

    func testParsesDoctorDetailAndBuildsAttentionIssue() throws {
        let json = """
        {
          "status": "fail",
          "checks": [
            {"name": "config.env", "status": "ok", "detail": "config.env"},
            {"name": "file-manifest", "status": "fail", "detail": "tracked=72 missing=17"},
            {"name": "klms-login-cache", "status": "warn", "detail": "KLMS 로그인이 풀린 것 같아. 다시 로그인해 줘."}
          ]
        }
        """

        let doctor = try JSONDecoder().decode(DoctorResult.self, from: Data(json.utf8))
        let snapshot = EngineSnapshot(doctorResult: doctor)

        XCTAssertEqual(doctor.checks[1].detail, "tracked=72 missing=17")
        XCTAssertEqual(doctor.checks[1].message, "tracked=72 missing=17")
        XCTAssertTrue(snapshot.needsAttention)
        XCTAssertEqual(snapshot.attentionSummary, "파일 17개 누락")
        XCTAssertEqual(snapshot.issues.map(\.title), ["파일 17개 누락", "KLMS 로그인 필요"])
    }

    func testParsesNoticeRenderWarningIssue() throws {
        let json = """
        {
          "status": "warn",
          "code": "capture_state_failed",
          "user_message": "읽음/중요 체크 상태 캡처 실패",
          "raw_first_line": "Native notice note render warning (capture): Error: Could not confirm the cursor",
          "nonfatal": true
        }
        """

        let status = try JSONDecoder().decode(NoticeRenderStatus.self, from: Data(json.utf8))
        let snapshot = EngineSnapshot(noticeRenderStatus: status)

        XCTAssertEqual(status.userMessage, "읽음/중요 체크 상태 캡처 실패")
        XCTAssertTrue(status.nonfatal)
        XCTAssertTrue(snapshot.needsAttention)
        XCTAssertEqual(snapshot.attentionSummary, "읽음/중요 체크 상태 캡처 실패")
    }

    func testParsesNoticeNoteRenderState() throws {
        let json = """
        {
          "note_id": "x-coredata://note-id",
          "note_title": "KLMS 공지",
          "updated_at": "2026-05-18 20:44 KST",
          "style_version": "2026-05-18-body-semantic-notes",
          "rendered_notices": [
            {"title": "A"},
            {"title": "B"}
          ]
        }
        """

        let state = try JSONDecoder().decode(NoticeNoteRenderState.self, from: Data(json.utf8))

        XCTAssertEqual(state.noteID, "x-coredata://note-id")
        XCTAssertEqual(state.noteTitle, "KLMS 공지")
        XCTAssertEqual(state.updatedAt, "2026-05-18 20:44 KST")
        XCTAssertEqual(state.renderedNoticeCount, 2)
    }

    func testParsesVerifyDetailFallbackFromMessage() throws {
        let json = """
        {
          "status": "fail",
          "checks": [
            {"name": "state", "status": "fail", "message": "state mismatch"}
          ]
        }
        """

        let verify = try JSONDecoder().decode(VerifyResult.self, from: Data(json.utf8))

        XCTAssertEqual(verify.checks.first?.detail, "state mismatch")
        XCTAssertEqual(verify.checks.first?.message, "state mismatch")
    }

    func testParsesVerifyIntegrationSummaries() throws {
        let json = """
        {
          "status": "ok",
          "notices": {
            "digest_count": 65,
            "rendered_count": 65,
            "missing_count": 0,
            "exam_candidate_count": 2,
            "missing_exam_candidate_count": 0,
            "assignment_candidate_count": 2,
            "missing_assignment_candidate_count": 0
          },
          "files": {
            "manifest_file_count": 91,
            "missing_file_count": 1,
            "missing_files": ["데이타베이스 개론/board-attachments/NanoQuiz.pdf"],
            "derived_assignment_count": 0,
            "missing_derived_assignment_count": 0,
            "derived_exam_count": 0,
            "missing_derived_exam_count": 0,
            "classification_error": ""
          },
          "state": {
            "assignment_count": 3,
            "exam_count": 2,
            "helpdesk_count": 1,
            "past_exam_count": 0,
            "missing_exam_info_count": 0
          },
          "calendar": {
            "exam_count": 2,
            "manual_exam_count": 1,
            "display_exam_count": 3,
            "helpdesk_count": 1,
            "legacy_assignment_exists": false,
            "legacy_alert_exists": false,
            "error": "",
            "result_totals": {"exam": 2, "helpdesk": 1}
          },
          "reminders": {
            "assignment_active_count": 3,
            "assignment_marker_count": 3,
            "assignment_list_exists": true,
            "issue_active_count": 0,
            "issue_marker_count": 0,
            "issue_list_exists": true,
            "alert_active_count": 6,
            "alert_marker_count": 6,
            "alert_list_exists": true,
            "total_active_count": 9,
            "total_marker_count": 9,
            "error": ""
          },
          "checks": []
        }
        """

        let verify = try JSONDecoder().decode(VerifyResult.self, from: Data(json.utf8))

        XCTAssertEqual(verify.notices?.renderedCount, 65)
        XCTAssertEqual(verify.notices?.examCandidateCount, 2)
        XCTAssertEqual(verify.files?.manifestFileCount, 91)
        XCTAssertEqual(verify.files?.missingFileCount, 1)
        XCTAssertEqual(verify.files?.missingFiles, ["데이타베이스 개론/board-attachments/NanoQuiz.pdf"])
        XCTAssertEqual(verify.state?.assignmentCount, 3)
        XCTAssertEqual(verify.calendar?.examCount, 2)
        XCTAssertEqual(verify.calendar?.manualExamCount, 1)
        XCTAssertEqual(verify.calendar?.displayExamCount, 3)
        XCTAssertEqual(verify.calendar?.resultTotals?.exam, 2)
        XCTAssertEqual(verify.reminders?.assignmentActiveCount, 3)
        XCTAssertEqual(verify.reminders?.alertActiveCount, 6)
        XCTAssertEqual(verify.reminders?.totalActiveCount, 9)
        XCTAssertEqual(verify.reminders?.assignmentListExists, true)
    }

    func testVerifyManifestIssueExplainsFileSyncMismatch() throws {
        let json = """
        {
          "status": "fail",
          "checks": [
            {"name": "manifest_files_exist", "status": "fail", "detail": "missing=18"}
          ]
        }
        """

        let verify = try JSONDecoder().decode(VerifyResult.self, from: Data(json.utf8))
        let snapshot = EngineSnapshot(verifyResult: verify)

        XCTAssertEqual(snapshot.attentionSummary, "상태 검사 실패 · 파일 18개 누락")
        XCTAssertEqual(
            snapshot.issues.first?.detail,
            "파일 목록에는 있는데 Mac 로컬 저장소에서 찾지 못한 파일이 18개 있다는 뜻입니다. 파일 동기화를 다시 실행하세요. 그래도 계속 실패하면 파일 탭에서 누락 파일을 확인하고 새 파일/수정 파일만 다시 받으면 됩니다."
        )
    }

    func testVerifyCalendarMismatchExplainsMissingCalendarExam() throws {
        let json = """
        {
          "status": "fail",
          "checks": [
            {"name": "calendar_exam_count_matches_state", "status": "fail", "detail": "calendar=1 state=2"},
            {"name": "calendar_result_exam_matches_state", "status": "fail", "detail": "result=1 state=2"}
          ]
        }
        """

        let verify = try JSONDecoder().decode(VerifyResult.self, from: Data(json.utf8))
        let snapshot = EngineSnapshot(verifyResult: verify)

        XCTAssertEqual(verify.checks[0].diagnosticTitle, "캘린더 시험 1개 누락")
        XCTAssertEqual(
            verify.checks[0].diagnosticExplanation,
            "앱 상태 파일에는 시험 2개가 있는데 Apple Calendar에는 시험 1개만 있습니다. 캘린더 이벤트가 삭제됐거나 반영 단계가 일부 실패했을 수 있습니다."
        )
        XCTAssertEqual(verify.checks[1].diagnosticTitle, "마지막 캘린더 반영에서 시험 1개 누락")
        XCTAssertEqual(snapshot.attentionSummary, "상태 검사 실패 · 캘린더 시험 1개 누락")
        XCTAssertTrue(snapshot.issues[0].detail.contains("과제/시험 동기화를 다시 실행"))
    }
}
