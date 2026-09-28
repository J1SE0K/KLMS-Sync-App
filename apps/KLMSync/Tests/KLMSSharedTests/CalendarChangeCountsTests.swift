import XCTest
@testable import KLMSShared

/// KLMSCalendarChangeCounts 의 동작 검사. 예전에는 DashboardDataModelTests 가 iOS 앱 소스에
/// 같은 switch 가 적혀 있는지를 문자열로 확인했다(Mac 쪽 두 벌은 검사가 없었다).
final class CalendarChangeCountsTests: XCTestCase {
    func testCountsCreatedMailUpdatedDeletedIgnoringCaseAndSpace() {
        let changes = [
            CalendarChange(action: "created"),
            CalendarChange(action: " Mail "),
            CalendarChange(action: "UPDATED"),
            CalendarChange(action: "updated\n"),
            CalendarChange(action: "deleted"),
            CalendarChange(action: "moved"),
            CalendarChange(action: ""),
        ]
        let counts = KLMSCalendarChangeCounts(changes: changes)
        XCTAssertEqual(counts, KLMSCalendarChangeCounts(created: 2, updated: 2, deleted: 1))
        XCTAssertEqual(counts.total, 5)
    }

    func testEmptyInputCountsNothing() {
        XCTAssertEqual(KLMSCalendarChangeCounts(changes: [CalendarChange]()), KLMSCalendarChangeCounts())
        XCTAssertEqual(KLMSCalendarChangeCounts().total, 0)
    }

    func testCountsAgreeWithDeletedFlagAndAcceptLazySequences() {
        let changes = [CalendarChange(action: " Deleted "), CalendarChange(action: "created")]
        XCTAssertTrue(changes[0].isDeletedAction)
        let counts = KLMSCalendarChangeCounts(changes: changes.lazy.filter { !$0.isDeletedAction })
        XCTAssertEqual(counts, KLMSCalendarChangeCounts(created: 1))
    }
}
