import XCTest
@testable import KLMSMac
import KLMSShared

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

    func testDashboardFileMetricFollowsScopeFilterAndHiddenState() {
        let springFile = CourseFileManifestEntry(
            filename: "봄 자료.pdf",
            relativePath: "알고리즘 개론/1주차/봄 자료.pdf",
            url: "https://klms.kaist.ac.kr/file-spring",
            course: "알고리즘 개론",
            absolutePath: "/tmp/봄 자료.pdf",
            klmsTimestamp: "2026-03-10 09:00 KST",
            klmsTimestampText: "2026년 3월 10일 오전 9:00"
        )
        let summerFile = CourseFileManifestEntry(
            filename: "여름 자료.pdf",
            relativePath: "공공정책 특강/1주차/여름 자료.pdf",
            url: "https://klms.kaist.ac.kr/file-summer",
            course: "공공정책 특강",
            absolutePath: "/tmp/여름 자료.pdf",
            klmsTimestamp: "2026-07-01 09:00 KST",
            klmsTimestampText: "2026년 7월 1일 오전 9:00"
        )
        let hiddenSpringFile = CourseFileManifestEntry(
            filename: "숨김 자료.pdf",
            relativePath: "알고리즘 개론/2주차/숨김 자료.pdf",
            url: "https://klms.kaist.ac.kr/file-hidden",
            course: "알고리즘 개론",
            absolutePath: "/tmp/숨김 자료.pdf",
            klmsTimestamp: "2026-03-11 09:00 KST",
            klmsTimestampText: "2026년 3월 11일 오전 9:00"
        )
        let snapshot = EngineSnapshot(
            appUserState: AppUserStateFile(files: [
                hiddenSpringFile.url: FileInteractionState(url: hiddenSpringFile.url, hidden: true)
            ]),
            courseFileManifest: [springFile, summerFile, hiddenSpringFile]
        )
        let summary = KLMSMacDashboardSummaryCache(
            visibleCounts: EngineVisibleCounts(newFiles: 0),
            serverFileCount: 99,
            serverDashboardItemsLoaded: true
        )

        let unfiltered = DashboardSummaryPresentation(snapshot: snapshot, summary: summary)
        XCTAssertEqual(unfiltered.primaryMetrics.first { $0.label == "파일" }?.value, 2)

        let scopedFileCount = DashboardFileMetricCounter.visibleCourseFileCount(
            snapshot: snapshot,
            selectedYear: "2026",
            selectedSemester: "봄학기"
        )
        XCTAssertEqual(scopedFileCount, 1)
    }

    func testFileFiltersUseServerItemsWhenLocalSnapshotIsStillEmpty() {
        let serverFile = ServerRelaySyncItem(
            id: "server-file-1",
            kind: "file",
            course: "공공정책 특강",
            academicTerm: "2026년 여름학기",
            academicYear: 2026,
            academicSemester: "여름학기",
            title: "강의자료.pdf",
            timestamp: "2026-07-01 09:00 KST"
        )

        let options = DashboardFilterOptions(
            kind: .files,
            snapshot: EngineSnapshot(),
            serverItems: [serverFile]
        )

        XCTAssertTrue(options.courses.contains("공공정책 특강"))
        XCTAssertTrue(options.years.contains("2026"))
        XCTAssertTrue(options.semesters.contains("여름학기"))
    }

    func testFileMetricUsesServerItemsWhenLocalSnapshotIsStillEmpty() {
        let visibleServerFile = ServerRelaySyncItem(
            id: "server-file-visible",
            kind: "file",
            course: "공공정책 특강",
            academicTerm: "2026년 여름학기",
            academicYear: 2026,
            academicSemester: "여름학기",
            title: "강의자료.pdf",
            timestamp: "2026-07-01 09:00 KST"
        )
        let hiddenServerFile = ServerRelaySyncItem(
            id: "server-file-hidden",
            kind: "file",
            course: "공공정책 특강",
            academicTerm: "2026년 여름학기",
            academicYear: 2026,
            academicSemester: "여름학기",
            title: "숨긴 자료.pdf",
            timestamp: "2026-07-02 09:00 KST",
            isHidden: true
        )

        let scopedFileCount = DashboardFileMetricCounter.visibleCourseFileCount(
            snapshot: EngineSnapshot(),
            selectedYear: "2026",
            selectedSemester: "여름학기",
            serverItems: [visibleServerFile, hiddenServerFile]
        )

        XCTAssertEqual(scopedFileCount, 1)
    }

    func testFileRecencyFallsBackToLocalDownloadWhenKLMSTimestampIsMissing() {
        XCTAssertEqual(
            fileRecencyText(
                klmsTimestampText: "KLMS 페이지에 시각 정보 없음",
                klmsTimestamp: "KLMS 페이지에 시각 정보 없음",
                localDownloadedAt: "2026-07-08 16:22 KST"
            ),
            "2026-07-08 16:22 KST"
        )
        XCTAssertNil(usableFileTimestampText("KLMS 페이지에 시각 정보 없음"))
    }

    func testNewFilesDoNotAppearAsAttentionMetric() {
        let summary = KLMSMacDashboardSummaryCache(
            visibleCounts: EngineVisibleCounts(newFiles: 3),
            serverFileCount: 12,
            serverDashboardItemsLoaded: true
        )

        let presentation = DashboardSummaryPresentation(snapshot: EngineSnapshot(), summary: summary)

        XCTAssertNil(presentation.attentionMetrics.first { $0.label == "새 파일" })
    }
}
