import Foundation

/// 원격 상태의 인증 결과를 화면과 알림에 어떻게 보일지 정하는 규칙.
///
/// iOS 앱이 가지고 있던 판정을 공유 대상으로 옮긴 것이다. 앱 타깃은 테스트에서 가져올 수 없어서
/// 예전에는 앱 소스 문자열을 검사했다. 여기서는 동작으로 검사한다.
public enum KLMSAuthStatusPolicy {
    /// 같은 종류의 인증 성공 알림을 다시 띄우기 전 최소 간격(초).
    public static let successAlertRepeatInterval: TimeInterval = 90

    public static func isAlreadyLoggedInMessage(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("이미 로그인") || normalized.contains("already")
    }

    /// 인증 숫자 선택이 끝났고 다시 로그인할 필요도 없는 상태인가.
    public static func hasAuthCompletionStatus(_ status: SanitizedRemoteStatus) -> Bool {
        status.authStatusMessage != nil
            && status.authDigits == nil
            && !status.loginRequired
    }

    /// 인증 완료 문구를 상태 줄에 보여도 되는가. 오류가 있거나 최근 명령이 실패·취소·Mac 응답 없음이면 숨긴다.
    public static func shouldShowAuthCompletion(
        status: SanitizedRemoteStatus,
        errorMessage: String,
        latestDisplayStatus: RemoteCommandStatus?
    ) -> Bool {
        guard hasAuthCompletionStatus(status),
              errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        switch latestDisplayStatus {
        case .failed, .cancelled, .macUnavailable:
            return false
        case .pending, .running, .completed, .none:
            return true
        }
    }

    /// 인증 완료 카드의 제목. 이미 로그인된 경우를 인증 완료로 부풀리지 않는다.
    public static func displayTitle(for status: SanitizedRemoteStatus) -> String {
        guard let message = status.authStatusMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else {
            return "인증 완료"
        }
        return isAlreadyLoggedInMessage(message) ? "이미 로그인됨" : "인증 완료"
    }

    /// 인증 숫자를 보여 주던 상태에서 실제로 인증이 끝난 상태로 넘어갔을 때만 알린다.
    /// 이미 로그인되어 있던 경우는 알리지 않는다.
    public static func shouldNotifyAuthSuccess(
        from previousStatus: SanitizedRemoteStatus,
        to status: SanitizedRemoteStatus
    ) -> Bool {
        guard let message = status.authStatusMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty,
              previousStatus.authDigits != nil,
              status.authDigits == nil,
              !status.loginRequired else {
            return false
        }
        return !isAlreadyLoggedInMessage(message)
    }

    /// 문구가 조금 달라도 같은 종류의 성공이면 같은 키를 준다.
    public static func successDeduplicationKey(_ message: String) -> String {
        if isAlreadyLoggedInMessage(message) {
            return "already-logged-in"
        }
        return "auth-completed"
    }

    /// 같은 키의 알림은 successAlertRepeatInterval 이 지나야 다시 띄운다.
    public static func shouldPresentSuccessAlert(
        deduplicationKey: String,
        lastDeduplicationKey: String?,
        lastPresentedAt: Date?,
        now: Date
    ) -> Bool {
        guard deduplicationKey != lastDeduplicationKey else {
            guard let lastPresentedAt else {
                return true
            }
            return now.timeIntervalSince(lastPresentedAt) > successAlertRepeatInterval
        }
        return true
    }
}
