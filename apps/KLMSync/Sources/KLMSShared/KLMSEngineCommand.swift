import Foundation

public enum KLMSSyncScope: String, CaseIterable, Sendable, Codable {
    case all
    case core
    case notice
    case files
    case shared

    public var cacheNamespace: String {
        switch self {
        case .all:
            "all"
        case .core:
            "core"
        case .notice:
            "notice"
        case .files:
            "files"
        case .shared:
            "shared"
        }
    }
}

public enum KLMSEngineCommand: String, CaseIterable, Sendable, Codable, Identifiable {
    case fullSync
    case coreSync
    case noticeSync
    case filesSync
    case verify
    case doctor
    case report
    case v2BuildState

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fullSync:
            "전체 동기화"
        case .coreSync:
            "과제/시험"
        case .noticeSync:
            "공지"
        case .filesSync:
            "파일"
        case .verify:
            "상태 점검"
        case .doctor:
            "진단"
        case .report:
            "리포트"
        case .v2BuildState:
            "v2 상태 생성"
        }
    }

    public var scriptName: String {
        switch self {
        case .fullSync:
            "run_all_full.sh"
        case .coreSync:
            "sync_klms_core.sh"
        case .noticeSync:
            "sync_klms_notice.sh"
        case .filesSync:
            "refresh_course_files.sh"
        case .verify:
            "verify_sync_state.sh"
        case .doctor:
            "doctor.sh"
        case .report:
            "sync_report.sh"
        case .v2BuildState:
            "klms_v2_build_state.sh"
        }
    }

    public var scope: KLMSSyncScope {
        switch self {
        case .fullSync:
            .all
        case .coreSync:
            .core
        case .noticeSync:
            .notice
        case .filesSync:
            .files
        case .verify, .doctor, .report, .v2BuildState:
            .shared
        }
    }

    public var supportsDryRun: Bool {
        switch self {
        case .fullSync, .coreSync, .noticeSync, .filesSync:
            true
        case .verify, .doctor, .report, .v2BuildState:
            false
        }
    }

    public var emitsJSON: Bool {
        switch self {
        case .verify, .doctor, .report:
            true
        case .fullSync, .coreSync, .noticeSync, .filesSync, .v2BuildState:
            false
        }
    }

    public func invocation(configPath: String = "./config.env", dryRun: Bool = false) -> KLMSCommandInvocation {
        var args: [String] = ["./\(scriptName)"]
        if emitsJSON {
            args.append("--json")
        }
        args.append(configPath)
        if dryRun && supportsDryRun {
            args.append("--dry-run")
        }
        return KLMSCommandInvocation(
            executablePath: "/bin/zsh",
            arguments: args,
            command: self,
            dryRun: dryRun && supportsDryRun
        )
    }
}

public struct KLMSCommandInvocation: Sendable, Equatable {
    public var executablePath: String
    public var arguments: [String]
    public var command: KLMSEngineCommand
    public var dryRun: Bool

    public init(
        executablePath: String,
        arguments: [String],
        command: KLMSEngineCommand,
        dryRun: Bool
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.command = command
        self.dryRun = dryRun
    }
}
