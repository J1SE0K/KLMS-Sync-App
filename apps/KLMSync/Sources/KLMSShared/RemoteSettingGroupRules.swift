import Foundation

// iOS 설정 화면이 서버 설정을 묶는 규칙. 앱 타깃은 테스트에서 가져올 수 없어서 예전에는 iOS 앱 소스 문자열을
// 검사했다. 여기로 옮겨 동작으로 검사한다(RemoteSettingGroupRulesTests).

public struct RemoteSettingGroup: Identifiable, Equatable, Sendable {
    public var title: String
    public var systemImage: String
    public var detail: String
    public var settings: [ServerRelaySetting]
    public var isCollapsible = false

    public init(
        title: String,
        systemImage: String,
        detail: String,
        settings: [ServerRelaySetting],
        isCollapsible: Bool = false
    ) {
        self.title = title
        self.systemImage = systemImage
        self.detail = detail
        self.settings = settings
        self.isCollapsible = isCollapsible
    }

    public var id: String { title }
    public var countText: String { "\(settings.count)개" }

    public static func grouped(settings: [ServerRelaySetting]) -> [RemoteSettingGroup] {
        let byKey = Dictionary(settings.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var used = Set<String>()
        let specs: [(title: String, systemImage: String, detail: String, isCollapsible: Bool, keys: [String])] = [
            (
                "로그인",
                "person.badge.key",
                "인증번호 감지와 로그인 보조 동작을 정합니다.",
                true,
                ["KLMS_LOGIN_ASSIST_ENABLED", "KLMS_LOGIN_ASSIST_ALLOW_NONINTERACTIVE"]
            ),
            (
                "동기화",
                "arrow.triangle.2.circlepath",
                "동기화 범위를 정합니다.",
                true,
                ["SYNC_MODE"]
            ),
            (
                "파일",
                "folder",
                "파일 탐색, 주차별 폴더, 보존 방식을 정합니다.",
                true,
                [
                    "FILE_REFRESH_MODE",
                    "FILE_SKIP_DOWNLOAD_WHEN_PREVIEW_EMPTY",
                    "FILE_WEEKLY_FOLDERS_ENABLED",
                    "FILE_KEEP_FRESH_DOWNLOADS",
                    "FILE_PRESERVE_DOWNLOAD_ARCHIVE",
                ]
            ),
            (
                "공지 메모",
                "checklist",
                "공지 메모의 접기, 양식, 상태 반영 방식을 정합니다.",
                true,
                [
                    "NOTICE_COLLAPSE_SECTIONS",
                    "NOTICE_COLLAPSE_COURSES",
                    "NOTICE_COLLAPSE_NOTICE_ITEMS",
                    "NOTICE_STYLE_NOTICE_ITEMS_AS_HEADINGS",
                    "NOTICE_HIDE_HIDDEN_ITEMS",
                    "NOTICE_NATIVE_STABLE_NOOP_SKIP",
                    "NOTICE_NATIVE_ALWAYS_CAPTURE_STATE",
                    "NOTICE_NATIVE_VERIFY_STABLE_SKIP_FORMAT",
                    "NOTICE_NATIVE_PLAIN_TEXT_PASTE",
                ]
            ),
            (
                "캘린더",
                "calendar",
                "같은 일정은 건너뛰고 변경이 있을 때만 반영합니다.",
                true,
                ["CALENDAR_SKIP_UNCHANGED_DESIRED"]
            ),
            (
                "고급",
                "slider.horizontal.3",
                "Safari 창 동작처럼 자주 바꾸지 않는 설정입니다.",
                true,
                [
                    "KLMS_SAFARI_BACKGROUND_WINDOW_ENABLED",
                    "KLMS_SAFARI_BACKGROUND_WINDOW_MODE",
                    "KLMS_SAFARI_REUSE_EXISTING_WINDOW_ENABLED",
                ]
            ),
        ]

        var groups: [RemoteSettingGroup] = specs.compactMap { spec in
            let groupSettings = spec.keys.compactMap { key -> ServerRelaySetting? in
                guard let setting = byKey[key] else { return nil }
                used.insert(key)
                return setting
            }
            guard !groupSettings.isEmpty else { return nil }
            return RemoteSettingGroup(
                title: spec.title,
                systemImage: spec.systemImage,
                detail: spec.detail,
                settings: groupSettings,
                isCollapsible: spec.isCollapsible
            )
        }

        let extras = settings.filter { !used.contains($0.key) }
        if !extras.isEmpty {
            if let advancedIndex = groups.firstIndex(where: { $0.title == "고급" }) {
                groups[advancedIndex].settings.append(contentsOf: extras)
            } else {
                groups.append(
                    RemoteSettingGroup(
                        title: "고급",
                        systemImage: "slider.horizontal.3",
                        detail: "Safari 창 동작처럼 자주 바꾸지 않는 설정입니다.",
                        settings: extras,
                        isCollapsible: true
                    )
                )
            }
        }
        for index in groups.indices where groups[index].title == "고급" {
            groups[index].isCollapsible = true
        }
        return groups
    }
}
