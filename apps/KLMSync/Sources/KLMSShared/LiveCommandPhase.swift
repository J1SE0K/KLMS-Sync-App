import Foundation

public enum KLMSLiveCommandPhase: String, Sendable, Equatable {
    case preparing
    case login
    case core
    case notice
    case files
    case cleanup

    public var displayName: String {
        switch self {
        case .preparing:
            "준비"
        case .login:
            "로그인"
        case .core:
            "과제/시험"
        case .notice:
            "공지"
        case .files:
            "파일"
        case .cleanup:
            "정리"
        }
    }

    public static func currentPhase(in output: String) -> KLMSLiveCommandPhase {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in lines.suffix(120).reversed() {
            if let phase = phase(forLatestLine: line) {
                return phase
            }
        }
        return .preparing
    }

    private static func phase(forLatestLine line: String) -> KLMSLiveCommandPhase? {
        let lowercased = line.lowercased()
        if lowercased.contains("cleanup start")
            || lowercased.contains("prune start")
            || line.contains("정리") {
            return .cleanup
        }
        if lowercased.contains("== files start")
            || lowercased.contains("[files ")
            || lowercased.contains("scope=files")
            || lowercased.contains("download start")
            || lowercased.contains("manifest build start")
            || lowercased.contains("file preview start") {
            return .files
        }
        if lowercased.contains("== notice start")
            || lowercased.contains("scope=notice")
            || lowercased.contains("notice-summary")
            || lowercased.contains("native notice")
            || line.contains("공지") {
            return .notice
        }
        if lowercased.contains("== core start")
            || lowercased.contains("scope=core")
            || lowercased.contains("assignments=")
            || lowercased.contains("exams=") {
            return .core
        }
        if lowercased.contains("login")
            || lowercased.contains("authenticated")
            || line.contains("KAIST 인증 번호") {
            return .login
        }
        return nil
    }
}
