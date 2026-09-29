import XCTest
@testable import KLMSMac
import KLMSShared

/// 대시보드 파일 목록 규칙: manifest 조회 표, 파일·과제 검색과 필터, 파일 종류 판정.
/// 예전에는 DashboardDataModelTests 가 DashboardDetailView.swift 에 같은 코드 줄이 적혀 있는지를 문자열로 확인했다.
final class DashboardFileRulesTests: XCTestCase {
    // MARK: - manifest 조회

    func testManifestLookupSkipsEmptyKeysAndKeepsLastDuplicate() {
        let first = CourseFileManifestEntry(
            filename: "a.pdf",
            relativePath: "알고리즘/a.pdf",
            url: "https://klms.kaist.ac.kr/file-a",
            course: "알고리즘"
        )
        let urlOnly = CourseFileManifestEntry(filename: "b.pdf", url: "https://klms.kaist.ac.kr/file-b", course: "자료구조")
        let pathOnly = CourseFileManifestEntry(filename: "c.pdf", relativePath: "운영체제/c.pdf", course: "운영체제")
        let duplicate = CourseFileManifestEntry(
            filename: "a2.pdf",
            relativePath: "알고리즘/a.pdf",
            url: "https://klms.kaist.ac.kr/file-a",
            course: "알고리즘 재수강"
        )

        let lookup = DashboardCourseManifestLookup([first, urlOnly, pathOnly, duplicate])

        XCTAssertEqual(Set(lookup.byURL.keys), ["https://klms.kaist.ac.kr/file-a", "https://klms.kaist.ac.kr/file-b"])
        XCTAssertEqual(Set(lookup.byRelativePath.keys), ["알고리즘/a.pdf", "운영체제/c.pdf"])
        XCTAssertNil(lookup.byURL[""])
        XCTAssertNil(lookup.byRelativePath[""])
        XCTAssertEqual(lookup.byURL["https://klms.kaist.ac.kr/file-a"], duplicate)
        XCTAssertEqual(lookup.byRelativePath["알고리즘/a.pdf"], duplicate)
        XCTAssertEqual(lookup.byURL["https://klms.kaist.ac.kr/file-b"], urlOnly)
        XCTAssertEqual(lookup.byRelativePath["운영체제/c.pdf"], pathOnly)
    }

    func testManifestLookupTableMatchesStruct() {
        let entry = CourseFileManifestEntry(filename: "a.pdf", relativePath: "x/a.pdf", url: "u-a", course: "과목")
        let table = DashboardCourseManifestLookup.table([entry])

        XCTAssertEqual(table.byURL, ["u-a": entry])
        XCTAssertEqual(table.byRelativePath, ["x/a.pdf": entry])
        XCTAssertTrue(DashboardCourseManifestLookup.table([]).byURL.isEmpty)
        XCTAssertTrue(DashboardCourseManifestLookup.table([]).byRelativePath.isEmpty)
    }

    // MARK: - 과제·시험 항목 검색

    func testStateItemSearchAcceptsEmptyQueryAndSearchedFields() {
        let item = StateItem(
            url: "https://klms.kaist.ac.kr/mod/assign/view.php?id=77",
            course: "Algorithms",
            title: "Homework 1",
            due: "마감 금요일",
            submission: "제출완료",
            location: "E3-1 1501",
            coverageSummary: "1-3장"
        )

        XCTAssertTrue(DashboardListFilterRules.stateItemSearchMatches(item, query: ""))
        XCTAssertTrue(DashboardListFilterRules.stateItemSearchMatches(item, query: "homework"))
        XCTAssertTrue(DashboardListFilterRules.stateItemSearchMatches(item, query: "ALGORITHMS"))
        XCTAssertTrue(DashboardListFilterRules.stateItemSearchMatches(item, query: "금요일"))
        XCTAssertTrue(DashboardListFilterRules.stateItemSearchMatches(item, query: "e3-1"))
        XCTAssertTrue(DashboardListFilterRules.stateItemSearchMatches(item, query: "1-3장"))
        XCTAssertTrue(DashboardListFilterRules.stateItemSearchMatches(item, query: "id=77"))
        // submission 은 검색 대상이 아니다.
        XCTAssertFalse(DashboardListFilterRules.stateItemSearchMatches(item, query: "제출완료"))
        XCTAssertFalse(DashboardListFilterRules.stateItemSearchMatches(item, query: "기말"))
    }

    func testStateItemSearchMatchesAcademicTermName() {
        // due 의 2026-03 은 2026년 봄학기로 추정된다. "봄학기" 는 어느 필드에도 직접 적혀 있지 않다.
        let item = StateItem(course: "Algorithms", title: "Homework 1", due: "2026-03-10 23:59")

        XCTAssertEqual(item.academicTerm, AcademicTerm(year: 2026, semester: .spring))
        XCTAssertTrue(DashboardListFilterRules.stateItemSearchMatches(item, query: "봄학기"))
        XCTAssertFalse(DashboardListFilterRules.stateItemSearchMatches(item, query: "가을학기"))
    }

