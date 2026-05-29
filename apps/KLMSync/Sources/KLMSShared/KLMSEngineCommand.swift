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

    public var displayName: String {
        switch self {
        case .all:
            "전체"
        case .core:
            "과제/시험"
        case .notice:
            "공지"
        case .files:
            "파일"
        case .shared:
            "공통"
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
            "공지 메모"
        case .filesSync:
            "파일 동기화"
        case .verify:
            "상태 검사"
        case .doctor:
            "권한/환경 진단"
        case .report:
            "요약 갱신"
        case .v2BuildState:
            "상태 파일 재생성"
        }
    }

    public var systemImage: String {
        switch self {
        case .fullSync:
            "arrow.triangle.2.circlepath"
        case .coreSync:
            "checklist"
        case .noticeSync:
            "note.text"
        case .filesSync:
            "folder"
        case .verify:
            "checkmark.seal"
        case .doctor:
            "wrench.and.screwdriver"
        case .report:
            "chart.bar.doc.horizontal"
        case .v2BuildState:
            "shippingbox.and.arrow.backward"
        }
    }

    public var shortDescription: String {
        switch self {
        case .fullSync:
            "과제/시험, 공지 메모, 강의 파일을 순서대로 모두 동기화합니다."
        case .coreSync:
            "과제, 시험, 헬프데스크를 갱신하고 캘린더/미리 알림에 반영합니다."
        case .noticeSync:
            "KLMS 공지와 확인한 공지 메모를 체크리스트와 문단 형식으로 갱신합니다."
        case .filesSync:
            "강의 파일 목록을 새로 읽고 새 파일 보관함, 격리, 삭제 결과를 갱신합니다."
        case .verify:
            "현재 저장된 상태, 파일 목록, 캘린더/미리 알림 결과가 맞는지 검사합니다."
        case .doctor:
            "config.env, Python/Node, Safari/Notes/캘린더/미리 알림 권한과 로그인 캐시를 점검합니다."
        case .report:
            "동기화는 실행하지 않고 앱 대시보드용 요약 파일만 다시 만듭니다."
        case .v2BuildState:
            "KLMS 캐시로 내부 상태 파일만 재생성합니다. 메모, 캘린더, 미리 알림에는 반영하지 않습니다."
        }
    }

    public var isDiagnostic: Bool {
        switch self {
        case .verify, .doctor, .report, .v2BuildState:
            true
        case .fullSync, .coreSync, .noticeSync, .filesSync:
            false
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

    public var refreshesSyncReportAfterRun: Bool {
        switch self {
        case .fullSync, .coreSync, .noticeSync, .filesSync:
            true
        case .verify, .doctor, .report, .v2BuildState:
            false
        }
    }

    public var refreshesVerificationAfterRun: Bool {
        switch self {
        case .fullSync, .coreSync, .noticeSync, .filesSync:
            true
        case .verify, .doctor, .report, .v2BuildState:
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
