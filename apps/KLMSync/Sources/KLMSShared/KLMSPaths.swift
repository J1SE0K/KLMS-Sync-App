import Foundation

public struct KLMSPaths: Sendable, Equatable {
    public var engineRoot: URL

    public init(engineRoot: URL = KLMSPaths.defaultEngineRoot()) {
        self.engineRoot = engineRoot
    }

    public static func defaultEngineRoot(
        fileManager: FileManager = .default
    ) -> URL {
        let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("KLMSNotesSync", isDirectory: true)
    }

    public var configURL: URL {
        engineRoot.appendingPathComponent("config.env")
    }

    public var overridesURL: URL {
        engineRoot.appendingPathComponent("manual_assignment_overrides.json")
    }

    public var runtimeURL: URL {
        engineRoot.appendingPathComponent("runtime", isDirectory: true)
    }

    public var courseFilesURL: URL {
        engineRoot.appendingPathComponent("course_files", isDirectory: true)
    }

    public var cacheURL: URL {
        runtimeURL.appendingPathComponent("cache", isDirectory: true)
    }

    public var stateURL: URL {
        runtimeURL.appendingPathComponent("state", isDirectory: true)
    }

    public var automationURL: URL {
        runtimeURL.appendingPathComponent("automation", isDirectory: true)
    }

    public var logsURL: URL {
        runtimeURL.appendingPathComponent("logs", isDirectory: true)
    }

    public var backupsURL: URL {
        runtimeURL.appendingPathComponent("backups", isDirectory: true)
    }

    public var appPythonPackagesURL: URL {
        runtimeURL.appendingPathComponent("app-python-packages", isDirectory: true)
    }

    public var appHistoryURL: URL {
        cacheURL.appendingPathComponent("app_command_history.json")
    }

    public var installedPayloadVersionURL: URL {
        automationURL.appendingPathComponent("app_engine_payload_version")
    }

    public var relayStdoutLogURL: URL {
        logsURL.appendingPathComponent("relay.stdout.log")
    }

    public var relayStderrLogURL: URL {
        logsURL.appendingPathComponent("relay.stderr.log")
    }

    public var syncReportURL: URL {
        cacheURL.appendingPathComponent("sync_report.json")
    }

    public var calendarSyncResultURL: URL {
        cacheURL
            .appendingPathComponent("core", isDirectory: true)
            .appendingPathComponent("calendar_sync_result.json")
    }

    public var doctorResultURL: URL {
        cacheURL.appendingPathComponent("doctor_result.json")
    }

    public var verifyResultURL: URL {
        cacheURL.appendingPathComponent("verify_sync_state.json")
    }

    public var loginStatusURL: URL {
        cacheURL.appendingPathComponent("login_status.json")
    }

    public var noticeRenderErrorSummaryURL: URL {
        cacheURL.appendingPathComponent("notice_render_error_summary.json")
    }

    public var noticeStageTimingURL: URL {
        cacheURL
            .appendingPathComponent("notice", isDirectory: true)
            .appendingPathComponent("stage_timings.json")
    }

    public var noticeDigestURL: URL {
        cacheURL.appendingPathComponent("notice_digest.json")
    }

    public var noticeRenderStateURL: URL {
        cacheURL.appendingPathComponent("notice_note_render_state.json")
    }

    public var noticeArchiveRenderStateURL: URL {
        cacheURL.appendingPathComponent("notice_archive_note_render_state.json")
    }

    public var noticeUserStateURL: URL {
        cacheURL.appendingPathComponent("notice_user_state.json")
    }

    public var appUserStateURL: URL {
        cacheURL.appendingPathComponent("app_user_state.json")
    }

    public var stateJSONURL: URL {
        stateURL.appendingPathComponent("state.json")
    }

    public var filePreviewURL: URL {
        cacheURL.appendingPathComponent("course_file_sync_preview.json")
    }

    public var downloadResultURL: URL {
        cacheURL.appendingPathComponent("course_file_download_result.json")
    }

    public var quarantineReportURL: URL {
        cacheURL.appendingPathComponent("course_file_quarantine_report.json")
    }

    public var cleanupResultURL: URL {
        cacheURL.appendingPathComponent("course_file_cleanup_result.json")
    }

    public var courseFileManifestURL: URL {
        cacheURL.appendingPathComponent("course_file_manifest.json")
    }

    public var academicTermCatalogURL: URL {
        cacheURL.appendingPathComponent("academic_terms.json")
    }

    public func dryRunReportURL(scope: KLMSSyncScope) -> URL {
        cacheURL
            .appendingPathComponent(scope.cacheNamespace, isDirectory: true)
            .appendingPathComponent("dry_run_report.json")
    }
}
