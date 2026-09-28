import Foundation

/// iOS 동반 앱의 동기화 카드가 버튼을 켜고 끄는 규칙. 앱 타깃은 테스트에서 가져올 수 없어서
/// 예전에는 앱 소스 문자열을 검사했다. 동작은 RemoteSyncControlRulesTests 가 검사한다.
/// Xcode 빌드는 이 파일을 iOS 앱과 같은 모듈로 묶으므로 앱 쪽에 같은 이름을 다시 선언하면 안 된다.
public enum KLMSRemoteSyncControls {
    /// 서버에 보낸 요청이 남아 있거나 Mac 이 실행 중이라고 알려 온 동안.
    public static func isRunning(hasInFlightRequest: Bool, phase: String) -> Bool {
        hasInFlightRequest || phase == "running"
    }

    public static func stateTitle(isRunning: Bool, activeRequestLabel: String, isRemoteAvailable: Bool) -> String {
        if isRunning {
            return activeRequestLabel
        }
        return isRemoteAvailable ? "준비됨" : "설정 필요"
    }

    /// 지금 실행 중인 명령과 같은 종류인가. 같은 버튼은 멈춤 버튼으로 남아야 해서 따로 가린다.
    public static func isCommandActive(
        _ kind: RemoteCommandKind,
        latestDisplayStatusIsInFlight: Bool,
        latestCommandKind: RemoteCommandKind?
    ) -> Bool {
        latestDisplayStatusIsInFlight && latestCommandKind == kind
    }

    /// 연결이 없거나 제출 중이면 모두 막고, 다른 요청이 도는 중이면 그 명령 버튼만 남긴다.
    public static func commandDisabled(
        isRemoteAvailable: Bool,
        isSubmitting: Bool,
        hasInFlightRequest: Bool,
        isCommandActive: Bool
    ) -> Bool {
        if !isRemoteAvailable {
            return true
        }
        if isSubmitting {
            return true
        }
        return hasInFlightRequest && !isCommandActive
    }
}
