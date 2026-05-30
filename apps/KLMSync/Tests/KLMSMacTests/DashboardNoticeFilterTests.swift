import XCTest
@testable import KLMSMac

final class DashboardNoticeFilterTests: XCTestCase {
    func testDashboardDetailKindIncludesFullFileList() {
        XCTAssertEqual(DashboardDetailKind.files.title, "파일 목록")
        XCTAssertTrue(DashboardDetailKind.allCases.contains(.files))
    }

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

    func testFreshNoticeCategoryExcludesAlreadyReadItems() {
        XCTAssertTrue(
            NoticeListCategory.fresh.matches(
                hidden: false,
                important: false,
                read: false,
                fresh: true
            )
        )
        XCTAssertFalse(
            NoticeListCategory.fresh.matches(
                hidden: false,
                important: false,
                read: true,
                fresh: true
            )
        )
    }
}
