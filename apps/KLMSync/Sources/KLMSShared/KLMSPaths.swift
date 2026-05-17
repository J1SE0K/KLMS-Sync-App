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

    public static func defaultLaunchAgentsDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return library.appendingPathComponent("LaunchAgents", isDirectory: true)
    }

    public var configURL: URL {
        engineRoot.appendingPathComponent("config.env")
    }

    public var runtimeURL: URL {
        engineRoot.appendingPathComponent("runtime", isDirectory: true)
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

    public var launchAgentLogURL: URL {
        logsURL.appendingPathComponent("launch-agent.log")
    }

    public var syncReportURL: URL {
        cacheURL.appendingPathComponent("sync_report.json")
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

    public func dryRunReportURL(scope: KLMSSyncScope) -> URL {
        cacheURL
            .appendingPathComponent(scope.cacheNamespace, isDirectory: true)
            .appendingPathComponent("dry_run_report.json")
    }
}
