import KLMSShared
import XCTest

final class RemoteSettingGroupRulesTests: XCTestCase {
    private func setting(_ key: String, title: String? = nil) -> ServerRelaySetting {
        ServerRelaySetting(key: key, title: title ?? key, updatedAt: "2026-09-29T00:00:00Z")
    }

    func testEmptySettingsMakeNoGroups() {
        XCTAssertEqual(RemoteSettingGroup.grouped(settings: []), [])
    }

    func testGroupsFollowSpecOrderAndKeyOrderAndSkipEmptyGroups() {
        let settings = [
            setting("CALENDAR_SKIP_UNCHANGED_DESIRED"),
            setting("FILE_WEEKLY_FOLDERS_ENABLED"),
            setting("KLMS_LOGIN_ASSIST_ALLOW_NONINTERACTIVE"),
            setting("FILE_REFRESH_MODE"),
            setting("KLMS_LOGIN_ASSIST_ENABLED"),
        ]
        let groups = RemoteSettingGroup.grouped(settings: settings)
        XCTAssertEqual(groups.map(\.title), ["로그인", "파일", "캘린더"])
        XCTAssertEqual(groups[0].settings.map(\.key), ["KLMS_LOGIN_ASSIST_ENABLED", "KLMS_LOGIN_ASSIST_ALLOW_NONINTERACTIVE"])
        XCTAssertEqual(groups[1].settings.map(\.key), ["FILE_REFRESH_MODE", "FILE_WEEKLY_FOLDERS_ENABLED"])
        XCTAssertEqual(groups[2].settings.map(\.key), ["CALENDAR_SKIP_UNCHANGED_DESIRED"])
        XCTAssertEqual(groups[0].systemImage, "person.badge.key")
        XCTAssertEqual(groups[0].detail, "인증번호 감지와 로그인 보조 동작을 정합니다.")
        XCTAssertEqual(groups[1].systemImage, "folder")
        XCTAssertEqual(groups[2].systemImage, "calendar")
        XCTAssertTrue(groups.allSatisfy(\.isCollapsible))
        XCTAssertEqual(groups[1].id, "파일")
        XCTAssertEqual(groups[1].countText, "2개")
    }

    func testAllSpecGroupsAppearInOrder() {
        let keys = [
            "KLMS_SAFARI_REUSE_EXISTING_WINDOW_ENABLED",
            "NOTICE_NATIVE_PLAIN_TEXT_PASTE",
            "SYNC_MODE",
            "CALENDAR_SKIP_UNCHANGED_DESIRED",
            "FILE_KEEP_FRESH_DOWNLOADS",
            "KLMS_LOGIN_ASSIST_ENABLED",
        ]
        let groups = RemoteSettingGroup.grouped(settings: keys.map { setting($0) })
        XCTAssertEqual(groups.map(\.title), ["로그인", "동기화", "파일", "공지 메모", "캘린더", "고급"])
        XCTAssertEqual(groups.map(\.systemImage), [
            "person.badge.key",
            "arrow.triangle.2.circlepath",
            "folder",
            "checklist",
            "calendar",
            "slider.horizontal.3",
        ])
    }

    func testUnknownSettingsJoinExistingAdvancedGroupAfterItsOwnKeys() {
        let settings = [
            setting("CUSTOM_B"),
            setting("KLMS_SAFARI_BACKGROUND_WINDOW_MODE"),
            setting("CUSTOM_A"),
            setting("SYNC_MODE"),
        ]
        let groups = RemoteSettingGroup.grouped(settings: settings)
        XCTAssertEqual(groups.map(\.title), ["동기화", "고급"])
        XCTAssertEqual(groups[1].settings.map(\.key), ["KLMS_SAFARI_BACKGROUND_WINDOW_MODE", "CUSTOM_B", "CUSTOM_A"])
    }

    func testUnknownSettingsCreateAdvancedGroupWhenMissing() {
        let groups = RemoteSettingGroup.grouped(settings: [setting("SYNC_MODE"), setting("CUSTOM_ONLY")])
        XCTAssertEqual(groups.map(\.title), ["동기화", "고급"])
        XCTAssertEqual(groups[1].settings.map(\.key), ["CUSTOM_ONLY"])
        XCTAssertEqual(groups[1].systemImage, "slider.horizontal.3")
        XCTAssertEqual(groups[1].detail, "Safari 창 동작처럼 자주 바꾸지 않는 설정입니다.")
        XCTAssertTrue(groups[1].isCollapsible)
    }

    func testDuplicateKeysKeepFirstSettingInGroupAndRepeatAsExtras() {
        let first = setting("SYNC_MODE", title: "처음")
        let second = setting("SYNC_MODE", title: "나중")
        let groups = RemoteSettingGroup.grouped(settings: [first, second])
        // 묶음은 키별 첫 설정을 쓴다. 이미 쓴 키는 extras 에서 빠지므로 두 번째 설정은 어디에도 들어가지 않는다.
        XCTAssertEqual(groups.map(\.title), ["동기화"])
        XCTAssertEqual(groups[0].settings, [first])
    }
}
