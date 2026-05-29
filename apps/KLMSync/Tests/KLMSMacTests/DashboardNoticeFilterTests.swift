import XCTest
@testable import KLMSMac

final class DashboardNoticeFilterTests: XCTestCase {
    func testAllCategoryShowsHiddenNoticesInsideHiddenOnlyArchive() {
        XCTAssertTrue(
            NoticeListCategory.all.matches(
                hidden: true,
                important: false,
                read: false,
                fresh: false,
                hiddenOnly: true
            )
        )
        XCTAssertFalse(
            NoticeListCategory.all.matches(
                hidden: false,
                important: false,
                read: false,
                fresh: false,
                hiddenOnly: true
            )
        )
    }

    func testVisibleNoticeCategoriesStillExcludeHiddenNoticesOutsideArchive() {
        XCTAssertFalse(
            NoticeListCategory.all.matches(
                hidden: true,
                important: false,
                read: false,
                fresh: false
            )
        )
        XCTAssertTrue(
            NoticeListCategory.hidden.matches(
                hidden: true,
                important: false,
                read: false,
                fresh: false
            )
        )
    }
}
