import Foundation

// Mac 앱과 iOS 앱이 같은 코드를 따로 들고 있던 작은 표시 규칙들. 앱 타깃은 테스트에서 가져올 수 없어서
// 예전에는 두 앱의 소스 문자열을 검사했다. 여기로 모아 동작으로 검사한다(SharedDisplayRulesTests).

/// 설정 값을 한 줄 요약으로 보일 때의 규칙.
public enum KLMSSettingValueSummary {
    /// 경로처럼 보이거나 18자를 넘는 값은 내용을 드러내지 않고 "저장됨"으로 줄인다.
    public static func compact(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "비어 있음"
        }
        if trimmed.contains("/") || trimmed.contains("\\") || trimmed.count > 18 {
            return "저장됨"
        }
        return trimmed
    }

    /// 선택형 설정 값의 표시 이름. 모르는 값은 compact 규칙을 따른다.
    public static func choiceTitle(_ value: String) -> String {
        switch value {
        case "auto":
            return "자동"
        case "quick":
            return "빠른 모드"
        case "full":
            return "전체 다시 읽기"
        case "manual-digits":
            return "인증번호 직접 선택"
        case "minimize":
            return "창 최소화"
        case "none":
            return "그대로 두기"
        case "":
            return "선택"
        default:
            return compact(value)
        }
    }
}

/// relay 토큰을 캐시 키에 넣을 때 쓰는 지문. 토큰 원문을 남기지 않는다.
/// 실행마다 값이 바뀌는 Hasher 대신 FNV-1a 방식(바이트 XOR 뒤 소수 0x100000001b3 곱셈)을 써서 앱을 다시 켜도 같은 키가 나온다.
/// 시작값은 표준 offset basis(0xcbf29ce484222325)가 아니라 두 앱이 원래 쓰던 1_469_598_103_934_665_603(0x14650fb0739d0383)이다.
/// 이미 저장된 캐시 키와 맞아야 하므로 이 값을 표준값으로 바꾸지 않는다.
public enum KLMSRelayTokenFingerprint {
    public static func make(_ token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "missing-token"
        }
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in trimmed.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "token-\(trimmed.count)-\(String(hash, radix: 16))"
    }
}

/// 보조 명령 버튼의 아이콘. 실행 중이면 멈춤, 막혀 있으면 자물쇠, 그 밖에는 아이콘 없음.
public enum KLMSCommandButtonIcon {
    public static func secondary(isRunning: Bool, isDisabled: Bool) -> String? {
        if isRunning { return "stop.fill" }
        if isDisabled { return "lock.fill" }
        return nil
    }
}

/// 화면에 보일 로그 길이를 줄이는 규칙. 한도는 화면마다 달라서 부르는 쪽이 정한다.
public enum KLMSLogTruncation {
    public static let foldedPrefix = "... 화면 표시용으로 이전 로그 일부를 접었습니다 ...\n"

    /// 한도를 넘으면 앞부분을 접고, 접었다는 안내 줄을 붙여 전체 길이를 한도에 맞춘다.
    public static func bounded(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else {
            return text
        }
        return foldedPrefix + String(text.suffix(maxCharacters - foldedPrefix.count))
    }

    /// 강조 표시를 계산할 원문. 한도를 넘으면 뒤쪽만 남긴다(안내 줄 없음).
    public static func highlightSource(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else {
            return text
        }
        return String(text.suffix(maxCharacters))
    }
}
