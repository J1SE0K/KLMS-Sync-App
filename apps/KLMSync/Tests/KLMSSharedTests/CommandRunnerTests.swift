import KLMSShared
import XCTest

final class CommandRunnerTests: XCTestCase {
    func testCommandSurfaceMatchesEngineEntrypoints() {
        XCTAssertEqual(
            KLMSEngineCommand.fullSync.invocation().arguments,
            ["./run_all_full.sh", "./config.env"]
        )
        XCTAssertEqual(
            KLMSEngineCommand.filesSync.invocation(dryRun: true).arguments,
            ["./refresh_course_files.sh", "./config.env", "--dry-run"]
        )
        XCTAssertEqual(
            KLMSEngineCommand.verify.invocation().arguments,
            ["./verify_sync_state.sh", "--json", "./config.env"]
        )
    }

    func testExtractsManualDigitsAndDigitsField() {
        XCTAssertEqual(
            KLMSCommandRunner.extractAuthDigits(from: "KAIST 인증 번호: 42"),
            "42"
        )
        XCTAssertEqual(
            KLMSCommandRunner.extractAuthDigits(from: "status=login digits=07"),
            "07"
        )
        XCTAssertNil(KLMSCommandRunner.extractAuthDigits(from: "no digits"))
    }

    func testAppendsHomebrewPathForGuiLaunches() {
        XCTAssertEqual(
            KLMSCommandRunner.pathWithDeveloperToolLocations("/usr/bin:/bin"),
            "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        )
    }
}
