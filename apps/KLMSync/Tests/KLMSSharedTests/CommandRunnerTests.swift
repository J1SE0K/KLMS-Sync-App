import KLMSShared
import XCTest

final class CommandRunnerTests: XCTestCase {
    func testCommandSurfaceMatchesEngineEntrypoints() {
        XCTAssertEqual(
            KLMSEngineCommand.fullSync.invocation().arguments,
            ["./run_all_full.sh", "./config.env"]
        )
        XCTAssertEqual(
            KLMSEngineCommand.coreSync.invocation().arguments,
            ["./sync_klms_core.sh", "./config.env"]
        )
        XCTAssertEqual(
            KLMSEngineCommand.noticeSync.invocation().arguments,
            ["./sync_klms_notice.sh", "./config.env"]
        )
        XCTAssertEqual(
            KLMSEngineCommand.filesSync.invocation().arguments,
            ["./refresh_course_files.sh", "./config.env"]
        )
        XCTAssertEqual(
            KLMSEngineCommand.fullSync.invocation(dryRun: true).arguments,
            ["./run_all_full.sh", "./config.env", "--dry-run"]
        )
        XCTAssertEqual(
            KLMSEngineCommand.noticeSync.invocation(dryRun: true).arguments,
            ["./sync_klms_notice.sh", "./config.env", "--dry-run"]
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

    func testSyncCommandsRefreshReportAfterRun() {
        XCTAssertTrue(KLMSEngineCommand.fullSync.refreshesSyncReportAfterRun)
        XCTAssertTrue(KLMSEngineCommand.coreSync.refreshesSyncReportAfterRun)
        XCTAssertTrue(KLMSEngineCommand.noticeSync.refreshesSyncReportAfterRun)
        XCTAssertTrue(KLMSEngineCommand.filesSync.refreshesSyncReportAfterRun)
        XCTAssertFalse(KLMSEngineCommand.verify.refreshesSyncReportAfterRun)
        XCTAssertFalse(KLMSEngineCommand.doctor.refreshesSyncReportAfterRun)
        XCTAssertFalse(KLMSEngineCommand.report.refreshesSyncReportAfterRun)
        XCTAssertFalse(KLMSEngineCommand.v2BuildState.refreshesSyncReportAfterRun)
    }

    func testLivePhaseUsesLatestRelevantLineInsteadOfStaleNoticeText() {
        let log = """
        == notice start 2026-05-20 22:22:20 KST ==
        status=ok scope=notice dry_run=0 notice_count=58 new=0 updated=0
        == notice finish 2026-05-20 22:22:22 KST status=0 duration_s=2 ==
        == files start 2026-05-20 22:22:22 KST ==
        [files 2026-05-20 22:22:23 KST] fetch start context=files-seed-pages mode=auto
        """

        XCTAssertEqual(KLMSLiveCommandPhase.currentPhase(in: log), .files)
    }

    func testLivePhaseKeepsCleanupAboveFilesForLatestFileCleanupLine() {
        let log = """
        == files start 2026-05-20 22:22:22 KST ==
        [files 2026-05-20 22:22:52 KST] cleanup start keep_fresh=0 preserve_archive=0 dry_run=0
        """

        XCTAssertEqual(KLMSLiveCommandPhase.currentPhase(in: log), .cleanup)
    }

    func testExtractsManualDigitsAndIgnoresStatusDigitsField() {
        XCTAssertEqual(
            KLMSCommandRunner.extractAuthDigits(from: "KAIST 인증 번호: 42"),
            "42"
        )
        XCTAssertNil(KLMSCommandRunner.extractAuthDigits(from: "status=login digits=07"))
        XCTAssertNil(KLMSCommandRunner.extractAuthDigits(from: "status=timeout last_status=twofactor_digits digits=07"))
        XCTAssertNil(KLMSCommandRunner.extractAuthDigits(from: "no digits"))
    }

    func testExtractsLatestManualAuthDigitsAndIgnoresLoggedPromptDigits() {
        let log = """
        KAIST 인증 번호: 05
        status=timeout last_status=twofactor_digits
        KLMS 로그인이 풀린 것 같아. 다시 로그인해 줘.
        [next run] digits=17
        """

        XCTAssertEqual(KLMSCommandRunner.extractAuthDigits(from: log), "05")
    }

    func testAuthenticatedOutputClearsAuthDigits() {
        let log = """
        KAIST 인증 번호: 85
        휴대폰 인증 화면에서 같은 번호를 선택하면 동기화를 계속 진행해.
        status=ok stage=authenticated
        KLMS 로그인 보조 완료
        """

        XCTAssertTrue(KLMSCommandRunner.outputIndicatesAuthenticated(log))
        XCTAssertNil(KLMSCommandRunner.extractAuthDigits(from: log))
        XCTAssertEqual(KLMSCommandRunner.extractLatestAuthDigits(from: log), "85")
    }

    func testAuthenticatedResultRemembersDigitsWereShown() {
        let result = KLMSCommandResult(
            invocation: KLMSEngineCommand.fullSync.invocation(),
            startedAt: Date(),
            finishedAt: Date(),
            exitCode: 0,
            standardOutput: "KAIST 인증 번호: 85\nstatus=ok stage=authenticated",
            standardError: "KLMS 로그인 보조 완료",
            authDigits: KLMSCommandRunner.extractAuthDigits(from: "KAIST 인증 번호: 85\nstatus=ok stage=authenticated")
        )

        XCTAssertTrue(result.loginAuthenticated)
        XCTAssertTrue(result.authChallengeCompleted)
        XCTAssertTrue(result.sawAuthDigits)
        XCTAssertNil(result.authDigits)
    }

    func testAuthenticatedOutputWithoutAuthDigitsDoesNotCompleteAuthChallenge() {
        let output = "status=ok stage=authenticated\nKLMS 로그인 보조 완료"
        let result = KLMSCommandResult(
            invocation: KLMSEngineCommand.fullSync.invocation(),
            startedAt: Date(),
            finishedAt: Date(),
            exitCode: 0,
            standardOutput: output,
            standardError: "",
            authDigits: KLMSCommandRunner.extractAuthDigits(from: output)
        )

        XCTAssertTrue(result.loginAuthenticated)
        XCTAssertFalse(result.authChallengeCompleted)
        XCTAssertFalse(result.sawAuthDigits)
        XCTAssertNil(result.authDigits)
        XCTAssertFalse(KLMSCommandRunner.outputConfirmsAuthChallengeCompletion(output))
    }

    func testOldAuthenticatedOutputDoesNotHideNewerAuthDigits() {
        let log = """
        status=ok stage=authenticated
        KLMS 로그인 보조 완료
        [later run] KAIST 인증 번호: 32
        status=timeout last_status=twofactor_digits
        """

        XCTAssertTrue(KLMSCommandRunner.outputIndicatesAuthenticated(log))
        XCTAssertFalse(KLMSCommandRunner.outputIndicatesAuthenticatedAfterLatestAuthDigits(log))
        XCTAssertEqual(KLMSCommandRunner.extractAuthDigits(from: log), "32")
    }

    func testAuthenticatedOutputAfterLatestDigitsClearsAuthDigits() {
        let log = """
        KAIST 인증 번호: 32
        status=ok stage=authenticated
        """

        XCTAssertTrue(KLMSCommandRunner.outputIndicatesAuthenticatedAfterLatestAuthDigits(log))
        XCTAssertNil(KLMSCommandRunner.extractAuthDigits(from: log))
    }

    func testStreamsOutputWhileCommandRunsAndExtractsDigits() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("klms-command-runner-stream-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        try "".write(to: directory.appendingPathComponent("config.env"), atomically: true, encoding: .utf8)
        let script = directory.appendingPathComponent("doctor.sh")
        try """
        #!/bin/zsh
        print "start"
        print "KAIST 인증 번호: 42"
        sleep 0.1
        print "done"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let output = StreamingOutputBox()
        let result = try await KLMSCommandRunner().run(
            .doctor,
            paths: KLMSPaths(engineRoot: directory)
        ) { chunk in
            output.append(chunk)
        }

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.authDigits, "42")
        XCTAssertTrue(output.text.contains("start"))
        XCTAssertTrue(output.text.contains("KAIST 인증 번호: 42"))
        XCTAssertTrue(output.text.contains("done"))
    }

    func testPassesAppEnvironmentToEngineCommand() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("klms-command-runner-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        try "".write(to: directory.appendingPathComponent("config.env"), atomically: true, encoding: .utf8)
        let script = directory.appendingPathComponent("doctor.sh")
        try """
        #!/bin/zsh
        print "KLMS_APP_RUN=$KLMS_APP_RUN"
        print "KLMS_SCRIPT_NOTIFICATIONS_ENABLED=$KLMS_SCRIPT_NOTIFICATIONS_ENABLED"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let result = try await KLMSCommandRunner().run(
            .doctor,
            paths: KLMSPaths(engineRoot: directory),
            environment: [
                "KLMS_APP_RUN": "1",
                "KLMS_SCRIPT_NOTIFICATIONS_ENABLED": "0",
            ]
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.standardOutput.contains("KLMS_APP_RUN=1"))
        XCTAssertTrue(result.standardOutput.contains("KLMS_SCRIPT_NOTIFICATIONS_ENABLED=0"))
    }

    func testDefaultsToUtf8LocaleForGuiLaunches() {
        let environment = KLMSCommandRunner.processEnvironmentForLaunch(
            base: ["PATH": "/usr/bin"],
            overrides: [:]
        )

        XCTAssertEqual(environment["LANG"], "ko_KR.UTF-8")
        XCTAssertEqual(environment["LC_ALL"], "ko_KR.UTF-8")
        XCTAssertEqual(environment["LC_CTYPE"], "ko_KR.UTF-8")
        XCTAssertEqual(environment["PYTHONIOENCODING"], "utf-8")
        XCTAssertEqual(environment["PYTHONUTF8"], "1")
        XCTAssertEqual(environment["PYTHONUNBUFFERED"], "1")
    }

    func testNormalizesDecomposedHangulInCommandOutput() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("klms-command-runner-normalize-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        try "".write(to: directory.appendingPathComponent("config.env"), atomically: true, encoding: .utf8)
        let script = directory.appendingPathComponent("doctor.sh")
        let decomposedTitle = "KLMS 공지".decomposedStringWithCanonicalMapping
        try """
        #!/bin/zsh
        print "\(decomposedTitle)"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let output = StreamingOutputBox()
        let result = try await KLMSCommandRunner().run(
            .doctor,
            paths: KLMSPaths(engineRoot: directory)
        ) { chunk in
            output.append(chunk)
        }

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.standardOutput.contains("KLMS 공지"))
        XCTAssertFalse(result.standardOutput.unicodeScalars.contains { (0x1100...0x11FF).contains(Int($0.value)) })
        XCTAssertTrue(output.text.contains("KLMS 공지"))
        XCTAssertFalse(output.text.unicodeScalars.contains { (0x1100...0x11FF).contains(Int($0.value)) })
    }

    func testDecodesLegacyKoreanCommandOutput() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("klms-command-runner-euckr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        try "".write(to: directory.appendingPathComponent("config.env"), atomically: true, encoding: .utf8)
        let script = directory.appendingPathComponent("doctor.sh")
        try """
        #!/bin/zsh
        printf '\\260\\370\\301\\366\\n'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let output = StreamingOutputBox()
        let result = try await KLMSCommandRunner().run(
            .doctor,
            paths: KLMSPaths(engineRoot: directory)
        ) { chunk in
            output.append(chunk)
        }

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.standardOutput.contains("공지"))
        XCTAssertTrue(output.text.contains("공지"))
    }

    func testRepairsCommonMojibakeForDisplay() {
        XCTAssertEqual("ê³µì§€".klmsDisplayText, "공지")
    }

    func testCancelsRunningCommand() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("klms-command-runner-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        try "".write(to: directory.appendingPathComponent("config.env"), atomically: true, encoding: .utf8)
        let script = directory.appendingPathComponent("doctor.sh")
        try """
        #!/bin/zsh
        print "start"
        sleep 30
        print "done"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let runner = KLMSCommandRunner()
        let task = Task {
            try await runner.run(.doctor, paths: KLMSPaths(engineRoot: directory))
        }

        try await Task.sleep(nanoseconds: 200_000_000)
        let requested = await runner.cancelCurrentCommand()
        let result = try await task.value

        XCTAssertTrue(requested)
        XCTAssertTrue(result.wasCancelled)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.standardOutput.contains("start"))
        XCTAssertFalse(result.standardOutput.contains("done"))
    }

    func testAppendsHomebrewPathForGuiLaunches() {
        XCTAssertEqual(
            KLMSCommandRunner.pathWithDeveloperToolLocations("/usr/bin:/bin"),
            "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        )
    }
}

private final class StreamingOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    var text: String {
        lock.lock()
        defer {
            lock.unlock()
        }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
