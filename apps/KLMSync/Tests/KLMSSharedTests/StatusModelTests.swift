import KLMSShared
import XCTest

final class StatusModelTests: XCTestCase {
    func testParsesSyncReportAndAttentionState() throws {
        let json = """
        {
          "status": "ok",
          "runs": {"files": {"scope": "files", "status": "ok", "completed_at": "now", "elapsed_ms": 1500}},
          "state": {"assignments": 2, "exams": 1, "helpdesk": 1},
          "notices": {"total": 9, "new": 2, "updated": 1, "ignored": 0},
          "files": {"total": 12, "new_files": 3, "quarantine": 1, "pruned": 4, "archive_pruned": 5},
          "calendar": {"created": 1, "updated": 2, "deleted": 3},
          "slowest": [{"name": "files", "duration_ms": 500, "status": "ok"}]
        }
        """

        let report = try JSONDecoder().decode(SyncReport.self, from: Data(json.utf8))

        XCTAssertEqual(report.state.assignments, 2)
        XCTAssertEqual(report.files.newFiles, 3)
        XCTAssertEqual(report.files.quarantine, 1)
        XCTAssertEqual(report.runs["files"]?.elapsedSecondsText, "1.50s")
        XCTAssertEqual(report.slowest.first?.durationSecondsText, "0.50s")
        XCTAssertTrue(report.needsAttention)
    }

    func testParsesFilePreviewAndQuarantineReport() throws {
        let previewJSON = """
        {
          "manifest_count": 10,
          "actual_file_count": 9,
          "new_url_count": 1,
          "moved_count": 2,
          "fresh_download_candidate_count": 3,
          "prune_candidate_count": 4,
          "type_mismatch_candidate_count": 5,
          "new_url_entries": [{"course": "CS", "filename": "a.pdf", "effective_relative_path": "CS/a.pdf", "url": "u"}],
          "moved_entries": [],
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
}