    // MARK: - 파일 항목 검색·필터

    func testFileSearchBlobJoinsFieldsWithSingleSpaces() {
        XCTAssertEqual(
            DashboardListFilterRules.fileSearchBlob(
                academicTerm: AcademicTerm(year: 2026, semester: .spring),
                title: "a",
                course: "b",
                path: "c",
                url: "d",
                sourceURL: "e"
            ),
            "2026년 봄학기 a b c d e"
        )
        XCTAssertEqual(
            DashboardListFilterRules.fileSearchBlob(academicTerm: nil, title: "a", course: "b", path: "c", url: "d", sourceURL: ""),
            " a b c d "
        )
    }

    /// 기본 필터(모두 끔, 전체 연도·학기·과목, 빈 검색어)에서 한 조건만 바꿔 부른다.
    /// "전체" 는 DashboardCourseFilter.all, "전체 연도"·"전체 학기"·"학기 미확인" 은 DashboardTermFilter 의 값이다.
    private func fileMatches(
        isHidden: Bool = false,
        isRecent: Bool = false,
        academicTerm: AcademicTerm? = AcademicTerm(year: 2026, semester: .spring),
        course: String = "알고리즘",
        searchBlob: String = "2026년 봄학기 Lecture01 알고리즘 /tmp/Lecture01.pdf",
        showHidden: Bool = false,
        hiddenOnly: Bool = false,
        newOnly: Bool = false,
        recentOnly: Bool = false,
        selectedYear: String = "전체 연도",
        selectedSemester: String = "전체 학기",
        selectedCourse: String = "전체",
        query: String = ""
    ) -> Bool {
        DashboardListFilterRules.fileMatches(
            isHidden: isHidden,
            isRecent: isRecent,
            academicTerm: academicTerm,
            course: course,
            searchBlob: searchBlob,
            showHidden: showHidden,
            hiddenOnly: hiddenOnly,
            newOnly: newOnly,
            recentOnly: recentOnly,
            selectedYear: selectedYear,
            selectedSemester: selectedSemester,
            selectedCourse: selectedCourse,
            normalizedQuery: query
        )
    }

    func testFileFilterDefaultsPassVisibleFile() {
        XCTAssertEqual(DashboardTermFilter.allYears, "전체 연도")
        XCTAssertEqual(DashboardTermFilter.allSemesters, "전체 학기")
        XCTAssertEqual(DashboardTermFilter.unknown, "학기 미확인")
        XCTAssertTrue(fileMatches())
    }

    func testFileFilterHiddenRules() {
        XCTAssertFalse(fileMatches(isHidden: true))
        XCTAssertTrue(fileMatches(isHidden: true, showHidden: true))
        XCTAssertFalse(fileMatches(isHidden: false, hiddenOnly: true))
        XCTAssertTrue(fileMatches(isHidden: true, showHidden: true, hiddenOnly: true))
        // hiddenOnly 만 켜고 showHidden 을 끄면 숨긴 파일도 첫 조건에서 빠진다.
        XCTAssertFalse(fileMatches(isHidden: true, hiddenOnly: true))
    }

    func testFileFilterNewAndRecentRequireRecentFile() {
        XCTAssertFalse(fileMatches(isRecent: false, newOnly: true))
        XCTAssertFalse(fileMatches(isRecent: false, recentOnly: true))
        XCTAssertTrue(fileMatches(isRecent: true, newOnly: true))
        XCTAssertTrue(fileMatches(isRecent: true, recentOnly: true))
        XCTAssertTrue(fileMatches(isRecent: true, newOnly: true, recentOnly: true))
    }

    func testFileFilterTermAndCourse() {
        XCTAssertTrue(fileMatches(selectedYear: "2026"))
        XCTAssertFalse(fileMatches(selectedYear: "2025"))
        XCTAssertTrue(fileMatches(selectedSemester: "봄학기"))
        XCTAssertFalse(fileMatches(selectedSemester: "가을학기"))
        XCTAssertFalse(fileMatches(selectedSemester: "학기 미확인"))
        XCTAssertTrue(fileMatches(academicTerm: nil, selectedSemester: "학기 미확인"))
        XCTAssertFalse(fileMatches(academicTerm: nil, selectedYear: "2026"))

        XCTAssertTrue(fileMatches(course: "알고리즘", selectedCourse: "알고리즘"))
        XCTAssertFalse(fileMatches(course: "자료구조", selectedCourse: "알고리즘"))
        XCTAssertTrue(fileMatches(course: "자료구조", selectedCourse: "전체"))
    }

    func testFileFilterSearchUsesSearchBlobCaseInsensitively() {
        XCTAssertTrue(fileMatches(query: ""))
        XCTAssertTrue(fileMatches(query: "lecture01"))
        XCTAssertTrue(fileMatches(query: "봄학기"))
        XCTAssertFalse(fileMatches(query: "기말"))
        // 검색어가 맞아도 앞선 조건에서 빠지면 통과하지 못한다.
        XCTAssertFalse(fileMatches(isHidden: true, query: "lecture01"))
    }

    // MARK: - 파일 종류 판정

    func testFileKindFixedBuckets() {
        XCTAssertEqual(DashboardFileKind(bucket: "assignment-attachments"), .assignmentAttachment)
        XCTAssertEqual(DashboardFileKind(bucket: "resources"), .resource)
        XCTAssertEqual(DashboardFileKind(bucket: "  resources \n"), .resource)
        XCTAssertEqual(DashboardFileKind(bucket: "folders"), .folder)
        XCTAssertEqual(DashboardFileKind(bucket: "page-attachments"), .pageAttachment)
        XCTAssertEqual(DashboardFileKind(bucket: "quarantine"), .quarantine)
        XCTAssertEqual(DashboardFileKind(bucket: "deleted"), .deleted)
        // 고정 bucket 은 제목에 과제·시험 신호가 있어도 바뀌지 않는다.
        XCTAssertEqual(DashboardFileKind(bucket: "resources", title: "HW1 midterm"), .resource)
    }

    func testFileKindBoardAttachmentsUseTitleSignals() {
        XCTAssertEqual(DashboardFileKind(bucket: "board-attachments", title: "HW3 안내.pdf"), .boardAssignmentAttachment)
        XCTAssertEqual(DashboardFileKind(bucket: "board-attachments", title: "Midterm 공지"), .boardExamAttachment)
        XCTAssertEqual(DashboardFileKind(bucket: "board-attachments", title: "강의 일정 공지"), .boardAttachment)
        // 과제 신호와 시험 신호가 함께 있으면 과제가 먼저다.
        XCTAssertEqual(DashboardFileKind(bucket: "board-attachments", title: "HW1 quiz"), .boardAssignmentAttachment)
    }

    func testFileKindEmptyBucketUsesTitlePathAndURL() {
        XCTAssertEqual(DashboardFileKind(bucket: "", title: "Written Assignment 2"), .assignmentRelated)
        XCTAssertEqual(DashboardFileKind(bucket: "", title: "Quiz 1"), .examRelated)
        XCTAssertEqual(DashboardFileKind(bucket: "", title: "Lecture01"), .other)
        XCTAssertEqual(DashboardFileKind(bucket: "", path: "과제/보고서.pdf"), .assignmentRelated)
        XCTAssertEqual(DashboardFileKind(bucket: "", url: "https://klms.kaist.ac.kr/mod/quiz/view.php"), .examRelated)
        XCTAssertEqual(DashboardFileKind(bucket: "", sourceURL: "https://example.com/homework"), .assignmentRelated)
        // 시험 신호는 부분 문자열로 찾아서 "latest" 안의 "test" 도 잡힌다.
        XCTAssertEqual(DashboardFileKind(bucket: "", title: "latest notes"), .examRelated)
    }

    func testFileKindTokenPrefixNeedsDigitsOnlySuffix() {
        XCTAssertEqual(DashboardFileKind(bucket: "", title: "PA2"), .assignmentRelated)
        XCTAssertEqual(DashboardFileKind(bucket: "", title: "wa"), .assignmentRelated)
        XCTAssertEqual(DashboardFileKind(bucket: "", title: "hw_10"), .assignmentRelated)
        XCTAssertEqual(DashboardFileKind(bucket: "", title: "pagination"), .other)
        XCTAssertEqual(DashboardFileKind(bucket: "", title: "hw3a"), .other)
    }

    func testFileKindUnknownBucketKeepsOriginalText() {
        XCTAssertEqual(DashboardFileKind(bucket: " custom "), .unknownBucket(" custom "))
        XCTAssertEqual(DashboardFileKind(bucket: " custom ").label, " custom ")
        XCTAssertEqual(DashboardFileKind(bucket: " custom ").icon, "doc")
    }

    func testFileKindLabelsAndIcons() {
        let expected: [(DashboardFileKind, String, String)] = [
            (.boardAssignmentAttachment, "과제 공지 첨부", "checklist"),
            (.boardExamAttachment, "시험/퀴즈 공지 첨부", "calendar.badge.clock"),
            (.boardAttachment, "공지 첨부", "megaphone"),
            (.assignmentAttachment, "과제 첨부", "checklist"),
            (.resource, "강의 자료", "books.vertical"),
            (.folder, "폴더 자료", "folder"),
            (.pageAttachment, "페이지 첨부", "doc"),
            (.quarantine, "격리", "exclamationmark.triangle"),
            (.deleted, "삭제 기록", "trash"),
            (.assignmentRelated, "과제 관련", "checklist"),
            (.examRelated, "시험/퀴즈", "calendar.badge.clock"),
            (.other, "기타 파일", "doc"),
        ]
        for (kind, label, icon) in expected {
            XCTAssertEqual(kind.label, label, "\(kind)")
            XCTAssertEqual(kind.icon, icon, "\(kind)")
        }
    }
}
